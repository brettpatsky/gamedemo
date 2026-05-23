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
	var col := Color(0.08, 0.08, 0.10, 0.75)
	# V-shape silhouette — wings sweep up/down with the flap phase.
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
