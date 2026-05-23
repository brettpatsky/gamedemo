# =============================================================================
# ExtractionZone.gd  (Level 5 objective marker)
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
	# Radius matches the CircleShape2D in extraction_zone.tscn — keep them
	# in sync or the visible disc won't match where the trigger actually fires.
	const R := 90.0
	draw_circle(Vector2.ZERO, R, Color(0.1, 0.9, 0.1, 0.25))
	draw_arc(Vector2.ZERO, R, 0.0, TAU, 48, Color(0.0, 0.8, 0.0), 3.0)
	# Up-arrow glyph in the centre, scaled to roughly half the radius.
	var pts := PackedVector2Array([
		Vector2(-32, 14), Vector2(0, -32), Vector2(32, 14),
		Vector2(22, 14), Vector2(0, -14), Vector2(-22, 14)
	])
	draw_colored_polygon(pts, Color(0.0, 0.7, 0.0, 0.6))
