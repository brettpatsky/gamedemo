# =============================================================================
# LeylineBeam.gd  (Boss Mission — Phase 1 / 3 hazard)
# A blinding beam of raw magic that rotates around the Heartstone. Spawned
# parented to the boss so the beam's transform tracks the boss automatically.
#
# Implementation note: the visible beam and its damage rectangle share one
# Area2D — rotating the node rotates both the draw call and the collision
# shape. Soldiers inside take periodic damage on a tick interval.
# =============================================================================
extends Area2D

const WIDTH:        float = 36.0
const DAMAGE_TICK:  float = 0.4   # seconds between damage ticks per soldier inside
const DAMAGE_PER_TICK: int = 1

var length:           float = 600.0
var rotation_speed:   float = 0.7   # radians per second
var _flash_phase:     float = 0.0
var _tick_timer:      float = 0.0
var _collision_shape: CollisionShape2D = null

func _ready() -> void:
	add_to_group("leyline_beams")
	collision_layer = 0
	collision_mask  = 2   # detect soldiers only
	monitoring  = true
	monitorable = false
	_collision_shape = CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(length, WIDTH)
	_collision_shape.shape = rect
	# Offset so the beam starts at the boss centre and extends outward along +x.
	_collision_shape.position = Vector2(length * 0.5, 0.0)
	add_child(_collision_shape)
	queue_redraw()

func configure(p_length: float, p_rot_speed: float) -> void:
	length = p_length
	rotation_speed = p_rot_speed
	if _collision_shape and _collision_shape.shape is RectangleShape2D:
		(_collision_shape.shape as RectangleShape2D).size = Vector2(length, WIDTH)
		_collision_shape.position = Vector2(length * 0.5, 0.0)
	queue_redraw()

func set_rotation_speed(p_rot_speed: float) -> void:
	rotation_speed = p_rot_speed

func _process(delta: float) -> void:
	rotation += rotation_speed * delta
	_flash_phase += delta
	_tick_timer -= delta
	queue_redraw()
	if _tick_timer > 0.0:
		return
	_tick_timer = DAMAGE_TICK
	for body in get_overlapping_bodies():
		if not body.is_in_group("soldiers"):
			continue
		if body.has_method("is_downed") and body.is_downed():
			continue
		if body.has_method("take_damage"):
			body.take_damage(DAMAGE_PER_TICK)

func _draw() -> void:
	var flicker: float = 0.7 + 0.3 * sin(_flash_phase * 18.0)
	# Outer glow.
	var glow_rect := Rect2(0.0, -WIDTH * 1.4, length, WIDTH * 2.8)
	draw_rect(glow_rect, Color(0.95, 0.55, 1.0, 0.18 * flicker))
	# Core beam.
	var core_rect := Rect2(0.0, -WIDTH * 0.5, length, WIDTH)
	draw_rect(core_rect, Color(1.0, 0.85, 1.0, 0.55 * flicker))
	# Hot centre line.
	draw_rect(Rect2(0.0, -WIDTH * 0.18, length, WIDTH * 0.36), Color(1.0, 1.0, 1.0, 0.85))
	# Tip blossom.
	draw_circle(Vector2(length, 0.0), WIDTH * 0.9, Color(1.0, 0.7, 1.0, 0.6 * flicker))
