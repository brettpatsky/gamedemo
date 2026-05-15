# =============================================================================
# Reticle.gd
# Replaces the OS mouse cursor with an in-world crosshair, and lets the
# gamepad right stick steer that cursor by warping the OS mouse position.
# Attach to a CanvasLayer in main.tscn — it owns a Node2D child (created in
# _ready) whose _draw paints the crosshair at the current mouse position.
# =============================================================================
extends CanvasLayer

const CURSOR_SPEED := 1200.0   # pixels/sec at full stick deflection
const DEADZONE     := 0.20

var _cursor: Node2D

func _ready() -> void:
	layer = 100
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	_cursor = _Cursor.new()
	add_child(_cursor)
	_cursor.position = get_viewport().get_mouse_position()

# Restore the OS cursor on scene change so the title screen / other scenes
# don't inherit our hidden state.
func _exit_tree() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _process(delta: float) -> void:
	var stick := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if stick.length() > DEADZONE:
		# Rescale past the deadzone so the cursor doesn't crawl at low deflection.
		var mag := (stick.length() - DEADZONE) / (1.0 - DEADZONE)
		var pos := get_viewport().get_mouse_position() + stick.normalized() * mag * CURSOR_SPEED * delta
		var rect := get_viewport().get_visible_rect()
		pos.x = clamp(pos.x, 0.0, rect.size.x)
		pos.y = clamp(pos.y, 0.0, rect.size.y)
		Input.warp_mouse(pos)
	_cursor.position = get_viewport().get_mouse_position()

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
