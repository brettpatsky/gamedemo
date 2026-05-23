# =============================================================================
# FortifiedStructure.gd  (Level 4 objective — Destroy Structures)
# A heavily armoured static building. The squad must destroy it to win.
# Main.gd connects to the structure_destroyed signal after map generation.
# =============================================================================
extends StaticBody2D

signal structure_destroyed

const MAX_HEALTH: int = 90

var _health: int
var _destroyed: bool = false

@onready var health_bar: ProgressBar = $HealthBar

func _ready() -> void:
	add_to_group("structures")
	_health = MAX_HEALTH
	health_bar.max_value = MAX_HEALTH
	health_bar.value     = _health
	queue_redraw()

func take_damage(amount: int, _element: int = 0) -> void:
	if _destroyed:
		return
	_health -= amount
	health_bar.value = _health
	queue_redraw()
	if _health <= 0:
		_destroyed = true
		_destroy()

func _destroy() -> void:
	structure_destroyed.emit()
	queue_free()

func _draw() -> void:
	draw_rect(Rect2(-40, -40, 80, 80), Color(0.35, 0.35, 0.38))
	draw_rect(Rect2(-40, -40, 80, 80), Color(0.15, 0.15, 0.17), false, 3.0)
	var hp_ratio: float = float(_health) / float(MAX_HEALTH)
	var target_col := Color(0.9, 0.1, 0.1, 0.3 + 0.7 * (1.0 - hp_ratio))
	draw_line(Vector2(-28, -28), Vector2(28, 28), target_col, 5.0)
	draw_line(Vector2(28, -28), Vector2(-28, 28), target_col, 5.0)
