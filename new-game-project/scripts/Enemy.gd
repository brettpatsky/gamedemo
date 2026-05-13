# =============================================================================
# Enemy.gd  (FIXED)
# Fix 1: CollisionShape2D.disabled now uses set_deferred() — Godot forbids
#         changing physics state mid-frame during a collision callback.
# Fix 2: Same pattern applied to DetectionArea's child CollisionShape2D.
# =============================================================================
extends CharacterBody2D

@export var move_speed:   float = 105.0
@export var max_health:   int   = 2
@export var sight_range:  float = 480.0
@export var attack_range: float = 280.0
@export var score_value:  int   = 10
@export var aim_jitter:   float = 0.22  # radians of random spread per shot
@export var bullet_speed:    float = 500.0
# Enemy bullet range is intentionally capped below every soldier weapon range
# (smallest squad range is soldier_2's pistol at 350) so the squad always
# out-ranges the enemy.
@export var bullet_distance: float = 300.0
@export var bullet_damage:   int   = 1

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

const PATROL_INTERVAL    := 3.0
const SHOOT_COOLDOWN     := 0.45
const TARGET_SCAN_PERIOD := 0.4   # seconds between active soldier searches

const WATER_SPEED_MULT := 0.4

var _scan_timer: float = 0.0

func _ready() -> void:
	add_to_group("enemies")
	_health              = max_health
	health_bar.max_value = max_health
	health_bar.value     = _health

	if bullet_scene == null:
		bullet_scene = load("res://scenes/bullet.tscn")

	detection.body_entered.connect(_on_body_entered_detection)
	detection.body_exited.connect(_on_body_exited_detection)
	# Soldiers are on collision layer 2; detection area must include it.
	detection.set_collision_mask_value(2, true)

	await get_tree().physics_frame
	_set_new_patrol_dest()

func _physics_process(delta: float) -> void:
	_shoot_cooldown = max(_shoot_cooldown - delta, 0.0)
	_scan_timer     = max(_scan_timer     - delta, 0.0)

	# Periodically actively look for soldiers within sight_range. This lets
	# enemies engage from much farther than the DetectionArea radius would
	# allow, and re-acquire a target if one slipped away unnoticed.
	if _scan_timer <= 0.0 and _state != State.DEAD:
		_scan_timer = TARGET_SCAN_PERIOD
		_acquire_target()

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

func _tick_alert(_delta: float) -> void:
	if not _is_target_engageable():
		_target = null
		_state = State.PATROL
		return
	var dist: float = global_position.distance_to(_target.global_position)
	if dist <= attack_range:
		_state = State.ATTACK
		return
	# Close the distance while opportunistically shooting if roughly in range.
	nav_agent.target_position = _target.global_position
	_move_toward_nav_target()
	if dist <= attack_range * 1.4 and _shoot_cooldown <= 0.0:
		var dir: Vector2 = (_target.global_position - global_position).normalized()
		_fire(dir)
		_shoot_cooldown = SHOOT_COOLDOWN

func _tick_attack(_delta: float) -> void:
	if not _is_target_engageable():
		_target = null
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

# Active soldier search — picks the closest live soldier within sight_range.
# Runs at TARGET_SCAN_PERIOD so the enemy can engage well before the
# physics-based DetectionArea would notice an approach.
func _acquire_target() -> void:
	var best: Node2D = null
	var best_d := sight_range
	for s in get_tree().get_nodes_in_group("soldiers"):
		if not _is_soldier_engageable(s):
			continue
		var d: float = (s as Node2D).global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best   = s
	if best != null:
		_target = best
		if _state == State.PATROL:
			_state = State.ALERT

# Downed soldiers are still in the "soldiers" group (they remain on the field
# so they can be revived), but enemies must not target them.
func _is_soldier_engageable(s: Node) -> bool:
	if not is_instance_valid(s):
		return false
	if s.has_method("is_downed") and s.is_downed():
		return false
	return true

func _is_target_engageable() -> bool:
	return _is_soldier_engageable(_target)

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
	_play_walk_anim(dir)

func _play_walk_anim(direction: Vector2) -> void:
	if abs(direction.y) > abs(direction.x):
		sprite.flip_h = false
		_play_anim("walk_up" if direction.y < 0 else "walk_down")
	else:
		sprite.flip_h = direction.x < 0
		_play_anim("walk_side")

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
	# Apply a small random spread so enemies miss occasionally instead of
	# laser-aiming every shot.
	var spread := randf_range(-aim_jitter, aim_jitter)
	var aim    := direction.rotated(spread)
	var b: Node2D = bullet_scene.instantiate()
	get_viewport().add_child(b)
	b.global_position = global_position
	b.initialise(aim, self)
	# Cap travel distance so enemy weapons are strictly out-ranged by the squad.
	if b.has_method("set_stats"):
		b.set_stats(bullet_damage, bullet_speed, bullet_distance, Color.ORANGE_RED)

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

	# Fade out over 2 seconds before removing from scene
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 2.0)
	await tween.finished
	queue_free()

# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_body_entered_detection(body: Node2D) -> void:
	if body.is_in_group("soldiers") and _state != State.DEAD:
		if not _is_soldier_engageable(body):
			return
		_target = body
		_state  = State.ALERT

func _on_body_exited_detection(body: Node2D) -> void:
	if body == _target:
		_target = null
		if _state != State.DEAD:
			_state = State.PATROL
