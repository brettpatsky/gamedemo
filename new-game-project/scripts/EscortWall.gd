# =============================================================================
# EscortWall.gd  (Level 3 — destructible barrier around the escort NPC)
# A small fortification surrounding the trapped NPC. When any wall is shot
# down, MapGenerator unseals the safe area and releases the NPC so it can
# follow the squad.
# =============================================================================
extends StaticBody2D

signal wall_destroyed

const MAX_HEALTH: int = 25

var _health: int

@onready var health_bar: ProgressBar = $HealthBar

func _ready() -> void:
	add_to_group("escort_walls")
	_health = MAX_HEALTH
	health_bar.max_value = MAX_HEALTH
	health_bar.value     = _health
	queue_redraw()

func take_damage(amount: int) -> void:
	_health -= amount
	health_bar.value = _health
	queue_redraw()
	if _health <= 0:
		_destroy()

func _destroy() -> void:
	wall_destroyed.emit()
	queue_free()

func _draw() -> void:
	draw_rect(Rect2(-28, -28, 56, 56), Color(0.45, 0.32, 0.22))
	draw_rect(Rect2(-28, -28, 56, 56), Color(0.20, 0.13, 0.08), false, 2.5)
	# Horizontal plank lines for a wood-fortification look
	for y in [-14, 0, 14]:
		draw_line(Vector2(-28, y), Vector2(28, y), Color(0.20, 0.13, 0.08), 1.5)
