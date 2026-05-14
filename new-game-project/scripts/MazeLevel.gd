# =============================================================================
# MazeLevel.gd
# Root script for the hand-authored maze scene (scenes/mazes/maze_1.tscn).
# Acts as a drop-in replacement for MapGenerator on level 4.
#
# Scene layout (edit in the Godot editor):
#   MazeLevel (Node2D, this script)
#   ├── Background          (ColorRect — map extents derived from its size)
#   ├── NavigationRegion2D  (receives the baked polygon at startup)
#   ├── SpawnPoint          (Node2D — soldier spawns here)
#   ├── Exit                (Area2D + MazeExit.gd + CollisionShape2D)
#   └── maze_rock / maze_hedge instances  (drag freely in the editor)
#
# Drop any maze_rock.tscn or maze_hedge.tscn instance anywhere as a direct
# child of this node. The navmesh re-bakes from their collision shapes on play.
# =============================================================================
extends Node2D

signal escaped

@onready var background: ColorRect          = $Background
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D

var _map_w_px: float = 0.0
var _map_h_px: float = 0.0

func _ready() -> void:
	add_to_group("map_generator")
	add_to_group("maze_level")
	_compute_map_bounds()
	_bake_nav()
	_connect_exit()

# ---------------------------------------------------------------------------
# MapGenerator-compatible interface (same API as MapGenerator.gd)
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
	return to_global(Vector2(96, 96))

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

# Builds the navmesh at startup from the wall collision shapes.
#
# Why manual outlines instead of bake_navigation_polygon()?
#   bake_navigation_polygon() uses the source-geometry group pipeline which
#   requires groups to propagate through packed-scene instances reliably.
#   The manual approach reads CollisionShape2D data directly — zero ambiguity.
#
# Why the original outline-per-wall code broke:
#   The old floor outline used a 16 px inset, so perimeter-wall outlines
#   (which start at x/y ≈ 2) crossed the floor boundary — that triggered the
#   "outlines can not overlap" convex-partition error.
#
# This version uses the full background as the floor outline so every wall
# outline is strictly inside it. Rock shapes (56×56) at 64 px grid spacing
# leave an 8 px gap between adjacent outlines — no shared edges, no error.
func _bake_nav() -> void:
	if nav_region == null:
		return

	var nav_poly := NavigationPolygon.new()

	# Outer walkable boundary = full background.
	nav_poly.add_outline(PackedVector2Array([
		Vector2(0,         0),
		Vector2(_map_w_px, 0),
		Vector2(_map_w_px, _map_h_px),
		Vector2(0,         _map_h_px),
	]))

	# One rectangular hole per StaticBody2D wall child, sized from its
	# CollisionShape2D so the method works for any shape size without needing
	# a hardcoded cell_size constant.
	for child in get_children():
		if not (child is StaticBody2D):
			continue
		var cs := child.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if cs == null or not (cs.shape is RectangleShape2D):
			continue
		var half: Vector2 = (cs.shape as RectangleShape2D).size * 0.5
		var c: Vector2 = (child as Node2D).position + cs.position
		nav_poly.add_outline(PackedVector2Array([
			c + Vector2(-half.x, -half.y),
			c + Vector2( half.x, -half.y),
			c + Vector2( half.x,  half.y),
			c + Vector2(-half.x,  half.y),
		]))

	nav_poly.make_polygons_from_outlines()
	nav_region.navigation_polygon = nav_poly
	print("[MazeLevel] Nav bake done — polygons: %d  vertices: %d  outlines_added: %d" % [
		nav_poly.get_polygon_count(), nav_poly.vertices.size(), nav_poly.get_outline_count()
	])

func _connect_exit() -> void:
	var exit: Node = get_exit_zone()
	if exit and exit.has_signal("escaped"):
		exit.escaped.connect(func() -> void: escaped.emit())
