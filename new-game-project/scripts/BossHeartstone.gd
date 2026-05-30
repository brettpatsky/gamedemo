# =============================================================================
# BossHeartstone.gd  (Boss Mission — "The Weeping Heartstone")
# Attach to scenes/bosses/boss_heartstone.tscn root StaticBody2D.
#
# Three-phase encounter:
#   Phase 1 — Leyline Grid:
#     Rotating beams sweep the arena. Boss is fully vulnerable.
#   Phase 2 — Parent's Mirage:
#     Boss becomes invulnerable. Spawns 3 Memory Totems with regenerating
#     shields and corrupted sludge pools that drain the rifle ammo pool.
#     Squad must destroy all totems to advance.
#   Phase 3 — Eldritch Meltdown:
#     Boss vulnerable again, but faster beams + spiralling projectile fire.
#     Periodically channels "The Void Embrace" — a 15-second wipe countdown
#     that kills the active squad if it completes. Heavy damage (grenades,
#     sacrifice) interrupts the channel.
# =============================================================================
extends StaticBody2D

const Balance = preload("res://scripts/BalanceConfig.gd")

signal boss_defeated
signal phase_changed(phase: int)
signal void_embrace_started
signal void_embrace_interrupted
signal void_embrace_progress(t: float)        # 0..1 channel progress
signal void_embrace_cleared                    # channel ended without wipe

# ---------------------------------------------------------------------------
# Health, phase thresholds, and per-phase timings live in BalanceConfig.gd
# under the BOSS_* prefix. Only data that's structural to this script (the
# Phase 1 attack pattern offsets) stays here.
# ---------------------------------------------------------------------------

# Phase 1 — telegraphed AOE zone offsets. Offsets are boss-relative.
const PHASE1_PATTERNS: Array = [
	# Pattern A — south triangle (zones at SW / SE / N). Safe spots: north
	# corners and the gap between SW and SE.
	[Vector2(-450,  160), Vector2( 450,  160), Vector2(   0, -220)],
	# Pattern B — north triangle (zones at NW / NE / S). Safe spots: south
	# centre and the east/west sides.
	[Vector2(-450, -180), Vector2( 450, -180), Vector2(   0,  160)],
	# Pattern C — diagonal pair plus a centre-south zone. Safe spots: NE and SW corners.
	[Vector2(-500, -180), Vector2( 500,  140), Vector2(-200,  140)],
	# Pattern D — opposite diagonals. Safe spots: NW and SE corners.
	[Vector2( 500, -180), Vector2(-500,  140), Vector2( 200,  140)],
]

# ---------------------------------------------------------------------------
# Preloads — sub-scripts spawned dynamically
# ---------------------------------------------------------------------------
const _ZONE_SCRIPT         = preload("res://scripts/PhaseDangerZone.gd")
const _SLUDGE_SCRIPT       = preload("res://scripts/SludgePool.gd")
const _PROJECTILE_SCRIPT   = preload("res://scripts/EldritchProjectile.gd")
const _TOTEM_SCENE: PackedScene = preload("res://scenes/bosses/memory_totem.tscn")

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _health: int = 0   # populated from BalanceConfig in _ready()
var _phase:  int = 0      # 0 = dormant (squad still in the corridor), 1/2/3 = active
var _invulnerable: bool = false
var _destroyed:    bool = false
# True once the squad has crossed the trigger threshold into the boss room.
# Until then, _process is idle and nothing attacks the squad — the player has
# time to organise in the passageway / outside area.
var _activated:    bool = false

var _zones:        Array[Node2D] = []   # Phase-1 active danger zones
var _totems:       Array[Node]   = []
var _sludge_pools: Array[Node2D] = []

# Phase-1 zone cycling state.
var _zone_pattern_idx: int   = 0
var _zone_cycle_timer: float = 0.0

# Phase-2 per-totem orbit state. Each slot has its own angle, angular
# velocity, and an independent radius-wobble phase so the squad can't lead
# their shots on a metronome. Speeds are re-rolled every REROLL_TIME via
# _totem_reroll_timer.
var _totem_angles:        Array[float] = []
var _totem_speeds:        Array[float] = []
var _totem_wobble_phases: Array[float] = []
var _totem_reroll_timer:  float = 0.0

# Phase-3 timers.
var _projectile_timer:    float = 0.0
var _spiral_angle:        float = 0.0
var _void_pre_timer:      float = 0.0
var _void_channel_timer:  float = 0.0
var _void_active:         bool  = false
var _ambient_phase:       float = 0.0   # for visual pulsing

@onready var health_bar: ProgressBar = $HealthBar

# =============================================================================
# READY
# =============================================================================
func _ready() -> void:
	add_to_group("enemies")
	add_to_group("boss")
	collision_layer = 1
	collision_mask  = 0
	_health = Balance.BOSS_MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE
	health_bar.max_value = _health
	health_bar.value     = _health
	# Dormant until the squad crosses into the boss room — BossArenaLevel's
	# trigger zone calls activate() at that point.

# Called by the arena trigger zone when a soldier enters the boss room.
func activate() -> void:
	if _activated or _destroyed:
		return
	_activated = true
	_enter_phase_1()

# =============================================================================
# PROCESS
# =============================================================================
func _process(delta: float) -> void:
	_ambient_phase += delta
	queue_redraw()
	if _destroyed:
		return
	if not _activated:
		return   # dormant until the squad enters the boss room
	match _phase:
		1: _tick_phase_1(delta)
		2: _tick_phase_2(delta)
		3: _tick_phase_3(delta)

# =============================================================================
# DAMAGE
# =============================================================================
func take_damage(amount: int, _element: int = 0) -> void:
	if _destroyed:
		return
	if not _activated:
		return   # ignore stray hits while the fight hasn't begun
	if _invulnerable:
		# Audio/visual feedback for "no damage" could go here. Returning silently
		# is fine — the player sees the HP bar isn't moving.
		return
	_health -= amount
	health_bar.value = _health
	if _void_active and amount >= Balance.BOSS_VOID_INTERRUPT_DMG:
		_interrupt_void_embrace()
	# Phase transitions — deferred because take_damage is invoked from a Bullet
	# collision callback during physics flushing. Spawning Area2D children
	# (beams / sludge / projectiles) is illegal mid-flush.
	if _phase == 1 and _health <= Balance.BOSS_PHASE_2_THRESHOLD:
		_phase = 2  # claim the phase NOW so we don't enter twice on subsequent hits
		call_deferred("_enter_phase_2")
	elif _phase == 3 and _health <= 0:
		_phase = -1
		call_deferred("_die")

# =============================================================================
# PHASE 1 — TELEGRAPHED FLOOR ZONES
# =============================================================================
func _enter_phase_1() -> void:
	_phase = 1
	_invulnerable = false
	_zone_pattern_idx = 0
	_zone_cycle_timer = 0.0
	_spawn_zone_pattern(_zone_pattern_idx)
	phase_changed.emit(1)

func _tick_phase_1(delta: float) -> void:
	_zone_cycle_timer += delta
	if _zone_cycle_timer < (Balance.BOSS_PHASE1_WARN + Balance.BOSS_PHASE1_DAMAGE + Balance.BOSS_PHASE1_PAUSE):
		return
	_zone_cycle_timer = 0.0
	_zone_pattern_idx = (_zone_pattern_idx + 1) % PHASE1_PATTERNS.size()
	_spawn_zone_pattern(_zone_pattern_idx)

func _spawn_zone_pattern(idx: int) -> void:
	# Defensive cleanup — the old pattern's zones free themselves after the
	# damage window, but if the boss skipped past a cycle (phase change), drop
	# any leftover zones now.
	_clear_zones()
	var pattern: Array = PHASE1_PATTERNS[idx]
	for offset: Vector2 in pattern:
		var zone := Area2D.new()
		zone.set_script(_ZONE_SCRIPT)
		get_parent().add_child(zone)
		zone.global_position = global_position + offset
		if zone.has_method("configure"):
			zone.configure(Balance.BOSS_PHASE1_WARN, Balance.BOSS_PHASE1_DAMAGE)
		_zones.append(zone)

func _clear_zones() -> void:
	for z in _zones:
		if is_instance_valid(z):
			z.queue_free()
	_zones.clear()

# =============================================================================
# PHASE 2 — PARENT'S MIRAGE
# =============================================================================
func _enter_phase_2() -> void:
	_phase = 2
	_invulnerable = true
	_totem_reroll_timer = 0.0
	_clear_zones()
	_spawn_totems()
	_spawn_sludge_pools()
	phase_changed.emit(2)

func _tick_phase_2(delta: float) -> void:
	# Per-totem chaos: each totem advances on its own angular velocity, with
	# a sine-driven radius wobble. Speeds re-roll every REROLL_TIME so the
	# squad can't predict the orbit by watching a few cycles.
	_totem_reroll_timer -= delta
	if _totem_reroll_timer <= 0.0:
		_totem_reroll_timer = Balance.BOSS_TOTEM_REROLL_TIME
		_reroll_totem_speeds()
	var any_alive: bool = false
	for i in _totems.size():
		var t: Node = _totems[i]
		if not is_instance_valid(t):
			continue
		any_alive = true
		_totem_angles[i] += _totem_speeds[i] * delta
		_totem_wobble_phases[i] += Balance.BOSS_TOTEM_WOBBLE_SPEED * delta
		var r: float = Balance.BOSS_TOTEM_RADIUS \
				+ sin(_totem_wobble_phases[i]) * Balance.BOSS_TOTEM_RADIUS_WOBBLE
		var angle: float = _totem_angles[i]
		(t as Node2D).global_position = global_position \
				+ Vector2(cos(angle), sin(angle)) * r
	if not any_alive:
		_phase = 3   # claim the phase early so this tick doesn't re-fire
		call_deferred("_enter_phase_3")

# Picks a fresh angular velocity for each surviving totem in
# [BASE - SPREAD, BASE + SPREAD * 2]. Asymmetric range so the mean drift
# stays forward — the orbit never crawls or reverses for long.
func _reroll_totem_speeds() -> void:
	for i in _totem_speeds.size():
		var base: float = Balance.BOSS_TOTEM_ORBIT_SPEED
		var spread: float = Balance.BOSS_TOTEM_SPEED_SPREAD
		_totem_speeds[i] = randf_range(base - spread, base + spread * 2.0)

func _spawn_totems() -> void:
	# Keep _totems sized to Balance.BOSS_TOTEM_COUNT so each slot keeps its
	# starting angle even after the totem in that slot is destroyed (the slot
	# becomes invalid, but the indices of surviving totems stay stable).
	_totems.clear()
	_totem_angles.clear()
	_totem_speeds.clear()
	_totem_wobble_phases.clear()
	for i in Balance.BOSS_TOTEM_COUNT:
		var base_angle: float = (TAU / float(Balance.BOSS_TOTEM_COUNT)) * float(i) - PI * 0.5
		var pos := global_position + Vector2(cos(base_angle), sin(base_angle)) * Balance.BOSS_TOTEM_RADIUS
		var totem: Node = _TOTEM_SCENE.instantiate()
		get_parent().add_child(totem)
		(totem as Node2D).global_position = pos
		if totem.has_signal("totem_destroyed"):
			totem.totem_destroyed.connect(_on_totem_destroyed)
		_totems.append(totem)
		_totem_angles.append(base_angle)
		# Random starting speed so totems begin desynced from frame 1.
		_totem_speeds.append(randf_range(
				Balance.BOSS_TOTEM_ORBIT_SPEED - Balance.BOSS_TOTEM_SPEED_SPREAD,
				Balance.BOSS_TOTEM_ORBIT_SPEED + Balance.BOSS_TOTEM_SPEED_SPREAD * 2.0))
		# Spread wobble phases so all three totems aren't bobbing in unison.
		_totem_wobble_phases.append(randf() * TAU)

func _on_totem_destroyed() -> void:
	# Compact handler — phase 2 tick will detect the empty list and advance.
	pass

func _spawn_sludge_pools() -> void:
	_sludge_pools.clear()
	for i in Balance.BOSS_SLUDGE_COUNT:
		var angle: float = (TAU / float(Balance.BOSS_SLUDGE_COUNT)) * float(i) + PI * 0.25
		var pos := global_position + Vector2(cos(angle), sin(angle)) * Balance.BOSS_SLUDGE_RADIUS_RING
		var pool := Area2D.new()
		pool.set_script(_SLUDGE_SCRIPT)
		get_parent().add_child(pool)
		pool.global_position = pos
		# Make the pool wander around the boss so the squad can't camp out of
		# range and snipe the totems. Each pool seeks new targets independently.
		if pool.has_method("configure"):
			pool.configure(global_position,
					Balance.BOSS_SLUDGE_WANDER_MIN,
					Balance.BOSS_SLUDGE_WANDER_MAX)
		_sludge_pools.append(pool)

func _clear_sludge_pools() -> void:
	for p in _sludge_pools:
		if is_instance_valid(p):
			p.queue_free()
	_sludge_pools.clear()

# =============================================================================
# PHASE 3 — ELDRITCH MELTDOWN
# =============================================================================
func _enter_phase_3() -> void:
	_phase = 3
	_invulnerable = false
	# Drop any straggler sludge / cleanup from phase 2 just in case.
	_clear_sludge_pools()
	# Phase 3 has no rotating beams — the spiral projectile storm + Void
	# Embrace channel + (still-orbiting) corrupted aura supply the threat.
	_void_pre_timer     = Balance.BOSS_VOID_PRE_DELAY
	_void_active        = false
	_void_channel_timer = 0.0
	_projectile_timer   = 0.0
	# Make sure Phase 3 starts at a defined HP even if the player overshot in
	# Phase 1 (it can't actually overshoot, but the bookkeeping is cheap).
	if _health > Balance.BOSS_PHASE_3_THRESHOLD:
		_health = Balance.BOSS_PHASE_3_THRESHOLD
		health_bar.value = _health
	phase_changed.emit(3)

func _tick_phase_3(delta: float) -> void:
	# Spiral projectile fire.
	_projectile_timer -= delta
	if _projectile_timer <= 0.0:
		_projectile_timer = Balance.BOSS_PROJECTILE_INTERVAL
		_fire_spiral_volley()

	# Void Embrace channel logic.
	if _void_active:
		_void_channel_timer -= delta
		void_embrace_progress.emit(1.0 - clampf(_void_channel_timer / Balance.BOSS_VOID_CHANNEL_TIME, 0.0, 1.0))
		if _void_channel_timer <= 0.0:
			_complete_void_embrace()
	else:
		_void_pre_timer -= delta
		if _void_pre_timer <= 0.0:
			_start_void_embrace()

func _fire_spiral_volley() -> void:
	# Two-armed spiral so the pattern reads as a proper magical storm.
	_spiral_angle += 0.55
	for arm in 2:
		var angle: float = _spiral_angle + float(arm) * PI
		var dir := Vector2(cos(angle), sin(angle))
		var p := Area2D.new()
		p.set_script(_PROJECTILE_SCRIPT)
		get_parent().add_child(p)
		p.global_position = global_position
		p.initialise(dir)

func _start_void_embrace() -> void:
	_void_active = true
	_void_channel_timer = Balance.BOSS_VOID_CHANNEL_TIME
	void_embrace_started.emit()
	void_embrace_progress.emit(0.0)

func _interrupt_void_embrace() -> void:
	if not _void_active:
		return
	_void_active = false
	_void_channel_timer = 0.0
	_void_pre_timer = Balance.BOSS_VOID_COOLDOWN_AFTER_INT
	void_embrace_interrupted.emit()
	void_embrace_cleared.emit()

func _complete_void_embrace() -> void:
	_void_active = false
	_void_pre_timer = Balance.BOSS_VOID_PRE_DELAY
	void_embrace_cleared.emit()
	# Wipe every soldier in the currently active group.
	var squad: Node = get_tree().get_first_node_in_group("squad_controller")
	var active_group_id: int = -1
	if squad and "_active_group" in squad:
		active_group_id = squad._active_group
	for s in get_tree().get_nodes_in_group("soldiers"):
		if not is_instance_valid(s):
			continue
		if s.has_method("is_downed") and s.is_downed():
			continue
		# If we can tell which group is active, only wipe that group; otherwise
		# wipe everyone alive (single-group play).
		if active_group_id >= 0 and "group_id" in s and s.group_id != active_group_id:
			continue
		if s.has_method("take_damage"):
			s.take_damage(Balance.BOSS_VOID_WIPE_DAMAGE)

# =============================================================================
# DEATH
# =============================================================================
func _die() -> void:
	_destroyed = true
	_void_active = false
	void_embrace_cleared.emit()
	_clear_zones()
	_clear_sludge_pools()
	for t in _totems:
		if is_instance_valid(t):
			t.queue_free()
	_totems.clear()
	GameManager.add_score(500)
	boss_defeated.emit()
	# Let GameManager bookkeeping settle (the boss counts as one enemy).
	if GameManager.enemies_alive > 0:
		GameManager.on_enemy_died()
	queue_free()

# =============================================================================
# DRAW — corrupted monolith
# =============================================================================
func _draw() -> void:
	var pulse: float = 0.5 + 0.5 * sin(_ambient_phase * 2.0)
	# Outer aura — wider during the void embrace channel.
	var aura_radius: float = 110.0 + (12.0 if _void_active else 0.0) + 6.0 * pulse
	var aura_color := Color(0.45, 0.05, 0.7, 0.25 + 0.25 * pulse)
	if _phase == 2:
		aura_color = Color(0.30, 0.05, 0.50, 0.30)   # deeper, "shielded" tone
	if _void_active:
		aura_color = Color(0.85, 0.15, 1.00, 0.45 + 0.20 * pulse)
	draw_circle(Vector2.ZERO, aura_radius, aura_color)
	# Stone body — six-sided dark crystal.
	var pts := PackedVector2Array()
	for i in 6:
		var a: float = (TAU / 6.0) * float(i) - PI * 0.5
		pts.append(Vector2(cos(a), sin(a)) * 80.0)
	draw_colored_polygon(pts, Color(0.12, 0.08, 0.18))
	# Inner cracks — colour intensifies as health drops.
	var hp_ratio: float = clampf(float(_health) / float(Balance.BOSS_MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE), 0.0, 1.0)
	var crack_color := Color(1.0, 0.4 * (1.0 - hp_ratio), 1.0 * (1.0 - hp_ratio * 0.5), 0.8)
	for i in 6:
		var a: float = (TAU / 6.0) * float(i) - PI * 0.5
		var inner := Vector2(cos(a), sin(a)) * 30.0
		var outer := Vector2(cos(a), sin(a)) * 70.0
		draw_line(inner, outer, crack_color, 2.5)
	# Pulsing eye / weeping heart in the centre.
	var core_alpha: float = 0.65 + 0.35 * pulse
	draw_circle(Vector2.ZERO, 22.0, Color(0.0, 0.0, 0.0, 1.0))
	draw_circle(Vector2.ZERO, 16.0, Color(1.0, 0.25, 0.85, core_alpha))
	draw_circle(Vector2.ZERO, 8.0,  Color(1.0, 0.95, 1.0, core_alpha))
	# Outer ring.
	draw_arc(Vector2.ZERO, 82.0, 0.0, TAU, 48, Color(0.7, 0.3, 1.0, 0.55), 3.0)

# =============================================================================
# PUBLIC accessors so HUD can read state for the Void Embrace bar.
# =============================================================================
func is_void_active() -> bool:
	return _void_active

func get_void_progress() -> float:
	if not _void_active:
		return 0.0
	return 1.0 - clampf(_void_channel_timer / Balance.BOSS_VOID_CHANNEL_TIME, 0.0, 1.0)

func get_phase() -> int:
	return _phase

func get_health() -> int:
	return _health

func is_invulnerable() -> bool:
	return _invulnerable
