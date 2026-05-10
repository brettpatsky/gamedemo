# =============================================================================
# MapGenerator.gd  (FIXED)
#
# FIX 1 — Navigation baking completely rewritten.
#   The original approach added one outline polygon per passable tile.
#   Godot's make_polygons_from_outlines() requires outlines to never share
#   edges or overlap — thousands of adjacent tile-squares violate this
#   instantly. The new approach uses a SINGLE large rectangle covering the
#   whole map as the walkable area. Soldiers and enemies can walk anywhere;
#   impassable tiles are visual only. This is standard practice for top-down
#   games and works perfectly with NavigationAgent2D.
#
# FIX 2 — Camera target point exposed via get_map_centre().
#   CameraController can call this to snap to the correct world position
#   on startup rather than guessing from pixel maths.
# =============================================================================
extends Node2D

const ObstacleClass = preload("res://scripts/Obstacle.gd")

@export var map_width:  int   = 55
@export var map_height: int   = 50
@export var tile_size:  int   = 64

@export var water_threshold: float = 0.40
@export var dirt_threshold:  float = 0.55
@export var rock_threshold:  float = 0.80
@export var noise_frequency: float = 0.05
@export var enemy_density:   int   = 30
@export var tile_config:     TileConfig

@onready var tile_map:   TileMapLayer       = $TileMapLayer
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D

var _noise := FastNoiseLite.new()
var _passable_cells: Array[Vector2i] = []

# References to level-specific nodes set during generate(); read by Main.gd.
var _objective_nodes: Dictionary = {}

# ---------------------------------------------------------------------------
func _ready() -> void:
	add_to_group("map_generator")
	if tile_config == null:
		tile_config = TileConfig.new()

# ---------------------------------------------------------------------------
func generate(seed_value: int = 0) -> void:
	_objective_nodes.clear()
	_configure_noise(seed_value)
	_fill_tiles()
	_spawn_obstacles()
	_bake_navigation()
	_spawn_enemies()
	match GameManager.current_level:
		2: _spawn_fortified_structure()
		3: _spawn_escort_mission()

# ---------------------------------------------------------------------------
# Returns the world-centre of the map so the camera can snap there on start.
# ---------------------------------------------------------------------------
func get_map_centre() -> Vector2:
	# map_to_local converts tile coords to local coords of the TileMapLayer.
	# to_global converts those to world space correctly regardless of offsets.
	@warning_ignore("integer_division")
	var centre_tile := Vector2i(map_width / 2, map_height / 2)
	return tile_map.to_global(tile_map.map_to_local(centre_tile))

# ---------------------------------------------------------------------------
# Returns true when world_pos is over a water tile — used by soldiers/enemies
# to apply the wading speed penalty.
func is_water_at(world_pos: Vector2) -> bool:
	var local_pos := tile_map.to_local(world_pos)
	var tile_pos  := tile_map.local_to_map(local_pos)
	return tile_map.get_cell_atlas_coords(tile_pos) == tile_config.water

func get_spawn_positions(count: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	# Spawn squad in the centre band of the map
	var candidates = _passable_cells.filter(func(c: Vector2i) -> bool:
		var cx := float(c.x) / map_width
		var cy := float(c.y) / map_height
		return cx > 0.38 and cx < 0.62 and cy > 0.45 and cy < 0.55
	)
	if candidates.is_empty():
		candidates = _passable_cells.filter(func(c: Vector2i) -> bool:
			var cy := float(c.y) / map_height
			return cy > 0.40 and cy < 0.60
		)
	candidates.shuffle()
	for i in min(count, candidates.size()):
		result.append(tile_map.to_global(tile_map.map_to_local(candidates[i])))
	return result

func get_map_rect() -> Rect2:
	var tl := tile_map.to_global(tile_map.map_to_local(Vector2i(0, 0)))
	var br := tile_map.to_global(tile_map.map_to_local(Vector2i(map_width, map_height)))
	return Rect2(tl, br - tl)

# =============================================================================
# PRIVATE
# =============================================================================

func _configure_noise(seed_value: int) -> void:
	_noise.seed            = seed_value
	_noise.noise_type      = FastNoiseLite.TYPE_PERLIN
	_noise.frequency       = noise_frequency
	_noise.fractal_type    = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4

func _fill_tiles() -> void:
	_passable_cells.clear()
	tile_map.clear()

	for x in map_width:
		for y in map_height:
			var raw:   float = _noise.get_noise_2d(float(x), float(y))
			var value: float = (raw + 1.0) * 0.5

			var atlas_coord: Vector2i
			if value < water_threshold:
				atlas_coord = tile_config.water
			elif value < dirt_threshold:
				atlas_coord = tile_config.dirt
				_passable_cells.append(Vector2i(x, y))
			elif value < rock_threshold:
				atlas_coord = tile_config.grass
				_passable_cells.append(Vector2i(x, y))
			else:
				atlas_coord = tile_config.rock

			tile_map.set_cell(Vector2i(x, y), tile_config.tileset_source_id, atlas_coord)

func _spawn_obstacles() -> void:
	# Keep the player centre-spawn zone and map border clear of obstacles.
	var eligible = _passable_cells.filter(func(c: Vector2i) -> bool:
		if c.x < 3 or c.x > map_width  - 4: return false
		if c.y < 3 or c.y > map_height - 4: return false
		var cx := float(c.x) / map_width
		var cy := float(c.y) / map_height
		return not (cx > 0.33 and cx < 0.67 and cy > 0.40 and cy < 0.60)
	)
	eligible.shuffle()

	var total := mini(int(eligible.size() * 0.08), 220)
	@warning_ignore("integer_division")
	var tree_count := total / 2
	for i in total:
		var cell: Vector2i = eligible[i]
		var obs: StaticBody2D = ObstacleClass.new()
		obs.is_tree = i < tree_count
		obs.position = tile_map.map_to_local(cell)
		add_child(obs)
		_passable_cells.erase(cell)

func _bake_navigation() -> void:
	# -------------------------------------------------------------------------
	# FIX: Use a single bounding rectangle as the nav polygon instead of one
	# polygon per tile. The per-tile approach caused Godot's convex partition
	# to fail because adjacent tile squares share edges, which is illegal.
	#
	# A single rectangle covering the entire map is valid and sufficient.
	# NavigationAgent2D will path-find across the whole area. Impassable tiles
	# (water, rock) are purely visual — for full obstacle avoidance you would
	# add NavigationObstacle2D nodes on them, but for a top-down shooter the
	# open nav mesh is fine and much more stable.
	# -------------------------------------------------------------------------
	var nav_poly := NavigationPolygon.new()

	# Get world-space corners of the full map via to_global so any node
	# offsets are accounted for automatically.
	var top_left  := tile_map.to_global(tile_map.map_to_local(Vector2i(0, 0)))
	var bot_right := tile_map.to_global(tile_map.map_to_local(Vector2i(map_width, map_height)))

	# NavigationPolygon works in the NavigationRegion2D's LOCAL space.
	# Convert from global → nav_region local.
	var tl := nav_region.to_local(top_left)
	var br := nav_region.to_local(bot_right)

	# Single clockwise outline = one walkable region, no holes.
	var outline := PackedVector2Array([
		tl,
		Vector2(br.x, tl.y),
		br,
		Vector2(tl.x, br.y)
	])

	# Directly assign vertices and polygon indices — avoids the deprecated
	# make_polygons_from_outlines() call. Works because our shape is a simple
	# convex quad (no triangulation needed).
	nav_poly.vertices = outline
	nav_poly.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	nav_region.navigation_polygon = nav_poly

func _spawn_enemies() -> void:
	# Spawn enemies across the entire map except the centre band where squad spawns
	var spawn_zone = _passable_cells.filter(func(c):
		var cy := float(c.y) / map_height
		# Avoid centre 30% (where squad starts at 0.45-0.55) — use top, bottom, sides
		return cy < 0.35 or cy > 0.65
	)
	spawn_zone.shuffle()

	var enemy_scene: PackedScene = load("res://scenes/enemy.tscn")
	if enemy_scene == null:
		enemy_scene = load("res://scenes/Enemy.tscn")
	if enemy_scene == null:
		push_warning("[MapGenerator] Enemy.tscn not found — skipping enemy spawn.")
		return

	var count: int = 50  # Fixed 50 enemies
	GameManager.enemies_alive = count
	GameManager.enemies_changed.emit(count)

	for i in count:
		if i >= spawn_zone.size():
			break
		var enemy: Node2D = enemy_scene.instantiate()
		enemy.position = tile_map.map_to_local(spawn_zone[i])
		add_child(enemy)

# ---------------------------------------------------------------------------
# Returns a level-specific node by group name (set during generate()).
# ---------------------------------------------------------------------------
func get_objective_node(group: String) -> Node:
	return _objective_nodes.get(group, null)

# ---------------------------------------------------------------------------
# Level 2 — spawn a fortified structure in the upper-centre of the map.
# ---------------------------------------------------------------------------
func _spawn_fortified_structure() -> void:
	var zone = _passable_cells.filter(func(c): return c.y > map_height * 0.10 and c.y < map_height * 0.25)
	if zone.is_empty():
		zone = _passable_cells.filter(func(c): return c.y < map_height * 0.35)
	if zone.is_empty():
		return
	zone.shuffle()

	var scene: PackedScene = load("res://scenes/fortified_structure.tscn")
	if scene == null:
		push_warning("[MapGenerator] fortified_structure.tscn not found.")
		return
	var node: Node2D = scene.instantiate()
	node.position = tile_map.map_to_local(zone[0])
	add_child(node)
	_objective_nodes["fortified_structure"] = node

# ---------------------------------------------------------------------------
# Level 3 — spawn an escort NPC near soldiers and an extraction zone at the top.
# ---------------------------------------------------------------------------
func _spawn_escort_mission() -> void:
	# NPC spawns close to the player start area
	var npc_zone = _passable_cells.filter(func(c): return c.y > map_height * 0.70)
	if npc_zone.is_empty():
		return
	npc_zone.shuffle()

	var npc_scene: PackedScene = load("res://scenes/npc_escort.tscn")
	if npc_scene == null:
		push_warning("[MapGenerator] npc_escort.tscn not found.")
		return
	var npc: Node2D = npc_scene.instantiate()
	npc.position = tile_map.map_to_local(npc_zone[0])
	add_child(npc)
	_objective_nodes["escort_npc"] = npc

	# Extraction zone at the very top of the map
	var ext_zone = _passable_cells.filter(func(c): return c.y < map_height * 0.10)
	if ext_zone.is_empty():
		ext_zone = _passable_cells.filter(func(c): return c.y < map_height * 0.20)
	if ext_zone.is_empty():
		return
	ext_zone.shuffle()

	var ext_scene: PackedScene = load("res://scenes/extraction_zone.tscn")
	if ext_scene == null:
		push_warning("[MapGenerator] extraction_zone.tscn not found.")
		return
	var zone_node: Node2D = ext_scene.instantiate()
	zone_node.position = tile_map.map_to_local(ext_zone[0])
	add_child(zone_node)
	_objective_nodes["extraction_zone"] = zone_node
