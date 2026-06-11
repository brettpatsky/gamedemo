# =============================================================================
# MemoryFragment.gd
# A hidden collectable item — one of three placed on each level. Touching it
# records it in RunState's per-level buffer; the reward picker at mission end
# only offers bonuses for fragments the player actually found.
# =============================================================================
extends Area2D

signal collected(id: String, display_name: String)

@export var fragment_id:   String = "fragment_unknown"
@export var display_name:  String = "Memory Fragment"

var _collected: bool = false
var _sprite: Sprite2D = null

func _ready() -> void:
	add_to_group("memory_fragments")
	body_entered.connect(_on_body_entered)

	var img_path := "res://resources/fragments/%s.png" % fragment_id
	if ResourceLoader.exists(img_path):
		_sprite = Sprite2D.new()
		_sprite.texture = load(img_path)
		_sprite.scale = Vector2(0.75, 0.75)
		_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_sprite)
		# Very subtle pulse — just enough to be findable without being obvious.
		var tw := create_tween().set_loops()
		tw.tween_property(_sprite, "scale", Vector2(0.82, 0.82), 0.9)
		tw.tween_property(_sprite, "scale", Vector2(0.68, 0.68), 0.9)
	else:
		queue_redraw()

func _on_body_entered(body: Node2D) -> void:
	if _collected or not body.is_in_group("soldiers"):
		return
	_collected = true
	RunState.note_found_fragment(fragment_id)
	emit_signal("collected", fragment_id, display_name)
	queue_free()

# Fallback drawn circle shown when the image asset has not yet been imported.
func _draw() -> void:
	if _sprite != null:
		return
	draw_circle(Vector2.ZERO, 9.0, Color(0.5, 0.85, 1.0, 0.55))
	draw_arc(Vector2.ZERO, 9.0, 0.0, TAU, 24, Color(0.9, 1.0, 1.0), 1.0)
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, -6), Vector2(2, 0), Vector2(0, 6), Vector2(-2, 0),
	]), Color(1, 1, 1, 0.9))
