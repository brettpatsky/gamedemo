# =============================================================================
# CameraController.gd
# Attach to the Camera2D node in Main.tscn.
# Add the camera to the "main_camera" group (Inspector > Node > Groups).
#
# FEATURES:
#   - Scroll wheel → smooth zoom in/out (clamped to min/max zoom).
#   - Middle-mouse drag OR WASD/arrow keys → pan the camera.
#   - Camera follows the squad centroid loosely (soft-follow with lerp).
#   - Map boundary clamping prevents panning off the edge.
# =============================================================================
extends Camera2D

# ---------------------------------------------------------------------------
# Exported tunables
# ---------------------------------------------------------------------------
@export var zoom_min:     float = 0.4    # zoomed out limit
@export var zoom_max:     float = 2.5    # zoomed in limit
@export var zoom_step:    float = 0.15   # amount per scroll tick
@export var zoom_speed:   float = 8.0    # lerp speed for smooth zoom animation

@export var pan_speed:    float = 350.0  # pixels/sec for keyboard pan
@export var follow_speed: float = 3.0    # lerp speed when following squad

# Map bounds — set these to tile_map world dimensions after generation
# e.g. map_width * tile_size, map_height * tile_size
@export var map_pixel_width:  float = 5120.0   # 80 tiles × 64 px
@export var map_pixel_height: float = 3840.0   # 60 tiles × 64 px

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _target_zoom:  float   = 1.0
var _pan_dragging: bool    = false
var _drag_start:   Vector2 = Vector2.ZERO
var _drag_cam_pos: Vector2 = Vector2.ZERO

# Reference to squad controller so we can follow the squad centroid
@onready var squad: Node2D = get_tree().get_first_node_in_group("squad_controller")

# ---------------------------------------------------------------------------
func _ready() -> void:
	add_to_group("main_camera")
	_target_zoom = zoom.x    # initialise from whatever is set in the scene

# ---------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	# ---- ZOOM via scroll wheel ------------------------------------------
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_target_zoom = clamp(_target_zoom + zoom_step, zoom_min, zoom_max)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_target_zoom = clamp(_target_zoom - zoom_step, zoom_min, zoom_max)

		# ---- MIDDLE MOUSE DRAG to pan -----------------------------------
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_pan_dragging  = event.pressed
			_drag_start    = event.position
			_drag_cam_pos  = position

	# ---- Mouse motion while middle-drag is active -----------------------
	elif event is InputEventMouseMotion and _pan_dragging:
		var delta_screen: Vector2 = event.position - _drag_start
		# Divide by zoom so panning feels consistent at all zoom levels
		position = _drag_cam_pos - delta_screen / zoom.x

# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	_handle_keyboard_pan(delta)
	_smooth_zoom(delta)
	_soft_follow_squad(delta)
	_clamp_to_map()

# =============================================================================
# PRIVATE
# =============================================================================

func _handle_keyboard_pan(delta: float) -> void:
	# Use built-in Input singleton — no need for InputMap setup for basic WASD
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1
	if dir != Vector2.ZERO:
		position += dir.normalized() * pan_speed * delta / zoom.x

func _smooth_zoom(delta: float) -> void:
	# Lerp current zoom toward the target for a buttery-smooth feel
	var new_z := lerp(zoom.x, _target_zoom, zoom_speed * delta)
	zoom = Vector2(new_z, new_z)

func _soft_follow_squad(delta: float) -> void:
	# Only follow when the camera isn't being manually dragged
	if _pan_dragging or squad == null:
		return
	# Get the squad centroid from SquadController.gd
	if not squad.has_method("get_centroid"):
		return
	var centroid: Vector2 = squad.get_centroid()
	if centroid != Vector2.ZERO:
		position = position.lerp(centroid, follow_speed * delta)

func _clamp_to_map() -> void:
	# Half-viewport in world space depends on current zoom
	var half_vp: Vector2 = get_viewport_rect().size * 0.5 / zoom.x
	position.x = clamp(position.x, half_vp.x,            map_pixel_width  - half_vp.x)
	position.y = clamp(position.y, half_vp.y,            map_pixel_height - half_vp.y)
