# =============================================================================
# Enemy.gd
# Attach to scenes/Enemy.tscn.
#
# BEHAVIOURS (simple finite state machine):
#   PATROL  → walks between two random waypoints on the nav-mesh.
#   ALERT   → spots a soldier within sight_range; starts moving toward them.
#   ATTACK  → within attack_range; fires at the nearest soldier.
#   DEAD    → plays die animation, awards score, then frees itself.
#
# SCENE NODE TREE:
#   Enemy (CharacterBody2D)
#   ├── NavigationAgent2D
#   ├── AnimatedSprite2D           ← "patrol", "alert", "shoot", "die" anims
#   ├── CollisionShape2D
#   ├── DetectionArea (Area2D)     ← large circle; soldiers trigger "alert"
#   │   └── CollisionShape2D
#   └── HealthBar (ProgressBar)
# =============================================================================
extends CharacterBody2D

# ---------------------------------------------------------------------------
# Exported settings
# ---------------------------------------------------------------------------
@export var move_speed:   float = 55.0
@export var max_health:   int   = 2
@export var sight_range:  float = 200.0   # pixels; when to switch to ALERT
@export var attack_range: float = 120.0   # pixels; when to start shooting
@export var score_value:  int   = 10      # points awarded on kill

@export var bullet_scene: PackedScene     # assign Enemy bullet in Inspector

# ---------------------------------------------------------------------------
# Node references
# ---------------------------------------------------------------------------
@onready var nav_agent:  NavigationAgent2D   = $NavigationAgent2D
@onready var sprite:     AnimatedSprite2D    = $AnimatedSprite2D
@onready var health_bar: ProgressBar         = $HealthBar
@onready var detection:  Area2D              = $DetectionArea

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------
enum State { PATROL, ALERT, ATTACK, DEAD }
var _state: State = State.PATROL

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------
var _health:           int
var _target:           Node2D = null      # the soldier being chased / shot
var _patrol_timer:     float  = 0.0       # time until next patrol waypoint
var _shoot_cooldown:   float  = 0.0
var _patrol_dest:      Vector2

const PATROL_INTERVAL  := 3.0    # seconds between new patrol waypoints
const SHOOT_COOLDOWN   := 0.8    # slower fire-rate than player (fairer)

# ---------------------------------------------------------------------------
func _ready() -> void:
	_health          = max_health
	health_bar.max_value = max_health
	health_bar.value     = _health

	# Listen for soldiers entering/leaving the detection circle
	detection.body_entered.connect(_on_body_entered_detection)
	detection.body_exited.connect(_on_body_exited_detection)

	# Randomise first patrol destination after nav is ready
	await get_tree().physics_frame
	_set_new_patrol_dest()

# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	_shoot_cooldown = max(_shoot_cooldown - delta, 0.0)

	match _state:
		State.PATROL:  _tick_patrol(delta)
		State.ALERT:   _tick_alert(delta)
		State.ATTACK:  _tick_attack(delta)
		State.DEAD:    pass

# =============================================================================
# STATE TICKS
# =============================================================================

func _tick_patrol(delta: float) -> void:
	_patrol_timer -= delta
	if _patrol_timer <= 0.0:
		_set_new_patrol_dest()

	_move_toward_nav_target()
	_play_anim("patrol")

func _tick_alert(delta: float) -> void:
	if not is_instance_valid(_target):
		_state = State.PATROL
		return

	var dist: float = global_position.distance_to(_target.global_position)

	if dist <= attack_range:
		_state = State.ATTACK
		return

	# Chase the soldier
	nav_agent.target_position = _target.global_position
	_move_toward_nav_target()
	_play_anim("patrol")   # reuse walk anim; or add "alert" in your sprite sheet

func _tick_attack(delta: float) -> void:
	if not is_instance_valid(_target):
		_state = State.PATROL
		return

	# Stop moving; face the target
	velocity = Vector2.ZERO
	move_and_slide()

	var dir: Vector2 = (_target.global_position - global_position).normalized()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0
	_play_anim("shoot")

	if _shoot_cooldown <= 0.0:
		_fire(dir)
		_shoot_cooldown = SHOOT_COOLDOWN

	# Re-evaluate range each tick; back to ALERT if soldier retreats
	var dist: float = global_position.distance_to(_target.global_position)
	if dist > attack_range * 1.2:
		_state = State.ALERT

# =============================================================================
# PRIVATE HELPERS
# =============================================================================

func _move_toward_nav_target() -> void:
	if nav_agent.is_navigation_finished():
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var dir:  Vector2 = (next - global_position).normalized()
	velocity = dir * move_speed
	move_and_slide()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0

func _set_new_patrol_dest() -> void:
	# Pick a random nearby point by nudging current position
	var offset := Vector2(randf_range(-150, 150), randf_range(-150, 150))
	_patrol_dest = global_position + offset
	nav_agent.target_position = _patrol_dest
	_patrol_timer = PATROL_INTERVAL

func _fire(direction: Vector2) -> void:
	if bullet_scene == null:
		return
	var b: Node2D = bullet_scene.instantiate()
	get_tree().current_scene.add_child(b)
	b.global_position = global_position
	b.initialise(direction, self)

func _play_anim(anim_name: String) -> void:
	if sprite.animation != anim_name:
		sprite.play(anim_name)

# =============================================================================
# PUBLIC — damage / death
# =============================================================================

func take_damage(amount: int) -> void:
	if _state == State.DEAD:
		return
	_health -= amount
	health_bar.value = _health
	if _health <= 0:
		_die()

func _die() -> void:
	_state = State.DEAD
	velocity = Vector2.ZERO
	_play_anim("die")
	$CollisionShape2D.disabled        = true
	$DetectionArea/CollisionShape2D.disabled = true

	GameManager.add_score(score_value)
	GameManager.on_enemy_died()

	await sprite.animation_finished
	queue_free()

# =============================================================================
# SIGNAL HANDLERS — detection area
# =============================================================================

func _on_body_entered_detection(body: Node2D) -> void:
	# Only react to Soldier nodes (they're in the "soldiers" group)
	if body.is_in_group("soldiers") and _state != State.DEAD:
		_target = body
		_state  = State.ALERT

func _on_body_exited_detection(body: Node2D) -> void:
	if body == _target:
		_target = null
		if _state != State.DEAD:
			_state = State.PATROL
