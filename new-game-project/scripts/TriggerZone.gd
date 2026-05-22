# =============================================================================
# TriggerZone.gd
# A configurable Area2D used for tutorial puzzles. Three visual styles
# (pressure plate / ritual circle / identity zone), with an optional
# `required_slot` filter so the IDENTITY style only counts the matching kid.
#
# Emits `state_changed(pressed: bool)` on the rising and falling edge — i.e.
# when occupants go 0→1 and 1→0. Multiple soldiers piling on don't fire
# extra signals.
# =============================================================================
class_name TriggerZone
extends Area2D

enum Style { PLATE, CIRCLE, IDENTITY }

signal state_changed(pressed: bool)

@export var radius:        float = 36.0
@export var style:         Style = Style.PLATE
@export var required_slot: int   = -1   # -1 = any soldier; else only matching slot

var _occupants: int = 0

func _ready() -> void:
	var shape := CircleShape2D.new()
	shape.radius = radius
	var cs := CollisionShape2D.new()
	cs.shape = shape
	add_child(cs)
	collision_layer = 0
	collision_mask  = 2   # soldiers live on layer 2
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	queue_redraw()

func _on_body_entered(body: Node2D) -> void:
	if not _accepts(body):
		return
	_occupants += 1
	if _occupants == 1:
		state_changed.emit(true)
		queue_redraw()

func _on_body_exited(body: Node2D) -> void:
	if not _accepts(body):
		return
	_occupants = maxi(_occupants - 1, 0)
	if _occupants == 0:
		state_changed.emit(false)
		queue_redraw()

func _accepts(body: Node2D) -> bool:
	if not body.is_in_group("soldiers"):
		return false
	if required_slot < 0:
		return true
	if not ("slot_index" in body):
		return false
	return body.slot_index == required_slot

func is_pressed() -> bool:
	return _occupants > 0

# Placeholder visuals — replace with real art once tile/sprite assets land.
func _draw() -> void:
	var active: bool = is_pressed()
	match style:
		Style.PLATE:
			var col: Color = Color(0.65, 0.55, 0.30) if not active else Color(0.95, 0.85, 0.45)
			var rect := Rect2(-radius, -radius * 0.55, radius * 2, radius * 1.1)
			draw_rect(rect, col)
			draw_rect(rect, col.darkened(0.45), false, 2.5)
			# Centre stud — flips colour when pressed.
			draw_circle(Vector2.ZERO, radius * 0.18,
					Color(0.3, 0.25, 0.15) if not active else Color(1, 0.95, 0.7))
		Style.CIRCLE:
			var col: Color = Color(0.55, 0.35, 0.95, 0.45) if not active \
					else Color(1.0, 0.85, 0.35, 0.85)
			draw_circle(Vector2.ZERO, radius, col)
			draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32,
					col.lightened(0.3) if active else col, 2.5)
			# Five-pointed star inside to suggest "ritual"
			var pts := PackedVector2Array()
			var r_in: float  = radius * 0.4
			var r_out: float = radius * 0.7
			for i in 10:
				var a := -PI * 0.5 + i * PI / 5.0
				var r: float = r_out if i % 2 == 0 else r_in
				pts.append(Vector2(cos(a), sin(a)) * r)
			draw_colored_polygon(pts,
					Color(1, 1, 0.7, 0.85) if active else Color(0.9, 0.7, 1.0, 0.55))
		Style.IDENTITY:
			var col: Color = Color(0.45, 0.65, 0.95) if not active else Color(0.55, 1.0, 0.75)
			draw_circle(Vector2.ZERO, radius, Color(col.r, col.g, col.b, 0.30))
			draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32, col, 2.5)
			if required_slot >= 0:
				draw_string(
					ThemeDB.fallback_font,
					Vector2(-60, -radius - 10),
					"Kid %d only" % (required_slot + 1),
					HORIZONTAL_ALIGNMENT_CENTER, 120, 13,
					Color(1, 1, 0.8)
				)
