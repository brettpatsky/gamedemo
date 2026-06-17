# =============================================================================
# LoadingScreen.gd  — autoload singleton (CanvasLayer)
# Covers the screen with a randomly chosen pixel-art splash during scene reloads.
#
# Usage:
#   LoadingScreen.show_loading()   # before reload_current_scene()
#   LoadingScreen.hide_loading()   # from Main._ready() once setup is done
# =============================================================================
extends CanvasLayer

const ART_PATHS: Array[String] = [
	"res://resources/loading_screen_1.png",
	"res://resources/loading_screen_2.png",
	"res://resources/loading_screen_3.png",
	"res://resources/loading_screen_4.png",
	"res://resources/loading_screen_5.png",
	"res://resources/loading_screen_6.png",
]

var _root:  Control = null   # faded as a unit (CanvasLayer has no modulate)
var _art:   TextureRect = null
var _tween: Tween = null

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

	_art = TextureRect.new()
	_art.expand_mode  = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_art)

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
	_pick_random_art()
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

func _pick_random_art() -> void:
	var available: Array[String] = ART_PATHS.filter(
		func(p: String) -> bool: return ResourceLoader.exists(p)
	)
	if available.is_empty():
		return
	var path: String = available[randi() % available.size()]
	_art.texture = load(path)
