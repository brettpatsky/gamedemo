# =============================================================================
# CameraController.gd  (FIXED)
# Fix: Camera was starting at (0,0) — the top-left corner of the map —
#      which puts the viewport mostly off-screen to the top-left.
#      Now centres on the map on _ready() so the play area is visible.
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

@onready var squad: Node2D = get_tree().get_first_node_in_group("squad_controller") as Node2D

func _ready() -> void:
	add_to_group("main_camera")
	_target_zoom = zoom.x

	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	if map_gen and map_gen.has_method("get_map_rect"):
		_map_rect = map_gen.get_map_rect()
	if map_gen and map_gen.has_method("get_map_centre"):
		position = map_gen.get_map_centre()
	else:
		position = _map_rect.get_center()

	# Start halfway between min and max zoom so the map isn't claustrophobically
	# close. Apply directly to zoom (not just _target_zoom) to skip the lerp snap.
	_target_zoom = (_get_min_zoom() + zoom_max) * 0.20
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
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):    dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):  dir.y += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):  dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): dir.x += 1
	if dir != Vector2.ZERO:
		position += dir.normalized() * pan_speed * delta / zoom.x

func _get_min_zoom() -> float:
	var vp := get_viewport_rect().size
	if _map_rect.size.x <= 0.0 or _map_rect.size.y <= 0.0:
		return zoom_min
	var min_x := vp.x / (_map_rect.size.x * MAX_MAP_FRACTION)
	var min_y := vp.y / (_map_rect.size.y * MAX_MAP_FRACTION)
	return maxf(maxf(min_x, min_y), zoom_min)

func _smooth_zoom(delta: float) -> void:
	_target_zoom = maxf(_target_zoom, _get_min_zoom())
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

func _clamp_to_map() -> void:
	var half_vp: Vector2 = get_viewport_rect().size * 0.5 / zoom.x
	position.x = clamp(position.x, _map_rect.position.x + half_vp.x, _map_rect.end.x - half_vp.x)
	position.y = clamp(position.y, _map_rect.position.y + half_vp.y, _map_rect.end.y - half_vp.y)
