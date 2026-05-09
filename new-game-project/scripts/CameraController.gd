# =============================================================================
# CameraController.gd  (FIXED)
# Fix: Camera was starting at (0,0) — the top-left corner of the map —
#      which puts the viewport mostly off-screen to the top-left.
#      Now centres on the map on _ready() so the play area is visible.
# =============================================================================
extends Camera2D

@export var zoom_min:     float = 0.4
@export var zoom_max:     float = 2.5
@export var zoom_step:    float = 0.15
@export var zoom_speed:   float = 8.0

@export var pan_speed:    float = 350.0
@export var follow_speed: float = 3.0

# These match MapGenerator defaults: 80 tiles × 64px, 60 tiles × 64px
@export var map_pixel_width:  float = 5120.0
@export var map_pixel_height: float = 3840.0

var _target_zoom:  float   = 1.0
var _pan_dragging: bool    = false
var _drag_start:   Vector2 = Vector2.ZERO
var _drag_cam_pos: Vector2 = Vector2.ZERO

@onready var squad: Node2D = get_tree().get_first_node_in_group("squad_controller") as Node2D

func _ready() -> void:
	add_to_group("main_camera")
	_target_zoom = zoom.x

	# Use the map generator's own coordinate maths so any TileMapLayer offset
	# is accounted for exactly.  Falls back to the hardcoded pixel estimate when
	# MapGenerator isn't in the tree yet (e.g. editing a sub-scene).
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	if map_gen and map_gen.has_method("get_map_centre"):
		position = map_gen.get_map_centre()
	else:
		position = Vector2(map_pixel_width * 0.5, map_pixel_height * 0.5)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_target_zoom = clamp(_target_zoom + zoom_step, zoom_min, zoom_max)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_target_zoom = clamp(_target_zoom - zoom_step, zoom_min, zoom_max)
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

func _smooth_zoom(delta: float) -> void:
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
	position.x = clamp(position.x, half_vp.x,  map_pixel_width  - half_vp.x)
	position.y = clamp(position.y, half_vp.y,  map_pixel_height - half_vp.y)
