# =============================================================================
# MapGenerator.gd
# Procedural top-down map: noise-driven tile biomes, scattered obstacles,
# boundary walls, a single-rectangle navigation polygon, and a per-mission
# objective hook. Spawns enemies for procedural levels (2 / 4 / 5) and the
# visual hill-shade overlay.
#
# Map dimensions come from BalanceConfig (MAP_AUTO_* / MAP_HANDCRAFTED_*).
# Noise frequency / density / thresholds stay as @export so individual
# scenes can still vary them. Gameplay range / slope / hill-shade constants
# all live in BalanceConfig under the TERRAIN_* / HILLSHADE_* prefixes.
# =============================================================================
extends Node2D
class_name MapGenerator

const ObstacleClass = preload("res://scripts/Obstacle.gd")
const Balance = preload("res://scripts/BalanceConfig.gd")

@export var map_width:  int = Balance.MAP_AUTO_WIDTH
@export var map_height: int = Balance.MAP_AUTO_HEIGHT
@export var tile_size:  int = Balance.MAP_AUTO_TILE_SIZE

@export var water_threshold: float = 0.40
@export var dirt_threshold:  float = 0.55
@export var noise_frequency: float = 0.05
@export var elevation_frequency: float = 0.025  # lower freq = bigger hill/valley features
@export var enemy_density:   int   = 30
@export var tile_config:     TileConfig

var tile_map:   TileMapLayer
var nav_region: NavigationRegion2D

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
	tile_map = get_node_or_null("TileMapLayer_ground") as TileMapLayer
	if tile_map == null:
		tile_map = get_node_or_null("TileMapLayer") as TileMapLayer
	nav_region = get_node_or_null("NavigationRegion2D") as NavigationRegion2D
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
	# Level numbers reflect the new mission order:
	#   1 Tutorial · 2 Eliminate · 3 Maze 1 · 4 Structures · 5 Escort · 6 Maze 2 · 7 Boss
	# Only 2 / 4 / 5 reach MapGenerator — the rest swap to hand-authored scenes.
	match GameManager.current_level:
		4: _spawn_fortified_structure()
		5: _spawn_escort_mission()
	# Procedural missions (2, 4, 5) also place that mission's parent cage
	# and themed memory fragment in the outer ring. Tutorial / mazes / boss
	# handle their own placement; this only runs for levels MapGenerator owns.
	var lv: int = GameManager.current_level
	if lv == 2 or lv == 4 or lv == 5:
		_spawn_mission_parent_and_fragment()
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
#   Hill   → Balance.HILL_RANGE_MULT   (bullets travel further)
#   Valley → Balance.VALLEY_RANGE_MULT (bullets travel less)
#   Flat   → 1.0
func get_range_modifier_at(world_pos: Vector2) -> float:
	var e := get_elevation_at(world_pos)
	if e > Balance.HILL_THRESHOLD:
		return Balance.HILL_RANGE_MULT
	if e < Balance.VALLEY_THRESHOLD:
		return Balance.VALLEY_RANGE_MULT
	return 1.0

# Movement-speed multiplier from terrain slope. Uphill steps slow, downhill
# steps speed up. Scale + clamp live in Balance (SLOPE_SPEED_*) so designers
# can widen or tighten the swing without code changes.
func get_slope_speed_mult(world_pos: Vector2, direction: Vector2) -> float:
	if direction.length_squared() < 0.01:
		return 1.0
	var dir := direction.normalized()
	# Sample roughly one tile ahead — far enough to register a real slope but
	# close enough to track the actual path the mover is on.
	var here  := get_elevation_at(world_pos)
	var ahead := get_elevation_at(world_pos + dir * float(tile_size))
	var slope := ahead - here   # >0 = uphill, <0 = downhill
	return clampf(1.0 - slope * Balance.SLOPE_SPEED_SCALE,
			Balance.SLOPE_SPEED_MIN, Balance.SLOPE_SPEED_MAX)

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
			else:
				# High-noise cells use grass so the maze_rock sprite (atlas 20,8)
				# never appears in procedural levels — it's reserved for actual maze
				# scenes. These cells are passable; obstacle density handles them.
				atlas_coord = tile_config.grass
				_passable_cells.append(Vector2i(x, y))

			tile_map.set_cell(Vector2i(x, y), tile_config.tileset_source_id, atlas_coord)

# ---------------------------------------------------------------------------
# Visual hill/valley overlay — three layers per tile, batched via a child
# Node2D's _draw(). Purely cosmetic. All colours / thresholds / alphas live
# in BalanceConfig (HILLSHADE_*) and are pushed onto the overlay below so
# the inline script doesn't have to import Balance itself.
# ---------------------------------------------------------------------------
func _spawn_topography() -> void:
	var overlay := Node2D.new()
	overlay.name = "TopographyOverlay"
	# Sit ON TOP of the tilemap (tilemap z_index = 0). Soldiers/enemies live
	# under SquadController and render after MapGenerator's subtree, so they
	# stay on top of this overlay regardless.
	overlay.z_index = 0
	overlay.show_behind_parent = false
	overlay.set_script(_make_topography_script())
	overlay.set("tile_size",  tile_size)
	overlay.set("map_width",  map_width)
	overlay.set("map_height", map_height)
	# Push all visual tunables in from Balance. The inline script keeps its
	# matching `var` fields and reads them directly in _draw().
	overlay.set("hill_threshold",      Balance.HILL_THRESHOLD)
	overlay.set("valley_threshold",    Balance.VALLEY_THRESHOLD)
	overlay.set("light_x",             Balance.HILLSHADE_LIGHT_X)
	overlay.set("light_y",             Balance.HILLSHADE_LIGHT_Y)
	overlay.set("shade_intensity",     Balance.HILLSHADE_INTENSITY)
	overlay.set("highlight_alpha",     Balance.HILLSHADE_HIGHLIGHT_ALPHA)
	overlay.set("shadow_alpha",        Balance.HILLSHADE_SHADOW_ALPHA)
	overlay.set("highlight_color",     Balance.HILLSHADE_HIGHLIGHT_COLOR)
	overlay.set("shadow_color",        Balance.HILLSHADE_SHADOW_COLOR)
	overlay.set("hill_tint",           Balance.HILLSHADE_HILL_TINT)
	overlay.set("valley_tint",         Balance.HILLSHADE_VALLEY_TINT)
	overlay.set("zone_max_alpha",      Balance.HILLSHADE_ZONE_MAX_ALPHA)
	overlay.set("zone_falloff",        Balance.HILLSHADE_ZONE_FALLOFF)
	overlay.set("drop_shadow_color",   Balance.HILLSHADE_DROP_SHADOW_COLOR)
	overlay.set("drop_shadow_width",   Balance.HILLSHADE_DROP_SHADOW_WIDTH)
	overlay.set("drop_shadow_alpha",   Balance.HILLSHADE_DROP_SHADOW_ALPHA)
	# Snapshot the elevation field as a flat float array so _draw() doesn't
	# touch the FastNoiseLite each frame.
	var samples := PackedFloat32Array()
	samples.resize(map_width * map_height)
	# Water mask — overlay must not paint hillshade on water tiles (the blue
	# already reads as water; lighting it stripes badly).
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

# Inline script for the overlay node — three layers stacked:
#   1) Smooth hillshade (per-corner colours so the gradient flows continuously).
#   2) Zone tint that fades in past the hill / valley thresholds.
#   3) Cliff drop-shadows along band transitions in the NW-lit direction.
# All tunables (colours, alphas, thresholds, light direction, shadow width)
# arrive as `var` fields populated by MapGenerator._spawn_topography() from
# BalanceConfig.
func _make_topography_script() -> GDScript:
	var src := """
extends Node2D

var tile_size:  int   = 64
var map_width:  int   = 0
var map_height: int   = 0
var elevation:  PackedFloat32Array
var water_mask: PackedByteArray

# Pushed in from BalanceConfig — see MapGenerator._spawn_topography().
var hill_threshold:    float = 0.18
var valley_threshold:  float = -0.18
var light_x:           float = -0.6
var light_y:           float = -0.6
var shade_intensity:   float = 6.0
var highlight_alpha:   float = 0.55
var shadow_alpha:      float = 0.65
var highlight_color:   Color = Color(1.00, 0.96, 0.78)
var shadow_color:      Color = Color(0.02, 0.06, 0.14)
var hill_tint:         Color = Color(1.00, 0.78, 0.40)
var valley_tint:       Color = Color(0.20, 0.40, 0.85)
var zone_max_alpha:    float = 0.35
var zone_falloff:      float = 0.30
var drop_shadow_color: Color = Color(0.02, 0.04, 0.10)
var drop_shadow_width: float = 16.0
var drop_shadow_alpha: float = 0.55

func _is_water(x: int, y: int) -> bool:
	if x < 0 or x >= map_width or y < 0 or y >= map_height:
		return true
	if water_mask.size() == 0:
		return false
	return water_mask[x * map_height + y] != 0

# Elevation band: -1 (valley), 0 (flat), 1 (hill). Out-of-bounds = flat so
# edge tiles don't draw phantom drop-shadows.
func _classify_at(x: int, y: int) -> int:
	if x < 0 or x >= map_width or y < 0 or y >= map_height:
		return 0
	var e: float = elevation[x * map_height + y]
	if e > hill_threshold: return 1
	if e < valley_threshold: return -1
	return 0

# Corner elevation = average of the (up to 4) tile centres meeting at this corner.
func _corner_elev(cx: int, cy: int) -> float:
	var sum: float = 0.0
	var n:   int   = 0
	for dx in [-1, 0]:
		for dy in [-1, 0]:
			var tx: int = cx + dx
			var ty: int = cy + dy
			if tx >= 0 and tx < map_width and ty >= 0 and ty < map_height:
				sum += elevation[tx * map_height + ty]
				n += 1
	if n == 0:
		return 0.0
	return sum / float(n)

# Hillshade + single-tier zone tint composited at the corner.
func _corner_color(cx: int, cy: int) -> Color:
	var e:  float = _corner_elev(cx, cy)
	var dx: float = _corner_elev(cx + 1, cy) - _corner_elev(cx - 1, cy)
	var dy: float = _corner_elev(cx, cy + 1) - _corner_elev(cx, cy - 1)
	var s:  float = -(dx * light_x + dy * light_y) * shade_intensity
	s = clampf(s, -1.0, 1.0)

	var shade_col: Color
	if s >= 0.0:
		shade_col = Color(highlight_color.r, highlight_color.g, highlight_color.b, s * highlight_alpha)
	else:
		shade_col = Color(shadow_color.r, shadow_color.g, shadow_color.b, -s * shadow_alpha)

	var zone_a: float = 0.0
	var zone_col: Color = hill_tint
	if e > hill_threshold:
		zone_a = clampf((e - hill_threshold) / zone_falloff, 0.0, 1.0) * zone_max_alpha
		zone_col = hill_tint
	elif e < valley_threshold:
		zone_a = clampf((valley_threshold - e) / zone_falloff, 0.0, 1.0) * zone_max_alpha
		zone_col = valley_tint

	# Composite zone OVER hillshade.
	var sa: float = shade_col.a
	var out_a: float = sa + zone_a * (1.0 - sa)
	if out_a <= 0.002:
		return Color(0, 0, 0, 0)
	var inv: float = 1.0 / out_a
	var r: float = (shade_col.r * sa + zone_col.r * zone_a * (1.0 - sa)) * inv
	var g: float = (shade_col.g * sa + zone_col.g * zone_a * (1.0 - sa)) * inv
	var b: float = (shade_col.b * sa + zone_col.b * zone_a * (1.0 - sa)) * inv
	return Color(r, g, b, out_a)

func _draw() -> void:
	if map_width == 0 or map_height == 0:
		return
	var ts:   float = float(tile_size)
	var half: float = ts * 0.5

	# Pass 1 — smooth hillshade + zone tint. Corner colours precomputed so
	# adjacent tiles share both position and colour at shared corners.
	var cw: int = map_width + 1
	var ch: int = map_height + 1
	var corner_cols: Array[Color] = []
	corner_cols.resize(cw * ch)
	for cx in cw:
		for cy in ch:
			corner_cols[cx * ch + cy] = _corner_color(cx, cy)

	for x in map_width:
		for y in map_height:
			if _is_water(x, y):
				continue
			var c00: Color = corner_cols[x       * ch + y]
			var c10: Color = corner_cols[(x + 1) * ch + y]
			var c11: Color = corner_cols[(x + 1) * ch + (y + 1)]
			var c01: Color = corner_cols[x       * ch + (y + 1)]
			if c00.a < 0.02 and c10.a < 0.02 and c11.a < 0.02 and c01.a < 0.02:
				continue
			if _is_water(x - 1, y) or _is_water(x + 1, y) \
					or _is_water(x, y - 1) or _is_water(x, y + 1):
				c00.a *= 0.45; c10.a *= 0.45; c11.a *= 0.45; c01.a *= 0.45
			var tx: float = x * ts - half
			var ty: float = y * ts - half
			var verts := PackedVector2Array([
				Vector2(tx, ty),
				Vector2(tx + ts, ty),
				Vector2(tx + ts, ty + ts),
				Vector2(tx, ty + ts),
			])
			var cols := PackedColorArray([c00, c10, c11, c01])
			draw_polygon(verts, cols)

	# Pass 2 — cliff drop-shadows along band transitions.
	var shadow_near := drop_shadow_color
	shadow_near.a = drop_shadow_alpha
	var shadow_far := drop_shadow_color
	shadow_far.a = 0.0
	for x in map_width:
		for y in map_height:
			if _is_water(x, y):
				continue
			var z_here: int = _classify_at(x, y)
			var tx: float = x * ts - half
			var ty: float = y * ts - half
			if _classify_at(x, y - 1) > z_here and not _is_water(x, y - 1):
				var w: float = drop_shadow_width
				var verts_n := PackedVector2Array([
					Vector2(tx,      ty),
					Vector2(tx + ts, ty),
					Vector2(tx + ts, ty + w),
					Vector2(tx,      ty + w),
				])
				var cols_n := PackedColorArray([
					shadow_near, shadow_near, shadow_far, shadow_far
				])
				draw_polygon(verts_n, cols_n)
			if _classify_at(x - 1, y) > z_here and not _is_water(x - 1, y):
				var w: float = drop_shadow_width
				var verts_w := PackedVector2Array([
					Vector2(tx,     ty),
					Vector2(tx + w, ty),
					Vector2(tx + w, ty + ts),
					Vector2(tx,     ty + ts),
				])
				var cols_w := PackedColorArray([
					shadow_near, shadow_far, shadow_far, shadow_near
				])
				draw_polygon(verts_w, cols_w)
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
	# Single bounding rectangle as the walkable region. Per-tile outlines
	# fail Godot's convex partition because adjacent tile squares share edges,
	# so soldiers and enemies just path across the whole open area; impassable
	# tiles (water, rock) are visual only.
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

	# Direct vertex / polygon assignment — the shape is a convex quad so no
	# triangulation is needed.
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
# Drops the current mission's parent cage and themed memory fragment into the
# outer ring of the map, well clear of the squad's central spawn band and
# far enough apart that they don't share a single fight. Mission N frees
# Kid N's parent (slot N-1) and grants the fragment from
# FragmentEffects.MISSION_FRAGMENTS[N].
# ---------------------------------------------------------------------------
func _spawn_mission_parent_and_fragment() -> void:
	var level: int = GameManager.current_level
	var child_slot: int = level - 1
	var fragment_id: String = FragmentEffects.get_mission_fragment_id(level)
	if fragment_id == "":
		return
	var fragment_name: String = FragmentEffects.get_display_name(fragment_id)

	var cage_scene: PackedScene = load("res://scenes/parent_cage.tscn")
	var frag_scene: PackedScene = load("res://scenes/memory_fragment.tscn")
	if cage_scene == null and frag_scene == null:
		return

	var outer := _passable_cells.filter(func(c: Vector2i) -> bool:
		if c.x < 3 or c.x > map_width - 4: return false
		if c.y < 3 or c.y > map_height - 4: return false
		var cx := float(c.x) / float(map_width)
		var cy := float(c.y) / float(map_height)
		return cx < 0.20 or cx > 0.80 or cy < 0.20 or cy > 0.80
	)
	if outer.is_empty():
		return
	outer.shuffle()
	var cage_cell: Vector2i = outer[0]

	if cage_scene:
		var cage: Node2D = cage_scene.instantiate()
		cage.position = tile_map.map_to_local(cage_cell)
		if "child_slot" in cage:
			cage.set("child_slot", child_slot)
		add_child(cage)
		_objective_nodes["parent_cage"] = cage

	if frag_scene:
		# Drop the fragment on the cell farthest from the cage so the player
		# has to commit to a detour rather than grab both in one fight.
		var best_cell: Vector2i = outer[0]
		var best_d: int = 0
		for c in outer:
			var diff: Vector2i = c - cage_cell
			var d: int = diff.x * diff.x + diff.y * diff.y
			if d > best_d:
				best_d = d
				best_cell = c
		var frag: Node2D = frag_scene.instantiate()
		frag.position = tile_map.map_to_local(best_cell)
		if "fragment_id" in frag:
			frag.set("fragment_id", fragment_id)
		if "display_name" in frag:
			frag.set("display_name", fragment_name)
		add_child(frag)
		_objective_nodes["memory_fragment"] = frag

# ---------------------------------------------------------------------------
# Level 4 — spawn 5 fortified structures spread across the map.
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
# Level 5 — NPC begins penned inside a small shelter of destructible walls,
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

	# Extraction zone at the top of the map. Keep a 2-tile margin from every
	# edge so the (now larger) zone disc never lands flush against the wall
	# where the NPC physically can't reach the centre.
	var ext_zone := _passable_cells.filter(func(c: Vector2i) -> bool:
		if c.x < 2 or c.x > map_width - 3: return false
		if c.y < 2 or c.y > map_height - 3: return false
		return float(c.y) / map_height < 0.15
	)
	if ext_zone.is_empty():
		ext_zone = _passable_cells.filter(func(c: Vector2i) -> bool:
			if c.x < 2 or c.x > map_width - 3: return false
			if c.y < 2 or c.y > map_height - 3: return false
			return float(c.y) / map_height < 0.25
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
