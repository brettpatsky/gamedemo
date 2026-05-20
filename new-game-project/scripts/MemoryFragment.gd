# =============================================================================
# MemoryFragment.gd
# A glowing memento from the real world. Any kid touching it collects it for
# the rest of the run. The id is recorded in RunState.fragments; effects are
# applied by gameplay code that consults that list (e.g. the reward screen).
# =============================================================================
extends Area2D

signal collected(id: String, display_name: String)

@export var fragment_id:   String = "fragment_unknown"
@export var display_name:  String = "Memory Fragment"

var _collected: bool = false

func _ready() -> void:
	add_to_group("memory_fragments")
	body_entered.connect(_on_body_entered)
	queue_redraw()

func _on_body_entered(body: Node2D) -> void:
	if _collected or not body.is_in_group("soldiers"):
		return
	_collected = true
	RunState.collect_fragment(fragment_id)
	emit_signal("collected", fragment_id, display_name)
	queue_free()

func _draw() -> void:
	draw_circle(Vector2.ZERO, 18.0, Color(0.5, 0.85, 1.0, 0.55))
	draw_arc(Vector2.ZERO, 18.0, 0.0, TAU, 32, Color(0.9, 1.0, 1.0), 1.5)
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, -12), Vector2(4, 0), Vector2(0, 12), Vector2(-4, 0),
	]), Color(1, 1, 1, 0.9))
