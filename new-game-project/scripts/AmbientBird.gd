# =============================================================================
# AmbientBird.gd
# A single bird silhouette that flies across the map. Spawned in flocks by
# AmbientLayer. Purely visual — all tunables live in BalanceConfig under the
# AMBIENT_BIRD_* prefix.
# =============================================================================
class_name AmbientBird
extends Node2D

const Balance = preload("res://scripts/BalanceConfig.gd")

var velocity_x: float = 0.0
var _despawn_x: float = 0.0
var _flap_phase: float = 0.0

# Called once right after instantiate. `dir` is +1 (rightward) or -1.
# `max_distance` is how far the bird travels before despawning.
func setup(start_pos: Vector2, dir: int, max_distance: float = 1800.0) -> void:
	global_position = start_pos
	velocity_x = float(dir) * randf_range(Balance.AMBIENT_BIRD_SPEED_MIN,
			Balance.AMBIENT_BIRD_SPEED_MAX)
	_despawn_x = start_pos.x + float(dir) * max_distance
	_flap_phase = randf() * TAU
	z_index = Balance.AMBIENT_BIRD_Z

func _process(delta: float) -> void:
	global_position.x += velocity_x * delta
	_flap_phase += delta * Balance.AMBIENT_BIRD_FLAP_RATE
	queue_redraw()
	if (velocity_x > 0 and global_position.x > _despawn_x) \
			or (velocity_x < 0 and global_position.x < _despawn_x):
		queue_free()

func _draw() -> void:
	var flap: float = sin(_flap_phase) * 5.0
	# Ground shadow pulses with the flap so the eye reads "above the ground":
	# wings-down → tighter/darker shadow, wings-up → wider/fainter. Drawn
	# first so the silhouette renders on top.
	var lift: float = (sin(_flap_phase) + 1.0) * 0.5   # 0..1
	var rx: float = Balance.AMBIENT_BIRD_SHADOW_RADIUS_X * (1.0 + lift * 0.25)
	var ry: float = Balance.AMBIENT_BIRD_SHADOW_RADIUS_Y * (1.0 + lift * 0.25)
	var shadow_col := Color(0.03, 0.03, 0.05, 0.32 - lift * 0.10)
	var shadow_pts := PackedVector2Array()
	for i in 16:
		var a: float = TAU * float(i) / 16.0
		shadow_pts.append(Vector2(cos(a) * rx,
				Balance.AMBIENT_BIRD_SHADOW_OFFSET_Y + sin(a) * ry))
	draw_colored_polygon(shadow_pts, shadow_col)

	# V-shape silhouette — wings sweep up/down with the flap phase.
	var pts := PackedVector2Array([
		Vector2(-10, flap),
		Vector2( -3, 0),
		Vector2(  3, 0),
		Vector2( 10, flap),
	])
	# Mirror horizontally when flying left so the V always points forward.
	if velocity_x < 0:
		for i in pts.size():
			pts[i] = Vector2(-pts[i].x, pts[i].y)
	draw_polyline(pts, Balance.AMBIENT_BIRD_BODY_COLOR, 2.0)
