# =============================================================================
# Soldier.gd  (FIXED)
# Fix 1: CollisionShape2D.disabled now uses set_deferred() — same physics
#         flush error as Enemy.gd when a bullet hits during a physics step.
# Fix 2: "die" animation is set to loop=false in SpriteFrames, but as a
#         safety net we check animation_finished only when not looping.
# =============================================================================
extends CharacterBody2D

@export var is_female: bool = false
@export var move_speed: float = 90.0
@export var max_health: int = 3

@export var male_frames:   SpriteFrames
@export var female_frames: SpriteFrames

@export var bullet_scene: PackedScene

@onready var nav_agent:  NavigationAgent2D    = $NavigationAgent2D
@onready var sprite:     AnimatedSprite2D     = $AnimatedSprite2D
@onready var health_bar: ProgressBar          = $HealthBar
@onready var footstep:   AudioStreamPlayer2D  = $FootstepAudio

enum State { IDLE, MOVING, SHOOTING, DEAD }
var _state: State = State.IDLE

var _health: int
var _move_target: Vector2 = Vector2.ZERO
var _fire_target: Vector2 = Vector2.ZERO
var _shoot_cooldown: float = 0.0
const SHOOT_COOLDOWN_SEC := 0.25
const ARRIVAL_THRESHOLD  := 8.0

func _ready() -> void:
	_health = max_health

	if is_female and female_frames:
		sprite.sprite_frames = female_frames
	elif male_frames:
		sprite.sprite_frames = male_frames

	health_bar.max_value = max_health
	health_bar.value     = _health

	_play_anim("idle")

	await get_tree().physics_frame

func _physics_process(delta: float) -> void:
	_shoot_cooldown = max(_shoot_cooldown - delta, 0.0)

	match _state:
		State.MOVING:
			_do_move(delta)
		State.SHOOTING:
			_do_shoot()
			_state = State.MOVING if not nav_agent.is_navigation_finished() else State.IDLE
		State.IDLE:
			velocity = Vector2.ZERO
			move_and_slide()
		State.DEAD:
			pass

# =============================================================================
# PUBLIC API
# =============================================================================

func move_to(destination: Vector2) -> void:
	if _state == State.DEAD:
		return
	_move_target = destination
	nav_agent.target_position = destination
	_state = State.MOVING
	_play_anim("walk")

func fire_at(target: Vector2) -> void:
	if _state == State.DEAD:
		return
	_fire_target = target
	_state = State.SHOOTING

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

func _do_move(_delta: float) -> void:
	if nav_agent.is_navigation_finished():
		_state = State.IDLE
		_play_anim("idle")
		footstep.stop()
		return

	var next_pos:  Vector2 = nav_agent.get_next_path_position()
	var direction: Vector2 = (next_pos - global_position).normalized()

	velocity = direction * move_speed
	move_and_slide()

	if direction.x != 0:
		sprite.flip_h = direction.x < 0

	if not footstep.playing:
		footstep.play()

func _do_shoot() -> void:
	if _shoot_cooldown > 0.0:
		return

	var dir: Vector2 = (_fire_target - global_position).normalized()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0

	_play_anim("shoot")

	if bullet_scene:
		var bullet: Node2D = bullet_scene.instantiate()
		get_tree().current_scene.add_child(bullet)
		bullet.global_position = global_position
		bullet.initialise(dir, self)

	_shoot_cooldown = SHOOT_COOLDOWN_SEC

func _die() -> void:
	_state = State.DEAD
	velocity = Vector2.ZERO
	_play_anim("die")
	footstep.stop()

	# FIX: set_deferred prevents "can't change state while flushing queries"
	# which happens when take_damage() is called from a bullet collision callback
	$CollisionShape2D.set_deferred("disabled", true)

	GameManager.on_soldier_died(self)

	# FIX: only await animation_finished if the die anim is not set to loop.
	# If it IS looping in your SpriteFrames, this would wait forever.
	# Safe approach: use a timer as fallback.
	if not sprite.sprite_frames.get_animation_loop("die"):
		await sprite.animation_finished
	else:
		await get_tree().create_timer(1.0).timeout

	queue_free()

# =============================================================================
# PRIVATE — ANIMATION
# =============================================================================

func _play_anim(anim_name: String) -> void:
	if sprite.animation != anim_name:
		sprite.play(anim_name)
