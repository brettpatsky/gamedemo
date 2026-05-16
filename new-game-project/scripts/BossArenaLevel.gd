# =============================================================================
# BossArenaLevel.gd  (Boss Mission — level 5)
# Root script for scenes/bosses/boss_arena.tscn. Drop-in replacement for
# MapGenerator on level 5, matching the same public interface so CameraController
# and Main.gd treat it identically.
#
# Scene layout (edit in the Godot editor):
#   BossArena (Node2D, this script)
#   ├── Background        (ColorRect — arena floor; defines map extents)
#   ├── NavigationRegion2D (single rectangular nav polygon baked at runtime)
#   ├── SpawnPoint        (Node2D — squad spawns here, bottom-centre)
#   └── Boss              (StaticBody2D — boss_heartstone.tscn instance, centre)
# =============================================================================
extends Node2D

signal boss_defeated

const WALL_THICKNESS: float = 96.0

@onready var background: ColorRect          = $Background
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D
@onready var spawn_point: Node2D            = $SpawnPoint
@onready var boss: Node                     = $Boss

var _map_w_px: float = 0.0
var _map_h_px: float = 0.0

# =============================================================================
# READY
# =============================================================================
func _ready() -> void:
	add_to_group("map_generator")
	add_to_group("boss_arena")
	_compute_map_bounds()
	_spawn_boundary_walls()
	_bake_nav()
	if boss and boss.has_signal("boss_defeated"):
		boss.boss_defeated.connect(func() -> void: boss_defeated.emit())

# =============================================================================
# MapGenerator-compatible interface — same names Main.gd / Camera / Bullet expect
# =============================================================================
func get_map_centre() -> Vector2:
	return to_global(Vector2(_map_w_px * 0.5, _map_h_px * 0.5))

func get_map_rect() -> Rect2:
	return Rect2(to_global(Vector2.ZERO), Vector2(_map_w_px, _map_h_px))

func is_water_at(_world_pos: Vector2) -> bool:
	return false

func get_elevation_at(_world_pos: Vector2) -> float:
	return 0.0

func get_range_modifier_at(_world_pos: Vector2) -> float:
	return 1.0

func get_slope_speed_mult(_world_pos: Vector2, _direction: Vector2) -> float:
	return 1.0

# Spawn the squad in a tight cluster around the spawn point so they don't
# clip into the boundary walls.
func get_spawn_positions(count: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var base: Vector2
	if spawn_point:
		base = spawn_point.global_position
	else:
		base = to_global(Vector2(_map_w_px * 0.5, _map_h_px - 200.0))
	for i in count:
		@warning_ignore("integer_division")
		var col: int = i % 3
		@warning_ignore("integer_division")
		var row: int = i / 3
		var offset := Vector2(float(col - 1) * 80.0, float(row) * 80.0)
		result.append(base + offset)
	return result

func get_objective_node(key: String) -> Variant:
	if key == "boss":
		return boss
	return null

func generate(_seed_value: int = 0) -> void:
	# Boss counts as a single "enemy" so the HUD enemy counter / off-screen
	# arrow both light up while the boss is alive.
	GameManager.enemies_alive = 1
	GameManager.enemies_changed.emit(1)

# =============================================================================
# PRIVATE
# =============================================================================
func _compute_map_bounds() -> void:
	if background:
		_map_w_px = background.size.x
		_map_h_px = background.size.y

func _spawn_boundary_walls() -> void:
	const T := WALL_THICKNESS
	# Walls hug the OUTSIDE of the playable rectangle (their inner faces sit on
	# the arena edge). Mask-0 so bullets stop on them but they don't pull RVO
	# avoidance traffic toward themselves.
	_add_wall(-T,           -T,            _map_w_px + 2.0 * T, T)               # top
	_add_wall(-T,           _map_h_px,     _map_w_px + 2.0 * T, T)               # bottom
	_add_wall(-T,            0.0,          T,                   _map_h_px)        # left
	_add_wall(_map_w_px,     0.0,          T,                   _map_h_px)        # right

func _add_wall(x: float, y: float, w: float, h: float) -> void:
	var body  := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask  = 0
	var shape := RectangleShape2D.new()
	shape.size = Vector2(w, h)
	var col   := CollisionShape2D.new()
	col.shape    = shape
	col.position = Vector2(x + w * 0.5, y + h * 0.5)
	body.add_child(col)
	add_child(body)

# Single rectangular nav polygon covering the arena. Matches MapGenerator's
# approach — avoids the deprecated make_polygons_from_outlines() path. The
# boss's StaticBody2D physically blocks soldiers (collision_layer = 1) and
# NavigationAgent2D's RVO avoidance steers the squad around it, so an explicit
# hole in the navmesh isn't required.
func _bake_nav() -> void:
	if nav_region == null:
		return
	const INSET := 24.0
	var nav_poly := NavigationPolygon.new()
	var tl := nav_region.to_local(to_global(Vector2(INSET, INSET)))
	var br := nav_region.to_local(to_global(Vector2(_map_w_px - INSET, _map_h_px - INSET)))
	nav_poly.vertices = PackedVector2Array([
		tl,
		Vector2(br.x, tl.y),
		br,
		Vector2(tl.x, br.y),
	])
	nav_poly.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	nav_region.navigation_polygon = nav_poly
