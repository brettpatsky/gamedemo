extends Control
# =============================================================================
# TouchAimStick.gd — on-screen twin-stick AIM pad for touch play.
#
# Press the pad and drag toward where you want the squad to shoot; the squad
# fires in that direction — so it works on doors / structures, not just enemies,
# and it fires even when no enemy is on screen. A press with almost no drag
# falls back to auto-aiming the nearest enemy, keeping the common case effortless.
#
# Emits aim_input(active, vec) where `vec` is the raw drag offset in pixels from
# the pad centre. The top-down camera is un-rotated, so screen-space drag
# direction equals world-space aim direction; the SquadController normalises it.
#
# Touches arrive as emulated mouse events (project has emulate_mouse_from_touch
# enabled), so handling mouse button/motion here covers both finger and (for
# editor testing) the mouse.
# =============================================================================

signal aim_input(active: bool, vec: Vector2)

const RADIUS      := 78.0   # pad radius (px); 2×RADIUS = the 156px FIRE footprint
const KNOB_RADIUS := 30.0
const DEADZONE    := 18.0   # below this drag, treat as "auto-aim nearest enemy"

var _pressing := false
var _knob: Vector2 = Vector2.ZERO   # knob offset from centre, clamped to RADIUS

func _ready() -> void:
	custom_minimum_size = Vector2(RADIUS * 2.0, RADIUS * 2.0)
	mouse_filter = Control.MOUSE_FILTER_STOP

func _center() -> Vector2:
	return size * 0.5

# Press must start on the pad — handled here so the pad consumes the event and
# no squad-move order leaks through to the field underneath.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and (event as InputEventMouseButton).pressed:
		_pressing = true
		_update_knob(get_local_mouse_position())
		aim_input.emit(true, _knob)
		accept_event()
		queue_redraw()

# Once pressing, track drag/release globally so the finger can slide off the pad
# without dropping the aim.
func _input(event: InputEvent) -> void:
	if not _pressing:
		return
	if event is InputEventMouseMotion:
		_update_knob(get_local_mouse_position())
		aim_input.emit(true, _knob)
		queue_redraw()
	elif event is InputEventMouseButton \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and not (event as InputEventMouseButton).pressed:
		_pressing = false
		aim_input.emit(false, _knob)
		_knob = Vector2.ZERO
		queue_redraw()

func _update_knob(local_pos: Vector2) -> void:
	var off: Vector2 = local_pos - _center()
	if off.length() > RADIUS:
		off = off.normalized() * RADIUS
	_knob = off

func _draw() -> void:
	var c: Vector2 = _center()
	# Base pad.
	draw_circle(c, RADIUS, Color(0.85, 0.18, 0.18, 0.45))
	draw_arc(c, RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.55), 3.0)
	if _pressing and _knob.length() >= DEADZONE:
		# Aiming — show the direction line + knob.
		draw_line(c, c + _knob, Color(1, 1, 1, 0.7), 4.0)
		draw_circle(c + _knob, KNOB_RADIUS, Color(1.0, 0.4, 0.3, 0.95))
		draw_arc(c + _knob, KNOB_RADIUS, 0.0, TAU, 24, Color(1, 1, 1, 0.85), 2.0)
	else:
		# Idle / no-drag — centred knob + FIRE label.
		draw_circle(c, KNOB_RADIUS, Color(0.95, 0.25, 0.22, 0.9))
		var f: Font = ThemeDB.fallback_font
		var fs := 22
		var tw: float = f.get_string_size("FIRE", HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
		draw_string(f, c + Vector2(-tw * 0.5, fs * 0.35), "FIRE",
				HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color.WHITE)
