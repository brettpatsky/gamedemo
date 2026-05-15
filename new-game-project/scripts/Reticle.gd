# =============================================================================
# Reticle.gd
# Autoload (singleton) — present in EVERY scene. Replaces the OS cursor with
# an in-world crosshair, lets the gamepad LEFT stick steer that cursor by
# warping the OS mouse, and translates gamepad face-button presses (A / X)
# into synthetic mouse clicks at the current cursor position.
#
# Synthesising mouse events (rather than binding A/X directly to game actions)
# means every Button under the reticle — title-screen mission buttons, the
# help popup's Close button, HUD weapon / formation / revive buttons — fires
# its `pressed` signal via the same path a real mouse click takes. The result:
# the controller drives the same UI as the mouse, no per-screen focus wiring.
# =============================================================================
extends CanvasLayer

const CURSOR_SPEED := 1200.0   # pixels/sec at full stick deflection
const DEADZONE     := 0.20

# Xbox/SDL face-button indices in Godot's JoyButton enum.
const JOY_BTN_A := 0
const JOY_BTN_X := 2

var _cursor: Node2D
var _cursor_pos: Vector2

func _ready() -> void:
	layer = 100
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	_cursor = _Cursor.new()
	add_child(_cursor)
	_cursor_pos = get_viewport().get_visible_rect().get_center()
	_cursor.position = _cursor_pos

# Gamepad A / X → synthetic mouse left / right click at the cursor.
# We consume the joypad event so it doesn't ALSO fire ui_accept (which would
# double-click any focused button).
func _input(event: InputEvent) -> void:
	if not (event is InputEventJoypadButton):
		return
	var jbe := event as InputEventJoypadButton
	if jbe.button_index == JOY_BTN_A:
		_emit_mouse_click(MOUSE_BUTTON_LEFT, jbe.pressed)
		get_viewport().set_input_as_handled()
	elif jbe.button_index == JOY_BTN_X:
		_emit_mouse_click(MOUSE_BUTTON_RIGHT, jbe.pressed)
		get_viewport().set_input_as_handled()

func _emit_mouse_click(button_index: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button_index
	ev.pressed = pressed
	ev.position = get_viewport().get_mouse_position()
	ev.global_position = ev.position
	Input.parse_input_event(ev)

func _process(delta: float) -> void:
	var stick := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
	if stick.length() > DEADZONE:
		# Rescale past the deadzone so the cursor doesn't crawl at low deflection.
		var mag := (stick.length() - DEADZONE) / (1.0 - DEADZONE)
		_cursor_pos += stick.normalized() * mag * CURSOR_SPEED * minf(delta, 0.05)
		var rect := get_viewport().get_visible_rect()
		_cursor_pos.x = clamp(_cursor_pos.x, rect.position.x, rect.end.x)
		_cursor_pos.y = clamp(_cursor_pos.y, rect.position.y, rect.end.y)
		Input.warp_mouse(_cursor_pos)
	else:
		# When stick is idle, stay in sync with the physical mouse.
		_cursor_pos = get_viewport().get_mouse_position()
	_cursor.position = _cursor_pos

# Inner Node2D class — kept in this file so the whole reticle is one unit.
class _Cursor extends Node2D:
	const RADIUS  := 11.0
	const GAP     := 4.0
	const TICK    := 7.0
	const THICK   := 2.0
	const COLOR   := Color(1, 1, 1, 0.95)
	const OUTLINE := Color(0, 0, 0, 0.65)
	func _draw() -> void:
		draw_circle(Vector2.ZERO, RADIUS, OUTLINE, false, THICK + 2.0)
		draw_circle(Vector2.ZERO, RADIUS, COLOR,   false, THICK)
		for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
			var a: Vector2 = d * GAP
			var b: Vector2 = d * (GAP + TICK)
			draw_line(a, b, OUTLINE, THICK + 2.0)
			draw_line(a, b, COLOR,   THICK)
