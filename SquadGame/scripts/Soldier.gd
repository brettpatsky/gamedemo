# =============================================================================
# Soldier.gd
# Attach to each Soldier scene (scenes/Soldier.tscn).
#
# SCENE NODE TREE (build this in the Godot editor):
#   Soldier (CharacterBody2D)
#   ├── NavigationAgent2D          ← handles A* pathfinding
#   ├── AnimatedSprite2D           ← cartoon sprite sheets
#   ├── CollisionShape2D           ← capsule/circle for physics
#   ├── HealthBar (ProgressBar)    ← floats above head
#   └── FootstepAudio (AudioStreamPlayer2D)
#
# SPRITE SHEET CONVENTION (cute cartoon style):
#   - Separate AnimatedSprite2D SpriteFrames resource per gender variant.
#   - Animation names: "idle", "walk", "shoot", "die"
#   - Female variant is assigned via is_female export bool (swap SpriteFrames).
# =============================================================================
extends CharacterBody2D

# ---------------------------------------------------------------------------
# Exports — configure each soldier in the Inspector or via code at spawn time
# ---------------------------------------------------------------------------
@export var is_female: bool = false      # swaps sprite sheet for female variant
@export var move_speed: float = 90.0     # pixels per second
@export var max_health: int = 3          # hits before death (cute, low number)

# Sprite frame resources — assign in Inspector or load() at runtime
@export var male_frames:   SpriteFrames  # drag in the male SpriteFrames resource
@export var female_frames: SpriteFrames  # drag in the female SpriteFrames resource

# Bullet scene — assign in Inspector
@export var bullet_scene: PackedScene

# ---------------------------------------------------------------------------
# Node references (resolved at _ready via @onready)
# ---------------------------------------------------------------------------
@onready var nav_agent:  NavigationAgent2D    = $NavigationAgent2D
@onready var sprite:     AnimatedSprite2D     = $AnimatedSprite2D
@onready var health_bar: ProgressBar          = $HealthBar
@onready var footstep:   AudioStreamPlayer2D  = $FootstepAudio

# ---------------------------------------------------------------------------
# State machine enum — keeps animation + logic tightly coupled
# ---------------------------------------------------------------------------
enum State { IDLE, MOVING, SHOOTING, DEAD }
var _state: State = State.IDLE

# ---------------------------------------------------------------------------
# Internal bookkeeping
# ---------------------------------------------------------------------------
var _health: int
var _move_target: Vector2 = Vector2.ZERO
var _fire_target: Vector2 = Vector2.ZERO
var _shoot_cooldown: float = 0.0
const SHOOT_COOLDOWN_SEC := 0.25   # seconds between shots (rapid-fire feel)
const ARRIVAL_THRESHOLD  := 8.0    # pixels; "close enough" to stop navigating

# ---------------------------------------------------------------------------
# _ready — initialise health, pick sprite sheet based on gender
# ---------------------------------------------------------------------------
func _ready() -> void:
	_health = max_health

	# Pick the correct cute cartoon sprite sheet
	if is_female and female_frames:
		sprite.sprite_frames = female_frames
	elif male_frames:
		sprite.sprite_frames = male_frames

	# Sync health bar
	health_bar.max_value = max_health
	health_bar.value     = _health

	_play_anim("idle")

	# NavigationAgent2D in Godot 4 needs one frame before paths are valid
	await get_tree().physics_frame

# ---------------------------------------------------------------------------
# _physics_process — runs every physics tick (default 60 Hz)
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	_shoot_cooldown = max(_shoot_cooldown - delta, 0.0)

	match _state:
		State.MOVING:
			_do_move(delta)
		State.SHOOTING:
			_do_shoot()
			# After shooting, return to moving if we still have a destination
			_state = State.MOVING if nav_agent.is_navigation_finished() == false else State.IDLE
		State.IDLE:
			velocity = Vector2.ZERO
			move_and_slide()
		State.DEAD:
			pass  # physics frozen; animation plays out

# =============================================================================
# PUBLIC API — called by SquadController
# =============================================================================

# Order the soldier to pathfind to a world-space position
func move_to(destination: Vector2) -> void:
	if _state == State.DEAD:
		return
	_move_target = destination
	nav_agent.target_position = destination
	_state = State.MOVING
	_play_anim("walk")

# Order the soldier to fire one projectile toward a world-space position
func fire_at(target: Vector2) -> void:
	if _state == State.DEAD:
		return
	_fire_target = target
	_state = State.SHOOTING

# Called externally (e.g. by an Enemy bullet) to deal damage
func take_damage(amount: int) -> void:
	if _state == State.DEAD:
		return
	_health -= amount
	health_bar.value = _health
	if _health <= 0:
		_die()

# =============================================================================
# PRIVATE — STATE BEHAVIOURS
# =============================================================================

func _do_move(delta: float) -> void:
	# NavigationAgent2D gives us the next waypoint along the baked nav-mesh path
	if nav_agent.is_navigation_finished():
		_state = State.IDLE
		_play_anim("idle")
		footstep.stop()
		return

	var next_pos: Vector2 = nav_agent.get_next_path_position()
	var direction: Vector2 = (next_pos - global_position).normalized()

	velocity = direction * move_speed
	move_and_slide()                # CharacterBody2D built-in; handles collision

	# Flip sprite to face direction of travel (left/right only for 2D top-down)
	if direction.x != 0:
		sprite.flip_h = direction.x < 0

	# Play footstep audio on movement
	if not footstep.playing:
		footstep.play()

func _do_shoot() -> void:
	if _shoot_cooldown > 0.0:
		return

	# Face the target
	var dir: Vector2 = (_fire_target - global_position).normalized()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0

	_play_anim("shoot")

	# Spawn bullet
	if bullet_scene:
		var bullet: Node2D = bullet_scene.instantiate()
		# Add to the scene root so bullet outlives the soldier if needed
		get_tree().current_scene.add_child(bullet)
		bullet.global_position = global_position
		# Bullet.gd expects an initialise(direction, shooter) call
		bullet.initialise(dir, self)

	_shoot_cooldown = SHOOT_COOLDOWN_SEC

func _die() -> void:
	_state = State.DEAD
	velocity = Vector2.ZERO
	_play_anim("die")
	footstep.stop()

	# Disable collision so the corpse doesn't block pathfinding
	$CollisionShape2D.disabled = true

	# Notify the global manager (updates score, checks loss condition)
	GameManager.on_soldier_died(self)

	# Wait for death animation, then queue free
	await sprite.animation_finished
	queue_free()

# =============================================================================
# PRIVATE — ANIMATION HELPER
# =============================================================================

func _play_anim(anim_name: String) -> void:
	# Guard: only switch if the animation is different (prevents restarting mid-loop)
	if sprite.animation != anim_name:
		sprite.play(anim_name)
