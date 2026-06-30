# =============================================================================
# HandcraftedMap.gd
# Drop-in replacement for MapGenerator used by hand-authored mission scenes
# (see scenes/handcrafted/mission_*.tscn).
#
# Workflow:
#   1. Open scenes/handcrafted/mission_X.tscn in Godot.
#   2. Pick a Season in the inspector, then click "Generate Caraka Map".
#   3. Hand-paint additional tiles / props on top of the generated base.
#   4. Save (Ctrl+S) — the .tscn captures everything.
#
# Generates terrain using the Caraka tilepack on three TileMapLayers:
#   - TileMapLayer_ground   : dirt base, auto-tiled edges at water boundaries
#   - TileMapLayer_objects  : seasonal grass + paths, auto-tiled transitions
#   - TileMapLayer_Overlay  : static animated water tiles
#
# Missing layers are auto-created on generate. Elevation is a separate backend
# concern: generate() seeds a Perlin heightmap via MapGenerator._init_elevation
# (decoupled from the tile rendering) so bullet range and slope speed respond to
# terrain height, and an optional NoiseTexture2D overlay shades it on screen.
# is_water_at() is overridden to check the water layer for movement slowdown.
# =============================================================================
@tool
extends MapGenerator
class_name HandcraftedMap

enum Season { SPRING, SUMMER, FALL, WINTER }

@export var season: Season = Season.SUMMER
@warning_ignore("unused_private_class_variable")
@export_tool_button("Generate Caraka Map", "Reload") var _caraka_btn: Callable = _editor_generate_caraka
@warning_ignore("unused_private_class_variable")
@export_tool_button("Set Up Blank Layers", "Add") var _setup_btn: Callable = _editor_setup_layers

# When true, generate() clears the saved tiles and regenerates fresh Caraka
# terrain at runtime. Set by Main.gd based on the title-screen "Map: Auto"
# toggle. Default false = use whatever tiles are already painted in the scene
# (the "Custom" / hand-edited workflow).
var regenerate_at_runtime: bool = false

# When true, water tiles are IMPASSABLE — added to the navmesh obstructions and
# given collision, so the squad can't wade across (lakes act as walls). Default
# false keeps the wade-through-with-slowdown behaviour the combat missions rely
# on. TutorialMap sets this true. Populated by _scan_passable_from_tiles.
var block_water: bool = false
var _water_block_cells: Dictionary = {}

# Optional blocking-decoration layer ("TileMapLayer_block"). Present only if the
# scene includes it (never auto-created, so other maps are untouched). ANY tile
# painted here is IMPASSABLE — nav obstruction + collision — independent of
# block_water. Lets you paint waterfalls / deep water / solid decor that the
# squad routes around, while unpainted gaps stay walkable (WYSIWYG).
var _block_layer: TileMapLayer
var _block_cells: Dictionary = {}

const TERRAIN_TILESET := "res://resources/caraka_terrain_tileset.tres"

# Decorative props (trees / rocks / bushes / flowers). Was toggled off while the
# elevation system was being iterated on; back on now.
const PLACE_PROPS := true

# Terrain set index per season (defined in caraka_terrain_tileset.tres)
# Water terrain set index in the Caraka tileset (terrain_set_6 = Water).
# The sub-terrain indices within that set: spring-shallow=0, spring-deep=1,
# summer-shallow=2, summer-deep=3, fall-shallow=4, fall-deep=5. We always
# use the SHALLOW variant for the playfield (deep is for waterfall ponds
# the Caraka pack ships, which the procedural maps don't use).
# Minimum side length (in tiles) for any contiguous patch of a given terrain
# type. The Caraka auto-tiler needs at least a 4×4 footprint to produce its
# full set of edges + corners — anything thinner renders as a broken strip
# with mismatched shoreline tiles. _enforce_min_block_size scrubs slivers.
const MIN_BLOCK_SIZE := 4

const WATER_TERRAIN_SET := 6
const SEASON_WATER_TERRAIN := {
	Season.SPRING: 0,
	Season.SUMMER: 2,
	Season.FALL:   4,
	Season.WINTER: 2,   # winter borrows summer water (no winter texture exists)
}

const SEASON_TERRAIN_SET := {
	Season.SPRING: 2,
	Season.SUMMER: 3,
	Season.FALL:   4,
	Season.WINTER: 5,
}

const TREE_TEXTURE := "res://resources/caraka/Props/Tree.png"
const ROCK_TEXTURE := "res://resources/caraka/Props/Rock/rock.png"
const BUSH_TEXTURE := "res://resources/caraka/Props/Bush.png"
const FLOWER_TEXTURE := "res://resources/caraka/Props/Flower.png"

# Tree.png is a 32×64 grid. We use only the row 0 conifers — the row 2
# deciduous trees render with a different proportion that doesn't match,
# and conifers + rocks already provide enough visual variety.
# Cols 0=spring, 1-2=summer, 3-5=fall, 6=winter. Cols 8+ are variant shapes.
# Region height is 48, NOT 64: each cell's conifer only occupies y 4-43; the
# bottom 12 px hold a small sapling/crystal that otherwise renders as a stray
# "partial tree" at the base of every conifer. Cropping to 48 drops it.
const TREE_REGIONS := {
	Season.SPRING: [Rect2(0, 0, 32, 48), Rect2(256, 0, 32, 48)],
	Season.SUMMER: [Rect2(32, 0, 32, 48), Rect2(64, 0, 32, 48)],
	Season.FALL:   [Rect2(96, 0, 32, 48), Rect2(128, 0, 32, 48)],
	Season.WINTER: [Rect2(192, 0, 32, 48), Rect2(448, 0, 32, 48)],
}

# Bush.png: 8 cols × 4 rows (16×16). Seasons in rows: 0=spring, 1=summer, 2=fall, 3=winter.
const BUSH_REGIONS := {
	Season.SPRING: [Rect2(0, 0, 16, 16), Rect2(16, 0, 16, 16), Rect2(32, 0, 16, 16)],
	Season.SUMMER: [Rect2(0, 16, 16, 16), Rect2(16, 16, 16, 16), Rect2(32, 16, 16, 16)],
	Season.FALL:   [Rect2(0, 32, 16, 16), Rect2(16, 32, 16, 16), Rect2(32, 32, 16, 16)],
	Season.WINTER: [Rect2(0, 48, 16, 16), Rect2(16, 48, 16, 16), Rect2(32, 48, 16, 16)],
}

var _terrain_grid: Dictionary = {}
var _objects_layer: TileMapLayer
var _water_layer: TileMapLayer
# Cells holding a prop with collision (trees / rocks). Baked into the navmesh as
# obstructions so units path AROUND forests instead of wedging on trunks, and
# excluded from the passable set so spawns/objectives never land on a prop.
var _prop_cells: Dictionary = {}

# Hidden cave (parent rescue) — entrance set into a plateau wall, parent hidden
# in an off-playfield fairy garden. Built by the parent/fragment spawner.
const CAVE_SYSTEM_SCRIPT := preload("res://scripts/CaveSystem.gd")
var _cave_system: Node2D
# Dedicated wide-body navmesh for the minotaur. Lives on its OWN NavigationServer
# map (a separate region on the default map would just union back the narrow gaps)
# and is eroded by ~the brute's body radius so its routes only run through openings
# it can actually fit. Built lazily on the first obstacle-bearing bake; the
# minotaur picks the map up via get_large_agent_nav_map().
var _large_nav_region: NavigationRegion2D = null
var _large_nav_map:    RID

# --- Discrete elevation tiers (Zelda-style cliffs) -------------------------
# _tier_grid: per-cell integer height tier (0 = low ground).
# _cliff_cells: cells occupied by a cliff face/shadow — non-walkable.
# _stair_cells: cells carved into a cliff as walkable steps (the only way up).
var _tier_grid:   Dictionary = {}
var _cliff_cells: Dictionary = {}
var _stair_cells: Dictionary = {}
var _cliff_layer: TileMapLayer
# Raised-tier grass top, on its own layer so it can be modulated a distinct
# (darker) shade from the low ground without tinting the cliff walls.
var _plateau_layer: TileMapLayer
# Per raised cell → {"wall": src, "stair": base_col} so each plateau gets a
# consistent (but varied between plateaus) light/dark wall + stair style.
var _tier1_style: Dictionary = {}

# Atlas source ids in caraka_terrain_tileset.tres (resolved from sources/N).
const WALL_SOURCE:      int = 4    # dirt wall.png        — light cliff face
const WALL_DARK_SOURCE: int = 5    # dirt wall - dark.png — dark cliff face
const STEPS_SOURCE:     int = 44   # Steps.png            — staircases
# Verified against the user's hand-painted reference (mission_2 TileMapLayer_reference):
# dirt wall sheets (8×6) carry the cliff block on ROWS 3-5 (cap/face/base). Columns:
#   col 0 = left end, col 5 = right end, cols 1-4 = interchangeable middle variants.
const WALL_ROW_CAP:   int = 3
const WALL_ROW_FACE:  int = 4
const WALL_ROW_BASE:  int = 5
const WALL_COL_LEFT:  int = 0
const WALL_COL_RIGHT: int = 5
const WALL_MID_COLS := [1, 2, 3, 4]   # cycled across the face for variety
# Steps sheet (6×4): two 3-wide staircases — cols 0-2 (light brown) and cols 3-5
# (dark brown), each rows 0/1/2 = cap/face/base. We pick one variant per plateau.
const STAIR_BASE_COLS := [0, 3]
const STEP_CAP:   int = 0
const STEP_FACE:  int = 1
const STEP_BASE:  int = 2

# Dimensions are applied here (NOT in generate()) because Main.gd calls
# camera.refresh_map_bounds() between scene instantiation and generate(); if
# the dimensions weren't already set, the camera would clamp to the inherited
# MapGenerator @export defaults and trap the viewport in the wrong corner.
# Map dimensions as (width_tiles, height_tiles, tile_size). Overridable so
# subclasses (e.g. TutorialMap) can size the map differently while reusing the
# whole Caraka layer/nav/collision pipeline. Default = the shared handcrafted size.
func _map_dims() -> Vector3i:
	if OS.get_name() == "Android":
		return Vector3i(80, 70, Balance.MAP_HANDCRAFTED_TILE_SIZE)
	return Vector3i(Balance.MAP_HANDCRAFTED_WIDTH, Balance.MAP_HANDCRAFTED_HEIGHT,
			Balance.MAP_HANDCRAFTED_TILE_SIZE)

func _apply_map_dims() -> void:
	var d := _map_dims()
	map_width  = d.x
	map_height = d.y
	tile_size  = d.z

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_apply_map_dims()
	super._ready()
	_resolve_layers()
	# Always run setup — it assigns the tileset (idempotent if already set) and
	# applies the 2× layer scale that maps 16 px art to MAP_HANDCRAFTED_TILE_SIZE
	# (32 px) visual cells. Must happen BEFORE the camera's refresh_map_bounds
	# call so get_map_rect returns the correct scaled-up dimensions.
	if tile_map:
		_setup_tileset()

func _resolve_layers() -> void:
	if _objects_layer == null:
		_objects_layer = get_node_or_null("TileMapLayer_objects") as TileMapLayer
		if _objects_layer == null:
			_objects_layer = _create_layer("TileMapLayer_objects")
	if _water_layer == null:
		_water_layer = get_node_or_null("TileMapLayer_Overlay") as TileMapLayer
		if _water_layer == null:
			_water_layer = _create_layer("TileMapLayer_Overlay")
	if _cliff_layer == null:
		_cliff_layer = get_node_or_null("TileMapLayer_cliff") as TileMapLayer
		if _cliff_layer == null:
			_cliff_layer = _create_layer("TileMapLayer_cliff")
	if _plateau_layer == null:
		_plateau_layer = get_node_or_null("TileMapLayer_plateau") as TileMapLayer
		if _plateau_layer == null:
			_plateau_layer = _create_layer("TileMapLayer_plateau")
	# Optional — adopted only if the scene authored it; never auto-created.
	if _block_layer == null:
		_block_layer = get_node_or_null("TileMapLayer_block") as TileMapLayer

func _create_layer(layer_name: String) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = layer_name
	add_child(layer)
	if Engine.is_editor_hint():
		var scene_root: Node = owner if owner else self
		layer.owner = scene_root
	return layer

func _setup_tileset() -> void:
	var ts: TileSet = load(TERRAIN_TILESET)
	tile_map.tile_set = ts
	tile_map.scale = Vector2(2.0, 2.0)
	if _objects_layer:
		_objects_layer.tile_set = ts
		_objects_layer.scale = Vector2(2.0, 2.0)
	if _water_layer:
		_water_layer.tile_set = ts
		_water_layer.scale = Vector2(2.0, 2.0)
	if _plateau_layer:
		_plateau_layer.tile_set = ts
		_plateau_layer.scale = Vector2(2.0, 2.0)
	if _cliff_layer:
		_cliff_layer.tile_set = ts
		_cliff_layer.scale = Vector2(2.0, 2.0)
	# Optional blocking-decor layer — assign tileset + scale, but DON'T force a
	# z_index so the scene controls where waterfalls/decor draw (e.g. over a cliff).
	if _block_layer:
		_block_layer.tile_set = ts
		_block_layer.scale = Vector2(2.0, 2.0)
	# Terrain z-band. Ground/grass/water sit at the bottom; the plateau-top grass
	# draws above them (covering the low grass on raised cells), then the cliff
	# layer (faces over the low ground they hang over), all below props / enemies
	# / mission nodes (z = 0).
	tile_map.z_index = -4
	if _objects_layer:
		_objects_layer.z_index = -3
	if _water_layer:
		_water_layer.z_index = -2
	if _plateau_layer:
		_plateau_layer.z_index = -2
		# Tint the raised top a richer/darker green so elevation reads at any zoom
		# (no overlay/shadow — just a distinct grass shade, per user request).
		_plateau_layer.self_modulate = Color(0.80, 0.88, 0.70)
	if _cliff_layer:
		_cliff_layer.z_index = -1

# ---------------------------------------------------------------------------
# Runtime entry point. Scans whatever tiles the scene already has (including
# any hand-painted additions), bakes navigation, then spawns mission content.
# ---------------------------------------------------------------------------
func generate(seed_value: int = 0) -> void:
	_objective_nodes.clear()
	_enemy_exclusion_radius = 0
	_resolve_layers()
	# Seed the backend heightmap first — both the gameplay queries (range/slope)
	# and the tier quantisation read from it.
	_init_elevation(seed_value)
	if regenerate_at_runtime:
		_setup_tileset()
		# The hand-painted reference layer (used to author the cliff look) is not
		# part of procedural output and has no collision — clear it so it doesn't
		# linger as a fake, walk-through wall over the regenerated terrain.
		var ref_layer := get_node_or_null("TileMapLayer_reference") as TileMapLayer
		if ref_layer:
			ref_layer.clear()
		_build_tier_grid()       # quantise heightmap → flat tiers (Phase A)
		await get_tree().process_frame
		_carve_stairs()          # punch reachable staircases through cliffs (Phase B)
		await get_tree().process_frame
		_generate_terrain(seed_value)
		await get_tree().process_frame
		_paint_cliffs()          # cliff faces + steps on the cliff layer (Phase C)
		if PLACE_PROPS:
			_place_props(seed_value)
			await get_tree().process_frame
	else:
		# Hand-painted ("Custom") map: derive the blocking from whatever the user
		# painted on TileMapLayer_cliff so cliffs/stairs/props still work without a
		# procedural pass. Everything below (passable scan, nav bake, collision +
		# map boundary) is shared with the Auto path.
		_setup_tileset()
		_derive_from_painted_tiles()
	await get_tree().process_frame
	_scan_passable_from_tiles()
	await _bake_navigation()
	_build_cliff_collision()
	# Custom mission scenes can pre-place their objective nodes (structures /
	# escort NPC / walls / extraction) directly in the .tscn — see mission_4
	# and mission_5. _adopt_scene_objectives registers any it finds; the
	# procedural spawners then no-op when their slot is already filled.
	_adopt_scene_objectives()
	# Spawn the parent-rescue cave FIRST so _spawn_escort_mission can read
	# _cave_foot_cell and keep the VIP's prison well clear of the cave mouth.
	var lv: int = GameManager.current_level
	# Parent + fragments for the proc-style parent levels (Eliminate 2, Elite Hunt 3,
	# Structures 5, Escort 6). Catacombs (4) and Blighted Marsh (7) place their own.
	if lv == 2 or lv == 3 or lv == 5 or lv == 6:
		_spawn_mission_parent_and_fragment()
	match lv:
		5:
			if not _objective_nodes.has("fortified_structure"):
				_spawn_fortified_structure()
		6:
			if not _objective_nodes.has("escort_npc"):
				_spawn_escort_mission()
	_spawn_enemies()

# Hand-painted ("Custom") maps: read blocking straight off the painted layers so
# the same nav/collision/boundary pipeline works without a procedural pass.
# WYSIWYG — a painted dirt-wall tile blocks, a painted Steps tile is a walkable
# gap, and the raised-grass layer marks the high tier (for the range bonus).
# Paint walls around a plateau (leaving Steps gaps) to enclose it.
func _derive_from_painted_tiles() -> void:
	_tier_grid.clear()
	_cliff_cells.clear()
	_stair_cells.clear()
	_prop_cells.clear()
	if _plateau_layer:
		for cell in _plateau_layer.get_used_cells():
			_tier_grid[cell] = 1
	if _cliff_layer == null:
		return
	for cell in _cliff_layer.get_used_cells():
		var sid := _cliff_layer.get_cell_source_id(cell)
		if sid == WALL_SOURCE or sid == WALL_DARK_SOURCE:
			_cliff_cells[cell] = true
		elif sid == STEPS_SOURCE:
			_stair_cells[cell] = true

# Picks up objective nodes that the .tscn placed by hand (instead of relying
# on the procedural spawners). Detection is by group membership filtered to
# direct children so other levels' own structures don't get harvested.
func _adopt_scene_objectives() -> void:
	var structs: Array[Node2D] = []
	for c in get_children():
		if c.is_in_group("structures"):
			structs.append(c)
	if not structs.is_empty():
		if regenerate_at_runtime:
			# Terrain was regenerated — the scene-placed structures sit at fixed
			# world positions designed for the saved terrain, which are likely
			# outside the new map bounds. Free them so _spawn_fortified_structure()
			# can place all five procedurally on valid tiles instead.
			for s in structs:
				s.queue_free()
		else:
			_objective_nodes["fortified_structure"] = structs

	# Escort objects (VIP, prison, extraction) are placed procedurally in
	# _spawn_escort_mission so they always land on valid ground clear of the
	# rescue cave. Mission 5 generates its terrain at runtime, so any escort nodes
	# saved in the .tscn would sit at fixed coords that don't match the new map
	# (this is exactly why the VIP used to end up inside the cave). Free any such
	# editor stubs and let the spawner place fresh ones.
	for c in get_children():
		if c.is_in_group("escort_npc") or c.is_in_group("escort_walls"):
			c.queue_free()
		elif c.scene_file_path != "" and c.scene_file_path.ends_with("extraction_zone.tscn"):
			c.queue_free()

# Rebuilds _passable_cells from the actual painted tiles in the scene. A cell
# is passable when the ground layer has a tile AND the water layer doesn't.
# Captures both auto-generated and hand-painted edits.
func _scan_passable_from_tiles() -> void:
	_passable_cells.clear()
	_water_block_cells.clear()
	_block_cells.clear()
	for x in map_width:
		for y in map_height:
			var cell := Vector2i(x, y)
			if _cliff_cells.has(cell):
				continue  # cliff face/shadow = impassable (stairs are walkable, not cliffs)
			if _prop_cells.has(cell):
				continue  # tree/rock collision = not passable (no spawns/objectives here)
			if _block_layer and _block_layer.get_cell_source_id(cell) != -1:
				# Painted blocking-decor (waterfall/deep water/etc.) — impassable,
				# regardless of whether the ground/water layers have a tile here.
				_block_cells[cell] = true
				continue
			var ground_id := tile_map.get_cell_source_id(cell)
			if ground_id == -1:
				continue  # no ground tile = not passable
			if _water_layer and _water_layer.get_cell_source_id(cell) != -1:
				# Water is never a spawn/objective cell. When block_water is on it
				# also becomes a hard obstacle (nav + collision) so lakes wall off.
				if block_water:
					_water_block_cells[cell] = true
				continue  # water tile present = not passable
			_passable_cells.append(cell)

# Topography is a per-tile _draw() loop — too slow at 110×100. The Caraka
# tileset has built-in shading so the procedural overlay isn't needed.
func _spawn_topography() -> void:
	pass

# Elevation range/slope queries are inherited from MapGenerator now — generate()
# seeds the heightmap so bullet range and movement speed respond to terrain.

# Override the parent's is_water_at — water lives on TileMapLayer_Overlay,
# not on the main ground layer. Any tile present on the water layer counts
# as water (triggers movement slowdown in Soldier/Enemy via _water_speed_mult).
func is_water_at(world_pos: Vector2) -> bool:
	if _water_layer == null:
		_water_layer = get_node_or_null("TileMapLayer_Overlay") as TileMapLayer
	if _water_layer == null:
		return false
	var local_pos := _water_layer.to_local(world_pos)
	var tile_pos  := _water_layer.local_to_map(local_pos)
	return _water_layer.get_cell_source_id(tile_pos) != -1

# Per-tile surface for footstep audio. Water → empty string (silent).
# Otherwise, the objects layer holds the seasonal terrain on top of the
# bare dirt ground — its presence flips dirt → grass (warm seasons) or
# dirt → snow (winter). Bare ground cells stay dirt.
func get_surface_at(world_pos: Vector2) -> String:
	if is_water_at(world_pos):
		return ""
	if _objects_layer == null:
		_objects_layer = get_node_or_null("TileMapLayer_objects") as TileMapLayer
	if _objects_layer != null:
		var local_pos := _objects_layer.to_local(world_pos)
		var tile_pos  := _objects_layer.local_to_map(local_pos)
		if _objects_layer.get_cell_source_id(tile_pos) != -1:
			return "snow" if season == Season.WINTER else "grass"
	return "dirt"

# ===========================================================================
# Terrain generation (used by both runtime generate() and the editor button)
# ===========================================================================
func _generate_terrain(seed_value: int) -> void:
	tile_map.clear()
	if _objects_layer:
		_objects_layer.clear()
	if _water_layer:
		_water_layer.clear()
	_terrain_grid.clear()

	var effective_seed: int = seed_value if seed_value != 0 else randi()

	var terrain_noise := FastNoiseLite.new()
	terrain_noise.seed = effective_seed
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	terrain_noise.frequency = 0.02
	terrain_noise.fractal_octaves = 4

	var water_noise := FastNoiseLite.new()
	water_noise.seed = effective_seed + 1000
	water_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	water_noise.frequency = 0.012
	water_noise.fractal_octaves = 2

	# Keep water clear of plateaus: a pond lapping a cliff base (or a staircase
	# running into it) reads as broken. Mask out everything within a margin of any
	# raised cell or carved stair.
	var near_raised: Dictionary = {}
	const WATER_CLEARANCE := 4
	for x in map_width:
		for y in map_height:
			if _tier_at(Vector2i(x, y)) < 1 and not _stair_cells.has(Vector2i(x, y)):
				continue
			for dx in range(-WATER_CLEARANCE, WATER_CLEARANCE + 1):
				for dy in range(-WATER_CLEARANCE, WATER_CLEARANCE + 1):
					near_raised[Vector2i(x + dx, y + dy)] = true

	for x in map_width:
		for y in map_height:
			var cell := Vector2i(x, y)
			var tv := (terrain_noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			var wv := (water_noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			var cx := float(x) / map_width
			var cy := float(y) / map_height
			var in_spawn := cx > 0.35 and cx < 0.65 and cy > 0.35 and cy < 0.65

			if wv < 0.25 and not in_spawn and _tier_grid.get(cell, 0) == 0 \
					and not near_raised.has(cell):
				_terrain_grid[cell] = "water"  # water only pools on the low tier
			elif tv < 0.15:
				_terrain_grid[cell] = "dirt"   # rare bare-dirt accents; cliffs read against grass
			else:
				_terrain_grid[cell] = "grass"

	_smooth_terrain(2)
	# Two passes of min-block enforcement so any sliver that gets re-typed in
	# pass 1 (and might itself form a new sliver of the replacement type) gets
	# caught in pass 2. Done BEFORE paths are drawn so the deliberately-thin
	# 3-wide path strips aren't culled.
	_enforce_min_block_size()
	_enforce_min_block_size()

	if season != Season.WINTER:
		_generate_paths(effective_seed)

	var land_cells: Array[Vector2i] = []
	var grass_cells: Array[Vector2i] = []
	var path_cells: Array[Vector2i] = []
	var water_cells: Array[Vector2i] = []

	for x in map_width:
		for y in map_height:
			var cell := Vector2i(x, y)
			match _terrain_grid.get(cell, "grass"):
				"grass":
					grass_cells.append(cell)
					land_cells.append(cell)
				"path":
					path_cells.append(cell)
					land_cells.append(cell)
				"dirt":
					land_cells.append(cell)
				"water":
					water_cells.append(cell)

	# Ground layer: dirt on land cells only (auto-tiled edges at water boundaries)
	tile_map.set_cells_terrain_connect(land_cells, 0, 0, false)

	# Objects layer: seasonal grass with auto-tiled edges (dirt shows through)
	var season_set: int = SEASON_TERRAIN_SET[season]
	if _objects_layer:
		_objects_layer.set_cells_terrain_connect(grass_cells, season_set, 0, false)
		if not path_cells.is_empty():
			_objects_layer.set_cells_terrain_connect(path_cells, season_set, 2, false)

	# Water layer: auto-tiled animated water with proper edges. The terrain
	# connector picks the right shoreline / corner / centre variant for each
	# cell based on its neighbours, and each tile carries an 8-frame animation
	# baked into the atlas so the surface ripples on its own.
	if _water_layer and not water_cells.is_empty():
		var water_terrain: int = SEASON_WATER_TERRAIN[season]
		_water_layer.set_cells_terrain_connect(
				water_cells, WATER_TERRAIN_SET, water_terrain, false)

# ===========================================================================
# DISCRETE ELEVATION TIERS — quantise the heightmap, carve stairs, draw cliffs.
# ===========================================================================
func _tier_at(cell: Vector2i) -> int:
	return int(_tier_grid.get(cell, 0))

# Number of thresholds the elevation exceeds → integer tier (0 = low ground).
func _tier_for(e: float) -> int:
	var t := 0
	for thr in Balance.ELEV_TIER_THRESHOLDS:
		if e > float(thr):
			t += 1
		else:
			break
	return t

# Phase A — sample the Perlin heightmap into flat tiers, flatten the spawn band
# + outer border to low ground, and dissolve plateaus too small to fight on.
func _build_tier_grid() -> void:
	_tier_grid.clear()
	_cliff_cells.clear()
	if _elevation_noise == null:
		return
	for x in map_width:
		for y in map_height:
			_tier_grid[Vector2i(x, y)] = 0
	_stamp_plateaus()           # broad blob plateaus on high ground (not noise contours)
	_force_flat_zones()
	_enforce_tier_min_block()   # opening: drop any border-clipped fragments
	_close_tier_holes(1)        # closing: re-fill the corner clips the opening shaved
	_force_flat_zones()         # closing may have grown into the border ring — reclear

# Plateaus are 1-2 large, deliberate, clean RECTANGLES (sharp 90° corners): the
# bottom row is one flat south-facing run → a single continuous wall with clean
# end caps, the vertical sides carry only the grass lip. Each rectangle is placed
# fully INSIDE the playfield and clear of the spawn band, so `_force_flat_zones`
# never clips it (clipping is what leaves thin tier-1 remnants → "floating" walls
# with no plateau). Candidates come from a jittered grid on non-valley ground.
func _stamp_plateaus() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _elevation_noise.seed
	const BORDER := 4
	const SPACING := 18
	# 3-6 smaller plateaus per map for visual variety.
	var max_plateaus: int = rng.randi_range(3, 6)
	# Spawn band kept fully clear (slightly larger than _force_flat_zones' 0.40-0.60
	# box so plateaus never get clipped, while leaving enough room around each).
	var sx0 := 0.38 * map_width
	var sx1 := 0.62 * map_width
	var sy0 := 0.38 * map_height
	var sy1 := 0.62 * map_height
	var candidates: Array[Vector2i] = []
	for gx in range(SPACING, map_width - SPACING + 1, SPACING):
		for gy in range(SPACING, map_height - SPACING + 1, SPACING):
			var c := Vector2i(gx + rng.randi_range(-5, 5), gy + rng.randi_range(-5, 5))
			if _elevation_noise.get_noise_2d(float(c.x), float(c.y)) < -0.35:
				continue  # skip only deep valleys
			candidates.append(c)
	# Shuffle deterministically, then greedily take rectangles that fit fully inside
	# the border, miss the spawn band, and don't crowd an already-placed one. Sizes
	# are chosen to fit the non-spawn margins so placement is reliable (≥1).
	for i in range(candidates.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := candidates[i]; candidates[i] = candidates[j]; candidates[j] = tmp
	var placed: Array[Rect2i] = []
	for c in candidates:
		if placed.size() >= max_plateaus:
			break
		var rect := _fit_plateau_rect(c, rng, placed, sx0, sx1, sy0, sy1, BORDER)
		if rect.size.x == 0:
			continue
		placed.append(rect)
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			for y in range(rect.position.y, rect.position.y + rect.size.y):
				_tier_grid[Vector2i(x, y)] = 1
	# Guarantee at least one plateau: if the size/spawn constraints rejected every
	# candidate, drop the spawn-clearance rule for a single fallback placement.
	if placed.is_empty() and not candidates.is_empty():
		for c in candidates:
			var rect := _fit_plateau_rect(c, rng, placed, sx0, sx1, sy0, sy1, BORDER, true)
			if rect.size.x == 0:
				continue
			for x in range(rect.position.x, rect.position.x + rect.size.x):
				for y in range(rect.position.y, rect.position.y + rect.size.y):
					_tier_grid[Vector2i(x, y)] = 1
			break

# Try to size a plateau rectangle around centre `c` that fits inside the border,
# misses the spawn band (unless `force`) and doesn't crowd an already-placed one.
# Returns a zero-size Rect2i if it can't fit.
func _fit_plateau_rect(c: Vector2i, rng: RandomNumberGenerator, placed: Array[Rect2i],
		sx0: float, sx1: float, sy0: float, sy1: float, border: int, force: bool = false) -> Rect2i:
	var rx := rng.randi_range(8, 12)
	var ry := rng.randi_range(6, 10)
	var x0 := c.x - rx
	var x1 := c.x + rx
	var y0 := c.y - ry
	var y1 := c.y + ry
	if x0 < border or x1 >= map_width - border or y0 < border or y1 >= map_height - border:
		return Rect2i(0, 0, 0, 0)
	if not force and x1 >= sx0 - 1 and x0 <= sx1 + 1 and y1 >= sy0 - 1 and y0 <= sy1 + 1:
		return Rect2i(0, 0, 0, 0)
	var rect := Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
	for p in placed:
		if rect.grow(4).intersects(p):
			return Rect2i(0, 0, 0, 0)
	return rect

# Keep the squad's central spawn and a border ring on low ground: the spawn band
# so the squad never starts trapped, the border so every cliff blob is interior
# (clean to outline for navigation later).
func _force_flat_zones() -> void:
	const BORDER := 3
	for x in map_width:
		for y in map_height:
			var cx := float(x) / map_width
			var cy := float(y) / map_height
			var edge := x < BORDER or x >= map_width - BORDER \
					or y < BORDER or y >= map_height - BORDER
			var spawn := cx > 0.40 and cx < 0.60 and cy > 0.40 and cy < 0.60
			if edge or spawn:
				_tier_grid[Vector2i(x, y)] = 0

# Morphological opening per tier level: any cell of tier ≥ level not covered by a
# solid MIN_BLOCK² square of tier ≥ level gets demoted, removing slivers while
# preserving full-size plateaus.
func _enforce_tier_min_block() -> void:
	var m: int = Balance.ELEV_TIER_MIN_BLOCK
	for level in range(Balance.ELEV_TIER_COUNT - 1, 0, -1):
		var kept: Dictionary = {}
		for x in range(0, map_width - m + 1):
			for y in range(0, map_height - m + 1):
				var solid := true
				for dx in m:
					for dy in m:
						if _tier_at(Vector2i(x + dx, y + dy)) < level:
							solid = false
							break
					if not solid:
						break
				if not solid:
					continue
				for dx in m:
					for dy in m:
						kept[Vector2i(x + dx, y + dy)] = true
		for cell in _tier_grid:
			if _tier_at(cell) >= level and not kept.has(cell):
				_tier_grid[cell] = level - 1

# Morphological closing per tier level (dilate by `radius`, then erode): fills
# interior pits and bridges concavities so each plateau becomes a solid blob.
# Closing is extensive, so this only ever RAISES cells — never carves a plateau.
func _close_tier_holes(radius: int) -> void:
	for level in range(Balance.ELEV_TIER_COUNT - 1, 0, -1):
		var dil: Dictionary = {}
		for x in map_width:
			for y in map_height:
				if _tier_at(Vector2i(x, y)) < level:
					continue
				for dx in range(-radius, radius + 1):
					for dy in range(-radius, radius + 1):
						dil[Vector2i(x + dx, y + dy)] = true
		# Erode the dilated set: a cell survives only if its full radius window is
		# inside the dilation. Original cells are interior, so they always survive.
		for c in dil:
			var solid := true
			for dx in range(-radius, radius + 1):
				for dy in range(-radius, radius + 1):
					if not dil.has(c + Vector2i(dx, dy)):
						solid = false
						break
				if not solid:
					break
			if solid and c.x >= 0 and c.x < map_width and c.y >= 0 and c.y < map_height:
				if _tier_at(c) < level:
					_tier_grid[c] = level

# Phase B — flood-fill same-tier regions and carve south-facing staircases from
# each raised region down to lower ground, so plateaus stay reachable. Wide
# plateaus get several stairs (spread across the face) so the squad isn't forced
# to funnel through a single exit.
func _carve_stairs() -> void:
	_stair_cells.clear()
	if Balance.ELEV_TIER_COUNT <= 1:
		return
	for region in _compute_regions():
		if int(region.tier) >= 1:
			_carve_region_stairs(region)

func _compute_regions() -> Array:
	var region_of: Dictionary = {}
	var regions: Array = []
	const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for x in map_width:
		for y in map_height:
			var start := Vector2i(x, y)
			if region_of.has(start):
				continue
			var t := _tier_at(start)
			var idx := regions.size()
			var cells: Array[Vector2i] = []
			var stack: Array[Vector2i] = [start]
			region_of[start] = idx
			while not stack.is_empty():
				var c: Vector2i = stack.pop_back()
				cells.append(c)
				for off in DIRS:
					var n: Vector2i = c + off
					if n.x < 0 or n.x >= map_width or n.y < 0 or n.y >= map_height:
						continue
					if region_of.has(n) or _tier_at(n) != t:
						continue
					region_of[n] = idx
					stack.append(n)
			regions.append({"tier": t, "cells": cells})
	return regions

func _carve_region_stairs(region: Dictionary) -> void:
	var tier_lv: int = int(region.tier)
	var w: int = Balance.ELEV_STAIR_WIDTH
	var h: int = Balance.ELEV_CLIFF_FACE_TILES

	# Every south-edge start where a full-width staircase fits and is flanked by
	# wall on both sides (so it stays interior to the face, not over a corner).
	var valid: Array[Vector2i] = []
	for c in region.cells:
		var ok := true
		for dx in w:
			var top := Vector2i(c.x + dx, c.y)
			if _tier_at(top) != tier_lv:
				ok = false
				break
			for d in range(1, h + 1):
				if _tier_at(Vector2i(c.x + dx, c.y + d)) >= tier_lv:
					ok = false
					break
			if not ok:
				break
			var landing := Vector2i(c.x + dx, c.y + h + 1)
			if landing.y >= map_height or _tier_at(landing) >= tier_lv:
				ok = false
				break
		if not ok:
			continue
		var lf := Vector2i(c.x - 1, c.y)
		var rf := Vector2i(c.x + w, c.y)
		var left_walled := _tier_at(lf) == tier_lv and _tier_at(lf + Vector2i(0, 1)) < tier_lv
		var right_walled := _tier_at(rf) == tier_lv and _tier_at(rf + Vector2i(0, 1)) < tier_lv
		if left_walled and right_walled:
			valid.append(c)
	if valid.is_empty():
		return

	# How many stairs: one per ~16 tiles of plateau width, 1-3. Spread them evenly
	# across the face, keeping a wall gap between adjacent staircases.
	var minx := 99999
	var maxx := -99999
	for c in region.cells:
		minx = mini(minx, c.x)
		maxx = maxi(maxx, c.x)
	var width := maxx - minx + 1
	var count: int = clampi(int(width / 16.0), 1, 3)
	var sep := w + 5
	var picked: Array[Vector2i] = []
	for i in count:
		var target_x := minx + int(width * float(i + 1) / float(count + 1))
		var best := Vector2i(-1, -1)
		var best_d := 1 << 30
		for c in valid:
			var crowded := false
			for p in picked:
				if absi(c.x - p.x) < sep:
					crowded = true
					break
			if crowded:
				continue
			var dd := absi(c.x - target_x)
			if dd < best_d:
				best_d = dd
				best = c
		if best.x >= 0:
			picked.append(best)

	# Stairs cover the plateau edge row (d=0, the top step) down through the wall
	# rows, so they line up with the cap-on-edge wall and stay walkable top-to-bottom.
	for best in picked:
		for dx in w:
			for d in range(0, h):
				_stair_cells[Vector2i(best.x + dx, best.y + d)] = true

# Phase C — render raised tiers like the Caraka reference: the plateau TOP is
# grass with the terrain's own auto-tiled edge lip (so the SIDES/back read as a
# grass edge), and only the FRONT (south) drop shows the brown wall face. Marks
# the impassable cliff cells via _compute_cliff_cells.
func _paint_cliffs() -> void:
	_compute_cliff_cells()
	if _cliff_layer == null:
		return
	_cliff_layer.clear()
	if _plateau_layer:
		_plateau_layer.clear()

	# 1. Raised tiers as an auto-tiled grass blob on the (tinted) plateau layer →
	#    the perimeter gets the grass-edge lip on every side (the reference's
	#    "grass edge") and the whole top reads a distinct shade from low ground.
	var season_set: int = SEASON_TERRAIN_SET[season]
	var raised: Array[Vector2i] = []
	for x in map_width:
		for y in map_height:
			if _tier_at(Vector2i(x, y)) >= 1:
				raised.append(Vector2i(x, y))
	if not raised.is_empty() and _plateau_layer:
		_plateau_layer.set_cells_terrain_connect(raised, season_set, 0, false)

	# 2. Front wall: cap/face/base block (rows 3/4/5). The CAP sits ON the
	#    plateau's south-edge row (covering its grass lip → no gap, exactly the
	#    reference), and face/base drop onto the low cells below. Source (light/
	#    dark) + end-vs-middle column come from the per-plateau style + run extent.
	_assign_cliff_styles()
	var h: int = Balance.ELEV_CLIFF_FACE_TILES
	for x in map_width:
		for y in map_height:
			var t := _tier_at(Vector2i(x, y))
			if t < 1:
				continue
			if _tier_at(Vector2i(x, y + 1)) >= t:
				continue  # only plateau cells whose SOUTH neighbour drops away
			var style: Dictionary = _tier1_style.get(Vector2i(x, y), {})
			var wall_src: int = style.get("wall", WALL_SOURCE)
			# A run ends where the side neighbour is not itself a south-edge cell →
			# cap that side with the end column; otherwise cycle a middle variant.
			var left_end := not (_tier_at(Vector2i(x - 1, y)) == t and _tier_at(Vector2i(x - 1, y + 1)) < t)
			var right_end := not (_tier_at(Vector2i(x + 1, y)) == t and _tier_at(Vector2i(x + 1, y + 1)) < t)
			var col: int = WALL_MID_COLS[x % WALL_MID_COLS.size()]
			if left_end:
				col = WALL_COL_LEFT
			elif right_end:
				col = WALL_COL_RIGHT
			for d in range(h):
				var cc := Vector2i(x, y + d)
				if cc.y >= map_height:
					break
				if d > 0 and _tier_at(cc) >= t:
					break  # ran into equal/higher ground below
				if _stair_cells.has(cc):
					continue
				var row := WALL_ROW_FACE
				if d == 0:
					row = WALL_ROW_CAP
				elif d == h - 1:
					row = WALL_ROW_BASE
				_cliff_layer.set_cell(cc, wall_src, Vector2i(col, row))
	_paint_stairs()

# Give every raised region a consistent style picked from a hash of its anchor
# cell, so adjacent plateaus tend to differ (light vs dark wall, light vs dark
# staircase) for variety while staying deterministic per map layout.
func _assign_cliff_styles() -> void:
	_tier1_style.clear()
	var ri := 0
	for region in _compute_regions():
		if int(region.tier) < 1:
			continue
		# Wall light/dark alternates every region, stair variant every two, so the
		# pair cycles through all four combinations regardless of plateau count.
		@warning_ignore("integer_division")
		var style := {
			"wall": WALL_SOURCE if (ri % 2 == 0) else WALL_DARK_SOURCE,
			"stair": STAIR_BASE_COLS[(ri / 2) % STAIR_BASE_COLS.size()],
		}
		for c in region.cells:
			_tier1_style[c] = style
		ri += 1

# Steps nine-slice, picked by each stair cell's stair-neighbours. The staircase
# variant (light/dark) comes from the plateau the stair descends from.
func _paint_stairs() -> void:
	for cell in _stair_cells:
		var c: Vector2i = cell
		# Walk up to the plateau cell this stair column descends from for its style.
		var top: Vector2i = c
		while _stair_cells.has(top + Vector2i(0, -1)):
			top += Vector2i(0, -1)
		var style: Dictionary = _tier1_style.get(top + Vector2i(0, -1), {})
		var base_col: int = style.get("stair", STAIR_BASE_COLS[0])
		# Always the MIDDLE step column (it tiles edge-to-edge). The Steps sheet's
		# left/right columns carry transparent padding meant for standalone stairs,
		# which leaves a visible gap against the wall — the reference used col 1 only.
		var row := STEP_FACE
		if not _stair_cells.has(c + Vector2i(0, -1)):
			row = STEP_CAP
		elif not _stair_cells.has(c + Vector2i(0, 1)):
			row = STEP_BASE
		_cliff_layer.set_cell(c, STEPS_SOURCE, Vector2i(base_col + 1, row))

# A cell is a cliff (impassable) if any orthogonal neighbour is higher (the
# blocking ring), plus the south face is extended CLIFF_FACE_TILES deep so the
# drop reads as a wall. Stair cells are exempt (they're the walkable way up).
func _compute_cliff_cells() -> void:
	_cliff_cells.clear()
	const DIRS := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	for x in map_width:
		for y in map_height:
			var c := Vector2i(x, y)
			var t := _tier_at(c)
			for off in DIRS:
				if _tier_at(c + off) > t:
					if not _stair_cells.has(c):
						_cliff_cells[c] = true
					break
	# South wall (cap-on-edge): the cap sits on the plateau's south-edge row and
	# face/base drop below — all impassable (matches the painted wall + the stair
	# carving), so the cap row is non-walkable and the only way down is the stairs.
	var h: int = Balance.ELEV_CLIFF_FACE_TILES
	for x in map_width:
		for y in map_height:
			var t := _tier_at(Vector2i(x, y))
			if t < 1:
				continue
			if _tier_at(Vector2i(x, y + 1)) >= t:
				continue
			for d in range(h):
				var cc := Vector2i(x, y + d)
				if cc.y >= map_height:
					break
				if d > 0 and _tier_at(cc) >= t:
					break
				if not _stair_cells.has(cc):
					_cliff_cells[cc] = true

# ===========================================================================
# PHASE D — blocking navigation + collision. Cliffs are impassable; the carved
# stairs (gaps in the cliff set) are the only way between tiers.
# ===========================================================================

# Greedy-merge a cell set into maximal rectangles so nav obstructions and
# collision use a handful of shapes instead of one per cell.
func _merge_cells_to_rects(cells: Dictionary) -> Array[Rect2i]:
	var covered: Dictionary = {}
	var rects: Array[Rect2i] = []
	for y in map_height:
		for x in map_width:
			var c := Vector2i(x, y)
			if not cells.has(c) or covered.has(c):
				continue
			var rw := 1
			while cells.has(Vector2i(x + rw, y)) and not covered.has(Vector2i(x + rw, y)):
				rw += 1
			var rh := 1
			var grow := true
			while grow:
				var ny := y + rh
				if ny >= map_height:
					break
				for dx in rw:
					var cc := Vector2i(x + dx, ny)
					if not cells.has(cc) or covered.has(cc):
						grow = false
						break
				if grow:
					rh += 1
			for dy in rh:
				for dx in rw:
					covered[Vector2i(x + dx, y + dy)] = true
			rects.append(Rect2i(x, y, rw, rh))
	return rects

# World-space Rect2 spanning a tile-rect (uses the tile_map transform so the 2×
# layer scale is honoured).
func _cell_rect_world(r: Rect2i) -> Rect2:
	var half := Vector2(tile_size, tile_size) * 0.5
	var tl: Vector2 = tile_map.to_global(tile_map.map_to_local(Vector2i(r.position.x, r.position.y))) - half
	var br: Vector2 = tile_map.to_global(tile_map.map_to_local(Vector2i(r.position.x + r.size.x - 1, r.position.y + r.size.y - 1))) + half
	return Rect2(tl, br - tl)

func _rect_outline_local(node: Node2D, world: Rect2) -> PackedVector2Array:
	var p := world.position
	var s := world.size
	return PackedVector2Array([
		node.to_local(p),
		node.to_local(p + Vector2(s.x, 0.0)),
		node.to_local(p + s),
		node.to_local(p + Vector2(0.0, s.y)),
	])

# Override the base rectangle bake: bake a navmesh over the whole map with the
# cliff faces AND collidable props (trees/rocks) carved out as obstructions, so
# agents path around plateaus + forests (through the clearings/paths) and only
# cross tiers through the stair gaps — instead of wedging on a trunk every step.
# Hook: extra obstruction outlines (in nav_region-local space) injected by
# subclasses — e.g. TutorialMap adds its CLOSED puzzle gates / intact special
# walls so each trial area is sealed until solved, then re-bakes on open.
# Default: none.
func _extra_nav_obstruction_outlines() -> Array:
	return []

func _bake_navigation() -> void:
	if nav_region == null:
		return
	var obstacles: Dictionary = {}
	for c in _cliff_cells:
		obstacles[c] = true
	for c in _prop_cells:
		obstacles[c] = true
	for c in _block_cells:
		obstacles[c] = true
	if block_water:
		for c in _water_block_cells:
			obstacles[c] = true
	var extra: Array = _extra_nav_obstruction_outlines()
	if obstacles.is_empty() and extra.is_empty():
		super._bake_navigation()
		return
	var src := NavigationMeshSourceGeometryData2D.new()
	src.add_traversable_outline(_rect_outline_local(nav_region, get_map_rect()))
	for r in _merge_cells_to_rects(obstacles):
		src.add_obstruction_outline(_rect_outline_local(nav_region, _cell_rect_world(r)))
	for outline in extra:
		src.add_obstruction_outline(outline)
	# Note: the cave corridor is NOT folded in here — it's a disjoint island the
	# recast bake silently drops. CaveSystem bakes it into its own dedicated map
	# and repoints the squad's agents onto it while underground.
	var np := NavigationPolygon.new()
	np.agent_radius = 10.0
	np.cell_size = _nav_cell_size()
	NavigationServer2D.bake_from_source_geometry_data(np, src)
	nav_region.navigation_polygon = np
	# Yield between the two C++ bakes — each one can take 1-2 seconds on a budget
	# Android device, and running them back-to-back in a single frame caused ANR kills.
	await get_tree().process_frame

	# Same source geometry, re-baked far more aggressively eroded for the minotaur.
	_bake_large_agent_navmesh(src)

# Bakes the wide-body navmesh from the SAME obstruction geometry as the kids'
# mesh, but eroded by MINOTAUR_NAV_AGENT_RADIUS so A* only routes the brute
# through gaps it physically fits. Kept on its own NavigationServer map; the
# region is created once and re-baked in place on every nav rebake (cave fold,
# tutorial gate opens, …). Cell size matches the kids' mesh.
func _bake_large_agent_navmesh(src: NavigationMeshSourceGeometryData2D) -> void:
	if _large_nav_region == null:
		_large_nav_region = NavigationRegion2D.new()
		_large_nav_region.name = "MinotaurNavRegion"
		add_child(_large_nav_region)
		_large_nav_region.global_transform = nav_region.global_transform
		_large_nav_map = NavigationServer2D.map_create()
		NavigationServer2D.map_set_cell_size(_large_nav_map, _nav_cell_size())
		NavigationServer2D.map_set_active(_large_nav_map, true)
		_large_nav_region.set_navigation_map(_large_nav_map)
	var np := NavigationPolygon.new()
	np.agent_radius = Balance.MINOTAUR_NAV_AGENT_RADIUS
	np.cell_size = _nav_cell_size()
	NavigationServer2D.bake_from_source_geometry_data(np, src)
	_large_nav_region.navigation_polygon = np

# Navmesh rasterisation resolution. The bake grid is (map_area / cell_size²), so
# a larger cell_size cuts the peak transient memory of bake_from_source_geometry_data
# quadratically. Budget Android devices were OOM-killed by the fine 4px grid over
# the full map (×2 for the minotaur mesh); 16px shrinks each bake grid ~16× while
# still resolving the 64px tile gaps the squad routes through.
func _nav_cell_size() -> float:
	return 16.0 if OS.get_name() == "Android" else 4.0

func get_large_agent_nav_map() -> RID:
	if _large_nav_map.is_valid():
		return _large_nav_map
	return super.get_large_agent_nav_map()

# The minotaur nav map is a NavigationServer resource, not a node, so it isn't
# reclaimed when this map node frees on scene reload — release it explicitly or
# every mission load leaks one.
func _exit_tree() -> void:
	if _large_nav_map.is_valid():
		NavigationServer2D.free_rid(_large_nav_map)
		_large_nav_map = RID()

# One static body whose rectangle shapes cover the cliff cells, so units (and
# bullets) physically cannot cross a cliff face even past nav avoidance.
func _build_cliff_collision() -> void:
	var existing := get_node_or_null("CliffCollision")
	if existing:
		existing.free()
	var body := StaticBody2D.new()
	body.name = "CliffCollision"
	add_child(body)
	# Cliff faces.
	for r in _merge_cells_to_rects(_cliff_cells):
		_add_box_collider(body, _cell_rect_world(r))
	# Impassable water (lakes) — only when block_water is on (e.g. the tutorial).
	if block_water:
		for r in _merge_cells_to_rects(_water_block_cells):
			_add_box_collider(body, _cell_rect_world(r))
	# Painted blocking-decor layer (waterfalls / solid decor) — always blocks.
	for r in _merge_cells_to_rects(_block_cells):
		_add_box_collider(body, _cell_rect_world(r))
	# Map-boundary frame: walls inset one tile from each visible edge so units
	# and their sprites are blocked before reaching the screen boundary.
	var m := get_map_rect()
	const T := 64.0             # wall thickness (extends outward past the map edge)
	var ts := float(tile_size)  # one tile = inward inset so sprites stay on screen
	_add_box_collider(body, Rect2(m.position.x - T, m.position.y - T,       m.size.x + 2.0 * T, T + ts))  # top
	_add_box_collider(body, Rect2(m.position.x - T, m.position.y + m.size.y - ts, m.size.x + 2.0 * T, T + ts))  # bottom
	_add_box_collider(body, Rect2(m.position.x - T, m.position.y - T,       T + ts, m.size.y + 2.0 * T))  # left
	_add_box_collider(body, Rect2(m.position.x + m.size.x - ts, m.position.y - T, T + ts, m.size.y + 2.0 * T))  # right

func _add_box_collider(body: StaticBody2D, wr: Rect2) -> void:
	var col := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = wr.size
	col.shape = shape
	col.position = to_local(wr.position + wr.size * 0.5)
	body.add_child(col)

# ===========================================================================
# HIDDEN CAVE — the level's captured parent is hidden in an underground fairy
# garden reached through a cave mouth in a plateau wall (see CaveSystem.gd),
# instead of the cage being dropped at a random world cell.
# ===========================================================================
func _spawn_mission_parent_and_fragment() -> void:
	var foot := _pick_cave_entrance_foot()
	if foot.x < 0:
		_spawn_freestanding_cave()   # no plateau wall (e.g. the flat Blighted Marsh) → ground portal
		return
	# Record the cave mouth so _spawn_escort_mission keeps the VIP prison away.
	_cave_foot_cell = foot
	var level: int = GameManager.current_level
	# Clear trees/rocks around the entrance so it stays approachable (and isn't
	# accidentally walked into while pathing around a prop).
	for dx in range(-3, 4):
		for dy in range(-4, 4):
			var c := foot + Vector2i(dx, dy)
			if _prop_cells.erase(c):
				var pn := get_node_or_null("Prop_%d_%d" % [c.x, c.y])
				if pn:
					pn.queue_free()
	var cave := Node2D.new()
	cave.set_script(CAVE_SYSTEM_SCRIPT)
	add_child(cave)
	cave.setup(_tile_to_world(foot), level - 2, get_map_rect())  # level 2 → Kid 1 (slot 0) … level 7 → Kid 6 (slot 5)
	_cave_system = cave
	if cave.parent_cage:
		_objective_nodes["parent_cage"] = cave.parent_cage
	# The cave corridor gets its own navmesh map (built inside CaveSystem.setup);
	# the squad's agents are repointed onto it on entry. No world re-bake needed —
	# folding the far-off corridor island into the world bake silently dropped it.
	_spawn_world_fragment(level, foot)

# Flat maps (no plateau tier ≥ 1, e.g. the Blighted Marsh) have no wall to set a
# cave mouth into — drop a freestanding ground portal in the outer ring instead,
# same placement rule as MapGenerator's plain cage fallback.
func _spawn_freestanding_cave() -> void:
	var level: int = GameManager.current_level
	var outer := _passable_cells.filter(func(c: Vector2i) -> bool:
		if c.x < 3 or c.x > map_width - 4 or c.y < 3 or c.y > map_height - 4:
			return false
		var cx := float(c.x) / float(map_width)
		var cy := float(c.y) / float(map_height)
		return cx < 0.20 or cx > 0.80 or cy < 0.20 or cy > 0.80
	)
	if outer.is_empty():
		super._spawn_mission_parent_and_fragment()   # ultimate fallback: literal cage
		return
	outer.shuffle()
	var entrance_cell: Vector2i = outer[0]
	var cave := Node2D.new()
	cave.set_script(CAVE_SYSTEM_SCRIPT)
	add_child(cave)
	cave.setup(_tile_to_world(entrance_cell), level - 2, get_map_rect(), true)
	_cave_system = cave
	if cave.parent_cage:
		_objective_nodes["parent_cage"] = cave.parent_cage
	_spawn_world_fragment(level, entrance_cell)

# Three memory fragments drop in the open world (the cave holds only the
# parent). IDs are picked randomly from the uncollected pool.
func _spawn_world_fragment(_level: int, avoid: Vector2i) -> void:
	var frag_scene: PackedScene = load("res://scenes/memory_fragment.tscn")
	if frag_scene == null:
		return
	var outer := _passable_cells.filter(func(c: Vector2i) -> bool:
		if c.x < 3 or c.x > map_width - 4 or c.y < 3 or c.y > map_height - 4:
			return false
		var cx := float(c.x) / float(map_width)
		var cy := float(c.y) / float(map_height)
		return cx < 0.22 or cx > 0.78 or cy < 0.22 or cy > 0.78
	)
	if outer.is_empty():
		return
	var frag_ids := _pick_level_fragment_ids(3)
	var positions := _spread_positions(outer, avoid, frag_ids.size())
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

# Foot = the walkable low-ground cell just below a plateau's south wall, near the
# centre of the largest plateau and clear of stairs/props — where the cave mouth
# sits. Returns (-1,-1) if there's no usable plateau wall.
func _pick_cave_entrance_foot() -> Vector2i:
	var best_region: Dictionary = {}
	var best_size := 0
	for region in _compute_regions():
		if int(region.tier) >= 1 and region.cells.size() > best_size:
			best_size = region.cells.size()
			best_region = region
	if best_region.is_empty():
		return Vector2i(-1, -1)
	var tier_lv := int(best_region.tier)
	var h: int = Balance.ELEV_CLIFF_FACE_TILES
	var sum_x := 0
	for c in best_region.cells:
		sum_x += c.x
	var cx: int = int(round(float(sum_x) / float(best_region.cells.size())))
	var best := Vector2i(-1, -1)
	var best_d := 1 << 30
	for c in best_region.cells:
		if _tier_at(Vector2i(c.x, c.y + 1)) >= tier_lv:
			continue   # not a south-edge cell
		var foot := Vector2i(c.x, c.y + h)
		if foot.y >= map_height or _cliff_cells.has(foot) or _prop_cells.has(foot):
			continue
		var near_stair := false
		for sc in _stair_cells:
			if absi(sc.x - c.x) < 4 and absi(sc.y - c.y) < 6:
				near_stair = true
				break
		if near_stair:
			continue
		var d: int = absi(c.x - cx)
		if d < best_d:
			best_d = d
			best = foot
	return best

# Cellular automata smoothing: any cell with fewer than 2 same-type 4-neighbors
# flips to its majority neighbor. Removes 1-cell pinches that auto-tiling
# struggles with.
func _smooth_terrain(passes: int) -> void:
	for p in passes:
		var updates: Dictionary = {}
		for x in map_width:
			for y in map_height:
				var cell := Vector2i(x, y)
				var current: String = _terrain_grid.get(cell, "grass")
				var counts: Dictionary = {"grass": 0, "dirt": 0, "water": 0}
				var same := 0
				for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = cell + off
					if n.x < 0 or n.x >= map_width or n.y < 0 or n.y >= map_height:
						continue
					var nt: String = _terrain_grid.get(n, "grass")
					counts[nt] = counts.get(nt, 0) + 1
					if nt == current:
						same += 1
				if same < 2:
					var best := current
					var best_count := -1
					for t in counts:
						if counts[t] > best_count:
							best = t
							best_count = counts[t]
					if best != current:
						updates[cell] = best
		for cell in updates:
			_terrain_grid[cell] = updates[cell]

# Morphological opening per terrain type. Any region that doesn't contain at
# least one MIN_BLOCK_SIZE×MIN_BLOCK_SIZE square of its own type gets every
# cell re-flipped to the surrounding majority. Eliminates the 1- and 2-cell
# slivers the noise + smoothing pass leaves behind — those slivers don't
# have valid edge variants in the Caraka tileset and render as broken
# corners. Run before paths are placed so the intentionally-thin path lines
# survive.
func _enforce_min_block_size() -> void:
	for type in ["grass", "dirt", "water"]:
		# Erode: find every top-left anchor whose MIN_BLOCK_SIZE-square is
		# fully this type. Dilate: any cell covered by such a square survives.
		var kept: Dictionary = {}
		for x in range(0, map_width - MIN_BLOCK_SIZE + 1):
			for y in range(0, map_height - MIN_BLOCK_SIZE + 1):
				var anchored := true
				for dx in MIN_BLOCK_SIZE:
					for dy in MIN_BLOCK_SIZE:
						if _terrain_grid.get(Vector2i(x + dx, y + dy)) != type:
							anchored = false
							break
					if not anchored:
						break
				if not anchored:
					continue
				for dx in MIN_BLOCK_SIZE:
					for dy in MIN_BLOCK_SIZE:
						kept[Vector2i(x + dx, y + dy)] = true
		# Flip un-kept cells of this type to the dominant neighbouring type.
		for cell in _terrain_grid.keys():
			if _terrain_grid.get(cell) != type:
				continue
			if kept.has(cell):
				continue
			_terrain_grid[cell] = _dominant_other_type(cell, type)

# Picks the most common terrain type in a 5×5 window around `cell`, ignoring
# the type we're trying to replace. Falls back to "dirt" when nothing else
# is around — dirt is the universal substrate the ground layer paints under
# every land tile.
func _dominant_other_type(cell: Vector2i, exclude: String) -> String:
	var counts: Dictionary = {}
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			if dx == 0 and dy == 0:
				continue
			var t = _terrain_grid.get(cell + Vector2i(dx, dy), null)
			if t == null or t == exclude:
				continue
			counts[t] = counts.get(t, 0) + 1
	var best: String = "dirt"
	var best_count: int = -1
	for t in counts:
		if counts[t] > best_count:
			best = t
			best_count = counts[t]
	return best

func _generate_paths(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 500
	var path_count := rng.randi_range(3, 5)
	var center := Vector2(map_width * 0.5, map_height * 0.5)

	for i in path_count:
		var start: Vector2i
		match rng.randi() % 4:
			0: start = Vector2i(0, rng.randi_range(10, map_height - 10))
			1: start = Vector2i(map_width - 1, rng.randi_range(10, map_height - 10))
			2: start = Vector2i(rng.randi_range(10, map_width - 10), 0)
			3: start = Vector2i(rng.randi_range(10, map_width - 10), map_height - 1)

		var pos := Vector2(start)
		var steps := rng.randi_range(30, 60)
		for s in steps:
			var to_center := (center - pos).normalized()
			var angle := to_center.angle() + rng.randf_range(-0.8, 0.8)
			pos += Vector2.from_angle(angle) * 2.0

			var cell := Vector2i(int(pos.x), int(pos.y))
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					var c := cell + Vector2i(dx, dy)
					if c.x >= 0 and c.x < map_width and c.y >= 0 and c.y < map_height:
						if _terrain_grid.get(c) == "grass":
							_terrain_grid[c] = "path"

# Props are placed in CLUSTERS, not a uniform scatter: a low-frequency "forest"
# noise field carves broad dense woodland blobs with open clearings between, and
# a separate "rocky" field clumps rocks into outcrops. Trees are scaled up so a
# conifer towers over the squad. Clearings get the occasional lone tree + flowers.
func _place_props(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	var effective: int = seed_value if seed_value != 0 else randi()
	rng.seed = effective

	var tree_tex: Texture2D = load(TREE_TEXTURE)
	var rock_tex: Texture2D = load(ROCK_TEXTURE)
	var bush_tex: Texture2D = load(BUSH_TEXTURE)
	var flower_tex: Texture2D = load(FLOWER_TEXTURE)
	var tree_regs: Array = TREE_REGIONS.get(season, TREE_REGIONS[Season.SPRING])
	var bush_regs: Array = BUSH_REGIONS.get(season, BUSH_REGIONS[Season.SPRING])
	var scene_owner: Node = owner if owner else self

	_prop_cells.clear()
	var prop_density: float = 0.3 if OS.get_name() == "Android" else 1.0
	var forest := FastNoiseLite.new()
	forest.seed = effective + 700
	forest.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	forest.frequency = 0.05
	forest.fractal_octaves = 3
	var rocky := FastNoiseLite.new()
	rocky.seed = effective + 1700
	rocky.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	rocky.frequency = 0.10
	rocky.fractal_octaves = 2

	# Keep a clear apron around every staircase (and its landing) so a tree never
	# spawns in front of the only way up/down.
	var near_stair: Dictionary = {}
	for sc in _stair_cells:
		for dx in range(-3, 4):
			for dy in range(-3, 4):
				near_stair[sc + Vector2i(dx, dy)] = true

	const TREE_SCALE := Vector2(2.6, 2.6)
	const EDGE := 2   # tile margin — keeps prop sprites from clipping off screen
	for cell in _terrain_grid:
		var ttype: String = _terrain_grid[cell]
		if ttype == "water" or ttype == "path":
			continue  # keep water + the dirt paths between forests clear
		if cell.x < EDGE or cell.x >= map_width - EDGE or cell.y < EDGE or cell.y >= map_height - EDGE:
			continue  # too close to the visible boundary
		if _cliff_cells.has(cell) or _tier_at(cell) >= 1:
			continue  # no props on cliffs / plateau tops
		if near_stair.has(cell):
			continue  # keep staircase approaches clear
		var cx := float(cell.x) / map_width
		var cy := float(cell.y) / map_height
		if cx > 0.38 and cx < 0.62 and cy > 0.38 and cy < 0.62:
			continue  # keep the squad's spawn area open

		var fv := forest.get_noise_2d(float(cell.x), float(cell.y))   # -1..1
		var rv := rocky.get_noise_2d(float(cell.x), float(cell.y))
		var roll := rng.randf()

		# Dense forest: tree probability ramps up toward the blob core; canopies
		# overlap (trees are bigger than a cell) so it reads as solid woodland,
		# while the gaps stay walkable.
		if ttype == "grass" and fv > 0.08:
			var dens: float = clampf(remap(fv, 0.08, 0.7, 0.15, 0.62), 0.0, 0.62) * prop_density
			if roll < dens:
				_spawn_prop(tree_tex, tree_regs[rng.randi() % tree_regs.size()], cell, TREE_SCALE, true, scene_owner)
				continue
			if roll < dens + 0.08 * prop_density:
				_spawn_prop(bush_tex, bush_regs[rng.randi() % bush_regs.size()], cell, Vector2(1.6, 1.6), false, scene_owner)
				continue

		# Rocky outcrops — clustered, independent of the forest field.
		if rv > 0.30:
			var rdens: float = clampf(remap(rv, 0.30, 0.75, 0.08, 0.40), 0.0, 0.40) * prop_density
			if roll < rdens:
				var rock_x := (rng.randi() % 4) * 32
				_spawn_prop(rock_tex, Rect2(rock_x, 0, 32, 32), cell, Vector2(1.7, 1.7), true, scene_owner)
				continue

		# Clearings: the odd lone tree + scattered flowers to keep them alive.
		if ttype == "grass":
			if roll < 0.012 * prop_density:
				_spawn_prop(tree_tex, tree_regs[rng.randi() % tree_regs.size()], cell, TREE_SCALE, true, scene_owner)
			elif roll < 0.05 * prop_density:
				var fx := (rng.randi() % 8) * 16
				var fy := (rng.randi() % 6) * 16
				_spawn_prop(flower_tex, Rect2(fx, fy, 16, 16), cell, Vector2(1.5, 1.5), false, scene_owner)

func _spawn_prop(tex: Texture2D, region: Rect2, cell: Vector2i, prop_scale: Vector2, has_collision: bool, scene_owner: Node) -> void:
	if has_collision:
		_prop_cells[cell] = true   # nav obstruction + non-passable
	var world_pos := to_local(tile_map.to_global(tile_map.map_to_local(cell)))
	var atlas_tex := AtlasTexture.new()
	atlas_tex.atlas = tex
	atlas_tex.region = region

	if has_collision:
		var body := StaticBody2D.new()
		body.position = world_pos
		body.name = "Prop_%d_%d" % [cell.x, cell.y]
		var sprite := Sprite2D.new()
		sprite.texture = atlas_tex
		sprite.scale = prop_scale
		body.add_child(sprite)
		var col := CollisionShape2D.new()
		var shape := CircleShape2D.new()
		shape.radius = 6.0
		col.shape = shape
		body.add_child(col)
		add_child(body)
		if Engine.is_editor_hint():
			body.owner = scene_owner
			sprite.owner = scene_owner
			col.owner = scene_owner
	else:
		var sprite := Sprite2D.new()
		sprite.position = world_pos
		sprite.name = "Decor_%d_%d" % [cell.x, cell.y]
		sprite.texture = atlas_tex
		sprite.scale = prop_scale
		add_child(sprite)
		if Engine.is_editor_hint():
			sprite.owner = scene_owner

# ===========================================================================
# EDITOR-ONLY: seed a Caraka layout into the scene. Save (Ctrl+S) to persist.
# Any hand-painted edits made afterward are also captured on save.
# ===========================================================================
# Editor: ensure this scene has the standard Caraka layer + navmesh layout so it
# can be hand-painted with full functionality, WITHOUT generating terrain. Brings
# any handcrafted scene up to the same structure as the others. Save afterwards.
func _editor_setup_layers() -> void:
	if not Engine.is_editor_hint():
		return
	_apply_map_dims()
	var scene_root: Node = owner if owner else self
	# Ground layer: adopt an existing TileMapLayer_ground/TileMapLayer, or make one.
	if tile_map == null:
		tile_map = get_node_or_null("TileMapLayer_ground") as TileMapLayer
		if tile_map == null:
			tile_map = get_node_or_null("TileMapLayer") as TileMapLayer
		if tile_map == null:
			tile_map = _create_layer("TileMapLayer_ground")
	if tile_map.name == "TileMapLayer":
		tile_map.name = "TileMapLayer_ground"   # normalise the name across scenes
	# Navmesh region.
	if get_node_or_null("NavigationRegion2D") == null:
		var nr := NavigationRegion2D.new()
		nr.name = "NavigationRegion2D"
		add_child(nr)
		nr.owner = scene_root
		nav_region = nr
	_resolve_layers()   # objects / Overlay / cliff / plateau
	_setup_tileset()    # tileset + 2× scale + z-order on every layer
	print("[HandcraftedMap] Standard layers ready. Paint your map (dirt-wall = blocking, Steps = stairs, raised-grass layer = plateau top), then Save (Ctrl+S).")

func _editor_generate_caraka() -> void:
	if not Engine.is_editor_hint():
		return
	_apply_map_dims()

	if tile_map == null:
		tile_map = get_node_or_null("TileMapLayer_ground") as TileMapLayer
		if tile_map == null:
			tile_map = get_node_or_null("TileMapLayer") as TileMapLayer
	if tile_map == null:
		push_warning("[HandcraftedMap] No TileMapLayer_ground found.")
		return

	_resolve_layers()

	# Clear previously-generated props (anything that isn't a TileMapLayer or
	# the NavigationRegion2D) so repeated clicks don't pile up sprites.
	var scene_root: Node = owner if owner else self
	for child in get_children():
		if child is TileMapLayer or child is NavigationRegion2D:
			continue
		if child.owner == scene_root:
			child.queue_free()

	_setup_tileset()
	_generate_terrain(randi())
	print("[HandcraftedMap] Generated %s terrain. Save (Ctrl+S) to persist." % Season.keys()[season])
