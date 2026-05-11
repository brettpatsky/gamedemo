extends CharacterBody2D

@export var is_female: bool = false
@export var move_speed: float = 157.5
@export var max_health: int = 3

@export var male_frames:   SpriteFrames
@export var female_frames: SpriteFrames

@export var bullet_scene: PackedScene

@onready var nav_agent:  NavigationAgent2D    = $NavigationAgent2D
@onready var sprite:     AnimatedSprite2D     = $AnimatedSprite2D
@onready var health_bar: ProgressBar          = $HealthBar
@onready var footstep:   AudioStreamPlayer2D  = $FootstepAudio

# ---------------------------------------------------------------------------
# Weapon system
# ---------------------------------------------------------------------------
enum WeaponType { PISTOL, AUTO, GRENADE, SACRIFICE }
const WEAPON_NAMES := ["Pistol", "Auto", "Grenade", "Sacrifice"]
const WEAPON_COUNT := 4

const _GRENADE_SCRIPT = preload("res://scripts/Grenade.gd")

var _weapon: WeaponType = WeaponType.PISTOL

# Ammo limits — pistol has unlimited ammo, sacrifice is limited by squad size
const RIFLE_AMMO_MAX   := 90
const GRENADE_AMMO_MAX := 5
var _rifle_ammo:   int = RIFLE_AMMO_MAX
var _grenade_ammo: int = GRENADE_AMMO_MAX

func cycle_weapon() -> void:
	_weapon = (_weapon + 1) % WEAPON_COUNT as WeaponType

func set_weapon(idx: int) -> void:
	if idx >= 0 and idx < WEAPON_COUNT:
		_weapon = idx as WeaponType

func get_weapon() -> WeaponType:
	return _weapon

func get_rifle_ammo() -> int:
	return _rifle_ammo

func get_grenade_ammo() -> int:
	return _grenade_ammo

# Returns true for the weapon that fires continuously while the button is held.
func is_continuous_fire() -> bool:
	return _weapon == WeaponType.AUTO

# ---------------------------------------------------------------------------
# Squad group membership (set by SquadController)
# ---------------------------------------------------------------------------
var group_id: int = 0

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------
enum State { IDLE, MOVING, SHOOTING, BOMB, DEAD }
var _state: State = State.IDLE

var _health: int
var _move_target: Vector2 = Vector2.ZERO
var _fire_target: Vector2 = Vector2.ZERO   # exact click (used by grenades)
var _bullet_aim:  Vector2 = Vector2.ZERO   # extended aim point for rifle/pistol direction
var _shoot_cooldown:    float = 0.0
var _shoot_flash_timer: float = 0.0

const SHOOT_FLASH_DURATION  := 0.18
const SHOOT_COOLDOWN_PISTOL := 0.5
const SHOOT_COOLDOWN_AUTO   := 0.12   # fast burst fire
const GRENADE_COOLDOWN_SEC  := 2.0
const ARRIVAL_THRESHOLD     := 8.0
const WATER_SPEED_MULT      := 0.4

# Walking-bomb (SACRIFICE) tunables — soldier sprints toward target then detonates.
const BOMB_SPEED_MULT     := 1.6     # multiplier applied to move_speed while armed
const BOMB_RADIUS         := 200.0   # explosion damage radius (px)
const BOMB_DAMAGE         := 15      # huge damage — instakill most things
const BOMB_ARRIVAL_DIST   := 24.0    # px from target to trigger detonation
const BOMB_FX_TIME        := 0.35    # explosion visual lifetime (sec)
var _bomb_target: Vector2 = Vector2.ZERO

# Stuck detection — if the soldier barely moves for STUCK_CHECK_INTERVAL seconds
# while in MOVING state, nudge them to escape corners of rocks/trees.
const STUCK_CHECK_INTERVAL := 1.5
const STUCK_THRESHOLD      := 10.0   # pixels
var _stuck_timer:     float   = STUCK_CHECK_INTERVAL
var _stuck_check_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	_health = max_health

	if is_female and female_frames:
		sprite.sprite_frames = female_frames
	elif male_frames:
		sprite.sprite_frames = male_frames

	health_bar.max_value = max_health
	health_bar.value     = _health

	_play_anim("idle")

	# Tighter arrival tolerance so soldiers don't overshoot and circle back.
	nav_agent.path_desired_distance  = 4.0
	nav_agent.target_desired_distance = 12.0

	# Soldiers live on layer 2; their mask only covers layer 1 (environment/tilemap).
	# This lets soldiers pass through each other instead of physically blocking,
	# which was causing groups to lock up when they occupied the same space.
	collision_layer = 2
	collision_mask  = 1

	await get_tree().physics_frame

func _physics_process(delta: float) -> void:
	_shoot_cooldown    = max(_shoot_cooldown    - delta, 0.0)
	_shoot_flash_timer = max(_shoot_flash_timer - delta, 0.0)

	match _state:
		State.MOVING:
			_do_move(delta)
		State.SHOOTING:
			_do_shoot()
			_state = State.MOVING if not nav_agent.is_navigation_finished() else State.IDLE
		State.BOMB:
			_do_bomb_charge(delta)
		State.IDLE:
			velocity = Vector2.ZERO
			move_and_slide()
			if _shoot_flash_timer <= 0.0:
				_play_anim("idle")
		State.DEAD:
			pass

# =============================================================================
# PUBLIC API
# =============================================================================

func move_to(destination: Vector2) -> void:
	if _state == State.DEAD or _state == State.BOMB:
		return
	_move_target = destination
	nav_agent.target_position = destination
	_stuck_timer     = STUCK_CHECK_INTERVAL
	_stuck_check_pos = global_position
	_state = State.MOVING

func halt() -> void:
	if _state == State.DEAD or _state == State.BOMB:
		return
	nav_agent.target_position = global_position
	velocity = Vector2.ZERO
	_state = State.IDLE

func fire_at(target: Vector2, bullet_aim: Vector2 = Vector2.ZERO) -> void:
	if _state == State.DEAD or _state == State.BOMB:
		return
	_fire_target = target
	_bullet_aim  = bullet_aim if bullet_aim != Vector2.ZERO else target
	match _weapon:
		WeaponType.PISTOL, WeaponType.AUTO:
			_state = State.SHOOTING
		WeaponType.GRENADE:
			_throw_grenade(target)
		WeaponType.SACRIFICE:
			# Designation handled at squad level (closest soldier becomes the bomb).
			pass

# Switch this soldier into walking-bomb mode: sprint toward target, detonate on
# arrival OR on death. Called by SquadController for the SACRIFICE weapon.
func arm_as_bomb(target: Vector2) -> void:
	if _state == State.DEAD or _state == State.BOMB:
		return
	_bomb_target = target
	nav_agent.target_position = target
	_state = State.BOMB
	# Tint the sprite red so it's visually obvious this soldier is armed.
	sprite.modulate = Color(1.0, 0.4, 0.4)
	footstep.play()

func take_damage(amount: int) -> void:
	if _state == State.DEAD:
		return
	_health -= amount
	health_bar.value = _health
	if _health <= 0:
		if _state == State.BOMB:
			# Detonate where we fell rather than dying quietly.
			_explode()
			return
		_die()

# =============================================================================
# PRIVATE — STATE BEHAVIOURS
# =============================================================================

func _do_move(delta: float) -> void:
	if nav_agent.is_navigation_finished():
		_state = State.IDLE
		_play_anim("idle")
		footstep.stop()
		return

	# Stuck detection: if we haven't moved STUCK_THRESHOLD pixels in the last
	# STUCK_CHECK_INTERVAL seconds, nudge and re-path to escape rocks/trees.
	_stuck_timer -= delta
	if _stuck_timer <= 0.0:
		_stuck_timer = STUCK_CHECK_INTERVAL
		if global_position.distance_to(_stuck_check_pos) < STUCK_THRESHOLD:
			_try_unstick()
		_stuck_check_pos = global_position

	var next_pos:  Vector2 = nav_agent.get_next_path_position()
	var direction: Vector2 = (next_pos - global_position).normalized()

	velocity = direction * move_speed * _water_speed_mult()
	move_and_slide()

	if _shoot_flash_timer <= 0.0:
		_play_walk_anim(direction)

	if not footstep.playing:
		footstep.play()

func _try_unstick() -> void:
	# Re-path to a jittered version of the target so the nav mesh finds an
	# alternate route around the obstacle without teleporting the body.
	var nudge := Vector2(randf_range(-24.0, 24.0), randf_range(-24.0, 24.0))
	nav_agent.target_position = _move_target + nudge

func _do_bomb_charge(_delta: float) -> void:
	# Sprint directly toward the bomb target. On arrival OR if killed in transit
	# (handled in take_damage), detonate.
	if global_position.distance_to(_bomb_target) <= BOMB_ARRIVAL_DIST:
		_explode()
		return

	if nav_agent.is_navigation_finished():
		_explode()
		return

	var next_pos:  Vector2 = nav_agent.get_next_path_position()
	var direction: Vector2 = (next_pos - global_position).normalized()
	velocity = direction * move_speed * BOMB_SPEED_MULT * _water_speed_mult()
	move_and_slide()
	_play_walk_anim(direction)

func _explode() -> void:
	# Splash damage to everything in range (enemies + structures; no soldier FF).
	var origin := global_position
	for group in ["enemies", "structures", "soldiers"]:
		for target in get_tree().get_nodes_in_group(group):
			if target == self:
				continue
			if target.is_in_group("soldiers"):
				continue  # no friendly fire on remaining squad
			if not target.has_method("take_damage"):
				continue
			if (target as Node2D).global_position.distance_to(origin) <= BOMB_RADIUS:
				target.take_damage(BOMB_DAMAGE)

	# Visual explosion: spawn a temporary Node2D that draws the blast circle.
	var fx := Node2D.new()
	fx.set_script(preload("res://scripts/BombExplosionFX.gd"))
	get_tree().current_scene.add_child(fx)
	fx.global_position = origin
	fx.start(BOMB_RADIUS, BOMB_FX_TIME)

	# The soldier dies in the blast.
	_health = 0
	health_bar.value = 0
	_die()

func _do_shoot() -> void:
	if _shoot_cooldown > 0.0:
		return

	match _weapon:
		WeaponType.AUTO:
			if _rifle_ammo <= 0:
				# Out of rifle ammo — fall back to pistol
				_weapon = WeaponType.PISTOL
				return
			_rifle_ammo      -= 1
			_shoot_cooldown   = SHOOT_COOLDOWN_AUTO
		WeaponType.PISTOL:
			_shoot_cooldown   = SHOOT_COOLDOWN_PISTOL
		_:
			return

	var dir: Vector2 = (_bullet_aim - global_position).normalized()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0

	_play_anim("shoot")
	_shoot_flash_timer = SHOOT_FLASH_DURATION

	if bullet_scene:
		var bullet: Node2D = bullet_scene.instantiate()
		get_viewport().add_child(bullet)
		bullet.global_position = global_position
		bullet.initialise(dir, self)

func _throw_grenade(target: Vector2) -> void:
	if _shoot_cooldown > 0.0:
		return
	if _grenade_ammo <= 0:
		# Out of grenades — fall back to pistol
		_weapon = WeaponType.PISTOL
		return
	_grenade_ammo   -= 1
	_shoot_cooldown  = GRENADE_COOLDOWN_SEC

	var dir: Vector2 = (target - global_position).normalized()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0
	_play_anim("shoot")
	_shoot_flash_timer = SHOOT_FLASH_DURATION

	var grenade   := Node2D.new()
	grenade.set_script(_GRENADE_SCRIPT)
	var spawn_pos := global_position
	get_viewport().add_child(grenade)
	grenade.global_position = spawn_pos
	grenade.initialise(spawn_pos, target, self)

# ---------------------------------------------------------------------------
# Returns a speed multiplier based on the tile the soldier is standing on.
func _water_speed_mult() -> float:
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	if map_gen and map_gen.has_method("is_water_at") and map_gen.is_water_at(global_position):
		return WATER_SPEED_MULT
	return 1.0

func _die() -> void:
	_state = State.DEAD
	velocity = Vector2.ZERO
	_play_anim("die")
	footstep.stop()

	# set_deferred prevents "can't change state while flushing queries"
	$CollisionShape2D.set_deferred("disabled", true)

	GameManager.on_soldier_died(self)

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

func _play_walk_anim(direction: Vector2) -> void:
	if abs(direction.y) > abs(direction.x):
		sprite.flip_h = false
		_play_anim("walk_up" if direction.y < 0 else "walk_down")
	else:
		sprite.flip_h = direction.x < 0
		_play_anim("walk_side")
