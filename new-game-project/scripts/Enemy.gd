# =============================================================================
# Enemy.gd  (FIXED)
# Fix 1: CollisionShape2D.disabled now uses set_deferred() — Godot forbids
#         changing physics state mid-frame during a collision callback.
# Fix 2: Same pattern applied to DetectionArea's child CollisionShape2D.
# =============================================================================
extends CharacterBody2D

@export var move_speed:   float = 55.0
@export var max_health:   int   = 2
@export var sight_range:  float = 200.0
@export var attack_range: float = 120.0
@export var score_value:  int   = 10

@export var bullet_scene: PackedScene

@onready var nav_agent:  NavigationAgent2D   = $NavigationAgent2D
@onready var sprite:     AnimatedSprite2D    = $AnimatedSprite2D
@onready var health_bar: ProgressBar         = $HealthBar
@onready var detection:  Area2D              = $DetectionArea

enum State { PATROL, ALERT, ATTACK, DEAD }
var _state: State = State.PATROL

var _health:           int
var _target:           Node2D = null
var _patrol_timer:     float  = 0.0
var _shoot_cooldown:   float  = 0.0
var _patrol_dest:      Vector2

const PATROL_INTERVAL  := 3.0
const SHOOT_COOLDOWN   := 0.8

const WATER_SPEED_MULT := 0.4

func _ready() -> void:
	add_to_group("enemies")
	_health              = max_health
	health_bar.max_value = max_health
	health_bar.value     = _health

	if bullet_scene == null:
		bullet_scene = load("res://scenes/bullet.tscn")

	detection.body_entered.connect(_on_body_entered_detection)
	detection.body_exited.connect(_on_body_exited_detection)

	await get_tree().physics_frame
	_set_new_patrol_dest()

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

func _tick_alert(_delta: float) -> void:
	if not is_instance_valid(_target):
		_state = State.PATROL
		return
	var dist: float = global_position.distance_to(_target.global_position)
	if dist <= attack_range:
		_state = State.ATTACK
		return
	nav_agent.target_position = _target.global_position
	_move_toward_nav_target()
	_play_anim("patrol")

func _tick_attack(_delta: float) -> void:
	if not is_instance_valid(_target):
		_state = State.PATROL
		return
	velocity = Vector2.ZERO
	move_and_slide()
	var dir: Vector2 = (_target.global_position - global_position).normalized()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0
	_play_anim("shoot")
	if _shoot_cooldown <= 0.0:
		_fire(dir)
		_shoot_cooldown = SHOOT_COOLDOWN
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
	velocity = dir * move_speed * _water_speed_mult()
	move_and_slide()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0

func _water_speed_mult() -> float:
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	if map_gen and map_gen.has_method("is_water_at") and map_gen.is_water_at(global_position):
		return WATER_SPEED_MULT
	return 1.0

func _set_new_patrol_dest() -> void:
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

	# FIX: use set_deferred so Godot applies the change AFTER the physics
	# step finishes — changing collision mid-step causes the flush error.
	$CollisionShape2D.set_deferred("disabled", true)
	$DetectionArea/CollisionShape2D.set_deferred("disabled", true)

	GameManager.add_score(score_value)
	GameManager.on_enemy_died()

	await sprite.animation_finished
	queue_free()

# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_body_entered_detection(body: Node2D) -> void:
	if body.is_in_group("soldiers") and _state != State.DEAD:
		_target = body
		_state  = State.ALERT

func _on_body_exited_detection(body: Node2D) -> void:
	if body == _target:
		_target = null
		if _state != State.DEAD:
			_state = State.PATROL
