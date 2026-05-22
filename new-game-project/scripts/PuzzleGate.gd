# =============================================================================
# PuzzleGate.gd
# A solid wall that blocks the squad until open() is called. Used between
# tutorial rooms; opens with a short fade-out when its room's puzzle is
# solved. Built in code (no .tscn) so TutorialLevel1 can spawn them at
# arbitrary doorway positions without authoring scenes.
# =============================================================================
class_name PuzzleGate
extends StaticBody2D

@export var width:  float = 64.0
@export var height: float = 128.0

var _opened: bool = false
var _shape:  CollisionShape2D = null

func _ready() -> void:
	add_to_group("puzzle_gates")
	var shape := RectangleShape2D.new()
	shape.size = Vector2(width, height)
	_shape = CollisionShape2D.new()
	_shape.shape = shape
	add_child(_shape)
	collision_layer = 1   # environment layer — soldiers/bullets see this as a wall
	collision_mask  = 0
	queue_redraw()

func open() -> void:
	if _opened:
		return
	_opened = true
	if _shape:
		_shape.set_deferred("disabled", true)
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.4)
	tween.tween_callback(queue_free)

func is_opened() -> bool:
	return _opened

func _draw() -> void:
	var col := Color(0.45, 0.25, 0.55, 0.95)
	var rect := Rect2(-width * 0.5, -height * 0.5, width, height)
	draw_rect(rect, col)
	draw_rect(rect, col.darkened(0.4), false, 3.0)
	# Inner glyph — three horizontal bars, clearly different from plain walls.
	for i in range(-1, 2):
		var y := float(i) * height * 0.25
		draw_line(Vector2(-width * 0.3, y), Vector2(width * 0.3, y),
				Color(0.85, 0.55, 1.0, 0.7), 2.0)
