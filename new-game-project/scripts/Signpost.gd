# =============================================================================
# Signpost.gd
# A self-contained, editor-placeable tutorial sign. Shows a Caraka Sign sprite
# with a blinking "?" and, when left-clicked, opens a dismissable instruction
# modal carrying this node's `text`. Self-contained (no map support needed) so
# it can be dropped anywhere in a hand-authored level.
#
# Click detection is by proximity in _input() so it fires BEFORE
# SquadController._unhandled_input consumes the left-click for a move order;
# a hit marks the event handled to suppress that move.
# =============================================================================
class_name Signpost
extends Node2D

@export_multiline var text: String = "Tutorial hint"
# World-space radius around the sign within which a left-click opens the modal.
@export var click_radius: float = 56.0

const _MODAL_W := 500.0
const _MODAL_H := 340.0
const _MODAL_BG := "res://resources/tutorial_modal.png"

var _active_modal: CanvasLayer = null

func _ready() -> void:
	add_to_group("tutorial_signposts")
	# Blink the "?" hint so it reads as interactive.
	var hint := get_node_or_null("Hint") as Label
	if hint:
		var tw := create_tween().set_loops()
		tw.tween_property(hint, "modulate:a", 0.2, 0.55)
		tw.tween_property(hint, "modulate:a", 1.0, 0.55)

func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mbe := event as InputEventMouseButton
	if not (mbe.pressed and mbe.button_index == MOUSE_BUTTON_LEFT):
		return
	if _active_modal != null:
		return   # the overlay's gui_input closes the modal via call_deferred
	if (get_global_mouse_position() - global_position).length() < click_radius:
		_show_modal()
		get_viewport().set_input_as_handled()

# ---------------------------------------------------------------------------
# Modal — full-screen overlay (transparent so the game stays visible) with the
# tutorial_modal.png card and this sign's text. Click anywhere to dismiss.
# ---------------------------------------------------------------------------
func _show_modal() -> void:
	if _active_modal != null:
		return
	var vp_size := get_viewport().get_visible_rect().size

	var modal := CanvasLayer.new()
	modal.layer = 50
	_active_modal = modal
	add_child(modal)

	var overlay := ColorRect.new()
	overlay.size = vp_size
	overlay.color = Color(0, 0, 0, 0)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			# Deferred so _active_modal is still set when _input() runs this frame —
			# stops the same click from immediately re-opening the sign.
			_close_modal.call_deferred()
	)
	modal.add_child(overlay)

	var panel := Control.new()
	panel.size = Vector2(_MODAL_W, _MODAL_H)
	panel.position = Vector2(
		vp_size.x * 0.5 - _MODAL_W * 0.5,
		vp_size.y * 0.5 - _MODAL_H * 0.5
	)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	modal.add_child(panel)

	if ResourceLoader.exists(_MODAL_BG):
		var bg := TextureRect.new()
		bg.texture = load(_MODAL_BG)
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		bg.size = Vector2(_MODAL_W, _MODAL_H)
		bg.mouse_filter = Control.MOUSE_FILTER_PASS
		panel.add_child(bg)

	const MARGIN := 52.0
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size = Vector2(_MODAL_W - MARGIN * 2, _MODAL_H - MARGIN * 2 - 24)
	lbl.position = Vector2(MARGIN, MARGIN + 8)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", Color(0.18, 0.10, 0.04))
	lbl.add_theme_color_override("font_outline_color", Color(1.0, 0.9, 0.65, 0.35))
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lbl)

	panel.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, 0.22)

func _close_modal() -> void:
	if _active_modal == null:
		return
	_active_modal.queue_free()
	_active_modal = null
