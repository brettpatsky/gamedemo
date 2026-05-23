extends CharacterBody2D

const Balance = preload("res://scripts/BalanceConfig.gd")

# -----------------------------------------------------------------------------
# Per-scene customisation — only visual / asset selections still live on the
# .tscn. All numeric balance (HP, speed, weapon damage, bullet colour) is
# read from BalanceConfig per-slot tables in _ready().
# -----------------------------------------------------------------------------
@export var is_female:     bool         = false
@export var male_frames:   SpriteFrames
@export var female_frames: SpriteFrames
@export var bullet_scene:  PackedScene

# Maze mode swaps _do_move for SoldierMazeMover.tick — see SoldierMazeMover.gd
# for the rationale. Set by Main.gd on level 4 / 5 soldiers.
@export var maze_mode: bool = false

# -----------------------------------------------------------------------------
# Stat fields — populated from BalanceConfig in _ready() by slot_index, then
# mutated at runtime by FragmentEffects (add_max_health, add_speed_bonus, …).
# Plain vars rather than @exports so the .tscn can't shadow the config.
# -----------------------------------------------------------------------------
var move_speed:      float = 0.0
var max_health:      int   = 0
var pistol_damage:   int   = 0
var pistol_speed:    float = 0.0
var pistol_distance: float = 0.0
var rifle_damage:    int   = 0
var rifle_speed:     float = 0.0
var rifle_distance:  float = 0.0
var bullet_color:    Color = Color.YELLOW

@onready var nav_agent:  NavigationAgent2D    = $NavigationAgent2D
@onready var sprite:     AnimatedSprite2D     = $AnimatedSprite2D
@onready var health_bar: ProgressBar          = $HealthBar
@onready var footstep:   AudioStreamPlayer2D  = $FootstepAudio
@onready var gunshot:    AudioStreamPlayer2D  = $GunShotAudio

# ---------------------------------------------------------------------------
# Weapon system
# ---------------------------------------------------------------------------
enum WeaponType { PISTOL, AUTO, GRENADE, SACRIFICE }
const WEAPON_NAMES := ["Pistol", "Auto", "Grenade", "Sacrifice"]
const WEAPON_COUNT := 4

const _GRENADE_SCRIPT = preload("res://scripts/Grenade.gd")
const _MAZE_MOVER_SCRIPT = preload("res://scripts/SoldierMazeMover.gd")

var _weapon: WeaponType = WeaponType.PISTOL

# Rifle ammo is a shared squad pool in GameManager — see GameManager.rifle_ammo_pool.
# Grenade ammo is still per-soldier since only one soldier throws per order.
var _grenade_ammo: int = 0   # populated from BalanceConfig in _ready()

func cycle_weapon() -> void:
	# Step forward until we land on an enabled weapon. Sacrifice is the only
	# gateable one today (tutorial pre-Puzzle 5); the loop trivially returns
	# on the first iteration when no gates are active.
	for _i in WEAPON_COUNT:
		_weapon = (_weapon + 1) % WEAPON_COUNT as WeaponType
		if _is_weapon_enabled(_weapon):
			return

func set_weapon(idx: int) -> void:
	if idx < 0 or idx >= WEAPON_COUNT:
		return
	var w := idx as WeaponType
	if not _is_weapon_enabled(w):
		return
	_weapon = w

func _is_weapon_enabled(w: WeaponType) -> bool:
	if w == WeaponType.SACRIFICE and not GameManager.sacrifice_enabled:
		return false
	return true

func get_weapon() -> WeaponType:
	return _weapon

func get_rifle_ammo() -> int:
	return GameManager.rifle_ammo_pool

func get_grenade_ammo() -> int:
	return _grenade_ammo

# Per-mission override for grenade stockpile — used by the boss level to hand
# the squad enough potions to break the orbiting Memory Totems.
func set_grenade_ammo(amount: int) -> void:
	_grenade_ammo = maxi(amount, 0)

# Returns true for any weapon that fires continuously while the button is held.
# Pistol and rifle both stream fire — the per-weapon SHOOT_COOLDOWN governs pace.
func is_continuous_fire() -> bool:
	return _weapon == WeaponType.AUTO or _weapon == WeaponType.PISTOL

# ---------------------------------------------------------------------------
# Squad group membership (set by SquadController)
# ---------------------------------------------------------------------------
var group_id:  int  = 0
var is_active: bool = true   # false when this soldier belongs to an inactive group

# Color per group — must match HUD.GROUP_COLORS so labels match buttons.
const GROUP_LABEL_COLORS: Array[Color] = [
	Color(1.0, 0.95, 0.0),   # group 1 — yellow
	Color(0.3,  0.9, 1.0),   # group 2 — cyan
	Color(0.5,  1.0, 0.4),   # group 3 — green
]
var _group_label: Label = null

# Auto-defend — idle-group soldiers fire their pistol when an enemy comes
# within range. Tuning lives in BalanceConfig (SOLDIER_AUTODEFEND_*).
var _autodefend_cooldown: float = 0.0

# Spawn-order slot (0..squad_size-1). Set by Main; used to index per-soldier
# accuracy stats stored in GameManager.
var slot_index: int = -1

# Per-run HP carry-over from RunState. Set by Main BEFORE add_child so that
# _ready can apply it after computing max_health. -1 = use full HP (default).
var _carry_hp_override: int = -1

func set_carried_hp(hp: int) -> void:
	_carry_hp_override = hp

func get_health() -> int:
	return _health

# Element classification (Fire / Ice / Lightning) is fixed by slot — see
# Elements.SLOT_ELEMENTS. Used by _do_shoot to colour-stamp bullets and by
# Enemy.take_damage to apply the soft counter multiplier.
func get_element() -> int:
	return Elements.of_slot(slot_index)

# Public helpers used by FragmentEffects to apply between-mission rewards.
# All three are safe to call right after the soldier has been added to the
# scene tree (_ready has run synchronously up to its first await by then).
func add_max_health(delta: int) -> void:
	max_health += delta
	_health = mini(_health + delta, max_health)
	if health_bar:
		health_bar.max_value = max_health
		health_bar.value     = _health

func heal_to_full() -> void:
	_health = max_health
	if health_bar:
		health_bar.value = _health

func add_grenade_ammo(delta: int) -> void:
	_grenade_ammo = maxi(_grenade_ammo + delta, 0)

func add_speed_bonus(percent: float) -> void:
	move_speed *= (1.0 + percent)
	if nav_agent:
		nav_agent.max_speed = move_speed

# Per-instance bonus state. Reset implicitly each mission because soldiers
# are re-instantiated when Main reloads the scene. FragmentEffects.apply_all
# bumps these in _ready order at mission start.
var damage_bonus:     int   = 0      # +damage on every bullet this kid fires
var range_mult:       float = 1.0    # multiplied into bullet max_distance
var cooldown_mult:    float = 1.0    # multiplied into fire cooldowns (< 1 = faster)
var damage_reduction: int   = 0      # subtracted from incoming damage
var water_immune:     bool  = false  # ignores water speed slowdown

func add_damage_bonus(delta: int) -> void:
	damage_bonus += delta

func add_range_mult(percent: float) -> void:
	range_mult *= (1.0 + percent)

func multiply_cooldown(multiplier: float) -> void:
	cooldown_mult *= multiplier

func add_damage_reduction(delta: int) -> void:
	damage_reduction += delta

func enable_water_immunity() -> void:
	water_immune = true

# Called by Bullet.gd when a bullet fired by this soldier successfully hits
# a damageable target. Bumps the shared accuracy counter.
func on_bullet_hit(_target: Node2D) -> void:
	GameManager.record_hit(slot_index)

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

# Shoot / water / sacrifice / stuck / catch-up tuning all lives in Balance.
# Variables below hold the per-instance state these systems use.
var _bomb_target:     Vector2 = Vector2.ZERO
var _bomb_timer:      float   = 0.0   # detonates in place if path is blocked
var _stuck_timer:     float   = 0.0   # reset from BalanceConfig in _ready/move_to
var _stuck_check_pos: Vector2 = Vector2.ZERO
var _stuck_strikes:   int     = 0     # ≥ HARD_STRIKES → hard-unstick teleport
var _unstick_timer:   float   = 0.0
var _unstick_dir:     Vector2 = Vector2.ZERO

func _ready() -> void:
	# Per-slot stats win when Main has assigned slot_index (every normal
	# mission spawn). Standalone test scenes that drop a soldier without a
	# slot fall back to the squad-wide BalanceConfig defaults.
	if slot_index >= 0 and slot_index < Balance.SOLDIER_MAX_HEALTH_PER_SLOT.size():
		move_speed      = Balance.SOLDIER_MOVE_SPEED_PER_SLOT[slot_index]
		max_health      = Balance.SOLDIER_MAX_HEALTH_PER_SLOT[slot_index]
		pistol_damage   = Balance.SOLDIER_PISTOL_DAMAGE_PER_SLOT[slot_index]
		pistol_speed    = Balance.SOLDIER_PISTOL_SPEED_PER_SLOT[slot_index]
		pistol_distance = Balance.SOLDIER_PISTOL_DISTANCE_PER_SLOT[slot_index]
		rifle_damage    = Balance.SOLDIER_RIFLE_DAMAGE_PER_SLOT[slot_index]
		rifle_speed     = Balance.SOLDIER_RIFLE_SPEED_PER_SLOT[slot_index]
		rifle_distance  = Balance.SOLDIER_RIFLE_DISTANCE_PER_SLOT[slot_index]
		bullet_color    = Balance.SOLDIER_BULLET_COLOR_PER_SLOT[slot_index]
	else:
		move_speed      = Balance.SOLDIER_MOVE_SPEED
		max_health      = Balance.SOLDIER_MAX_HEALTH
		pistol_damage   = Balance.SOLDIER_PISTOL_DAMAGE
		pistol_speed    = Balance.SOLDIER_PISTOL_SPEED
		pistol_distance = Balance.SOLDIER_PISTOL_DISTANCE
		rifle_damage    = Balance.SOLDIER_RIFLE_DAMAGE
		rifle_speed     = Balance.SOLDIER_RIFLE_SPEED
		rifle_distance  = Balance.SOLDIER_RIFLE_DISTANCE
	_grenade_ammo = Balance.SOLDIER_GRENADE_AMMO_MAX
	_health = max_health
	if _carry_hp_override > 0:
		_health = min(_carry_hp_override, max_health)

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
	# Enable RVO avoidance so soldiers steer around static obstacles (trees/rocks)
	# instead of grinding into them. Radius matches soldier collision footprint.
	nav_agent.radius             = 18.0
	nav_agent.avoidance_enabled  = true
	nav_agent.neighbor_distance  = 120.0
	nav_agent.max_neighbors      = 8
	nav_agent.max_speed          = move_speed
	if not nav_agent.velocity_computed.is_connected(_on_safe_velocity):
		nav_agent.velocity_computed.connect(_on_safe_velocity)

	# Maze movement bypasses RVO entirely — corridors are 1 tile wide so
	# avoidance offers nothing but steers the soldier into walls.
	if maze_mode:
		nav_agent.avoidance_enabled = false

	# Soldiers live on layer 2; their mask only covers layer 1 (environment/tilemap).
	# This lets soldiers pass through each other instead of physically blocking,
	# which was causing groups to lock up when they occupied the same space.
	collision_layer = 2
	collision_mask  = 1

	# Floating group-number label — shown above the health bar when the squad
	# is split. Hidden by default; SquadController calls show_group_label().
	_group_label = Label.new()
	_group_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_group_label.position = Vector2(-12, -82)
	_group_label.add_theme_font_size_override("font_size", 14)
	_group_label.hide()
	add_child(_group_label)

	await get_tree().physics_frame

func _physics_process(delta: float) -> void:
	_shoot_cooldown    = max(_shoot_cooldown    - delta, 0.0)
	_shoot_flash_timer = max(_shoot_flash_timer - delta, 0.0)
	_try_autodefend(delta)

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
	_stuck_timer     = Balance.SOLDIER_STUCK_CHECK_INTERVAL
	_stuck_check_pos = global_position
	_stuck_strikes   = 0
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
	# Hard gate — tutorial pre-Puzzle 5 has Sacrifice locked even if a stray
	# fire command somehow reaches here (HUD button is disabled but this is
	# the only path that can actually spend a kid).
	if not GameManager.sacrifice_enabled:
		return
	_bomb_target = target
	_bomb_timer  = Balance.SACRIFICE_TIMEOUT
	nav_agent.target_position = target
	_state = State.BOMB
	# Tint the sprite red so it's visually obvious this soldier is armed.
	sprite.modulate = Color(1.0, 0.4, 0.4)
	footstep.play()

func take_damage(amount: int, _element: int = 0) -> void:
	if _state == State.DEAD:
		return
	if GameManager.god_mode:
		return
	# Snack Bar (fragment) soaks `damage_reduction` HP off each hit, minimum 0
	# so trivial bullets become no-ops rather than negative damage = heal.
	# (Element is accepted for signature compatibility with Bullet._try_hit
	# but soldiers don't have weakness/resistance — friendly fire is rare
	# and the element pattern is intentionally enemy-only for now.)
	var net: int = maxi(amount - damage_reduction, 0)
	if net <= 0:
		return
	_health -= net
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
	if maze_mode:
		if _MAZE_MOVER_SCRIPT.tick(self):
			_state = State.IDLE
			_play_anim("idle")
		return

	if nav_agent.is_navigation_finished():
		_state = State.IDLE
		_play_anim("idle")
		footstep.stop()
		return

	_unstick_timer = max(_unstick_timer - delta, 0.0)

	# Stuck detection: if we haven't moved Balance.SOLDIER_STUCK_THRESHOLD pixels in the last
	# Balance.SOLDIER_STUCK_CHECK_INTERVAL seconds, sidestep to escape corners
	# of rocks/trees. After SOLDIER_STUCK_HARD_STRIKES consecutive failed
	# checks (≈3 s) escalate to a hard-unstick teleport along the planned path.
	_stuck_timer -= delta
	if _stuck_timer <= 0.0:
		_stuck_timer = Balance.SOLDIER_STUCK_CHECK_INTERVAL
		var moved: bool = global_position.distance_to(_stuck_check_pos) >= Balance.SOLDIER_STUCK_THRESHOLD
		if moved:
			_stuck_strikes = 0
		else:
			_stuck_strikes += 1
			if _unstick_timer <= 0.0:
				_try_unstick()
			if _stuck_strikes >= Balance.SOLDIER_STUCK_HARD_STRIKES:
				_hard_unstick()
				_stuck_strikes = 0
		_stuck_check_pos = global_position

	var is_unsticking := _unstick_timer > 0.0
	var speed_mult    := _catchup_speed_mult()

	var next_pos:  Vector2 = nav_agent.get_next_path_position()
	var direction: Vector2 = (next_pos - global_position).normalized()

	# While sidestepping, blend the unstick direction in to escape the obstacle.
	if is_unsticking:
		direction = (direction + _unstick_dir * 1.5).normalized()

	var slope_mult := _slope_speed_mult(direction)
	var desired := direction * move_speed * _water_speed_mult() * slope_mult * speed_mult
	if nav_agent.avoidance_enabled:
		nav_agent.max_speed = move_speed * speed_mult
		nav_agent.set_velocity(desired)
	else:
		velocity = desired
		move_and_slide()

	if _shoot_flash_timer <= 0.0:
		_play_walk_anim(direction)

	if not footstep.playing:
		footstep.play()

func _on_safe_velocity(safe_velocity: Vector2) -> void:
	# Avoidance computes velocities asynchronously — a callback queued during
	# MOVING can fire after the soldier has died or armed as a bomb. Without
	# this guard the corpse keeps drifting from a stale safe-velocity result.
	if _state != State.MOVING:
		return
	velocity = safe_velocity
	move_and_slide()

func _try_unstick() -> void:
	# Pick a perpendicular sidestep direction relative to the current heading.
	# Alternating sign across nudges so we don't keep retrying the same side.
	var heading: Vector2 = (nav_agent.get_next_path_position() - global_position).normalized()
	if heading == Vector2.ZERO:
		heading = (_move_target - global_position).normalized()
	var perp := Vector2(-heading.y, heading.x)
	if randf() < 0.5:
		perp = -perp
	_unstick_dir   = perp
	_unstick_timer = Balance.SOLDIER_UNSTICK_DURATION
	# Also nudge the nav target slightly so the path re-evaluates on the next tick.
	var nudge := perp * 32.0
	nav_agent.target_position = _move_target + nudge

# Final-resort unstick: snap the soldier toward the next waypoint along the
# planned path. Breaks RVO-deadlocks and corner-wedges that the sidestep
# nudge can't escape. Caps the jump at one tile so it reads as "ducking
# around the obstacle" rather than a teleport.
func _hard_unstick() -> void:
	if nav_agent.is_navigation_finished():
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var diff: Vector2 = next - global_position
	if diff.length() < 1.0:
		return
	global_position += diff.normalized() * minf(diff.length(), 64.0)
	_unstick_timer = 0.0   # cancel any in-flight sidestep so we don't double-nudge

func _do_bomb_charge(delta: float) -> void:
	# Sprint directly toward the bomb target. On arrival OR if killed in transit
	# (handled in take_damage), detonate.
	if global_position.distance_to(_bomb_target) <= Balance.SACRIFICE_ARRIVAL_DIST:
		_explode()
		return

	if nav_agent.is_navigation_finished():
		_explode()
		return

	# Safety net: if the target is unreachable (click landed inside a wall,
	# nav graph has no path), the agent never marks navigation finished and
	# the bomber would sprint forever. Detonate in place after SACRIFICE_TIMEOUT.
	_bomb_timer -= delta
	if _bomb_timer <= 0.0:
		_explode()
		return

	var next_pos:  Vector2 = nav_agent.get_next_path_position()
	var direction: Vector2 = (next_pos - global_position).normalized()
	velocity = direction * move_speed * Balance.SACRIFICE_SPEED_MULT * _water_speed_mult()
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
			if (target as Node2D).global_position.distance_to(origin) <= Balance.SACRIFICE_RADIUS:
				target.take_damage(Balance.SACRIFICE_DAMAGE)

	# Visual explosion: spawn a temporary Node2D that draws the blast circle.
	# Added to the viewport directly, matching how grenades are spawned, so the
	# node is always parented correctly regardless of scene structure.
	var fx := Node2D.new()
	fx.set_script(preload("res://scripts/BombExplosionFX.gd"))
	get_viewport().add_child(fx)
	fx.global_position = origin
	fx.start(Balance.SACRIFICE_RADIUS, Balance.SACRIFICE_FX_TIME)

	# The soldier dies in the blast.
	_health = 0
	health_bar.value = 0
	_die()

func _do_shoot() -> void:
	if _shoot_cooldown > 0.0:
		return

	match _weapon:
		WeaponType.AUTO:
			if GameManager.rifle_ammo_pool <= 0:
				# Shared pool exhausted — fall back to pistol
				_weapon = WeaponType.PISTOL
				return
			GameManager.rifle_ammo_pool -= 1
			_shoot_cooldown = Balance.SOLDIER_RIFLE_COOLDOWN * cooldown_mult
		WeaponType.PISTOL:
			_shoot_cooldown   = Balance.SOLDIER_PISTOL_COOLDOWN * cooldown_mult
		_:
			return

	var dir: Vector2 = (_bullet_aim - global_position).normalized()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0

	_play_anim("shoot")
	_shoot_flash_timer = Balance.SOLDIER_SHOOT_FLASH_DURATION
	gunshot.pitch_scale = randf_range(0.9, 1.1)
	gunshot.play()

	if bullet_scene:
		var bullet: Node2D = bullet_scene.instantiate()
		get_viewport().add_child(bullet)
		bullet.global_position = global_position
		bullet.initialise(dir, self)
		# damage_bonus and range_mult come from FragmentEffects — Lost Marble
		# bumps damage, Brother's Cap bumps range. Both stack with whatever
		# base values the kid's tscn (or BalanceConfig) provides.
		# Bullet colour is element-driven so the player reads Fire/Ice/Lightning
		# at a glance; the per-kid bullet_color is no longer used for projectiles.
		var elem: int = get_element()
		var elem_col: Color = Elements.color_of(elem)
		if _weapon == WeaponType.AUTO:
			bullet.set_stats(rifle_damage + damage_bonus, rifle_speed,
					rifle_distance * range_mult, elem_col, elem)
		else:
			bullet.set_stats(pistol_damage + damage_bonus, pistol_speed,
					pistol_distance * range_mult, elem_col, elem)
		GameManager.record_shot(slot_index)

func _throw_grenade(target: Vector2) -> void:
	if _shoot_cooldown > 0.0:
		return
	if _grenade_ammo <= 0:
		# Out of grenades — fall back to pistol
		_weapon = WeaponType.PISTOL
		return
	_grenade_ammo   -= 1
	_shoot_cooldown  = Balance.SOLDIER_GRENADE_COOLDOWN

	var dir: Vector2 = (target - global_position).normalized()
	if dir.x != 0:
		sprite.flip_h = dir.x < 0
	_play_anim("shoot")
	_shoot_flash_timer = Balance.SOLDIER_SHOOT_FLASH_DURATION

	var grenade   := Node2D.new()
	grenade.set_script(_GRENADE_SCRIPT)
	var spawn_pos := global_position
	get_viewport().add_child(grenade)
	grenade.global_position = spawn_pos
	grenade.initialise(spawn_pos, target, self)

# ---------------------------------------------------------------------------
# Returns a speed multiplier based on the tile the soldier is standing on.
# Swimming Goggles (fragment) bypasses the water slowdown entirely.
func _water_speed_mult() -> float:
	if water_immune:
		return 1.0
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	if map_gen and map_gen.has_method("is_water_at") and map_gen.is_water_at(global_position):
		return Balance.SOLDIER_WATER_SPEED_MULT
	return 1.0

# Slope speed multiplier — slower going uphill, faster going downhill.
# MapGenerator clamps the result to ±25 %.
func _slope_speed_mult(direction: Vector2) -> float:
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	if map_gen and map_gen.has_method("get_slope_speed_mult"):
		return map_gen.get_slope_speed_mult(global_position, direction)
	return 1.0

# Distance-based catch-up. Soldiers near the squad centroid run at base speed;
# stragglers smoothly ramp up to Balance.SOLDIER_CATCHUP_SPEED_MULT. This replaces the old
# binary timer that sprinted indiscriminately after water exits / unstick
# events, even when the soldier was already in formation.
func _catchup_speed_mult() -> float:
	var squad: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad == null or not squad.has_method("get_centroid"):
		return 1.0
	var centroid: Vector2 = squad.get_centroid()
	if centroid == Vector2.ZERO:
		return 1.0
	var d: float = global_position.distance_to(centroid)
	if d <= Balance.SOLDIER_CATCHUP_NEAR:
		return 1.0
	var t: float = clampf((d - Balance.SOLDIER_CATCHUP_NEAR) / (Balance.SOLDIER_CATCHUP_FAR - Balance.SOLDIER_CATCHUP_NEAR), 0.0, 1.0)
	return lerpf(1.0, Balance.SOLDIER_CATCHUP_SPEED_MULT, t)

func _die() -> void:
	# Soldiers are not removed from the field — they remain as a "downed" body
	# that can be brought back via the revive potion. queue_free is intentionally
	# not called here.
	_state = State.DEAD
	velocity = Vector2.ZERO
	hide_group_label()
	_play_anim("die")
	# Freeze on the last frame once the die animation finishes — prevents looping
	# even if the SpriteFrames loop flag is inadvertently set.
	sprite.animation_finished.connect(_on_die_anim_finished, CONNECT_ONE_SHOT)
	footstep.stop()

	# set_deferred prevents "can't change state while flushing queries"
	$CollisionShape2D.set_deferred("disabled", true)

	GameManager.on_soldier_died(self)

	# Dim & desaturate the sprite so a downed soldier reads as inactive at a
	# glance. Hide the health bar — it will reappear on revive.
	sprite.modulate = Color(0.55, 0.55, 0.6, 0.75)
	health_bar.hide()

# Brings a downed soldier back to full health. Called by SquadController when
# the player spends a revive potion.
func revive() -> void:
	if _state != State.DEAD:
		return
	_health = max_health
	health_bar.value = _health
	health_bar.show()
	sprite.modulate = Color.WHITE
	$CollisionShape2D.set_deferred("disabled", false)
	_state = State.IDLE
	_play_anim("idle")
	GameManager.on_soldier_revived(self)

func _on_die_anim_finished() -> void:
	if _state == State.DEAD:
		sprite.stop()

# Lets callers check whether this soldier is a revivable corpse.
func is_downed() -> bool:
	return _state == State.DEAD

# True while this soldier is sprinting toward a bomb target.
# Used by SquadController to exclude them from the camera centroid.
func is_armed_bomb() -> bool:
	return _state == State.BOMB

# Show a colour-coded group number above this soldier's health bar.
func show_group_label(num: int) -> void:
	if _group_label == null:
		return
	_group_label.text = str(num)
	var col := GROUP_LABEL_COLORS[(num - 1) % GROUP_LABEL_COLORS.size()]
	_group_label.add_theme_color_override("font_color", col)
	_group_label.show()

func hide_group_label() -> void:
	if _group_label != null:
		_group_label.hide()

# Autonomous pistol fire for soldiers whose group is not currently commanded.
# Fires at reduced rate and accuracy so they have a fighting chance but still
# feel "unattended" compared to the player-directed group.
func _try_autodefend(delta: float) -> void:
	if is_active or _state == State.DEAD or _state == State.BOMB:
		_autodefend_cooldown = 0.0
		return
	_autodefend_cooldown = max(_autodefend_cooldown - delta, 0.0)
	if _autodefend_cooldown > 0.0:
		return
	var closest: Node2D = null
	var closest_d: float = Balance.SOLDIER_AUTODEFEND_RANGE
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		var d: float = (e as Node2D).global_position.distance_to(global_position)
		if d < closest_d:
			closest_d = d
			closest   = e
	if closest == null:
		return
	var dir := (closest.global_position - global_position).normalized()
	dir = dir.rotated(randf_range(-Balance.SOLDIER_AUTODEFEND_JITTER, Balance.SOLDIER_AUTODEFEND_JITTER))
	if dir.x != 0:
		sprite.flip_h = dir.x < 0
	gunshot.pitch_scale = randf_range(0.9, 1.1)
	gunshot.play()
	if bullet_scene:
		var bullet: Node2D = bullet_scene.instantiate()
		get_viewport().add_child(bullet)
		bullet.global_position = global_position
		bullet.initialise(dir, self)
		bullet.set_stats(pistol_damage, pistol_speed, pistol_distance, bullet_color)
	_autodefend_cooldown = Balance.SOLDIER_AUTODEFEND_COOLDOWN
	var hud := get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("show_under_attack"):
		hud.show_under_attack(group_id + 1)

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
