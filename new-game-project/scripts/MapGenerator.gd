# =============================================================================
# MapGenerator.gd
# Base class for all map providers (HandcraftedMap, TutorialLevel1, MazeLevel,
# MazeLevel2, BossArenaLevel). Holds the shared data (tile_map / nav_region /
# passable cells / objective tracking) and the shared spawn helpers (enemies,
# parent cages, fortified structures, escort mission). Subclasses override
# generate() to populate their terrain however they want.
#
# Procedural noise-driven generation lived here historically but was retired
# when the Caraka tilepack pipeline took over (see HandcraftedMap.gd). Gameplay
# queries (is_water_at, slope, range) default to neutral here so subclasses
# only need to override the ones their map type actually supports.
# =============================================================================
extends Node2D
class_name MapGenerator

const Balance = preload("res://scripts/BalanceConfig.gd")

@export var map_width:  int = Balance.MAP_AUTO_WIDTH
@export var map_height: int = Balance.MAP_AUTO_HEIGHT
@export var tile_size:  int = Balance.MAP_AUTO_TILE_SIZE

var tile_map:   TileMapLayer
var nav_region: NavigationRegion2D

var _passable_cells: Array[Vector2i] = []
var _objective_nodes: Dictionary = {}

# Backend elevation field — a continuous Perlin heightmap, decoupled from the
# 2D tile rendering. Stays null until a subclass opts in via _init_elevation();
# while null, all the elevation queries fall back to neutral so flat map types
# (mazes / tutorial / boss arena) keep their level surface. See _init_elevation.
var _elevation_noise: FastNoiseLite = null

# Subclass-controlled exclusion zone — cells within this radius of the centre
# are skipped during enemy spawn (used by the escort mission to keep the NPC's
# pocket clear of hostiles).
var _enemy_exclusion_centre: Vector2i = Vector2i.ZERO
var _enemy_exclusion_radius: int = 0

# Cave entrance cell (set by HandcraftedMap when it builds the parent-rescue
# cave). The escort prison is kept well clear of it so the VIP never spawns on
# top of — or inside — the cave mouth. (-1, -1) = no cave this mission.
var _cave_foot_cell: Vector2i = Vector2i(-1, -1)

# ---------------------------------------------------------------------------
func _ready() -> void:
	add_to_group("map_generator")
	tile_map = get_node_or_null("TileMapLayer_ground") as TileMapLayer
	if tile_map == null:
		tile_map = get_node_or_null("TileMapLayer") as TileMapLayer
	nav_region = get_node_or_null("NavigationRegion2D") as NavigationRegion2D

# Subclasses override this to populate terrain + spawn mission content.
func generate(_seed_value: int = 0) -> void:
	pass

# ---------------------------------------------------------------------------
# Camera / squad helpers
# ---------------------------------------------------------------------------
# map_to_local() errors if the layer has no TileSet yet. The camera's _ready can
# query bounds before the handcrafted map has assigned its tileset (Main re-calls
# refresh_map_bounds once it's ready); fall back to a tile_size-based estimate so
# those early calls return sane values instead of spamming engine errors.
func _has_tileset() -> bool:
	return tile_map != null and tile_map.tile_set != null

func get_map_centre() -> Vector2:
	@warning_ignore("integer_division")
	var centre_tile := Vector2i(map_width / 2, map_height / 2)
	if not _has_tileset():
		return Vector2(centre_tile) * float(tile_size)
	return tile_map.to_global(tile_map.map_to_local(centre_tile))

func get_map_rect() -> Rect2:
	if not _has_tileset():
		return Rect2(Vector2.ZERO, Vector2(map_width, map_height) * float(tile_size))
	# map_to_local returns the CENTRE of a tile; add half-tile to reach the
	# actual outer corners so the camera clamps to the visible edge.
	var half_tile := Vector2(tile_size, tile_size) * 0.5
	var tl := tile_map.to_global(tile_map.map_to_local(Vector2i(0, 0)) - half_tile)
	var br := tile_map.to_global(tile_map.map_to_local(Vector2i(map_width - 1, map_height - 1)) + half_tile)
	return Rect2(tl, br - tl)

func get_spawn_positions(count: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
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

# ---------------------------------------------------------------------------
# Gameplay queries — neutral defaults; subclasses override as needed.
# HandcraftedMap.is_water_at checks the water TileMapLayer; mazes / tutorial
# return false (no water in those scenes).
# ---------------------------------------------------------------------------
func is_water_at(_world_pos: Vector2) -> bool:
	return false

# ---------------------------------------------------------------------------
# Elevation backend — a Perlin heightmap that lives entirely in data, separate
# from the 2D tile frontend. Subclasses that want hilly terrain call
# _init_elevation() once during generate(); everyone else inherits the neutral
# behaviour because _elevation_noise stays null (guarded in get_elevation_at).
#
# Sampling happens in continuous tile-space (one noise unit ≈ one tile) so the
# field is independent of the tileset's pixel scale AND lines up 1:1 with the
# NoiseTexture2D visual overlay, which bakes the same noise at one pixel per
# tile. Returned elevation is the raw Perlin value in roughly [-1, 1].
# ---------------------------------------------------------------------------
func _init_elevation(seed_value: int) -> void:
	var n := FastNoiseLite.new()
	# Offset off the terrain/water seeds (seed, seed+1000) so elevation doesn't
	# visually correlate with where the grass/water bands fell.
	n.seed = (seed_value if seed_value != 0 else randi()) + 2000
	n.noise_type = FastNoiseLite.TYPE_PERLIN
	n.frequency = Balance.ELEV_NOISE_FREQUENCY
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = Balance.ELEV_NOISE_OCTAVES
	n.fractal_lacunarity = Balance.ELEV_NOISE_LACUNARITY
	n.fractal_gain = Balance.ELEV_NOISE_GAIN
	_elevation_noise = n

# Continuous tile-space coordinate for a world position. map_to_local works in
# the tileset's own (unscaled) pixel units, so dividing the inverse-transformed
# point by the tileset cell size yields a fractional tile index — exactly the
# coordinate space the overlay texture is baked in.
func _world_to_noise_coords(world_pos: Vector2) -> Vector2:
	if tile_map == null:
		return world_pos
	var cell := 16.0
	if tile_map.tile_set:
		cell = float(tile_map.tile_set.tile_size.x)
	return tile_map.to_local(world_pos) / cell

func get_elevation_at(world_pos: Vector2) -> float:
	if _elevation_noise == null:
		return 0.0
	var c := _world_to_noise_coords(world_pos)
	return clampf(_elevation_noise.get_noise_2d(c.x, c.y), -1.0, 1.0)

# Bullet range bonus/penalty: above HILL_THRESHOLD ramps up toward
# HILL_RANGE_MULT, below VALLEY_THRESHOLD ramps down toward VALLEY_RANGE_MULT,
# flat ground in between stays 1.0. Smooth so there's no hard step at a border.
func get_range_modifier_at(world_pos: Vector2) -> float:
	var e := get_elevation_at(world_pos)
	if e >= Balance.HILL_THRESHOLD:
		var t := inverse_lerp(Balance.HILL_THRESHOLD, 1.0, minf(e, 1.0))
		return lerpf(1.0, Balance.HILL_RANGE_MULT, t)
	if e <= Balance.VALLEY_THRESHOLD:
		var t := inverse_lerp(Balance.VALLEY_THRESHOLD, -1.0, maxf(e, -1.0))
		return lerpf(1.0, Balance.VALLEY_RANGE_MULT, t)
	return 1.0

# Slope speed: central finite-difference of the heightmap gives the gradient
# (elevation-per-tile) in x and y; its dot with the movement direction is the
# directional slope. Moving uphill (positive slope) slows you, downhill speeds
# you up, clamped to the configured band.
func get_slope_speed_mult(world_pos: Vector2, direction: Vector2) -> float:
	if _elevation_noise == null or direction.length_squared() < 0.0001:
		return 1.0
	var step_tiles := Balance.ELEV_SLOPE_SAMPLE_TILES
	var step_px := float(tile_size) * step_tiles
	var ex := get_elevation_at(world_pos + Vector2(step_px, 0.0)) \
			- get_elevation_at(world_pos - Vector2(step_px, 0.0))
	var ey := get_elevation_at(world_pos + Vector2(0.0, step_px)) \
			- get_elevation_at(world_pos - Vector2(0.0, step_px))
	var gradient := Vector2(ex, ey) / (2.0 * step_tiles)
	var dir_slope := gradient.dot(direction.normalized())
	return clampf(1.0 - dir_slope * Balance.SLOPE_SPEED_SCALE,
			Balance.SLOPE_SPEED_MIN, Balance.SLOPE_SPEED_MAX)

# Surface key under a world position — drives per-tile footstep playback.
# Return "dirt", "grass", or "snow". Empty string = silent (water / off-map).
# Base default is dirt; HandcraftedMap overrides to consult the seasonal
# objects layer. Maze / tutorial / boss levels stay dirt-only.
func get_surface_at(_world_pos: Vector2) -> String:
	return "dirt"

# ---------------------------------------------------------------------------
# Objective lookup — subclasses store nodes in _objective_nodes during
# generate(); external systems (HUD, objective manager) read them by group.
# ---------------------------------------------------------------------------
func get_objective_node(group: String) -> Variant:
	return _objective_nodes.get(group, null)

# Converts a tile grid coord to a world position suitable for nodes added as
# children of self. Must round-trip through to_global so the tile_map's scale
# (2× for the Caraka layers) is honoured — calling map_to_local directly
# returns coords in the layer's local space, which is HALF the world distance.
func _tile_to_world(cell: Vector2i) -> Vector2:
	return to_local(tile_map.to_global(tile_map.map_to_local(cell)))

# ---------------------------------------------------------------------------
# Shared spawn helpers — used by HandcraftedMap (procedural levels 2/4/5).
# Maze / tutorial / boss scripts override these locally.
# ---------------------------------------------------------------------------
func _bake_navigation() -> void:
	# Single bounding rectangle as the walkable region. Per-tile outlines
	# fail Godot's convex partition because adjacent tile squares share edges,
	# so soldiers and enemies just path across the whole open area; impassable
	# tiles (water, rock) are visual only.
	var nav_poly := NavigationPolygon.new()
	var half_tile := Vector2(tile_size, tile_size) * 0.5
	var inset     := Vector2(tile_size, tile_size) * 0.25
	var top_left  := tile_map.to_global(tile_map.map_to_local(Vector2i(0, 0)) - half_tile + inset)
	var bot_right := tile_map.to_global(tile_map.map_to_local(Vector2i(map_width - 1, map_height - 1)) + half_tile - inset)
	var tl := nav_region.to_local(top_left)
	var br := nav_region.to_local(bot_right)
	var outline := PackedVector2Array([
		tl,
		Vector2(br.x, tl.y),
		br,
		Vector2(tl.x, br.y)
	])
	nav_poly.vertices = outline
	nav_poly.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	nav_region.navigation_polygon = nav_poly

func _spawn_enemies() -> void:
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
		enemy.position = _tile_to_world(spawn_zone[i])
		add_child(enemy)

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

	var cage_scene: PackedScene = load("res://scenes/parent_cage.tscn")
	var frag_scene: PackedScene = load("res://scenes/memory_fragment.tscn")

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
		cage.position = _tile_to_world(cage_cell)
		if "child_slot" in cage:
			cage.set("child_slot", child_slot)
		add_child(cage)
		_objective_nodes["parent_cage"] = cage

	if frag_scene:
		var frag_ids := _pick_level_fragment_ids(3)
		var positions := _spread_positions(outer, cage_cell, frag_ids.size())
		var spawned: Array = []
		for i in frag_ids.size():
			var frag: Node2D = frag_scene.instantiate()
			frag.position = _tile_to_world(positions[i])
			if "fragment_id" in frag:
				frag.set("fragment_id", frag_ids[i])
			if "display_name" in frag:
				frag.set("display_name", FragmentEffects.get_display_name(frag_ids[i]))
			add_child(frag)
			spawned.append(frag)
		_objective_nodes["memory_fragments"] = spawned

# Pick up to `count` fragment IDs not yet permanently collected this run.
func _pick_level_fragment_ids(count: int) -> Array[String]:
	var available: Array[String] = []
	for id in FragmentEffects.FRAGMENT_METADATA.keys():
		if not RunState.fragments.has(id):
			available.append(id)
	available.shuffle()
	if available.size() > count:
		available.resize(count)
	return available

# Return `count` positions spread across the outer-ring cells, staying clear
# of `avoid`. Uses a greedy max-dispersion pass.
func _spread_positions(cells: Array, avoid: Vector2i, count: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if cells.is_empty():
		return result
	# Seed with the cell farthest from the cage.
	var first: Vector2i = cells[0]
	var best_d := 0
	for c: Vector2i in cells:
		var diff: Vector2i = c - avoid
		var d: int = diff.x * diff.x + diff.y * diff.y
		if d > best_d:
			best_d = d
			first = c
	result.append(first)
	# Each subsequent point maximises the minimum distance to already-placed ones.
	while result.size() < count:
		var pick: Vector2i = cells[0]
		var pick_min := 0
		for c: Vector2i in cells:
			var min_d := 2147483647
			for p: Vector2i in result:
				var diff: Vector2i = c - p
				var d: int = diff.x * diff.x + diff.y * diff.y
				if d < min_d:
					min_d = d
			if min_d > pick_min:
				pick_min = min_d
				pick = c
		result.append(pick)
	return result

# ---------------------------------------------------------------------------
# Level 4 — spawn 5 fortified structures spread across the map.
# ---------------------------------------------------------------------------
func _spawn_fortified_structure() -> void:
	var scene: PackedScene = load("res://scenes/fortified_structure.tscn")
	if scene == null:
		push_warning("[MapGenerator] fortified_structure.tscn not found.")
		return

	# Five non-overlapping zones covering different parts of the map.
	# Border-padded by 6 tiles to keep structures well clear of map edges.
	# Minimum 20-tile gap between any two placed structures avoids clumping.
	const PAD       := 6
	const MIN_TILES := 20
	var zone_filters: Array[Callable] = [
		func(c: Vector2i) -> bool:  # top strip
			return c.x >= PAD and c.x <= map_width - PAD - 1 \
				and c.y >= PAD and c.y < int(map_height * 0.28),
		func(c: Vector2i) -> bool:  # left flank
			return c.x >= PAD and c.x < int(map_width * 0.25) \
				and c.y >= int(map_height * 0.28) and c.y <= map_height - PAD - 1,
		func(c: Vector2i) -> bool:  # right flank
			return c.x > int(map_width * 0.75) and c.x <= map_width - PAD - 1 \
				and c.y >= int(map_height * 0.28) and c.y <= map_height - PAD - 1,
		func(c: Vector2i) -> bool:  # bottom-left
			return c.x >= PAD and c.x < int(map_width * 0.50) \
				and c.y > int(map_height * 0.70) and c.y <= map_height - PAD - 1,
		func(c: Vector2i) -> bool:  # bottom-right
			return c.x >= int(map_width * 0.50) and c.x <= map_width - PAD - 1 \
				and c.y > int(map_height * 0.70) and c.y <= map_height - PAD - 1,
	]

	var spawned: Array[Node2D] = []
	for filter in zone_filters:
		var candidates := _passable_cells.filter(filter)
		# Remove tiles too close to already-placed structures.
		if not spawned.is_empty():
			var min_dist: float = MIN_TILES * float(tile_size)
			candidates = candidates.filter(func(c: Vector2i) -> bool:
				var wp: Vector2 = _tile_to_world(c)
				for s: Node2D in spawned:
					if wp.distance_to(s.position) < min_dist:
						return false
				return true
			)
		if candidates.is_empty():
			continue
		candidates.shuffle()
		var node: Node2D = scene.instantiate()
		node.position = _tile_to_world(candidates[0])
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
	# Pick an NPC spot in the bottom band of the map, on passable ground and well
	# clear of the rescue cave so the VIP is never trapped inside it.
	var cave := _cave_foot_cell
	var has_cave := cave.x >= 0
	var npc_zone := _passable_cells.filter(func(c: Vector2i) -> bool:
		if c.x < 4 or c.x > map_width  - 5: return false
		if c.y < 4 or c.y > map_height - 5: return false
		if has_cave and absi(c.x - cave.x) + absi(c.y - cave.y) <= 14: return false
		return float(c.y) / map_height > 0.78
	)
	if npc_zone.is_empty():
		npc_zone = _passable_cells.filter(func(c: Vector2i) -> bool:
			if c.x < 4 or c.x > map_width - 5: return false
			if c.y < 4 or c.y > map_height - 5: return false
			if has_cave and absi(c.x - cave.x) + absi(c.y - cave.y) <= 14: return false
			return float(c.y) / map_height > 0.70
		)
	if npc_zone.is_empty():
		return
	npc_zone.shuffle()
	var npc_cell: Vector2i = npc_zone[0]

	# Drop the prison first, then the VIP at its centre with a higher z_index so
	# the captive reads as trapped INSIDE the cell rather than hidden behind it.
	var prison_scene: PackedScene = load("res://scenes/vip_prison.tscn")
	if prison_scene == null:
		push_warning("[MapGenerator] vip_prison.tscn not found.")
	else:
		var prison: Node2D = prison_scene.instantiate()
		prison.position = _tile_to_world(npc_cell)
		add_child(prison)
		_objective_nodes["escort_walls"] = [prison]

	var npc_scene: PackedScene = load("res://scenes/npc_escort.tscn")
	if npc_scene == null:
		push_warning("[MapGenerator] npc_escort.tscn not found.")
		return
	var npc: Node2D = npc_scene.instantiate()
	npc.position = _tile_to_world(npc_cell)
	npc.z_index = 2
	add_child(npc)
	_objective_nodes["escort_npc"] = npc

	# Mark the surrounding tiles as off-limits to enemy spawn so the NPC has a
	# pocket of safety while the squad fights its way over.
	_enemy_exclusion_centre = npc_cell
	_enemy_exclusion_radius = 6

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
	zone_node.position = _tile_to_world(ext_zone[0])
	add_child(zone_node)
	_objective_nodes["extraction_zone"] = zone_node
