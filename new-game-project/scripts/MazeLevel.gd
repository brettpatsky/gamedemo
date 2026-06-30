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

# Maze grid: '#' = wall, '.' = open. 22 cols × 15 rows at CELL_SIZE px each.
# Spawn is at (col=1, row=1); exit sits at (col=20, row=13). Verified solvable:
# (1,1)→ down the left wall → right at row 5 → through the middle corridor →
# up via col 13 → across the top row 1 → down the right side → (13,20).
const CELL_SIZE := 64
@warning_ignore("integer_division")
const _HALF_CELL := CELL_SIZE / 2
const MAZE_LAYOUT: Array[String] = [
	"######################",
	"#.....#..............#",
	"#.###.#.####.#.#####.#",
	"#.#...#....#...#.....#",
	"#.#.#####.###.###.####",
	"#.............#.#....#",
	"###.#.#.#####.#.#.##.#",
	"#...#.#.......#...#..#",
	"#.###.#####.#.#####.##",
	"#.#...#.....#.....#..#",
	"#.#.#.#.#########.#.##",
	"#.#.#...........#.#..#",
	"#.#.###..######.#.##.#",
	"#...........#........#",
	"######################",
]

const _ROCK_SCENE: PackedScene = preload("res://scenes/mazes/maze_rock.tscn")
const _MEMORY_FRAGMENT_SCENE: PackedScene = preload("res://scenes/memory_fragment.tscn")
const CAVE_SYSTEM_SCRIPT := preload("res://scripts/CaveSystem.gd")

@onready var background: ColorRect          = $Background
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D

var _map_w_px: float = 0.0
var _map_h_px: float = 0.0
var _parent_cage:      Node  = null
var _memory_fragments: Array = []

func _ready() -> void:
	add_to_group("map_generator")
	add_to_group("maze_level")
	_spawn_walls_from_layout()
	_resize_background_to_layout()
	_compute_map_bounds()
	_bake_nav()
	_connect_exit()
	_spawn_mission_parent_and_fragment()

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
	if key == "parent_cage":
		return _parent_cage
	if key == "memory_fragments":
		return _memory_fragments
	if key == "memory_fragment":
		return _memory_fragments[0] if not _memory_fragments.is_empty() else null
	return null

# Places the parent cage and THREE memory-fragment collectables in random open
# cells of the maze. Candidate cells skip the spawn halo (so nothing lands on
# the squad's start) and the exit halo (so a collectable is never sitting on the
# exit trigger, where walking onto it would end the level instead of letting the
# player grab it). Same `child_slot` / fragment_id contract as
# MapGenerator._spawn_mission_parent_and_fragment.
func _spawn_mission_parent_and_fragment() -> void:
	var level: int = GameManager.current_level
	var exit_c := _exit_cell()

	var open_cells: Array[Vector2i] = []
	for row_idx in MAZE_LAYOUT.size():
		var row: String = MAZE_LAYOUT[row_idx]
		for col_idx in row.length():
			if row[col_idx] != ".":
				continue
			# Spawn is at (1,1); skip a 4-cell halo so nothing lands on the
			# squad's starting position.
			var diff_x: int = col_idx - 1
			var diff_y: int = row_idx - 1
			if diff_x * diff_x + diff_y * diff_y < 16:
				continue
			# Skip the exit cell and its 8 neighbours so collectables stay clear
			# of the exit trigger.
			if exit_c.x >= 0 and absi(col_idx - exit_c.x) <= 1 and absi(row_idx - exit_c.y) <= 1:
				continue
			open_cells.append(Vector2i(col_idx, row_idx))
	if open_cells.is_empty():
		return
	open_cells.shuffle()
	var cage_cell: Vector2i = open_cells[0]

	# A freestanding ground portal into the hidden cave, in place of the old
	# literal parent_cage — the maze has no plateau wall to set a mouth into.
	var cave := Node2D.new()
	cave.set_script(CAVE_SYSTEM_SCRIPT)
	add_child(cave)
	cave.setup(_cell_centre(cage_cell), level - 1, get_map_rect(), true)
	_parent_cage = cave.parent_cage

	if _MEMORY_FRAGMENT_SCENE:
		# Three distinct, not-yet-collected fragments, spread out from the cage
		# and each other so the player explores to find them all.
		var frag_ids := _pick_fragment_ids(3)
		var frag_cells := _spread_cells(open_cells, cage_cell, frag_ids.size())
		var spawned: Array = []
		for i in mini(frag_ids.size(), frag_cells.size()):
			var frag: Node2D = _MEMORY_FRAGMENT_SCENE.instantiate()
			frag.position = _cell_centre(frag_cells[i])
			if "fragment_id" in frag:
				frag.set("fragment_id", frag_ids[i])
			if "display_name" in frag:
				frag.set("display_name", FragmentEffects.get_display_name(frag_ids[i]))
			add_child(frag)
			spawned.append(frag)
		_memory_fragments = spawned

# Cell -> world-space centre of that cell.
func _cell_centre(c: Vector2i) -> Vector2:
	return Vector2(c.x * CELL_SIZE + _HALF_CELL, c.y * CELL_SIZE + _HALF_CELL)

# The maze exit's grid cell, derived from the Exit node's actual position so it
# tracks any hand-edits to the scene. Returns (-1,-1) if there's no Exit node.
func _exit_cell() -> Vector2i:
	var exit: Node = get_exit_zone()
	if exit is Node2D:
		var p: Vector2 = (exit as Node2D).position
		return Vector2i(floori(p.x / CELL_SIZE), floori(p.y / CELL_SIZE))
	return Vector2i(-1, -1)

# Up to `count` fragment IDs not yet permanently collected this run (mirrors
# MapGenerator._pick_level_fragment_ids so maze rewards match the other levels).
func _pick_fragment_ids(count: int) -> Array[String]:
	var available: Array[String] = []
	for id in FragmentEffects.FRAGMENT_METADATA.keys():
		if not RunState.fragments.has(id):
			available.append(id)
	available.shuffle()
	if available.size() > count:
		available.resize(count)
	return available

# Greedy max-dispersion pick of `count` cells: first the one farthest from the
# cage, then each next maximising its minimum distance to the cage and all
# already-picked cells, so the three collectables spread across the maze.
func _spread_cells(cells: Array[Vector2i], avoid: Vector2i, count: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if cells.is_empty():
		return result
	var first: Vector2i = cells[0]
	var best_d := -1
	for c in cells:
		var diff: Vector2i = c - avoid
		var d: int = diff.x * diff.x + diff.y * diff.y
		if d > best_d:
			best_d = d
			first = c
	result.append(first)
	while result.size() < count and result.size() < cells.size():
		var pick: Vector2i = cells[0]
		var pick_score := -1
		for c in cells:
			if result.has(c):
				continue
			var diff0: Vector2i = c - avoid
			var min_d: int = diff0.x * diff0.x + diff0.y * diff0.y
			for r in result:
				var diff: Vector2i = c - r
				min_d = mini(min_d, diff.x * diff.x + diff.y * diff.y)
			if min_d > pick_score:
				pick_score = min_d
				pick = c
		result.append(pick)
	return result

func generate(_seed_value: int = 0) -> void:
	GameManager.enemies_alive = 0
	GameManager.enemies_changed.emit(0)

# ---------------------------------------------------------------------------
# PRIVATE
# ---------------------------------------------------------------------------
func _spawn_walls_from_layout() -> void:
	for row_idx in MAZE_LAYOUT.size():
		var row: String = MAZE_LAYOUT[row_idx]
		for col_idx in row.length():
			if row[col_idx] != "#":
				continue
			var rock: Node2D = _ROCK_SCENE.instantiate()
			rock.position = Vector2(
				col_idx * CELL_SIZE + _HALF_CELL,
				row_idx * CELL_SIZE + _HALF_CELL,
			)
			add_child(rock)

func _resize_background_to_layout() -> void:
	if background == null or MAZE_LAYOUT.is_empty():
		return
	var w: int = MAZE_LAYOUT[0].length() * CELL_SIZE
	var h: int = MAZE_LAYOUT.size() * CELL_SIZE
	background.offset_left   = 0
	background.offset_top    = 0
	background.offset_right  = w
	background.offset_bottom = h

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
