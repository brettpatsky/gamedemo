# =============================================================================
# ExtractionZone.gd  (Level 3 objective marker)
# When the escort NPC ("escort_npc" group) enters this zone, npc_extracted
# fires. Main.gd connects this to mission-win.
# =============================================================================
extends Area2D

signal npc_extracted

var _triggered: bool = false

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	queue_redraw()

func _on_body_entered(body: Node2D) -> void:
	if _triggered:
		return
	if body.is_in_group("escort_npc"):
		_triggered = true
		npc_extracted.emit()

func _draw() -> void:
	draw_circle(Vector2.ZERO, 50.0, Color(0.1, 0.9, 0.1, 0.25))
	draw_arc(Vector2.ZERO, 50.0, 0.0, TAU, 48, Color(0.0, 0.8, 0.0), 3.0)
	var pts := PackedVector2Array([
		Vector2(-18,  8), Vector2(0, -18), Vector2(18,  8),
		Vector2(12,   8), Vector2(0,  -8), Vector2(-12,  8)
	])
	draw_colored_polygon(pts, Color(0.0, 0.7, 0.0, 0.6))
