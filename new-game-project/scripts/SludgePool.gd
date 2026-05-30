# =============================================================================
# SludgePool.gd  (Boss Mission — Phase 2 floor hazard)
# Patches of corrupted purple sludge spawned by the Heartstone. Any soldier
# standing inside drains the shared rifle-ammo pool at a steady rate — the
# "Mana Drain" debuff. Forces the player to keep the active group moving or
# swap to a different squad before the rifle pool runs dry.
# =============================================================================
extends Area2D

const Balance = preload("res://scripts/BalanceConfig.gd")

# Radius, drain rate, and damage tuning live in BalanceConfig (SLUDGE_*).
var _accumulator: float = 0.0
var _anim_phase:  float = 0.0
var _damage_timer: float = 0.0

# Wandering state — pool drifts toward _target_pos within an annulus around
# _anchor_pos, then picks a new target. Anchor + wander radii are pushed in
# via configure(); a zero anchor leaves the pool stationary (back-compat).
var _anchor_pos: Vector2 = Vector2.ZERO
var _wander_min: float   = 0.0
var _wander_max: float   = 0.0
var _target_pos: Vector2 = Vector2.ZERO
var _has_anchor: bool    = false

# Called by BossHeartstone immediately after add_child. Stationary pools
# (legacy behaviour) skip the call and stay where spawned.
func configure(anchor: Vector2, wander_min: float, wander_max: float) -> void:
	_anchor_pos = anchor
	_wander_min = wander_min
	_wander_max = wander_max
	_has_anchor = true
	_target_pos = _pick_target()

func _ready() -> void:
	add_to_group("sludge_pools")
	collision_layer = 0
	collision_mask  = 2   # detect soldiers
	# monitoring defaults to true (we need it); monitorable defaults to true
	# (harmless — no Area2D in the game masks our layer-0 sludge anyway). We
	# intentionally do NOT assign these in code because property writes are
	# blocked when the node is added during a physics-query flush.
	# Build the collision shape in code so the scene file isn't needed.
	var shape := CircleShape2D.new()
	shape.radius = Balance.SLUDGE_RADIUS
	var cs := CollisionShape2D.new()
	cs.shape = shape
	add_child(cs)
	queue_redraw()

func _process(delta: float) -> void:
	_anim_phase += delta
	_drift(delta)
	queue_redraw()
	var bodies: Array = get_overlapping_bodies()
	# Walk the live, undowned soldiers once and apply both the ammo drain (in
	# aggregate) and per-soldier periodic damage.
	var alive_inside: Array = []
	for b in bodies:
		if not b.is_in_group("soldiers"):
			continue
		if b.has_method("is_downed") and b.is_downed():
			continue
		alive_inside.append(b)
	if alive_inside.is_empty():
		_damage_timer = 0.0   # reset so the first soldier to step in eats a tick fast
		return
	# Rifle pool drain — aggregated across all soldiers standing in sludge.
	_accumulator += Balance.SLUDGE_DRAIN_RATE * delta * float(alive_inside.size())
	var whole: int = int(_accumulator)
	if whole > 0:
		_accumulator -= float(whole)
		GameManager.rifle_ammo_pool = maxi(GameManager.rifle_ammo_pool - whole, 0)
	# Soldier damage — per-tick chip damage on each soldier standing inside.
	_damage_timer -= delta
	if _damage_timer > 0.0:
		return
	_damage_timer = Balance.SLUDGE_DAMAGE_TICK
	for s in alive_inside:
		if s.has_method("take_damage"):
			s.take_damage(Balance.SLUDGE_DAMAGE_PER_TICK)

# Glide toward the current wander target; when within one pool radius, pick a
# new target inside the configured annulus. Stationary pools (anchor never
# set) short-circuit so legacy behaviour is preserved.
func _drift(delta: float) -> void:
	if not _has_anchor:
		return
	var to_target: Vector2 = _target_pos - global_position
	var step: float = Balance.BOSS_SLUDGE_DRIFT_SPEED * delta
	if to_target.length() <= step or to_target.length() <= Balance.SLUDGE_RADIUS * 0.5:
		_target_pos = _pick_target()
		return
	global_position += to_target.normalized() * step

# Picks a random point in the annulus [WANDER_MIN, WANDER_MAX] around the
# anchor (the boss position at spawn time). Uses sqrt() on the radius so
# samples are uniform over area, not biased toward the centre.
func _pick_target() -> Vector2:
	var ang: float = randf() * TAU
	var t: float = randf()
	var r: float = sqrt(lerpf(_wander_min * _wander_min, _wander_max * _wander_max, t))
	return _anchor_pos + Vector2(cos(ang), sin(ang)) * r

func _draw() -> void:
	# Layered violet pools — outer halo + main body + writhing inner rim.
	draw_circle(Vector2.ZERO, Balance.SLUDGE_RADIUS,        Color(0.30, 0.05, 0.45, 0.35))
	draw_circle(Vector2.ZERO, Balance.SLUDGE_RADIUS * 0.85, Color(0.45, 0.10, 0.65, 0.55))
	draw_circle(Vector2.ZERO, Balance.SLUDGE_RADIUS * 0.55, Color(0.65, 0.20, 0.85, 0.65))
	# Three slowly drifting bubbles to sell the "alive" feel.
	for i in 3:
		var phase: float = _anim_phase * 0.8 + float(i) * (TAU / 3.0)
		var r: float = Balance.SLUDGE_RADIUS * (0.35 + 0.10 * sin(phase * 1.7))
		var pos := Vector2(cos(phase), sin(phase)) * (Balance.SLUDGE_RADIUS * 0.45)
		draw_circle(pos, r * 0.20, Color(0.9, 0.6, 1.0, 0.55))
	draw_arc(Vector2.ZERO, Balance.SLUDGE_RADIUS, 0.0, TAU, 48, Color(0.85, 0.50, 1.0, 0.75), 2.5)
