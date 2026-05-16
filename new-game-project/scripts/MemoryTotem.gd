# =============================================================================
# MemoryTotem.gd  (Boss Mission — Phase 2 objective)
# Pillars summoned by the Heartstone that guard the boss while it's invulnerable.
# The squad must destroy all three to bring the Heartstone back into Phase 3.
#
# Balance: the shield regenerates *continuously* (not on a hit-delay timer).
# A six-soldier pistol volley puts out ~12 dps, and the totem heals 16 hp/s —
# so pistol alone can never kill a totem. Rifle (~50 dps with full squad) or a
# grenade burst (12 instant) are required, exactly per the boss design.
# A delay-based regen failed because six asynchronous pistols hit too densely
# to ever trigger the "no recent hit" condition.
# =============================================================================
extends StaticBody2D

signal totem_destroyed

const MAX_HEALTH:    int   = 80
const REGEN_RATE:    float = 16.0   # HP / second restored continuously

var _health:      float = MAX_HEALTH
var _destroyed:   bool  = false
var _pulse_phase: float = 0.0

@onready var health_bar: ProgressBar = $HealthBar

func _ready() -> void:
	add_to_group("structures")    # damaged by bullets/grenades; ignored by auto-defend
	add_to_group("memory_totems")
	collision_layer = 1
	collision_mask  = 0
	health_bar.max_value = MAX_HEALTH
	health_bar.value     = _health
	queue_redraw()

func _process(delta: float) -> void:
	if _destroyed:
		return
	_pulse_phase += delta
	if _health < MAX_HEALTH:
		_health = minf(_health + REGEN_RATE * delta, float(MAX_HEALTH))
		health_bar.value = _health
	queue_redraw()

func take_damage(amount: int) -> void:
	if _destroyed:
		return
	_health -= amount
	health_bar.value = _health
	queue_redraw()
	if _health <= 0:
		_destroyed = true
		totem_destroyed.emit()
		queue_free()

func _draw() -> void:
	var hp_ratio: float = clampf(_health / float(MAX_HEALTH), 0.0, 1.0)
	# Inner corrupted core — deep violet.
	draw_circle(Vector2.ZERO, 32.0, Color(0.25, 0.05, 0.45))
	draw_circle(Vector2.ZERO, 22.0, Color(0.55, 0.15, 0.85))
	# Pulsing shield ring — bright when at full health, dim/cracked when low.
	var pulse: float = 0.5 + 0.5 * sin(_pulse_phase * 4.0)
	var ring_alpha: float = 0.35 + 0.45 * hp_ratio * pulse
	draw_arc(Vector2.ZERO, 46.0, 0.0, TAU, 32, Color(0.95, 0.7, 1.0, ring_alpha), 5.0)
	draw_arc(Vector2.ZERO, 38.0, 0.0, TAU, 32, Color(0.7, 0.3, 1.0), 2.0)
	# Carved memory rune lines so the totem reads as a magical fixture.
	var runes := PackedVector2Array([
		Vector2(-14, -10), Vector2(14, -10),
		Vector2(-10,   0), Vector2(10,   0),
		Vector2(-14,  10), Vector2(14,  10),
	])
	for i in range(0, runes.size(), 2):
		draw_line(runes[i], runes[i + 1], Color(1.0, 0.85, 0.4, 0.7), 2.0)
