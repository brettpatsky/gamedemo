# =============================================================================
# CaveParent.gd
# The captured parent standing in the cave's fairy garden (no cage). The matching
# kid reaching them frees the parent. Mirrors ParentCage's API (child_slot +
# parent_freed / wrong_kid_entered signals + is_opened) so Main's existing
# _wire_parent_cage wiring drives it unchanged.
# =============================================================================
extends Area2D

signal parent_freed(slot: int)
signal wrong_kid_entered(slot: int)

@export var child_slot: int = 0

const PARENT_TEX := "res://resources/caves/parent_npc.png"

var _opened: bool = false
var _last_wrong_time: float = -INF
var _sprite: Sprite2D
var _glow: Sprite2D

func _ready() -> void:
	add_to_group("parent_cages")        # so Main can find it like a cage
	collision_mask = 0
	set_collision_mask_value(2, true)   # detect soldiers (layer 2)
	var cs := CollisionShape2D.new()
	var sh := CircleShape2D.new()
	sh.radius = 38.0
	cs.shape = sh
	add_child(cs)
	body_entered.connect(_on_body_entered)

	# Soft glow halo behind the parent.
	_glow = Sprite2D.new()
	_glow.texture = _radial_glow(96, Color(1.0, 0.95, 0.7))
	_glow.z_index = 2
	_glow.z_as_relative = false
	add_child(_glow)

	_sprite = Sprite2D.new()
	_sprite.scale = Vector2(2.0, 2.0)
	_sprite.z_index = 3
	_sprite.z_as_relative = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if ResourceLoader.exists(PARENT_TEX):
		_sprite.texture = load(PARENT_TEX)
	add_child(_sprite)

	var lbl := Label.new()
	lbl.text = "Kid %d's parent" % (child_slot + 1)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-70, -104)
	lbl.custom_minimum_size = Vector2(140, 0)
	lbl.z_index = 4
	lbl.z_as_relative = false
	add_child(lbl)

func _on_body_entered(body: Node2D) -> void:
	if _opened or not body.is_in_group("soldiers"):
		return
	var slot: int = body.slot_index if "slot_index" in body else -1
	if slot == child_slot:
		_opened = true
		RunState.free_parent(slot)
		emit_signal("parent_freed", slot)
		# Brighten + drift up on rescue.
		var tw := create_tween()
		tw.tween_property(_sprite, "position:y", _sprite.position.y - 18.0, 0.6)
		tw.parallel().tween_property(_glow, "scale", Vector2(1.5, 1.5), 0.6)
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_wrong_time >= 1.0:
		_last_wrong_time = now
		emit_signal("wrong_kid_entered", slot)

func is_opened() -> bool:
	return _opened

# A simple radial-gradient glow texture (no asset dependency).
func _radial_glow(size: int, col: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := size * 0.5
	for x in size:
		for y in size:
			var d := Vector2(x - c, y - c).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a * a * 0.65))
	return ImageTexture.create_from_image(img)
