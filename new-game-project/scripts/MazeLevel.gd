# =============================================================================
# MazeLevel.gd
# Root script for hand-authored maze scenes (scenes/mazes/maze_*.tscn).
# Acts as a drop-in replacement for MapGenerator on level 4.
#
# Scene tree:
#   MazeLevel (Node2D, this script)
#   ├── Background          (ColorRect — defines map extents via its size)
#   ├── NavigationRegion2D  (baked at runtime from wall children)
#   ├── SpawnPoint          (Node2D — soldier starts here)
#   ├── Exit                (Area2D with MazeExit.gd + CollisionShape2D child)
#   ├── HedgeWall_*         (maze_hedge.tscn instances — move freely in editor)
#   └── RockWall_*          (maze_rock.tscn instances — move freely in editor)
#
# Edit the scene in the Godot editor: drag walls, swap scenes, add new types.
# =============================================================================
extends Node2D

signal escaped

@export var cell_size: int = 64

@onready var background:  ColorRect          = $Background
@onready var nav_region:  NavigationRegion2D = $NavigationRegion2D

var _map_w_px: float = 0.0
var _map_h_px: float = 0.0

func _ready() -> void:
	add_to_group("map_generator")
	add_to_group("maze_level")
	_compute_map_bounds()
	_bake_navigation()
	_connect_exit()

# ---------------------------------------------------------------------------
# MapGenerator-compatible interface
# ---------------------------------------------------------------------------
func get_map_centre() -> Vector2:
	return to_global(Vector2(_map_w_px * 0.5, _map_h_px * 0.5))

func get_map_rect() -> Rect2:
	return Rect2(to_global(Vector2.ZERO), Vector2(_map_w_px, _map_h_px))

func is_water_at(_world_pos: Vector2) -> bool:
	return false

func get_spawn_position() -> Vector2:
	var sp: Node = find_child("SpawnPoint", false, false)
	if sp is Node2D:
		return (sp as Node2D).global_position
	return to_global(Vector2(cell_size * 1.5, cell_size * 1.5))

func get_spawn_positions(_count: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	out.append(get_spawn_position())
	return out

func get_exit_zone() -> Node:
	return find_child("Exit", false, false)

func get_objective_node(key: String) -> Variant:
	if key == "maze_exit":
		return get_exit_zone()
	return null

func generate(_seed_value: int = 0) -> void:
	GameManager.enemies_alive = 0
	GameManager.enemies_changed.emit(0)

# ---------------------------------------------------------------------------
# PRIVATE
# ---------------------------------------------------------------------------
func _compute_map_bounds() -> void:
	if background:
		_map_w_px = background.size.x
		_map_h_px = background.size.y

func _connect_exit() -> void:
	var exit: Node = get_exit_zone()
	if exit and exit.has_signal("escaped"):
		exit.escaped.connect(func() -> void: escaped.emit())

func _bake_navigation() -> void:
	if nav_region == null:
		return
	var nav_poly := NavigationPolygon.new()

	var inset: float = float(cell_size) * 0.25
	var tl := nav_region.to_local(to_global(Vector2(inset, inset)))
	var br := nav_region.to_local(to_global(Vector2(_map_w_px - inset, _map_h_px - inset)))
	nav_poly.add_outline(PackedVector2Array([
		tl, Vector2(br.x, tl.y), br, Vector2(tl.x, br.y),
	]))

	var margin := 2.0
	for child in get_children():
		if not (child is StaticBody2D):
			continue
		var p: Vector2 = (child as Node2D).position
		var half: float = cell_size * 0.5
		var x: float = p.x - half + margin
		var y: float = p.y - half + margin
		var w: float = cell_size - margin * 2.0
		var h: float = cell_size - margin * 2.0
		var ctl := nav_region.to_local(to_global(Vector2(x, y)))
		var cbr := nav_region.to_local(to_global(Vector2(x + w, y + h)))
		nav_poly.add_outline(PackedVector2Array([
			ctl, Vector2(cbr.x, ctl.y), cbr, Vector2(ctl.x, cbr.y),
		]))

	nav_poly.make_polygons_from_outlines()
	nav_region.navigation_polygon = nav_poly
