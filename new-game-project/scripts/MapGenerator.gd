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
@export var elevation_frequency: float = 0.025  # lower freq = bigger hill/valley features
@export var enemy_density:   int   = 30
@export var tile_config:     TileConfig

# Elevation thresholds: any tile with elevation noise above HILL_THRESHOLD is
# "high ground" (range bonus); below VALLEY_THRESHOLD is "low ground" (range
# penalty). Kept here so Bullet.gd and the visual overlay agree on which tiles
# count. Update both these AND the duplicates in _make_topography_script() if
# you tune them.
const HILL_THRESHOLD:    float = 0.18
const VALLEY_THRESHOLD:  float = -0.18
const HILL_RANGE_MULT:   float = 1.35
const VALLEY_RANGE_MULT: float = 0.70

@onready var tile_map:   TileMapLayer       = $TileMapLayer
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D

var _noise           := FastNoiseLite.new()
var _elevation_noise := FastNoiseLite.new()
var _passable_cells: Array[Vector2i] = []

# References to level-specific nodes set during generate(); read by Main.gd.
var _objective_nodes: Dictionary = {}

# Level-3 safe-zone exclusion (tile coords) — enemies must not spawn inside.
var _enemy_exclusion_centre: Vector2i = Vector2i.ZERO
var _enemy_exclusion_radius: int = 0

# ---------------------------------------------------------------------------
func _ready() -> void:
	add_to_group("map_generator")
	if tile_config == null:
		tile_config = TileConfig.new()

# ---------------------------------------------------------------------------
func generate(seed_value: int = 0) -> void:
	_objective_nodes.clear()
	_enemy_exclusion_radius = 0
	_configure_noise(seed_value)
	_fill_tiles()
	_spawn_topography()
	_spawn_obstacles()
	_spawn_boundary_walls()
	_bake_navigation()
	# Escort mission picks the NPC spot first so enemy spawn can avoid it.
	match GameManager.current_level:
		2: _spawn_fortified_structure()
		3: _spawn_escort_mission()
	_spawn_enemies()

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

# Raw elevation noise value (-1..1) at the given world position. Sampled at
# tile granularity so the visual overlay and gameplay agree on terrain class.
func get_elevation_at(world_pos: Vector2) -> float:
	var local_pos := tile_map.to_local(world_pos)
	var tile_pos  := tile_map.local_to_map(local_pos)
	return _elevation_noise.get_noise_2d(float(tile_pos.x), float(tile_pos.y))

# Projectile range multiplier based on the shooter's footing.
#   Hill   → HILL_RANGE_MULT   (bullets travel further)
#   Valley → VALLEY_RANGE_MULT (bullets travel less)
#   Flat   → 1.0
func get_range_modifier_at(world_pos: Vector2) -> float:
	var e := get_elevation_at(world_pos)
	if e > HILL_THRESHOLD:
		return HILL_RANGE_MULT
	if e < VALLEY_THRESHOLD:
		return VALLEY_RANGE_MULT
	return 1.0

# Movement-speed multiplier from terrain slope. Samples the elevation noise
# directly ahead of the mover and compares with its current footing; uphill
# steps slow the mover, downhill steps speed it up. Clamped to a ±25 % swing
# so it tweaks pacing without making any tile a no-go zone.
func get_slope_speed_mult(world_pos: Vector2, direction: Vector2) -> float:
	if direction.length_squared() < 0.01:
		return 1.0
	var dir := direction.normalized()
	# Sample roughly one tile ahead — far enough to register a real slope but
	# close enough to track the actual path the mover is on.
	var here  := get_elevation_at(world_pos)
	var ahead := get_elevation_at(world_pos + dir * float(tile_size))
	var slope := ahead - here   # >0 = uphill, <0 = downhill
	# Noise deltas across one tile are typically within ±0.2; scale to ±0.25.
	return clampf(1.0 - slope * 1.25, 0.75, 1.25)

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
	# map_to_local returns the CENTRE of a tile, so the actual visible bounds
	# are half a tile past the corner tiles' centres. Using corners (not
	# centres) makes the camera clamp exactly to the visible map edge — no
	# stray empty viewport strip on the right/bottom.
	var half_tile := Vector2(tile_size, tile_size) * 0.5
	var tl := tile_map.to_global(tile_map.map_to_local(Vector2i(0, 0)) - half_tile)
	var br := tile_map.to_global(tile_map.map_to_local(Vector2i(map_width - 1, map_height - 1)) + half_tile)
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

	# Separate noise field for elevation so hills/valleys don't align with
	# water/grass/rock biome boundaries.
	_elevation_noise.seed            = seed_value + 9173
	_elevation_noise.noise_type      = FastNoiseLite.TYPE_PERLIN
	_elevation_noise.frequency       = elevation_frequency
	_elevation_noise.fractal_type    = FastNoiseLite.FRACTAL_FBM
	_elevation_noise.fractal_octaves = 3

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

# ---------------------------------------------------------------------------
# Visual hill/valley overlay. Samples a low-frequency elevation noise across
# every tile and draws a single batched polygon layer of tinted shading per
# tile — bright/warm for hills, dark/cool for valleys. Purely cosmetic; no
# gameplay effect. Implemented as one child Node2D so we can hand the noise
# values into its _draw() once and let Godot handle batching.
# ---------------------------------------------------------------------------
func _spawn_topography() -> void:
	var overlay := Node2D.new()
	overlay.name = "TopographyOverlay"
	# Sit ON TOP of the tilemap (tilemap z_index = 0). Soldiers/enemies live
	# under the sibling SquadController and render after MapGenerator's whole
	# subtree, so they remain on top of this overlay regardless.
	overlay.z_index = 0
	overlay.show_behind_parent = false
	overlay.set_script(_make_topography_script())
	overlay.set("tile_size",  tile_size)
	overlay.set("map_width",  map_width)
	overlay.set("map_height", map_height)
	# Snapshot the elevation field as a flat float array so _draw() doesn't
	# touch the FastNoiseLite each frame.
	var samples := PackedFloat32Array()
	samples.resize(map_width * map_height)
	# Water mask — overlay must not paint hillshade on water tiles (they're
	# obvious from the blue colour and stippling them with light/shadow looks
	# like a bad photo filter).
	var water_bytes := PackedByteArray()
	water_bytes.resize(map_width * map_height)
	for x in map_width:
		for y in map_height:
			var idx := x * map_height + y
			samples[idx] = _elevation_noise.get_noise_2d(float(x), float(y))
			var atlas := tile_map.get_cell_atlas_coords(Vector2i(x, y))
			water_bytes[idx] = 1 if atlas == tile_config.water else 0
	overlay.set("elevation",  samples)
	overlay.set("water_mask", water_bytes)
	overlay.position = tile_map.position
	add_child(overlay)

# Inline script for the overlay node — proper hillshade rendering.
#
# Each tile is tinted by the dot product of its surface normal (derived from
# elevation gradient) with a virtual light direction coming from the NW. The
# eye naturally reads bright-NW-edge / dark-SE-edge tiles as raised ground
# and inverted shading as depressions — the same trick paper topo maps use.
#
# Water tiles are skipped (water_mask = 1) so the shading doesn't muddy up
# the blue. Subtle contour lines mark the gameplay thresholds so players can
# tell where the projectile / movement bonuses kick in.
func _make_topography_script() -> GDScript:
	var src := """
extends Node2D

var tile_size:  int   = 64
var map_width:  int   = 0
var map_height: int   = 0
var elevation:  PackedFloat32Array
var water_mask: PackedByteArray

const HILL_THRESHOLD   := 0.18
const VALLEY_THRESHOLD := -0.18

# Hillshade — light coming from the NW (negative x and y). Adjusting these
# changes the apparent sun direction; intensity scales gradient magnitude
# into the [-1, 1] brightness band.
const LIGHT_X         := -0.6
const LIGHT_Y         := -0.6
const SHADE_INTENSITY := 5.0
const HIGHLIGHT_ALPHA := 0.55
const SHADOW_ALPHA    := 0.65

const HIGHLIGHT := Color(1.00, 0.96, 0.78)   # warm sun-lit cream
const SHADOW    := Color(0.02, 0.06, 0.14)   # deep cool shadow

# Threshold contour — kept subtle so the hillshade is the dominant visual.
const CONTOUR_HILL   := Color(1.00, 0.92, 0.40, 0.50)
const CONTOUR_VALLEY := Color(0.40, 0.85, 1.00, 0.50)
const CONTOUR_THICK  := 1.5

func _elev(x: int, y: int) -> float:
	if x < 0: x = 0
	elif x >= map_width: x = map_width - 1
	if y < 0: y = 0
	elif y >= map_height: y = map_height - 1
	return elevation[x * map_height + y]

func _is_water(x: int, y: int) -> bool:
	if x < 0 or x >= map_width or y < 0 or y >= map_height:
		return false
	if water_mask.size() == 0:
		return false
	return water_mask[x * map_height + y] != 0

func _classify(e: float) -> int:
	if e > HILL_THRESHOLD:   return 1
	if e < VALLEY_THRESHOLD: return -1
	return 0

func _draw() -> void:
	if map_width == 0 or map_height == 0:
		return
	var ts: float = float(tile_size)
	# TileMapLayer.map_to_local() returns the CENTRE of each tile; offset by
	# half a tile so our rects align with what the player sees underneath.
	var half: float = ts * 0.5

	# Pass 1 — hillshade. Per-tile brightness from the elevation gradient.
	for x in map_width:
		for y in map_height:
			if _is_water(x, y):
				continue
			var dx: float = _elev(x + 1, y) - _elev(x - 1, y)
			var dy: float = _elev(x, y + 1) - _elev(x, y - 1)
			# Surface facing the light → bright; facing away → dark.
			# Negate so an uphill-toward-light slope reads as bright.
			var s: float = -(dx * LIGHT_X + dy * LIGHT_Y) * SHADE_INTENSITY
			s = clampf(s, -1.0, 1.0)
			if absf(s) < 0.04:
				continue   # essentially flat — leave the tile alone
			var rect := Rect2(x * ts - half, y * ts - half, ts, ts)
			if s > 0.0:
				var col: Color = HIGHLIGHT
				col.a = s * HIGHLIGHT_ALPHA
				draw_rect(rect, col, true)
			else:
				var col2: Color = SHADOW
				col2.a = -s * SHADOW_ALPHA
				draw_rect(rect, col2, true)

	# Pass 2 — thin contour lines along the gameplay threshold so players can
	# tell where the projectile / movement modifier turns on. Drawn after the
	# hillshade so they stay crisp.
	for x in map_width:
		for y in map_height:
			if _is_water(x, y):
				continue
			var cls: int = _classify(elevation[x * map_height + y])
			if cls == 0:
				continue
			var line_col: Color = CONTOUR_HILL if cls == 1 else CONTOUR_VALLEY
			var tx: float = x * ts - half
			var ty: float = y * ts - half
			# Right edge.
			var ncls: int = 0
			if x + 1 < map_width:
				ncls = _classify(elevation[(x + 1) * map_height + y])
			if ncls != cls:
				draw_line(Vector2(tx + ts, ty), Vector2(tx + ts, ty + ts), line_col, CONTOUR_THICK)
			# Bottom edge.
			ncls = 0
			if y + 1 < map_height:
				ncls = _classify(elevation[x * map_height + (y + 1)])
			if ncls != cls:
				draw_line(Vector2(tx, ty + ts), Vector2(tx + ts, ty + ts), line_col, CONTOUR_THICK)
			if x == 0:
				draw_line(Vector2(tx, ty), Vector2(tx, ty + ts), line_col, CONTOUR_THICK)
			if y == 0:
				draw_line(Vector2(tx, ty), Vector2(tx + ts, ty), line_col, CONTOUR_THICK)
"""
	var gs := GDScript.new()
	gs.source_code = src
	gs.reload()
	return gs

# ---------------------------------------------------------------------------
# Invisible static walls around the map perimeter so neither soldiers nor
# enemies can squeeze past the edge of the navigable area.
# ---------------------------------------------------------------------------
func _spawn_boundary_walls() -> void:
	# Compute the *actual* visible-tile bounds. map_to_local() returns the
	# CENTRE of a tile, so the visible corners are half a tile beyond the
	# corner tiles' centres.
	var half_tile: Vector2 = Vector2(tile_size, tile_size) * 0.5
	var tl_local: Vector2 = tile_map.position + tile_map.map_to_local(Vector2i(0, 0)) - half_tile
	var br_local: Vector2 = tile_map.position + tile_map.map_to_local(Vector2i(map_width - 1, map_height - 1)) + half_tile
	var w: float = br_local.x - tl_local.x
	var h: float = br_local.y - tl_local.y
	const T := 256.0   # very thick walls so RVO avoidance can't tunnel past

	# Top, bottom, left, right.  Walls sit OUTSIDE the visible tile region,
	# their inner face touching the visible edge exactly.
	_add_wall(tl_local.x - T, tl_local.y - T, w + T * 2.0, T)             # top
	_add_wall(tl_local.x - T, br_local.y,     w + T * 2.0, T)             # bottom
	_add_wall(tl_local.x - T, tl_local.y,     T,           h)             # left
	_add_wall(br_local.x,     tl_local.y,     T,           h)             # right

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

	# Total obstacle budget — half trees (clustered into forests), half rocks
	# (scattered individually).
	var total := mini(int(eligible.size() * 0.08), 220)
	@warning_ignore("integer_division")
	var tree_budget := total / 2
	var rock_budget := total - tree_budget

	# Fast lookup for eligibility / dedup as we flood-fill forest clusters.
	var eligible_set: Dictionary = {}
	for c in eligible:
		eligible_set[c] = true

	# ---- Trees: spawn in clusters of 5+ tiles using a randomised flood-fill ----
	const MIN_CLUSTER_SIZE := 5
	const MAX_CLUSTER_SIZE := 14
	var trees_placed := 0
	var seed_idx     := 0
	while trees_placed < tree_budget and seed_idx < eligible.size():
		var seed_cell: Vector2i = eligible[seed_idx]
		seed_idx += 1
		if not eligible_set.has(seed_cell):
			continue

		# Target size — random within range, but no smaller than the minimum or
		# what's left in the budget.
		var remaining := tree_budget - trees_placed
		var target_size: int = mini(randi_range(MIN_CLUSTER_SIZE, MAX_CLUSTER_SIZE), remaining)
		if target_size < MIN_CLUSTER_SIZE and remaining >= MIN_CLUSTER_SIZE:
			target_size = MIN_CLUSTER_SIZE

		var cluster: Array[Vector2i] = []
		var frontier: Array[Vector2i] = [seed_cell]
		while cluster.size() < target_size and not frontier.is_empty():
			# Pop a random frontier cell so clusters grow organically rather than in a line.
			var pick: int = randi() % frontier.size()
			var cell: Vector2i = frontier[pick]
			frontier.remove_at(pick)
			if not eligible_set.has(cell):
				continue
			eligible_set.erase(cell)
			cluster.append(cell)
			# 4-neighbour expansion.
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = cell + off
				if eligible_set.has(n):
					frontier.append(n)

		# If the seed was isolated and we couldn't reach the minimum, skip it.
		if cluster.size() < MIN_CLUSTER_SIZE:
			# Return cells to the pool so rocks can still use them.
			for c in cluster:
				eligible_set[c] = true
			continue

		for cell in cluster:
			var tree: StaticBody2D = ObstacleClass.new()
			tree.is_tree  = true
			tree.position = tile_map.map_to_local(cell)
			add_child(tree)
			_passable_cells.erase(cell)
			trees_placed += 1

	# ---- Rocks: scatter individually across whatever's left. ----
	var rocks_placed := 0
	for cell in eligible:
		if rocks_placed >= rock_budget:
			break
		if not eligible_set.has(cell):
			continue
		eligible_set.erase(cell)
		var rock: StaticBody2D = ObstacleClass.new()
		rock.is_tree  = false
		rock.position = tile_map.map_to_local(cell)
		add_child(rock)
		_passable_cells.erase(cell)
		rocks_placed += 1

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

	# Use the exact corners of the first and last visible tiles. map_to_local()
	# returns tile CENTRES, so add half a tile to reach the actual outer
	# corners. Then inset slightly so the path stays a hair inside the walls.
	var half_tile := Vector2(tile_size, tile_size) * 0.5
	var inset     := Vector2(tile_size, tile_size) * 0.25
	var top_left  := tile_map.to_global(tile_map.map_to_local(Vector2i(0, 0)) - half_tile + inset)
	var bot_right := tile_map.to_global(tile_map.map_to_local(Vector2i(map_width - 1, map_height - 1)) + half_tile - inset)

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
	var excl_centre := _enemy_exclusion_centre
	var excl_r2 := _enemy_exclusion_radius * _enemy_exclusion_radius
	var has_excl := _enemy_exclusion_radius > 0
	var spawn_zone = _passable_cells.filter(func(c: Vector2i) -> bool:
		if c.x < 2 or c.x > map_width  - 3: return false
		if c.y < 2 or c.y > map_height - 3: return false
		if has_excl:
			var dx: int = c.x - excl_centre.x
			var dy: int = c.y - excl_centre.y
			if dx * dx + dy * dy <= excl_r2:
				return false
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
func get_objective_node(group: String) -> Variant:
	return _objective_nodes.get(group, null)

# ---------------------------------------------------------------------------
# Level 2 — spawn 5 fortified structures spread across the map.
# ---------------------------------------------------------------------------
func _spawn_fortified_structure() -> void:
	var scene: PackedScene = load("res://scenes/fortified_structure.tscn")
	if scene == null:
		push_warning("[MapGenerator] fortified_structure.tscn not found.")
		return

	# Five non-overlapping zones covering different parts of the map.
	# Border-padded by 2 tiles; centre squad-spawn area naturally avoided.
	var zone_filters: Array[Callable] = [
		func(c: Vector2i) -> bool:  # top strip
			return c.x >= 2 and c.x <= map_width - 3 \
				and c.y >= 2 and c.y < int(map_height * 0.28),
		func(c: Vector2i) -> bool:  # left flank
			return c.x >= 2 and c.x < int(map_width * 0.25) \
				and c.y >= int(map_height * 0.28) and c.y <= map_height - 3,
		func(c: Vector2i) -> bool:  # right flank
			return c.x > int(map_width * 0.75) and c.x <= map_width - 3 \
				and c.y >= int(map_height * 0.28) and c.y <= map_height - 3,
		func(c: Vector2i) -> bool:  # bottom-left
			return c.x >= 2 and c.x < int(map_width * 0.50) \
				and c.y > int(map_height * 0.70) and c.y <= map_height - 3,
		func(c: Vector2i) -> bool:  # bottom-right
			return c.x >= int(map_width * 0.50) and c.x <= map_width - 3 \
				and c.y > int(map_height * 0.70) and c.y <= map_height - 3,
	]

	var spawned: Array[Node2D] = []
	for filter in zone_filters:
		var candidates := _passable_cells.filter(filter)
		if candidates.is_empty():
			continue
		candidates.shuffle()
		var node: Node2D = scene.instantiate()
		node.position = tile_map.map_to_local(candidates[0])
		add_child(node)
		spawned.append(node)

	_objective_nodes["fortified_structure"] = spawned

# ---------------------------------------------------------------------------
# Level 3 — NPC begins penned inside a small shelter of destructible walls,
# placed away from the squad spawn so the player must travel to the rescue
# point. A surrounding safe radius keeps enemies from spawning inside the
# shelter — only the wall is between the NPC and incoming fire.
# ---------------------------------------------------------------------------
func _spawn_escort_mission() -> void:
	# Pick an NPC spot in the bottom band of the map with clearance for walls.
	var npc_zone := _passable_cells.filter(func(c: Vector2i) -> bool:
		if c.x < 4 or c.x > map_width  - 5: return false
		if c.y < 4 or c.y > map_height - 5: return false
		return float(c.y) / map_height > 0.78
	)
	if npc_zone.is_empty():
		npc_zone = _passable_cells.filter(func(c: Vector2i) -> bool:
			return c.x >= 4 and c.x <= map_width - 5 \
				and c.y >= 4 and c.y <= map_height - 5 \
				and float(c.y) / map_height > 0.70
		)
	if npc_zone.is_empty():
		return
	npc_zone.shuffle()
	var npc_cell: Vector2i = npc_zone[0]

	var npc_scene: PackedScene = load("res://scenes/npc_escort.tscn")
	if npc_scene == null:
		push_warning("[MapGenerator] npc_escort.tscn not found.")
		return
	var npc: Node2D = npc_scene.instantiate()
	npc.position = tile_map.map_to_local(npc_cell)
	add_child(npc)
	_objective_nodes["escort_npc"] = npc

	# Mark the surrounding tiles as off-limits to enemy spawn so the NPC has a
	# pocket of safety while the squad fights its way over.
	_enemy_exclusion_centre = npc_cell
	_enemy_exclusion_radius = 6

	# Build a ring of destructible walls around the NPC (cardinal directions,
	# 2 tiles out). The squad only needs to take down one to free the NPC.
	var wall_scene: PackedScene = load("res://scenes/escort_wall.tscn")
	if wall_scene == null:
		push_warning("[MapGenerator] escort_wall.tscn not found.")
	else:
		var wall_offsets: Array[Vector2i] = [
			Vector2i( 0, -2),  # north — facing the squad
			Vector2i( 2,  0),
			Vector2i(-2,  0),
			Vector2i( 0,  2),
		]
		var walls: Array[Node2D] = []
		for off in wall_offsets:
			var cell: Vector2i = npc_cell + off
			if cell.x < 1 or cell.x > map_width - 2: continue
			if cell.y < 1 or cell.y > map_height - 2: continue
			var wall: Node2D = wall_scene.instantiate()
			wall.position = tile_map.map_to_local(cell)
			add_child(wall)
			walls.append(wall)
		_objective_nodes["escort_walls"] = walls

	# Extraction zone at the very top of the map
	var ext_zone := _passable_cells.filter(func(c: Vector2i) -> bool:
		return float(c.y) / map_height < 0.10
	)
	if ext_zone.is_empty():
		ext_zone = _passable_cells.filter(func(c: Vector2i) -> bool:
			return float(c.y) / map_height < 0.20
		)
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
