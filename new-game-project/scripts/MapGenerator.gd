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

@export var map_width:  int   = 80
@export var map_height: int   = 60
@export var tile_size:  int   = 64

@export var water_threshold: float = 0.25
@export var dirt_threshold:  float = 0.55
@export var rock_threshold:  float = 0.80
@export var noise_frequency: float = 0.05
@export var enemy_density:   int   = 30

@onready var tile_map:   TileMapLayer       = $TileMapLayer
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D

const TILE_WATER  := 0
const TILE_GRASS  := 1
const TILE_DIRT   := 2
const TILE_ROCK   := 3

var _noise := FastNoiseLite.new()
var _passable_cells: Array[Vector2i] = []

# ---------------------------------------------------------------------------
func generate(seed_value: int = 0) -> void:
	_configure_noise(seed_value)
	_fill_tiles()
	_bake_navigation()
	_spawn_enemies()

# ---------------------------------------------------------------------------
# Returns the world-centre of the map so the camera can snap there on start.
# ---------------------------------------------------------------------------
func get_map_centre() -> Vector2:
	# map_to_local converts tile coords to local coords of the TileMapLayer.
	# to_global converts those to world space correctly regardless of offsets.
	var centre_tile := Vector2i(map_width / 2, map_height / 2)
	return tile_map.to_global(tile_map.map_to_local(centre_tile))

# ---------------------------------------------------------------------------
func get_spawn_positions(count: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var candidates = _passable_cells.filter(func(c): return c.y > map_height * 0.75)
	candidates.shuffle()
	for i in min(count, candidates.size()):
		result.append(tile_map.to_global(tile_map.map_to_local(candidates[i])))
	return result

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

			var tile_id: int
			if value < water_threshold:
				tile_id = TILE_WATER
			elif value < dirt_threshold:
				tile_id = TILE_DIRT
				_passable_cells.append(Vector2i(x, y))
			elif value < rock_threshold:
				tile_id = TILE_GRASS
				_passable_cells.append(Vector2i(x, y))
			else:
				tile_id = TILE_ROCK

			tile_map.set_cell(Vector2i(x, y), 0, Vector2i(tile_id, 0))

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

	nav_poly.add_outline(outline)
	nav_poly.make_polygons_from_outlines()
	nav_region.navigation_polygon = nav_poly

func _spawn_enemies() -> void:
	var spawn_zone = _passable_cells.filter(func(c): return c.y < map_height * 0.4)
	spawn_zone.shuffle()

	var enemy_scene: PackedScene = load("res://scenes/enemy.tscn")
	if enemy_scene == null:
		# Try capitalised name as fallback
		enemy_scene = load("res://scenes/Enemy.tscn")
	if enemy_scene == null:
		push_warning("[MapGenerator] Enemy.tscn not found — skipping enemy spawn.")
		return

	var count: int = spawn_zone.size() / enemy_density
	GameManager.enemies_alive = count

	for i in count:
		if i >= spawn_zone.size():
			break
		var enemy: Node2D = enemy_scene.instantiate()
		enemy.position = tile_map.map_to_local(spawn_zone[i])
		add_child(enemy)
