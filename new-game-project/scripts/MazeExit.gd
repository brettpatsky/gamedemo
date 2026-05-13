# =============================================================================
# MazeExit.gd  (Level 4 escape goal)
# Attached to the Area2D created by MazeLevel.gd. Emits `escaped` when the
# soldier (group "soldiers") steps inside. MazeLevel re-emits it on its own
# `escaped` signal so Main.gd can wire mission-win to a single source.
# =============================================================================
extends Area2D

signal escaped

var _triggered: bool = false

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	queue_redraw()

func _on_body_entered(body: Node2D) -> void:
	if _triggered:
		return
	if body.is_in_group("soldiers"):
		_triggered = true
		escaped.emit()

func _draw() -> void:
	draw_circle(Vector2.ZERO, 40.0, Color(0.1, 0.9, 0.1, 0.25))
	draw_arc(Vector2.ZERO, 40.0, 0.0, TAU, 48, Color(0.0, 0.8, 0.0), 3.0)
	var pts := PackedVector2Array([
		Vector2(-14,  6), Vector2(0, -14), Vector2(14,  6),
		Vector2( 10,  6), Vector2(0,  -6), Vector2(-10, 6)
	])
	draw_colored_polygon(pts, Color(0.0, 0.7, 0.0, 0.6))
