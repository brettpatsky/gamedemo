# =============================================================================
# LoadingScreen.gd  — autoload singleton (CanvasLayer)
# Covers the screen with a pixel-art splash during scene reloads.
#
# Usage:
#   LoadingScreen.show_loading()   # before reload_current_scene()
#   LoadingScreen.hide_loading()   # from Main._ready() once setup is done
# =============================================================================
extends CanvasLayer

const ART_PATH := "res://resources/loading_screen.png"

var _root:  Control     = null   # faded as a unit (CanvasLayer has no modulate)
var _tween: Tween       = null

func _ready() -> void:
	layer   = 100
	visible = false

	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.04, 0.08)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)

	var art := TextureRect.new()
	art.expand_mode  = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if ResourceLoader.exists(ART_PATH):
		art.texture = load(ART_PATH)
	_root.add_child(art)

	var lbl := Label.new()
	lbl.text                 = "Loading..."
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_BOTTOM
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.offset_bottom        = -24.0
	lbl.add_theme_font_size_override("font_size", 24)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_root.add_child(lbl)

func show_loading() -> void:
	if _tween:
		_tween.kill()
		_tween = null
	_root.modulate.a = 1.0
	visible          = true

func hide_loading() -> void:
	if not visible:
		return
	_tween = create_tween()
	_tween.tween_property(_root, "modulate:a", 0.0, 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(func() -> void:
		visible          = false
		_root.modulate.a = 1.0
	)
