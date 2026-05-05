# =============================================================================
# MapGenerator.gd
# Procedurally generates a top-down isometric-style map.
#
# HOW IT WORKS:
#   1. FastNoiseLite generates a height-map float array.
#   2. Height values are bucketed into terrain types (water, grass, dirt, rock).
#   3. Each terrain type maps to a tile ID in your TileSet resource.
#   4. A NavigationRegion2D / NavigationPolygon is baked so soldiers can path-find.
#
# SCENE SETUP:
#   - Add a TileMapLayer node as a child (Godot 4.x) or TileMap (Godot 3.x).
#   - Assign a TileSet with at minimum 4 tile IDs (0=water,1=grass,2=dirt,3=rock).
#   - Add a NavigationRegion2D as sibling; the generator will bake it at runtime.
# =============================================================================
extends Node2D

# ---------------------------------------------------------------------------
# Exported tunables — tweak in the Inspector without touching code
# ---------------------------------------------------------------------------
@export var map_width:  int   = 80          # tiles across
@export var map_height: int   = 60          # tiles tall
@export var tile_size:  int   = 64          # pixels per tile (match your TileSet)

# Noise thresholds — values are 0..1 from FastNoiseLite
@export var water_threshold: float = 0.25   # below this → water (impassable)
@export var dirt_threshold:  float = 0.55   # below this → dirt
@export var rock_threshold:  float = 0.80   # below this → grass; above → rock

@export var noise_frequency: float = 0.05   # lower = smoother / larger features

# Enemy spawn density (1 enemy per N passable tiles, roughly)
@export var enemy_density: int = 30

# ---------------------------------------------------------------------------
# Node references — set in _ready via $NodePath shorthand
# ---------------------------------------------------------------------------
@onready var tile_map: TileMapLayer = $TileMapLayer
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D

# ---------------------------------------------------------------------------
# Tile IDs — must match your TileSet resource
# ---------------------------------------------------------------------------
const TILE_WATER  := 0
const TILE_GRASS  := 1
const TILE_DIRT   := 2
const TILE_ROCK   := 3

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _noise := FastNoiseLite.new()
var _passable_cells: Array[Vector2i] = []   # cells enemies/soldiers can occupy

# ---------------------------------------------------------------------------
# Public API — call this from Main.gd to (re-)generate the map
# ---------------------------------------------------------------------------
func generate(seed_value: int = 0) -> void:
	_configure_noise(seed_value)
	_fill_tiles()
	_bake_navigation()
	_spawn_enemies()

# ---------------------------------------------------------------------------
# Returns an array of world-space Vector2 positions suitable for soldier spawn
# ---------------------------------------------------------------------------
func get_spawn_positions(count: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	# Pick from the bottom-left quarter of the map so spawns are away from action
	var candidates = _passable_cells.filter(func(c): return c.y > map_height * 0.75)
	candidates.shuffle()
	for i in min(count, candidates.size()):
		result.append(tile_map.map_to_local(candidates[i]))
	return result

# =============================================================================
# PRIVATE HELPERS
# =============================================================================

func _configure_noise(seed_value: int) -> void:
	_noise.seed          = seed_value
	_noise.noise_type    = FastNoiseLite.TYPE_PERLIN
	_noise.frequency     = noise_frequency
	# Fractal layering adds interesting detail at multiple scales
	_noise.fractal_type  = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4

func _fill_tiles() -> void:
	_passable_cells.clear()
	tile_map.clear()

	for x in map_width:
		for y in map_height:
			# get_noise_2d returns -1..1; remap to 0..1 for easier thresholding
			var raw:   float = _noise.get_noise_2d(float(x), float(y))
			var value: float = (raw + 1.0) * 0.5

			var tile_id: int
			if value < water_threshold:
				tile_id = TILE_WATER        # impassable
			elif value < dirt_threshold:
				tile_id = TILE_DIRT
				_passable_cells.append(Vector2i(x, y))
			elif value < rock_threshold:
				tile_id = TILE_GRASS
				_passable_cells.append(Vector2i(x, y))
			else:
				tile_id = TILE_ROCK         # impassable decorative rocks

			# set_cell(layer, coords, source_id, atlas_coords)
			# Using source_id=0, atlas_coords derived from tile_id row
			tile_map.set_cell(Vector2i(x, y), 0, Vector2i(tile_id, 0))

func _bake_navigation() -> void:
	# Build a NavigationPolygon from the passable cells so NavigationAgent2D works.
	# In production you can use TileMap's built-in navigation layers instead.
	var nav_poly := NavigationPolygon.new()
	var outline  := PackedVector2Array()

	# Simple approach: add the whole map as walkable, then cut out impassable tiles.
	# A more optimal approach would merge adjacent passable rects.
	var half := Vector2(tile_size, tile_size) * 0.5
	for cell in _passable_cells:
		var world_pos: Vector2 = tile_map.map_to_local(cell)
		# Each passable cell contributes a small walkable polygon
		var tl := world_pos - half
		var br := world_pos + half
		var poly := PackedVector2Array([
			tl, Vector2(br.x, tl.y), br, Vector2(tl.x, br.y)
		])
		nav_poly.add_outline(poly)

	nav_poly.make_polygons_from_outlines()
	nav_region.navigation_polygon = nav_poly
	# Bake is automatic when NavigationPolygon is assigned in Godot 4

func _spawn_enemies() -> void:
	# Enemies spawn in the upper half of the map
	var spawn_zone = _passable_cells.filter(func(c): return c.y < map_height * 0.4)
	spawn_zone.shuffle()

	# Load the enemy scene (create enemies/Enemy.tscn separately)
	var enemy_scene: PackedScene = load("res://scenes/Enemy.tscn")
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
