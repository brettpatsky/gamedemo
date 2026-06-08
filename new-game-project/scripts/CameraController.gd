# =============================================================================
# CameraController.gd
# Top-down chase camera. Follows the squad centroid, supports keyboard /
# right-stick panning + wheel zoom, clamps to the map rect, and starts
# fully zoomed out so the player sees the whole arena on mission start.
# =============================================================================
extends Camera2D

# zoom_min is now computed dynamically — see _get_min_zoom().
# This exported value acts as a floor only if the map rect isn't known yet.
@export var zoom_min:     float = 0.5
@export var zoom_max:     float = 3.5
@export var zoom_step:    float = 0.15
@export var zoom_speed:   float = 8.0

# Never reveal more than this fraction of the map in any single axis at max zoom-out.
# 0.40 = player sees at most 40% of map width or height at once. Raise to show more.
const MAX_MAP_FRACTION := 1

@export var pan_speed:    float = 350.0
@export var follow_speed: float = 3.0

var _target_zoom:  float   = 1.0
var _pan_dragging: bool    = false
var _drag_start:   Vector2 = Vector2.ZERO
var _drag_cam_pos: Vector2 = Vector2.ZERO
var _map_rect:     Rect2   = Rect2(Vector2.ZERO, Vector2(7680.0, 6400.0))
# When > 0, replaces the auto-computed _get_min_zoom() as the zoom floor.
# Used by enter_cave_view so the player can zoom out freely inside the cave.
var _zoom_floor:   float   = -1.0

@onready var squad: Node2D = get_tree().get_first_node_in_group("squad_controller") as Node2D

func _ready() -> void:
	add_to_group("main_camera")
	_target_zoom = zoom.x
	refresh_map_bounds()

# Re-read map_rect / centre from the current "map_generator" node and reset
# zoom + position. Called by Main.gd after it swaps the procedural MapGenerator
# for a hand-authored maze on level 4.
func refresh_map_bounds() -> void:
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	if map_gen and map_gen.has_method("get_map_rect"):
		_map_rect = map_gen.get_map_rect()
	if map_gen and map_gen.has_method("get_map_centre"):
		position = map_gen.get_map_centre()
	else:
		position = _map_rect.get_center()

	# Always start fully zoomed out so the player can survey the whole
	# accessible area immediately. They can scroll-wheel in for combat.
	# (The boss level already needs this so its T-arena fits on screen.)
	_target_zoom = _get_min_zoom()
	zoom = Vector2(_target_zoom, _target_zoom)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_target_zoom = clamp(_target_zoom + zoom_step, _get_min_zoom(), zoom_max)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_target_zoom = clamp(_target_zoom - zoom_step, _get_min_zoom(), zoom_max)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_pan_dragging  = event.pressed
			_drag_start    = event.position
			_drag_cam_pos  = position
	elif event is InputEventMouseMotion and _pan_dragging:
		var delta_screen: Vector2 = event.position - _drag_start
		position = _drag_cam_pos - delta_screen / zoom.x

func _process(delta: float) -> void:
	_handle_keyboard_pan(delta)
	_smooth_zoom(delta)
	_soft_follow_squad(delta)
	_clamp_to_map()

func _handle_keyboard_pan(delta: float) -> void:
	# Action-based — covers WASD, arrow keys, AND gamepad left stick
	# (bindings in project.godot). get_vector returns analog magnitude so the
	# left stick gives gradient pan speed, while keys still pan at full tilt.
	var dir := Input.get_vector("cam_left", "cam_right", "cam_up", "cam_down")
	if dir != Vector2.ZERO:
		position += dir * pan_speed * delta / zoom.x

func _get_min_zoom() -> float:
	var vp := get_viewport_rect().size
	if _map_rect.size.x <= 0.0 or _map_rect.size.y <= 0.0:
		return zoom_min
	var min_x := vp.x / (_map_rect.size.x * MAX_MAP_FRACTION)
	var min_y := vp.y / (_map_rect.size.y * MAX_MAP_FRACTION)
	return maxf(maxf(min_x, min_y), zoom_min)

func _smooth_zoom(delta: float) -> void:
	var min_z := _zoom_floor if _zoom_floor > 0.0 else _get_min_zoom()
	_target_zoom = maxf(_target_zoom, min_z)
	var new_z := lerpf(zoom.x, _target_zoom, zoom_speed * delta)
	zoom = Vector2(new_z, new_z)

func _soft_follow_squad(delta: float) -> void:
	if _pan_dragging or squad == null:
		return
	if not squad.has_method("get_centroid"):
		return
	var centroid: Vector2 = squad.get_centroid()
	if centroid != Vector2.ZERO:
		position = position.lerp(centroid, follow_speed * delta)

# Restrict the camera to a new rect and smoothly zoom to fit it.
# Does NOT snap position — the squad follow and clamp bring the view there naturally.
func lock_to_rect(rect: Rect2) -> void:
	_map_rect    = rect
	_zoom_floor  = -1.0   # re-enable auto min-zoom for the world map
	_target_zoom = _get_min_zoom()

# Use this instead of lock_to_rect when entering the cave.
# Snaps to zoom=1.0 (full 1280×720 art visible + dark backdrop fills surplus viewport)
# and lets the player zoom out freely down to zoom_min rather than forcing the
# min-zoom needed to fill the screen.
func enter_cave_view(rect: Rect2) -> void:
	_map_rect    = rect
	_zoom_floor  = zoom_min   # freely zoomable; no forced fill
	_target_zoom = 1.0
	zoom         = Vector2(1.0, 1.0)   # snap immediately while screen is black
	position     = rect.get_center()

func _clamp_to_map() -> void:
	var half_vp: Vector2 = get_viewport_rect().size * 0.5 / zoom.x
	position.x = clamp(position.x, _map_rect.position.x + half_vp.x, _map_rect.end.x - half_vp.x)
	position.y = clamp(position.y, _map_rect.position.y + half_vp.y, _map_rect.end.y - half_vp.y)
