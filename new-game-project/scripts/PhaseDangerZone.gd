# =============================================================================
# PhaseDangerZone.gd  (Boss Mission — telegraphed floor AOE)
# A large circular zone that's drawn for WARN_DURATION as a pulsing red
# telegraph (no damage), then "activates" for DAMAGE_DURATION dealing periodic
# damage to any soldier standing inside, then frees itself.
#
# Replaces the Phase 1 rotating beams: forces the squad to move out of the
# telegraphed footprint within ~2 seconds rather than offering a safe corner.
# =============================================================================
extends Area2D

const RADIUS:          float = 150.0
const DAMAGE_TICK:     float = 0.4
const DAMAGE_PER_TICK: int   = 1

# Per-zone timing — instances overwrite these via configure() so Phase 1 and
# Phase 3 can have different telegraph / damage windows.
var warn_duration:   float = 1.8
var damage_duration: float = 2.0

var _elapsed:     float = 0.0
var _tick_timer:  float = 0.0
var _pulse_phase: float = 0.0

func configure(p_warn: float, p_damage: float) -> void:
	warn_duration   = p_warn
	damage_duration = p_damage

func _ready() -> void:
	add_to_group("danger_zones")
	collision_layer = 0
	collision_mask  = 2   # detect soldiers
	# monitoring/monitorable defaults are fine; do not assign during physics
	# flushing — the same caveat that bit SludgePool.
	var shape := CircleShape2D.new()
	shape.radius = RADIUS
	var cs := CollisionShape2D.new()
	cs.shape = shape
	add_child(cs)
	queue_redraw()

func _process(delta: float) -> void:
	_elapsed     += delta
	_pulse_phase += delta
	queue_redraw()
	if _elapsed >= warn_duration + damage_duration:
		queue_free()
		return
	if _elapsed < warn_duration:
		return   # telegraph phase — visual only
	# Damage phase — periodic ticks while soldiers stand inside.
	_tick_timer -= delta
	if _tick_timer > 0.0:
		return
	_tick_timer = DAMAGE_TICK
	for body in get_overlapping_bodies():
		if not body.is_in_group("soldiers"):
			continue
		if body.has_method("is_downed") and body.is_downed():
			continue
		if body.has_method("take_damage"):
			body.take_damage(DAMAGE_PER_TICK)

func _draw() -> void:
	if _elapsed < warn_duration:
		_draw_telegraph()
	else:
		_draw_active()

func _draw_telegraph() -> void:
	# Bright, fast-flashing outline so the danger zone is impossible to miss.
	var t: float = clampf(_elapsed / warn_duration, 0.0, 1.0)
	var pulse: float = 0.5 + 0.5 * sin(_pulse_phase * 14.0)
	var fill_alpha: float = 0.10 + 0.20 * pulse + 0.15 * t
	var ring_alpha: float = 0.55 + 0.40 * pulse
	draw_circle(Vector2.ZERO, RADIUS, Color(1.0, 0.20, 0.55, fill_alpha))
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 64, Color(1.0, 0.45, 0.95, ring_alpha), 6.0)
	# X mark across the centre so the player can clock the zone shape at a glance.
	var arm: float = RADIUS * 0.38
	var x_col := Color(1.0, 0.6, 1.0, ring_alpha * 0.9)
	draw_line(Vector2(-arm, -arm), Vector2( arm,  arm), x_col, 5.0)
	draw_line(Vector2( arm, -arm), Vector2(-arm,  arm), x_col, 5.0)

func _draw_active() -> void:
	var t: float = clampf((_elapsed - warn_duration) / damage_duration, 0.0, 1.0)
	var fade: float = 1.0 - t * 0.35
	var pulse: float = 0.5 + 0.5 * sin(_pulse_phase * 22.0)
	# Saturated magenta fill — clear "this is hurting you" signalling.
	draw_circle(Vector2.ZERO, RADIUS,        Color(1.00, 0.15, 0.55, 0.55 * fade))
	draw_circle(Vector2.ZERO, RADIUS * 0.80, Color(1.00, 0.40, 0.85, 0.55 * fade))
	draw_circle(Vector2.ZERO, RADIUS * 0.30, Color(1.00, 0.85, 1.00, 0.45 + 0.40 * pulse))
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 72, Color(1.0, 0.65, 1.0, 0.90 * fade), 6.5)
