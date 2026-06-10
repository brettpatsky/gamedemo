# =============================================================================
# CaveParent.gd
# Mother AND father standing in the cave's fairy garden. The matching kid
# reaching them frees both parents, who dissolve in a brilliant white-light
# flash. Mirrors ParentCage's API (child_slot, parent_freed / wrong_kid_entered
# signals, is_opened) so Main's _wire_parent_cage wiring needs no changes.
# =============================================================================
extends Area2D

signal parent_freed(slot: int)
signal wrong_kid_entered(slot: int)

@export var child_slot: int = 0

const PARENT_TEX := "res://resources/caves/parent_npc.png"

var _opened: bool = false
var _last_wrong_time: float = -INF
var _sprite: Sprite2D        # mother
var _father_sprite: Sprite2D # father (colour-remapped + flipped)
var _glow: Sprite2D
var _label: Label

func _ready() -> void:
	add_to_group("parent_cages")
	collision_mask = 0
	set_collision_mask_value(2, true)   # detect soldiers (layer 2)
	var cs := CollisionShape2D.new()
	var sh := CircleShape2D.new()
	sh.radius = 52.0   # wider to cover both characters
	cs.shape = sh
	add_child(cs)
	body_entered.connect(_on_body_entered)

	# Warm glow behind both parents — wider than the original single-parent version.
	_glow = Sprite2D.new()
	_glow.texture = _radial_glow(140, Color(1.0, 0.95, 0.7))
	_glow.z_index = 2
	_glow.z_as_relative = false
	add_child(_glow)

	# Mother — left of centre, faces default direction (right).
	_sprite = Sprite2D.new()
	_sprite.scale = Vector2(2.0, 2.0)
	_sprite.position = Vector2(-22.0, 0.0)
	_sprite.z_index = 3
	_sprite.z_as_relative = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if ResourceLoader.exists(PARENT_TEX):
		_sprite.texture = load(PARENT_TEX)
	add_child(_sprite)

	# Father — right of centre, flipped so he faces inward toward the mother.
	_father_sprite = Sprite2D.new()
	_father_sprite.scale = Vector2(2.0, 2.0)
	_father_sprite.position = Vector2(22.0, 0.0)
	_father_sprite.flip_h = true
	_father_sprite.z_index = 3
	_father_sprite.z_as_relative = false
	_father_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var father_tex := _create_father_tex()
	if father_tex:
		_father_sprite.texture = father_tex
	elif ResourceLoader.exists(PARENT_TEX):
		_father_sprite.texture = load(PARENT_TEX)   # fallback: reuse mother
	add_child(_father_sprite)

	_label = Label.new()
	_label.text = "Kid %d's parents" % (child_slot + 1)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-70, -112)
	_label.custom_minimum_size = Vector2(140, 0)
	_label.z_index = 4
	_label.z_as_relative = false
	add_child(_label)

func _on_body_entered(body: Node2D) -> void:
	if _opened or not body.is_in_group("soldiers"):
		return
	var slot: int = body.slot_index if "slot_index" in body else -1
	if slot == child_slot:
		_opened = true
		RunState.free_parent(slot)
		emit_signal("parent_freed", slot)
		_play_save_effect()
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_wrong_time >= 1.0:
		_last_wrong_time = now
		emit_signal("wrong_kid_entered", slot)

func _play_save_effect() -> void:
	# ── white sparkle particles ──────────────────────────────────────────────
	var sparks := CPUParticles2D.new()
	sparks.emitting         = true
	sparks.one_shot         = true
	sparks.amount           = 30
	sparks.lifetime         = 0.9
	sparks.explosiveness    = 0.95
	sparks.emission_shape   = CPUParticles2D.EMISSION_SHAPE_SPHERE
	sparks.emission_sphere_radius = 20.0
	sparks.direction        = Vector2.UP
	sparks.spread           = 180.0
	sparks.initial_velocity_min = 45.0
	sparks.initial_velocity_max = 120.0
	sparks.gravity          = Vector2.ZERO
	sparks.scale_amount_min = 3.0
	sparks.scale_amount_max = 7.0
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	grad.set_color(1, Color(1.0, 0.95, 0.45, 0.0))
	sparks.color_ramp = grad
	sparks.z_index         = 6
	sparks.z_as_relative   = false
	add_child(sparks)

	# ── concentrated white burst that rapidly expands ────────────────────────
	var flash := Sprite2D.new()
	flash.texture        = _radial_glow(220, Color.WHITE)
	flash.scale          = Vector2(0.35, 0.35)   # starts small — burst feeling
	flash.z_index        = 5
	flash.z_as_relative  = false
	add_child(flash)

	# ── tween everything in parallel ─────────────────────────────────────────
	var tw := create_tween()
	tw.set_parallel(true)

	# Parents dissolve into the expanding light.
	tw.tween_property(_sprite,        "modulate:a", 0.0, 0.45)
	tw.tween_property(_father_sprite, "modulate:a", 0.0, 0.45)
	tw.tween_property(_label,         "modulate:a", 0.0, 0.35).set_delay(0.05)

	# White flash: concentrates then explodes outward.
	tw.tween_property(flash, "scale",      Vector2(4.0, 4.0), 0.6)
	tw.tween_property(flash, "modulate:a", 0.0,               0.6).set_delay(0.08)

	# Background glow swells and fades last.
	tw.tween_property(_glow, "scale",      Vector2(5.0, 5.0), 0.8)
	tw.tween_property(_glow, "modulate:a", 0.0,               0.8).set_delay(0.1)

	# Free the node once everything has finished.
	tw.tween_callback(queue_free).set_delay(0.85)

func is_opened() -> bool:
	return _opened

# =============================================================================
# FATHER TEXTURE — colour-remaps the mother sprite:
#   red hair  → warm brown
#   teal dress → dark navy-blue
#   outlines and skin kept intact
# =============================================================================
func _create_father_tex() -> ImageTexture:
	if not ResourceLoader.exists(PARENT_TEX):
		return null
	var img: Image = (load(PARENT_TEX) as Texture2D).get_image()
	if img == null:
		return null
	var w := img.get_width()
	var h := img.get_height()
	var dst := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var c: Color = img.get_pixel(x, y)
			if c.a < 0.05:
				dst.set_pixel(x, y, Color.TRANSPARENT)
			else:
				dst.set_pixel(x, y, _remap_father(c))
	return ImageTexture.create_from_image(dst)

func _remap_father(c: Color) -> Color:
	var r := c.r;  var g := c.g;  var b := c.b;  var a := c.a
	# Dark outlines — preserve unchanged so the figure stays sharp.
	if r < 0.15 and g < 0.15 and b < 0.15:
		return c
	# Red / orange hair (R strongly dominant) → warm brown.
	if r > 0.50 and r > g * 1.7 and r > b * 2.4:
		return Color(r * 0.56, g * 0.52 + 0.06, b * 0.28, a)
	# Teal / cyan dress (G and/or B dominant over R) → dark navy-blue.
	if (g > r + 0.12 or b > r + 0.18) and (g + b) > 0.3:
		return Color(r * 0.65, g * 0.48, minf(b * 1.15 + 0.08, 1.0), a)
	return c

# Simple radial-gradient glow (no external asset).
func _radial_glow(size: int, col: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := size * 0.5
	for x in size:
		for y in size:
			var d := Vector2(x - c, y - c).length() / c
			var al := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, al * al * 0.65))
	return ImageTexture.create_from_image(img)
