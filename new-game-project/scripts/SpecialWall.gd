# =============================================================================
# SpecialWall.gd
# A destructible wall that ignores damage below a configurable threshold.
# Used by the tutorial for two distinct puzzles:
#
#   Grenade Wall   — min_damage = 5  (pistol/staff = 1 ignored; grenade = 12 breaks it)
#   Sacrifice Wall — min_damage = 13 (grenade = 12 ignored; sacrifice = 15 breaks it)
#
# In group "structures" so Soldier._explode and Grenade._deal_damage find it
# via their normal group iteration.
# =============================================================================
class_name SpecialWall
extends StaticBody2D

signal destroyed

@export var width:                  float  = 96.0
@export var height:                 float  = 96.0
@export var max_health:             int    = 24
@export var min_damage_to_register: int    = 5
@export var hint_text:              String = ""

var _health:    int
var _destroyed: bool = false

func _ready() -> void:
	add_to_group("structures")
	_health = max_health
	var shape := RectangleShape2D.new()
	shape.size = Vector2(width, height)
	var cs := CollisionShape2D.new()
	cs.shape = shape
	add_child(cs)
	collision_layer = 1
	collision_mask  = 0
	queue_redraw()

func take_damage(amount: int) -> void:
	if _destroyed or amount < min_damage_to_register:
		return
	_health -= amount
	queue_redraw()
	if _health <= 0:
		_destroyed = true
		destroyed.emit()
		queue_free()

func _draw() -> void:
	var ratio: float = float(_health) / float(max_health)
	var base := Color(0.55, 0.30, 0.25).lerp(Color(0.30, 0.18, 0.18), 1.0 - ratio)
	var rect := Rect2(-width * 0.5, -height * 0.5, width, height)
	draw_rect(rect, base)
	draw_rect(rect, base.darkened(0.45), false, 3.0)
	# Crack marks scale with damage so the player can read progress without a bar.
	if ratio < 0.95:
		var crack := Color(0.10, 0.08, 0.08, 0.75)
		draw_line(Vector2(-width * 0.4, -height * 0.3),
				Vector2(width * 0.2, height * 0.4), crack, 2.5)
	if ratio < 0.5:
		var crack := Color(0.10, 0.08, 0.08, 0.75)
		draw_line(Vector2(width * 0.3, -height * 0.35),
				Vector2(-width * 0.1, height * 0.2), crack, 2.5)
	if hint_text != "":
		draw_string(
			ThemeDB.fallback_font,
			Vector2(-width * 0.6, -height * 0.5 - 10),
			hint_text,
			HORIZONTAL_ALIGNMENT_CENTER, width * 1.2, 12,
			Color(1, 1, 0.75)
		)
