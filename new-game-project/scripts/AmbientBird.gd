# =============================================================================
# AmbientBird.gd
# A bird that flies across the map. Spawned in flocks by AmbientLayer.
# Cycles through three wing-position sprites (up / glide / down) driven by
# the existing flap phase. Keeps the procedural ground shadow so the bird
# reads as airborne. Falls back to the old V-line silhouette if textures are
# not yet imported.
# =============================================================================
class_name AmbientBird
extends Node2D

const Balance = preload("res://scripts/BalanceConfig.gd")

# Frames cycle: up → glide → down → glide → repeat
const BIRD_FRAMES: PackedStringArray = [
	"res://resources/environment/ambient/bird_up.png",
	"res://resources/environment/ambient/bird_base.png",
	"res://resources/environment/ambient/bird_down.png",
	"res://resources/environment/ambient/bird_base.png",
]

var velocity_x:  float = 0.0
var _despawn_x:  float = 0.0
var _flap_phase: float = 0.0
var _sprite:     Sprite2D = null
var _last_frame: int = -1

func setup(start_pos: Vector2, dir: int, max_distance: float = 1800.0) -> void:
	global_position = start_pos
	velocity_x  = float(dir) * randf_range(Balance.AMBIENT_BIRD_SPEED_MIN,
			Balance.AMBIENT_BIRD_SPEED_MAX)
	_despawn_x  = start_pos.x + float(dir) * max_distance
	_flap_phase = randf() * TAU
	z_index     = Balance.AMBIENT_BIRD_Z

	_sprite        = Sprite2D.new()
	_sprite.scale  = Vector2(1.5, 1.5)
	_sprite.flip_h = (dir < 0)
	add_child(_sprite)
	_update_frame()

func _process(delta: float) -> void:
	global_position.x += velocity_x * delta
	_flap_phase       += delta * Balance.AMBIENT_BIRD_FLAP_RATE
	_update_frame()
	queue_redraw()
	if (velocity_x > 0 and global_position.x > _despawn_x) \
			or (velocity_x < 0 and global_position.x < _despawn_x):
		queue_free()

func _update_frame() -> void:
	if _sprite == null:
		return
	var idx: int = int(_flap_phase / (TAU / BIRD_FRAMES.size())) % BIRD_FRAMES.size()
	if idx == _last_frame:
		return
	_last_frame = idx
	var path: String = BIRD_FRAMES[idx]
	if ResourceLoader.exists(path):
		_sprite.texture = load(path)

func _draw() -> void:
	# Ground shadow pulses with the flap so the eye reads "above the ground".
	var lift: float = (sin(_flap_phase) + 1.0) * 0.5
	var rx: float   = Balance.AMBIENT_BIRD_SHADOW_RADIUS_X * (1.0 + lift * 0.25)
	var ry: float   = Balance.AMBIENT_BIRD_SHADOW_RADIUS_Y * (1.0 + lift * 0.25)
	var shadow_col  := Color(0.03, 0.03, 0.05, 0.32 - lift * 0.10)
	var pts := PackedVector2Array()
	for i in 16:
		var a: float = TAU * float(i) / 16.0
		pts.append(Vector2(cos(a) * rx,
				Balance.AMBIENT_BIRD_SHADOW_OFFSET_Y + sin(a) * ry))
	draw_colored_polygon(pts, shadow_col)

	# Fallback V-line silhouette if textures haven't been imported yet.
	if _sprite != null and _sprite.texture != null:
		return
	var flap: float = sin(_flap_phase) * 5.0
	var fp := PackedVector2Array([
		Vector2(-10, flap), Vector2(-3, 0), Vector2(3, 0), Vector2(10, flap),
	])
	if velocity_x < 0:
		for i in fp.size():
			fp[i] = Vector2(-fp[i].x, fp[i].y)
	draw_polyline(fp, Balance.AMBIENT_BIRD_BODY_COLOR, 2.0)
