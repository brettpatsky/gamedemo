# =============================================================================
# AmbientBird.gd
# A single bird silhouette that flies across the map. Spawned in flocks by
# AmbientLayer at random vertical bands above the camera. Purely visual —
# no collision, no group membership, no interaction with the squad.
# =============================================================================
class_name AmbientBird
extends Node2D

const SPEED_MIN := 130.0
const SPEED_MAX := 220.0
const FLAP_RATE := 7.0

var velocity_x: float = 0.0
var _despawn_x: float = 0.0
var _flap_phase: float = 0.0

# Called once right after instantiate. `dir` is +1 (rightward) or -1.
# `max_distance` is how far the bird travels before despawning.
func setup(start_pos: Vector2, dir: int, max_distance: float = 1800.0) -> void:
	global_position = start_pos
	velocity_x = float(dir) * randf_range(SPEED_MIN, SPEED_MAX)
	_despawn_x = start_pos.x + float(dir) * max_distance
	_flap_phase = randf() * TAU
	z_index = 10   # above squad/terrain, below weather

func _process(delta: float) -> void:
	global_position.x += velocity_x * delta
	_flap_phase += delta * FLAP_RATE
	queue_redraw()
	# Despawn once past the planned travel distance, regardless of camera.
	if (velocity_x > 0 and global_position.x > _despawn_x) \
			or (velocity_x < 0 and global_position.x < _despawn_x):
		queue_free()

func _draw() -> void:
	var flap: float = sin(_flap_phase) * 5.0
	# Ground shadow — flattened ellipse a fixed offset BELOW the bird so the
	# eye reads "this thing is above the ground". The shadow subtly pulses
	# with the flap phase: wings-down (bird closer to ground) → tighter,
	# darker shadow; wings-up (bird lifting) → wider, fainter. Drawn first
	# so the bird silhouette renders on top of it.
	const SHADOW_Y    := 30.0
	const SHADOW_RX   := 7.5
	const SHADOW_RY   := 2.5
	var lift: float = (sin(_flap_phase) + 1.0) * 0.5   # 0..1
	var rx: float = SHADOW_RX * (1.0 + lift * 0.25)
	var ry: float = SHADOW_RY * (1.0 + lift * 0.25)
	var shadow_col := Color(0.03, 0.03, 0.05, 0.32 - lift * 0.10)
	var shadow_pts := PackedVector2Array()
	for i in 16:
		var a: float = TAU * float(i) / 16.0
		shadow_pts.append(Vector2(cos(a) * rx, SHADOW_Y + sin(a) * ry))
	draw_colored_polygon(shadow_pts, shadow_col)

	# V-shape silhouette — wings sweep up/down with the flap phase.
	var col := Color(0.08, 0.08, 0.10, 0.75)
	var pts := PackedVector2Array([
		Vector2(-10, flap),
		Vector2( -3, 0),
		Vector2(  3, 0),
		Vector2( 10, flap),
	])
	# Mirror the wings horizontally if flying left so the V points forward.
	if velocity_x < 0:
		for i in pts.size():
			pts[i] = Vector2(-pts[i].x, pts[i].y)
	draw_polyline(pts, col, 2.0)
