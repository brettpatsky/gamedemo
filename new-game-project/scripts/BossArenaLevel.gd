# =============================================================================
# BossArenaLevel.gd  (Boss Mission — level 6)
# Root script for scenes/bosses/boss_arena.tscn. Drop-in replacement for
# MapGenerator on the boss level, matching the same public interface so
# CameraController and Main.gd treat it identically.
#
# Layout:
#   ┌────────────────────────────────┐
#   │       Boss room (wide)         │   y = 0 .. ROOM_HEIGHT
#   │              [Boss]            │
#   │                                │
#   ├──────────────┬──┬──────────────┤
#   │   wall       │  │     wall     │   approach corridor between the
#   │              │  │              │   inner walls; squad spawns here
#   └──────────────┴──┴──────────────┘   y = ROOM_HEIGHT .. _map_h_px
#
# Scene layout (edit in Godot editor):
#   BossArena (Node2D, this script)
#   ├── Background        (ColorRect — defines map extents)
#   ├── NavigationRegion2D
#   ├── SpawnPoint        (Node2D, position bottom-centre of corridor)
#   └── Boss              (boss_heartstone.tscn instance, centred in room)
# =============================================================================
extends Node2D

signal boss_defeated

const WALL_THICKNESS: float = 96.0

# Approach corridor dimensions. ROOM_HEIGHT is the y boundary between the boss
# room (above) and the corridor (below). CORRIDOR_HALF_W defines a 200-px-wide
# corridor centred horizontally. Map is sized so the whole arena fits on
# screen at min camera zoom (no scrolling needed for the fight itself).
const ROOM_HEIGHT:      float = 700.0
const CORRIDOR_HALF_W:  float = 100.0

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
	_spawn_corridor_walls()
	_bake_nav()
	if boss and boss.has_signal("boss_defeated"):
		boss.boss_defeated.connect(func() -> void: boss_defeated.emit())

# =============================================================================
# MapGenerator-compatible interface — same names Main.gd / Camera / Bullet expect
# =============================================================================
func get_map_centre() -> Vector2:
	# Aim the camera at the boss room (not the geometric middle of the map,
	# which would land in the corridor wall). Slight downward bias keeps both
	# the boss and the corridor entrance comfortably on screen.
	return to_global(Vector2(_map_w_px * 0.5, ROOM_HEIGHT * 0.5 + 100.0))

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

# Squad spawns in a single-file column inside the south corridor so they have
# to advance up the narrow approach before fanning out into the boss room.
func get_spawn_positions(count: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var base: Vector2
	if spawn_point:
		base = spawn_point.global_position
	else:
		base = to_global(Vector2(_map_w_px * 0.5, _map_h_px - 80.0))
	# 2-wide column tight around the spawn point so all 6 soldiers fit inside
	# the narrow 200×200 corridor without clipping into the walls.
	for i in count:
		@warning_ignore("integer_division")
		var col: int = i % 2
		@warning_ignore("integer_division")
		var row: int = i / 2
		var offset := Vector2(float(col) * 60.0 - 30.0, (float(row) - 1.0) * 50.0)
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
	# Outer perimeter — walls hug the OUTSIDE of the playable rectangle.
	_add_wall(-T,           -T,            _map_w_px + 2.0 * T, T)               # top
	_add_wall(-T,           _map_h_px,     _map_w_px + 2.0 * T, T)               # bottom
	_add_wall(-T,            0.0,          T,                   _map_h_px)        # left
	_add_wall(_map_w_px,     0.0,          T,                   _map_h_px)        # right

# Carves the south approach corridor by walling off the bottom-left and
# bottom-right rectangles, leaving only a narrow gap in the middle. Walls are
# placed INSIDE the playable rect (unlike perimeter walls), so bullets stop on
# them and soldiers can't cross. Combined with the navmesh re-bake, soldiers
# path through the corridor opening instead of trying to walk straight north.
func _spawn_corridor_walls() -> void:
	var centre_x: float = _map_w_px * 0.5
	var left_w:   float = centre_x - CORRIDOR_HALF_W
	var right_x:  float = centre_x + CORRIDOR_HALF_W
	var right_w:  float = _map_w_px - right_x
	var height:   float = _map_h_px - ROOM_HEIGHT
	_add_wall(0.0,     ROOM_HEIGHT, left_w,  height)   # bottom-left wall block
	_add_wall(right_x, ROOM_HEIGHT, right_w, height)   # bottom-right wall block

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

# T-shaped navmesh: the wide boss room joined to the narrow approach corridor.
# Built as a single concave outline so NavigationAgent2D paths from the spawn
# point in the corridor up to anywhere in the boss room without snags. Uses
# make_polygons_from_outlines because the shape isn't convex — Godot 4 still
# supports it (deprecation warning is benign; the same pattern is used in
# MazeLevel.gd).
func _bake_nav() -> void:
	if nav_region == null:
		return
	const INSET := 24.0
	var centre_x: float = _map_w_px * 0.5
	var corr_left:  float = centre_x - CORRIDOR_HALF_W + INSET
	var corr_right: float = centre_x + CORRIDOR_HALF_W - INSET
	var room_left:  float = INSET
	var room_right: float = _map_w_px - INSET
	var room_top:   float = INSET
	var room_bot:   float = ROOM_HEIGHT
	var corr_bot:   float = _map_h_px - INSET

	var nav_poly := NavigationPolygon.new()
	nav_poly.add_outline(PackedVector2Array([
		nav_region.to_local(to_global(Vector2(room_left,  room_top))),
		nav_region.to_local(to_global(Vector2(room_right, room_top))),
		nav_region.to_local(to_global(Vector2(room_right, room_bot))),
		nav_region.to_local(to_global(Vector2(corr_right, room_bot))),
		nav_region.to_local(to_global(Vector2(corr_right, corr_bot))),
		nav_region.to_local(to_global(Vector2(corr_left,  corr_bot))),
		nav_region.to_local(to_global(Vector2(corr_left,  room_bot))),
		nav_region.to_local(to_global(Vector2(room_left,  room_bot))),
	]))
	nav_poly.make_polygons_from_outlines()
	nav_region.navigation_polygon = nav_poly
