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
# When set, build the AnimatedSprite2D's SpriteFrames at runtime from per-anim
# strip PNGs in this folder (<idle|walk|shoot>_<facing>.png). Used for Lua's
# high-quality 8-direction set; leaving it empty keeps the .tscn-embedded frames.
@export var frames_dir: String = ""

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

# Per-surface footstep streams loaded by naming convention in _ready (see
# _load_footstep_streams). Keyed by surface name ("dirt"/"grass"/"snow").
# Missing files leave the entry null — _play_footstep falls back to the
# original .tscn-assigned stream so the soldier never goes silent.
var _surface_streams: Dictionary = {}
var _last_surface:    String = ""
# Soldier hit sound — built programmatically in _ready so the per-soldier
# .tscn files don't each need a new AudioStreamPlayer2D node.
var _hit_audio: AudioStreamPlayer2D = null

# ---------------------------------------------------------------------------
# Weapon system
# ---------------------------------------------------------------------------
enum WeaponType { PISTOL, AUTO, GRENADE, SACRIFICE }
const WEAPON_NAMES := ["Pistol", "Auto", "Grenade", "Sacrifice"]
const WEAPON_COUNT := 4

const _GRENADE_SCRIPT = preload("res://scripts/Grenade.gd")
const _MAZE_MOVER_SCRIPT = preload("res://scripts/SoldierMazeMover.gd")
const _FLOATING_NUMBER_SCRIPT = preload("res://scripts/FloatingNumberFX.gd")

var _weapon: WeaponType = WeaponType.PISTOL

# Rifle and grenade ammo are both shared squad pools in GameManager
# (rifle_ammo_pool / grenade_ammo_pool). Per-soldier counters caused HUD
# desync — the readout showed one soldier's stockpile, throws drew from
# whoever was closest, so the count "ran out" before the squad actually did.

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
	return GameManager.grenade_ammo_pool

# Per-mission override for grenade stockpile — used by the boss level to hand
# the squad enough potions to break the orbiting Memory Totems. Now writes
# the squad-wide pool; callers loop over soldiers but each call overwrites
# the same shared value, which is harmless.
func set_grenade_ammo(amount: int) -> void:
	GameManager.grenade_ammo_pool = maxi(amount, 0)

# Returns true for any weapon that fires continuously while the button is held.
# Pistol and rifle both stream fire — the per-weapon SHOOT_COOLDOWN governs pace.
func is_continuous_fire() -> bool:
	return _weapon == WeaponType.AUTO or _weapon == WeaponType.PISTOL

# ---------------------------------------------------------------------------
# Squad group membership (set by SquadController)
# ---------------------------------------------------------------------------
var group_id:  int  = 0
var is_active: bool = true   # false when this soldier belongs to an inactive group

var _group_tag: Sprite2D = null

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
	var scaled: int = delta * Balance.COMBAT_NUMBER_SCALE
	max_health += scaled
	_health = mini(_health + scaled, max_health)
	if health_bar:
		health_bar.max_value = max_health
		health_bar.value     = _health

func heal_to_full() -> void:
	_health = max_health
	if health_bar:
		health_bar.value = _health

func add_grenade_ammo(delta: int) -> void:
	GameManager.grenade_ammo_pool = maxi(GameManager.grenade_ammo_pool + delta, 0)

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
var hit_shield:       int   = 0      # Wooden Shield: hits fully blocked before HP loss
var lifesteal:        int   = 0      # Healing Charm: HP regained per bullet hit on an enemy
var regen_amount:     int   = 0      # River Stone: HP healed every regen_interval seconds
var regen_interval:   float = 0.0    # 0 disables the regen tick
var _regen_timer:     float = 0.0

# Transient external slow (e.g. boss thorny vines). Refreshed each frame while the
# soldier stands in the hazard; decays back to 1.0 shortly after leaving.
var _slow_mult:  float = 1.0
var _slow_timer: float = 0.0

# Apply (or refresh) a movement slow. mult < 1.0 slows; the strongest active slow
# wins for the duration. Called every frame by area hazards the soldier overlaps.
func slow_down(mult: float, duration: float) -> void:
	_slow_mult = minf(_slow_mult, mult)
	_slow_timer = maxf(_slow_timer, duration)

func add_damage_bonus(delta: int) -> void:
	damage_bonus += delta * Balance.COMBAT_NUMBER_SCALE

func add_range_mult(percent: float) -> void:
	range_mult *= (1.0 + percent)

func multiply_cooldown(multiplier: float) -> void:
	cooldown_mult *= multiplier

func add_damage_reduction(delta: int) -> void:
	damage_reduction += delta * Balance.COMBAT_NUMBER_SCALE

func enable_water_immunity() -> void:
	water_immune = true

func add_hit_shield(charges: int) -> void:
	hit_shield += charges

func add_lifesteal(delta: int) -> void:
	lifesteal += delta

func add_regen(amount: int, interval: float) -> void:
	regen_amount += amount
	regen_interval = interval
	_regen_timer = interval

# Called by Bullet.gd when a bullet fired by this soldier successfully hits
# a damageable target. Bumps the shared accuracy counter.
func on_bullet_hit(_target: Node2D) -> void:
	GameManager.record_hit(slot_index)
	# Healing Charm (fragment) — siphon a little HP back on every connecting shot.
	if lifesteal > 0 and _state != State.DEAD and _health < max_health:
		var healed: int = mini(lifesteal, max_health - _health)
		_health += healed
		if health_bar:
			health_bar.value = _health
		_spawn_damage_number(healed, Color(0.4, 0.95, 0.5))

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------
enum State { IDLE, MOVING, SHOOTING, BOMB, DEAD }
var _state: State = State.IDLE

# True while the soldier has an unfinished move order (a move_to destination or
# an active formation march). After a shot the SHOOTING state resumes MOVING
# only when this is set — without it the soldier consulted the nav agent's stale
# target and "walked off" when fired while standing still / out of formation.
var _has_active_move: bool = false

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
var _unstick_nudged:  bool    = false # nav target nudged off _move_target; restore on expiry

# Formation-march state. When _formation_active, SquadController drives this
# soldier as part of a rigid formation: it sets _formation_goal (this soldier's
# slot = march leader position + formation offset) every physics frame, and the
# soldier steers straight to it (see _do_formation_move). This replaces the old
# per-soldier corridor — one shared leader keeps the whole squad rigid instead
# of each kid running its own nav agent and drifting out of formation.
var _formation_active: bool    = false
var _formation_goal:   Vector2 = Vector2.ZERO
# While far from its slot, a soldier nav-paths to it (routing around obstacles)
# instead of beelining; these throttle how often that path is recomputed.
var _form_repathing:    bool  = false
var _form_repath_timer: float = 0.0

# Rescue-teleport state. _straggler_timer accumulates while the squad reports
# this soldier stranded; _teleporting freezes it during the fade-out/in warp.
var _straggler_timer: float  = 0.0
var _teleporting:     bool   = false
var _teleport_tween:  Tween  = null

# Formation offset of this soldier's slot — used by the plain-move_to catch-up
# (revive rally / group-split spread); the rigid march doesn't read it.
var _formation_offset_cur: Vector2 = Vector2.ZERO

# Cached group singletons — these are looked up several times per physics frame
# (water/slope/footsteps/catch-up); soldiers are re-instantiated every mission
# so the cache can never go stale across maps.
var _map_gen_cache: Node = null
var _squad_cache:   Node = null

func _map_gen() -> Node:
	if _map_gen_cache == null or not is_instance_valid(_map_gen_cache):
		_map_gen_cache = get_tree().get_first_node_in_group("map_generator")
	return _map_gen_cache

func _squad() -> Node:
	if _squad_cache == null or not is_instance_valid(_squad_cache):
		_squad_cache = get_tree().get_first_node_in_group("squad_controller")
	return _squad_cache

# Last direction the soldier was facing — drives directional idle/shoot anims.
var _facing: String = "down"
# True when the active SpriteFrames has diagonal animations (Lua's 8-way set).
# Other kids keep 4-way frames, so _dir_to_facing stays 4-way for them.
var _use_8way: bool = false
# Briefly after a shot, the soldier keeps facing the AIM direction even while
# walking, so she looks at her target while strafing instead of snapping to her
# movement heading between shots. Set in _do_shoot/_throw_grenade.
var _aim_hold: float  = 0.0
var _aim_face: String = ""

func _ready() -> void:
	# Player-authored squad loadout (title-screen editor) wins when the player
	# has engaged it. Move speed and bullet colour aren't editable, so they keep
	# their per-slot BalanceConfig values. SquadConfig guarantees every value is
	# > 0, so this path can't produce a zeroed stat.
	if SquadConfig.overrides_active and slot_index >= 0 and slot_index < SquadConfig.SQUAD_SIZE:
		var cfg_dmg: int = SquadConfig.dmg_value(slot_index) * Balance.COMBAT_NUMBER_SCALE
		move_speed      = Balance.SOLDIER_MOVE_SPEED_PER_SLOT[slot_index]
		max_health      = SquadConfig.hp_value(slot_index)  * Balance.COMBAT_NUMBER_SCALE
		pistol_damage   = cfg_dmg
		rifle_damage    = cfg_dmg
		pistol_speed    = SquadConfig.spd_value(slot_index)
		rifle_speed     = SquadConfig.spd_value(slot_index)
		pistol_distance = SquadConfig.rng_value(slot_index)
		rifle_distance  = SquadConfig.rng_value(slot_index)
		bullet_color    = Balance.SOLDIER_BULLET_COLOR_PER_SLOT[slot_index]
	# Per-slot stats win when Main has assigned slot_index (every normal
	# mission spawn). Standalone test scenes that drop a soldier without a
	# slot fall back to the squad-wide BalanceConfig defaults.
	elif slot_index >= 0 and slot_index < Balance.SOLDIER_MAX_HEALTH_PER_SLOT.size():
		move_speed      = Balance.SOLDIER_MOVE_SPEED_PER_SLOT[slot_index]
		max_health      = Balance.SOLDIER_MAX_HEALTH_PER_SLOT[slot_index]      * Balance.COMBAT_NUMBER_SCALE
		pistol_damage   = Balance.SOLDIER_PISTOL_DAMAGE_PER_SLOT[slot_index]   * Balance.COMBAT_NUMBER_SCALE
		pistol_speed    = Balance.SOLDIER_PISTOL_SPEED_PER_SLOT[slot_index]
		pistol_distance = Balance.SOLDIER_PISTOL_DISTANCE_PER_SLOT[slot_index]
		rifle_damage    = Balance.SOLDIER_RIFLE_DAMAGE_PER_SLOT[slot_index]    * Balance.COMBAT_NUMBER_SCALE
		rifle_speed     = Balance.SOLDIER_RIFLE_SPEED_PER_SLOT[slot_index]
		rifle_distance  = Balance.SOLDIER_RIFLE_DISTANCE_PER_SLOT[slot_index]
		bullet_color    = Balance.SOLDIER_BULLET_COLOR_PER_SLOT[slot_index]
	else:
		move_speed      = Balance.SOLDIER_MOVE_SPEED
		max_health      = Balance.SOLDIER_MAX_HEALTH      * Balance.COMBAT_NUMBER_SCALE
		pistol_damage   = Balance.SOLDIER_PISTOL_DAMAGE   * Balance.COMBAT_NUMBER_SCALE
		pistol_speed    = Balance.SOLDIER_PISTOL_SPEED
		pistol_distance = Balance.SOLDIER_PISTOL_DISTANCE
		rifle_damage    = Balance.SOLDIER_RIFLE_DAMAGE    * Balance.COMBAT_NUMBER_SCALE
		rifle_speed     = Balance.SOLDIER_RIFLE_SPEED
		rifle_distance  = Balance.SOLDIER_RIFLE_DISTANCE
	# Grenade pool is initialised once per mission in GameManager.reset_squad_stats,
	# not here — every soldier reads the same shared counter.
	_health = max_health
	if _carry_hp_override > 0:
		_health = min(_carry_hp_override, max_health)

	if is_female and female_frames:
		sprite.sprite_frames = female_frames
	elif male_frames:
		sprite.sprite_frames = male_frames

	# Lua (and any future kid) can supply a folder of high-quality directional
	# strips that replace the embedded frames at runtime.
	if frames_dir != "":
		_build_frames_from_dir(frames_dir)
	# Diagonal animations present -> drive movement/aim with 8-way facing.
	_use_8way = sprite.sprite_frames != null \
			and sprite.sprite_frames.has_animation(&"walk_up_right")

	health_bar.max_value = max_health
	health_bar.value     = _health
	_style_health_bar()

	_load_footstep_streams()
	_hit_audio = _build_hit_audio("res://resources/audio/sfx/soldier_hit.ogg")

	_play_anim("idle_" + _facing)

	# Tighter arrival tolerance so soldiers don't overshoot and circle back.
	nav_agent.path_desired_distance  = 4.0
	nav_agent.target_desired_distance = 12.0
	nav_agent.max_speed              = move_speed
	# RVO avoidance is deliberately OFF. Soldiers don't physically collide with
	# each other (layer 2 / mask 1) and static geometry is baked into the navmesh,
	# so inter-agent avoidance has no collision to prevent — it only shoved
	# soldiers off their formation slots and made them jostle when stopping.
	# Separation is the formation offsets' job; routing-as-a-group is the rigid
	# leader march's job (see formation_begin / SquadController._begin_march).
	nav_agent.avoidance_enabled  = false

	# Soldiers live on layer 2; their mask only covers layer 1 (environment/tilemap).
	# This lets soldiers pass through each other instead of physically blocking,
	# which was causing groups to lock up when they occupied the same space.
	collision_layer = 2
	collision_mask  = 1

	# Floating group shield icon — shown above the health bar when the squad
	# is split. Hidden by default; SquadController calls show_group_label().
	_group_tag = Sprite2D.new()
	_group_tag.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_group_tag.position = Vector2(0, -62)
	_group_tag.hide()
	add_child(_group_tag)

	await get_tree().physics_frame

func _physics_process(delta: float) -> void:
	_shoot_cooldown    = max(_shoot_cooldown    - delta, 0.0)
	_shoot_flash_timer = max(_shoot_flash_timer - delta, 0.0)
	_aim_hold          = max(_aim_hold          - delta, 0.0)
	if _slow_timer > 0.0:
		_slow_timer -= delta
		if _slow_timer <= 0.0:
			_slow_mult = 1.0

	# River Stone (fragment) — slow passive heal while alive and hurt.
	if regen_amount > 0 and regen_interval > 0.0 and _state != State.DEAD:
		_regen_timer -= delta
		if _regen_timer <= 0.0:
			_regen_timer = regen_interval
			if _health < max_health:
				_health = mini(_health + regen_amount, max_health)
				if health_bar:
					health_bar.value = _health

	# Frozen mid rescue-teleport: the fade tween owns position; hold still.
	if _teleporting:
		velocity = Vector2.ZERO
		return

	_try_autodefend(delta)

	match _state:
		State.MOVING:
			_do_move(delta)
		State.SHOOTING:
			_do_shoot()
			_state = State.MOVING if not _movement_finished() else State.IDLE
		State.BOMB:
			_do_bomb_charge(delta)
		State.IDLE:
			velocity = Vector2.ZERO
			move_and_slide()
			if _shoot_flash_timer <= 0.0:
				_play_anim("idle_" + _facing)
		State.DEAD:
			pass

# =============================================================================
# PUBLIC API
# =============================================================================

func move_to(destination: Vector2, formation_offset: Vector2 = Vector2.ZERO) -> void:
	if _state == State.DEAD or _state == State.BOMB:
		return
	_formation_active = false
	_unstick_nudged = false
	_unstick_timer  = 0.0
	_formation_offset_cur = formation_offset
	_move_target = destination
	nav_agent.target_position = destination
	_stuck_timer     = Balance.SOLDIER_STUCK_CHECK_INTERVAL
	_stuck_check_pos = global_position
	_stuck_strikes   = 0
	_has_active_move = true
	_state = State.MOVING

# Formation-march hooks, called by SquadController. begin puts the soldier into
# march mode; the controller then calls set_formation_goal() each physics frame
# with this soldier's slot (march leader position + its formation offset), and
# the soldier steers straight there in _do_formation_move. end drops it to IDLE.
# One shared leader driving every soldier is what keeps the squad rigid — no
# per-soldier pathfinding to drift or split.
func formation_begin(offset: Vector2) -> void:
	if _state == State.DEAD or _state == State.BOMB:
		return
	_formation_offset_cur = offset
	_formation_goal  = global_position
	_formation_active = true
	_form_repathing  = false
	_form_repath_timer = 0.0
	_unstick_timer   = 0.0
	_unstick_nudged  = false
	_has_active_move = true
	_state = State.MOVING

func set_formation_goal(goal: Vector2) -> void:
	_formation_goal = goal

func formation_end() -> void:
	if not _formation_active:
		return
	_formation_active = false
	_has_active_move = false
	if _state == State.MOVING:
		velocity = Vector2.ZERO
		_state = State.IDLE
		_play_anim("idle_" + _facing)
		footstep.stop()

# Last-resort recovery: warp the soldier onto `pos` (a navmesh point at its
# formation slot) when it's so wedged — boxed in by forest, slot in a wall — that
# it can't path back to the squad. Plays a fade-out / fade-in so the jump reads
# as an intentional blink rather than a glitch. Called by SquadController when a
# march gives up on a straggler or a soldier drifts too far from its group.
func snap_to(pos: Vector2) -> void:
	if _state == State.DEAD or _state == State.BOMB or _teleporting:
		return
	_teleporting = true
	_straggler_timer = 0.0
	velocity = Vector2.ZERO
	nav_agent.target_position = pos
	_form_repathing = false
	_form_repath_timer = 0.0
	footstep.stop()
	if _teleport_tween and _teleport_tween.is_valid():
		_teleport_tween.kill()
	# Fade out at the old spot, hop while invisible, fade back in at the slot.
	var fade := Balance.SQUAD_TELEPORT_FADE_TIME
	_teleport_tween = create_tween()
	_teleport_tween.tween_property(sprite, "modulate:a", 0.0, fade)
	_teleport_tween.tween_callback(func() -> void: global_position = pos)
	_teleport_tween.tween_property(sprite, "modulate:a", 1.0, fade)
	_teleport_tween.tween_callback(func() -> void: _teleporting = false)

# Accumulates the "stranded" timer from the squad's per-frame straggler check
# and returns true once this soldier has been too far for long enough to warrant
# the rescue teleport. Cleared whenever it's back near the group (or dead/warping).
func tick_straggler(too_far: bool, delta: float) -> bool:
	if _state == State.DEAD or _state == State.BOMB or _teleporting:
		_straggler_timer = 0.0
		return false
	if not too_far:
		_straggler_timer = 0.0
		return false
	_straggler_timer += delta
	if _straggler_timer >= Balance.SQUAD_STRAGGLER_TELEPORT_TIME:
		_straggler_timer = 0.0
		return true
	return false

func clear_straggler() -> void:
	_straggler_timer = 0.0

func is_formation_marching() -> bool:
	return _formation_active

func halt() -> void:
	if _state == State.DEAD or _state == State.BOMB:
		return
	_formation_active = false
	_has_active_move = false
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
	_formation_active = false
	_has_active_move = false
	_bomb_target = target
	_bomb_timer  = Balance.SACRIFICE_TIMEOUT
	nav_agent.target_position = target
	_state = State.BOMB
	# Tint the sprite red so it's visually obvious this soldier is armed.
	sprite.modulate = Color(1.0, 0.4, 0.4)
	_play_footstep()
	# Burn a sacrifice charge — no-op unless the tutorial / a future fragment
	# has imposed a cap. Hits zero → sacrifice disables so the player can't
	# arm a second kid by accident.
	GameManager.consume_sacrifice_charge()

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
	# Wooden Shield (fragment) eats whole hits before any HP is lost.
	if hit_shield > 0:
		hit_shield -= 1
		_spawn_damage_number(0, Color(0.6, 0.85, 1.0), "BLOCK")
		return
	_health -= net
	health_bar.value = _health
	_spawn_damage_number(net, Color(1.0, 0.35, 0.35))
	if _hit_audio != null:
		_hit_audio.pitch_scale = randf_range(0.9, 1.1)
		_hit_audio.play()
	if _health <= 0:
		if _state == State.BOMB:
			# Detonate where we fell rather than dying quietly.
			_explode()
			return
		_die()

# Visual styling for the health bar — kept out of the .tscn so inherited
# soldier scenes (soldier_1..6) don't each need their own StyleBoxFlat
# resources. Hides the default "100%" label and gives the bar a small,
# colour-coded silhouette above the sprite.
func _style_health_bar() -> void:
	health_bar.show_percentage = false
	health_bar.custom_minimum_size = Vector2(36, 5)
	health_bar.size = Vector2(36, 5)
	health_bar.position = Vector2(-18, -40)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.1, 0.85)
	bg.border_color = Color(0, 0, 0, 0.9)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(2)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.85, 0.4)
	fill.set_corner_radius_all(2)
	health_bar.add_theme_stylebox_override("background", bg)
	health_bar.add_theme_stylebox_override("fill", fill)

func _spawn_damage_number(amount: int, color: Color, text_override: String = "") -> void:
	var fx := Node2D.new()
	fx.set_script(_FLOATING_NUMBER_SCRIPT)
	get_viewport().add_child(fx)
	fx.global_position = global_position + Vector2(0, -48)
	fx.start(amount, color, text_override)

# =============================================================================
# PRIVATE — STATE BEHAVIOURS
# =============================================================================

func _do_move(delta: float) -> void:
	if maze_mode:
		if _MAZE_MOVER_SCRIPT.tick(self):
			_state = State.IDLE
			_play_anim("idle_" + _facing)
		return

	# Formation march (SquadController-driven): steer straight to the slot the
	# controller assigned this frame. The squad moves as one rigid body.
	if _formation_active:
		_do_formation_move(delta)
		return

	if nav_agent.is_navigation_finished():
		_has_active_move = false
		_state = State.IDLE
		_play_anim("idle_" + _facing)
		footstep.stop()
		return

	_unstick_timer = max(_unstick_timer - delta, 0.0)
	# A sidestep nudge moves the nav target off the real goal; restore it once
	# the sidestep expires so the soldier still ends on its exact slot
	# (leaving it nudged dragged soldiers ~32 px out of formation).
	if _unstick_nudged and _unstick_timer <= 0.0:
		_unstick_nudged = false
		nav_agent.target_position = _move_target

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

	var next_pos:  Vector2 = nav_agent.get_next_path_position()
	var direction: Vector2 = (next_pos - global_position).normalized()

	# While sidestepping, blend the unstick direction in to escape the obstacle.
	if is_unsticking:
		direction = (direction + _unstick_dir * 1.5).normalized()

	var speed_mult := _catchup_speed_mult(direction)
	var slope_mult := _slope_speed_mult(direction)
	velocity = direction * move_speed * _water_speed_mult() * slope_mult * speed_mult * _slow_mult
	move_and_slide()

	if _shoot_flash_timer <= 0.0:
		_play_walk_anim(direction)

	_play_footstep()

# Formation steering toward the controller-assigned slot. In formation the slot
# is right next to the soldier, so it beelines (rigid, smooth). If it falls more
# than REPATH_DIST behind — wedged on a prop, slowed in water, blocked at a
# corner — it switches to nav-pathing toward the slot (routing AROUND whatever
# blocked it) and speeds up to REJOIN_MULT to sprint back into formation. The
# rest of the squad never waits, so one stuck soldier doesn't slow everyone.
func _do_formation_move(delta: float) -> void:
	_form_repath_timer = max(_form_repath_timer - delta, 0.0)
	var to_goal := _formation_goal - global_position
	var dist := to_goal.length()
	if dist <= Balance.SQUAD_FORMATION_ARRIVE_EPS:
		velocity = Vector2.ZERO
		move_and_slide()
		_form_repathing = false
		if _shoot_flash_timer <= 0.0:
			_play_anim("idle_" + _facing)
		footstep.stop()
		return

	# Catch-up: at/near the slot move at base speed; the further behind, the
	# faster (up to REJOIN_MULT) so a straggler closes the gap quickly.
	var speed_mult := 1.0
	if dist > Balance.SOLDIER_CATCHUP_NEAR:
		var t := clampf((dist - Balance.SOLDIER_CATCHUP_NEAR) \
				/ (Balance.SOLDIER_CATCHUP_FAR - Balance.SOLDIER_CATCHUP_NEAR), 0.0, 1.0)
		speed_mult = lerpf(1.0, Balance.SQUAD_FORMATION_REJOIN_MULT, t)

	var dir: Vector2
	if dist <= Balance.SQUAD_FORMATION_REPATH_DIST:
		# In/near formation — beeline straight to the slot.
		_form_repathing = false
		dir = to_goal / dist
	else:
		# Fallen behind — route to the slot via the navmesh so we go AROUND the
		# obstacle that dropped us, not back into it. Refresh the path on a timer
		# (the slot keeps moving) rather than every frame.
		if not _form_repathing or _form_repath_timer <= 0.0:
			nav_agent.target_position = _formation_goal
			_form_repathing = true
			_form_repath_timer = 0.2
		if nav_agent.is_navigation_finished():
			dir = to_goal / dist
		else:
			dir = (nav_agent.get_next_path_position() - global_position).normalized()

	var step := move_speed * _water_speed_mult() * _slope_speed_mult(dir) * speed_mult * _slow_mult
	# Arrive: never overshoot the slot in a single physics step.
	velocity = dir * minf(step, dist / delta)
	move_and_slide()
	if _shoot_flash_timer <= 0.0:
		_play_walk_anim(dir)
	_play_footstep()

# "Has this soldier finished its current move order?" Drives whether SHOOTING
# resumes MOVING after a shot. Uses the explicit intent flag, NOT the nav agent:
# during a formation march the nav target is stale (soldiers steer directly), so
# consulting it made a soldier "walk off" toward an old target when fired while
# idle or out of formation.
func _movement_finished() -> bool:
	return not _has_active_move

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
	# Nudge the nav target slightly so the path re-evaluates on the next tick
	# (restored to _move_target in _do_move when the sidestep expires).
	nav_agent.target_position = _move_target + perp * 32.0
	_unstick_nudged = true

# Final-resort unstick: nudge the soldier toward the next waypoint along the
# planned path. Breaks corner-wedges that the sidestep nudge can't escape. Uses
# move_and_collide (NOT a raw position set) so it slides past prop corners but
# can never punch through a wall / cliff face — a raw teleport here let wedged
# soldiers pop straight off a plateau through the cliff. Only the non-formation
# move path (revive rally / split spread) reaches this; the rigid march steers
# directly and never enters stuck detection.
func _hard_unstick() -> void:
	if nav_agent.is_navigation_finished():
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var diff: Vector2 = next - global_position
	if diff.length() < 1.0:
		return
	move_and_collide(diff.normalized() * minf(diff.length(), 64.0))
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
				target.take_damage(Balance.SACRIFICE_DAMAGE * Balance.COMBAT_NUMBER_SCALE)

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
	_facing = _dir_to_facing(dir)
	_aim_face = _facing
	_aim_hold = 0.5
	_play_anim("shoot_" + _facing)
	_shoot_flash_timer = Balance.SOLDIER_SHOOT_FLASH_DURATION
	gunshot.pitch_scale = randf_range(0.9, 1.1)
	gunshot.play()

	if bullet_scene:
		var bullet: Node2D = bullet_scene.instantiate()
		get_viewport().add_child(bullet)
		bullet.global_position = global_position
		bullet.initialise(dir, self)
		# damage_bonus and range_mult come from FragmentEffects — Lost Marble
		# bumps damage, Brother's Cap bumps range. Both stack with the kid's
		# per-slot stats in BalanceConfig.
		# Bullet colour is element-driven so the player reads Fire/Ice/Lightning
		# at a glance; the per-kid bullet_color only shows on autodefend tracers
		# and the bio-card name.
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
	if GameManager.grenade_ammo_pool <= 0:
		# Pool exhausted — flip self to pistol so the next click pistol-fires.
		_weapon = WeaponType.PISTOL
		return
	GameManager.grenade_ammo_pool -= 1
	_shoot_cooldown  = Balance.SOLDIER_GRENADE_COOLDOWN

	# Cap throw distance — clicks past GRENADE_MAX_RANGE clamp to the rim so the
	# weapon can't reach across the whole map.
	var to_target: Vector2 = target - global_position
	if to_target.length() > Balance.GRENADE_MAX_RANGE:
		target = global_position + to_target.normalized() * Balance.GRENADE_MAX_RANGE

	var dir: Vector2 = (target - global_position).normalized()
	_facing = _dir_to_facing(dir)
	_aim_face = _facing
	_aim_hold = 0.5
	_play_anim("shoot_" + _facing)
	_shoot_flash_timer = Balance.SOLDIER_SHOOT_FLASH_DURATION

	var grenade   := Node2D.new()
	grenade.set_script(_GRENADE_SCRIPT)
	var spawn_pos := global_position
	get_viewport().add_child(grenade)
	grenade.global_position = spawn_pos
	grenade.initialise(spawn_pos, target, self)

	# Last potion just left the bag — auto-switch this soldier off grenade so a
	# follow-up click on the same thrower drops into pistol fire instead of
	# silently no-op'ing on the empty-pool guard above.
	if GameManager.grenade_ammo_pool <= 0:
		_weapon = WeaponType.PISTOL

# ---------------------------------------------------------------------------
# Returns a speed multiplier based on the tile the soldier is standing on.
# Swimming Goggles (fragment) bypasses the water slowdown entirely.
func _water_speed_mult() -> float:
	if water_immune:
		return 1.0
	var map_gen: Node = _map_gen()
	if map_gen and map_gen.has_method("is_water_at") and map_gen.is_water_at(global_position):
		return Balance.SOLDIER_WATER_SPEED_MULT
	return 1.0

# Slope speed multiplier — slower going uphill, faster going downhill.
# MapGenerator clamps the result to ±25 %.
func _slope_speed_mult(direction: Vector2) -> float:
	var map_gen: Node = _map_gen()
	if map_gen and map_gen.has_method("get_slope_speed_mult"):
		return map_gen.get_slope_speed_mult(global_position, direction)
	return 1.0

# Straggler catch-up. A soldier BEHIND its own formation slot (group centroid +
# assigned offset, and only when the slot is ahead of its heading) ramps up
# toward CATCHUP_SPEED_MULT to rejoin. Soldiers in or ahead of position move at
# base speed — no drag/slow-down, which was making the lead soldiers visibly
# crawl. With the shared corridor giving everyone equal-length parallel paths
# this rarely fires except after a stuck-recovery; it's a safety net, not the
# primary cohesion mechanism (that's the formation offsets themselves).
func _catchup_speed_mult(direction: Vector2) -> float:
	var squad: Node = _squad()
	if squad == null or not squad.has_method("get_group_centroid"):
		return 1.0
	var centroid: Vector2 = squad.get_group_centroid(group_id)
	if centroid == Vector2.ZERO:
		return 1.0
	var to_slot: Vector2 = (centroid + _formation_offset_cur) - global_position
	var d: float = to_slot.length()
	if d <= Balance.SOLDIER_CATCHUP_NEAR or to_slot.dot(direction) < 0.0:
		return 1.0   # in/ahead of slot — base speed
	var t: float = clampf((d - Balance.SOLDIER_CATCHUP_NEAR) / (Balance.SOLDIER_CATCHUP_FAR - Balance.SOLDIER_CATCHUP_NEAR), 0.0, 1.0)
	return lerpf(1.0, Balance.SOLDIER_CATCHUP_SPEED_MULT, t)

func _die() -> void:
	# Soldiers are not removed from the field — they remain as a "downed" body
	# that can be brought back via the revive potion. queue_free is intentionally
	# not called here.
	_state = State.DEAD
	velocity = Vector2.ZERO
	_formation_active = false   # don't resume a stale march if revived without a rally move
	_has_active_move = false
	# Cancel any in-flight rescue teleport so its tween can't fight the corpse
	# tint / drag the body after death.
	if _teleport_tween and _teleport_tween.is_valid():
		_teleport_tween.kill()
	_teleporting = false
	hide_group_label()
	# Prefer a directional death (die_<facing>, 8-way set); fall back to the single
	# non-directional "die" carried over from the embedded frames (other kids).
	var death_anim := "die_" + _facing
	if sprite.sprite_frames == null or not sprite.sprite_frames.has_animation(death_anim):
		death_anim = "die"
	_play_anim(death_anim)
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
	sprite.speed_scale = 1.0
	$CollisionShape2D.set_deferred("disabled", false)
	_state = State.IDLE
	_play_anim("idle_" + _facing)
	GameManager.on_soldier_revived(self)

func _on_die_anim_finished() -> void:
	# Pin to the LAST frame of "die" (face-down corpse pose). AnimatedSprite2D
	# .stop() would reset to frame 0 (standing pose), so we freeze explicitly
	# by zeroing the speed scale and re-asserting the final frame index. The
	# sprite_frames null-check is for the standalone test scenes that don't
	# assign frames.
	if _state != State.DEAD or sprite.sprite_frames == null:
		return
	var anim := sprite.animation
	if not sprite.sprite_frames.has_animation(anim):
		return
	var frames: int = sprite.sprite_frames.get_frame_count(anim)
	if frames > 0:
		sprite.frame = frames - 1
	sprite.speed_scale = 0.0

# Lets callers check whether this soldier is a revivable corpse.
func is_downed() -> bool:
	return _state == State.DEAD

# True while this soldier is sprinting toward a bomb target.
# Used by SquadController to exclude them from the camera centroid.
func is_armed_bomb() -> bool:
	return _state == State.BOMB

# Show a colour-coded shield icon above this soldier's health bar.
func show_group_label(num: int) -> void:
	if _group_tag == null:
		return
	_group_tag.texture = _make_group_icon(num - 1)
	_group_tag.show()

func hide_group_label() -> void:
	if _group_tag != null:
		_group_tag.hide()

func _px(img: Image, x: int, y: int, color: Color) -> void:
	if x >= 0 and x < img.get_width() and y >= 0 and y < img.get_height():
		img.set_pixel(x, y, color)

func _make_group_icon(group_index: int) -> ImageTexture:
	const GROUP_COLORS: Array[Color] = [
		Color(1.0, 0.95, 0.0),
		Color(0.3,  0.9, 1.0),
		Color(0.5,  1.0, 0.4),
	]
	var img := Image.create(24, 24, false, Image.FORMAT_RGBA8)
	img.fill(Color.TRANSPARENT)
	var base: Color = GROUP_COLORS[group_index % GROUP_COLORS.size()]
	var dark   := Color(base.r * 0.40, base.g * 0.40, base.b * 0.40, 1.0)
	var mid    := Color(base.r * 0.75, base.g * 0.75, base.b * 0.75, 1.0)
	var bright := Color(minf(base.r * 1.2 + 0.15, 1.0), minf(base.g * 1.2 + 0.15, 1.0), minf(base.b * 1.2 + 0.15, 1.0), 1.0)
	for y in 22:
		var half_w: int = 9 if y <= 15 else maxi(9 - (y - 15) * 2, 0)
		for x in range(12 - half_w, 12 + half_w + 1):
			var on_edge := (x == 12 - half_w or x == 12 + half_w or y == 0 or (y == 21 and half_w == 0))
			_px(img, x, y, dark if on_edge else base)
	for y in range(2, 6):
		for x in range(5, 10):
			_px(img, x, y, bright)
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			if abs(dx) + abs(dy) <= 2:
				_px(img, 12 + dx, 10 + dy, mid)
	_px(img, 12, 10, bright)
	return ImageTexture.create_from_image(img)

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
		# Nothing in range — wait a beat before walking the enemy list again
		# instead of re-scanning all ~50 enemies every physics frame.
		_autodefend_cooldown = Balance.SOLDIER_AUTODEFEND_RESCAN
		return
	var dir := (closest.global_position - global_position).normalized()
	dir = dir.rotated(randf_range(-Balance.SOLDIER_AUTODEFEND_JITTER, Balance.SOLDIER_AUTODEFEND_JITTER))
	_facing = _dir_to_facing(dir)
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
# PRIVATE — AUDIO
# =============================================================================

# Loads up to three per-soldier footstep streams by naming convention so each
# kid sounds different on each surface. Missing files leave the slot null and
# _play_footstep falls back to whatever the .tscn's FootstepAudio already has.
# Convention: res://resources/audio/sfx/footsteps/footstep_<surface>_<N>.ogg
# with N = slot_index + 1 (matches the laser1..laser6 numbering).
func _load_footstep_streams() -> void:
	var n: int = slot_index + 1 if slot_index >= 0 else 1
	for surface in ["dirt", "grass", "snow"]:
		var path := "res://resources/audio/sfx/footsteps/footstep_%s_%d.ogg" % [surface, n]
		if ResourceLoader.exists(path):
			_surface_streams[surface] = load(path)

# Spawns a fresh AudioStreamPlayer2D wired to the squad SFX bus, used for the
# one-shot hit grunt. Skips silently if the file isn't present so the project
# still runs before the audio drop lands. Pitch wobble matches gunshot for
# consistency.
func _build_hit_audio(path: String) -> AudioStreamPlayer2D:
	if not ResourceLoader.exists(path):
		return null
	var player := AudioStreamPlayer2D.new()
	player.stream = load(path)
	player.bus = &"sfx"
	player.max_distance = 2000.0
	player.max_polyphony = 3
	add_child(player)
	return player

# Switches the footstep stream to match the surface under the soldier's feet
# and starts (or continues) playback. Called from _do_move and from the maze
# mover. Surface "" = silent (water): stop the loop.
func _play_footstep() -> void:
	var map_gen: Node = _map_gen()
	var surface: String = "dirt"
	if map_gen and map_gen.has_method("get_surface_at"):
		surface = map_gen.get_surface_at(global_position)
	if surface == "":
		footstep.stop()
		return
	if surface != _last_surface:
		_last_surface = surface
		var stream: AudioStream = _surface_streams.get(surface, null)
		if stream != null:
			footstep.stream = stream
		# else: leave whatever the .tscn assigned so the soldier isn't silent
		# until the actual surface audio file is dropped in.
		footstep.stop()
	if not footstep.playing:
		footstep.play()

# =============================================================================
# PRIVATE — ANIMATION
# =============================================================================

func _dir_to_facing(dir: Vector2) -> String:
	if _use_8way:
		# 8-way octant facing (Godot y is down, so positive angle = down). A zero
		# vector keeps the current facing so a stopped soldier doesn't snap.
		if dir == Vector2.ZERO:
			return _facing
		var deg := rad_to_deg(dir.angle())
		if deg < 0.0:
			deg += 360.0
		var idx: int = int(round(deg / 45.0)) % 8
		return ["right", "down_right", "down", "down_left",
				"left", "up_left", "up", "up_right"][idx]
	if abs(dir.y) > abs(dir.x):
		return "up" if dir.y < 0 else "down"
	return "left" if dir.x < 0 else "right"

# Builds the AnimatedSprite2D's SpriteFrames at runtime from per-anim strip PNGs
# in `dir` (<idle|walk|shoot>_<facing>.png — horizontal strips of square frames).
# Carries over any existing "die" animation and normalises on-screen size to
# match the other kids. No-ops (keeps embedded frames) if nothing loads.
func _build_frames_from_dir(dir: String) -> void:
	var specs := {
		"idle":  {"fps": 6.0,  "loop": true},
		"walk":  {"fps": 10.0, "loop": true},
		"shoot": {"fps": 12.0, "loop": false},
		"die":   {"fps": 10.0, "loop": false},
	}
	var facings := ["down", "up", "left", "right",
			"down_right", "down_left", "up_right", "up_left"]
	var nf := SpriteFrames.new()
	nf.remove_animation(&"default")
	var frame_h := 0
	var added := 0
	var die_added := 0
	for prefix in specs:
		for facing in facings:
			var path: String = dir.path_join("%s_%s.png" % [prefix, facing])
			if not ResourceLoader.exists(path):
				continue
			var tex: Texture2D = load(path)
			if tex == null or tex.get_height() <= 0:
				continue
			frame_h = tex.get_height()
			var strip_img: Image = tex.get_image()
			@warning_ignore("integer_division")
			var cols: int = maxi(1, tex.get_width() / frame_h)
			var anim := "%s_%s" % [prefix, facing]
			nf.add_animation(anim)
			nf.set_animation_loop(anim, specs[prefix]["loop"])
			nf.set_animation_speed(anim, specs[prefix]["fps"])
			for i in cols:
				# Each frame becomes its OWN mipmapped texture (not an atlas region):
				# mipmaps don't bleed neighbouring frames, and with linear+mipmap
				# filtering she stays smooth — not blocky — when the camera zooms
				# right in, and shimmer-free when zoomed out.
				var sub: Image = strip_img.get_region(Rect2i(i * frame_h, 0, frame_h, frame_h))
				sub.generate_mipmaps()
				nf.add_frame(anim, ImageTexture.create_from_image(sub))
			added += 1
			if prefix == "die":
				die_added += 1
	if added == 0:
		return
	# Preserve the death pose from the embedded frames ONLY when the folder didn't
	# supply a directional die set (die_<facing>.png). Characters with their own
	# 8-way die (e.g. Cameron) skip this; _die() plays die_<facing> for them.
	var old := sprite.sprite_frames
	if die_added == 0 and old != null and old.has_animation(&"die"):
		nf.add_animation(&"die")
		nf.set_animation_loop(&"die", old.get_animation_loop(&"die"))
		nf.set_animation_speed(&"die", old.get_animation_speed(&"die"))
		for i in old.get_frame_count(&"die"):
			nf.add_frame(&"die", old.get_frame_texture(&"die", i),
					old.get_frame_duration(&"die", i))
	sprite.sprite_frames = nf
	# Linear + mipmaps: she's a detailed (non-pixel-art) sprite, so smooth filtering
	# reads far better than nearest at any zoom (no blocky pixels zoomed in, no
	# shimmer zoomed out). The other kids keep their own nearest pixel-art filter.
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Normalise scale by the character's ACTUAL drawn height, not the (much taller,
	# padded) canvas — v3 frames have lots of empty space, so scaling by frame
	# height made her tiny. Measure the opaque bounds of a standing frame and size
	# her to ~77 px tall to match the other kids (64 px frame x 1.2 scale).
	var ref_path: String = dir.path_join("idle_down.png")
	if not ResourceLoader.exists(ref_path):
		ref_path = dir.path_join("walk_down.png")
	var char_h: int = frame_h
	if ResourceLoader.exists(ref_path):
		var rimg: Image = (load(ref_path) as Texture2D).get_image()
		if rimg != null:
			var ur: Rect2i = rimg.get_used_rect()
			if ur.size.y > 0:
				char_h = ur.size.y
	if char_h > 0:
		var s := 76.8 / float(char_h)
		sprite.scale = Vector2(s, s)

func _play_anim(anim_name: String) -> void:
	if sprite.sprite_frames == null or not sprite.sprite_frames.has_animation(anim_name):
		return
	# Also (re)start when the right animation is selected but not actually playing.
	# Some soldier .tscn files pre-set animation = &"idle_down" on the sprite, so on
	# first load the name already matches and a plain name-change guard would skip
	# play() — leaving the kid frozen on frame 0 until they walked and stopped.
	if sprite.animation != anim_name or not sprite.is_playing():
		sprite.play(anim_name)

func _play_walk_anim(direction: Vector2) -> void:
	# Keep facing the aim direction for a beat after firing (strafe-while-shooting)
	# instead of snapping to the movement heading between shots.
	if _aim_hold > 0.0 and _aim_face != "":
		_facing = _aim_face
	else:
		_facing = _dir_to_facing(direction)
	var anim := "walk_" + _facing
	if sprite.sprite_frames and sprite.sprite_frames.has_animation(anim):
		sprite.flip_h = false
		_play_anim(anim)
	elif sprite.sprite_frames and sprite.sprite_frames.has_animation("walk_side"):
		# Fallback for soldiers that don't yet have separate walk_left/walk_right.
		sprite.flip_h = _facing == "left"
		_play_anim("walk_side")
