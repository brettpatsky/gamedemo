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
# Missing layers are auto-created on generate. Topography / elevation queries
# return neutral values since handcrafted maps don't use noise-driven terrain.
# is_water_at() is overridden to check the water layer for movement slowdown.
# =============================================================================
@tool
extends MapGenerator
class_name HandcraftedMap

enum Season { SPRING, SUMMER, FALL, WINTER }

@export var season: Season = Season.SUMMER
@warning_ignore("unused_private_class_variable")
@export_tool_button("Generate Caraka Map", "Reload") var _caraka_btn: Callable = _editor_generate_caraka

# When true, generate() clears the saved tiles and regenerates fresh Caraka
# terrain at runtime. Set by Main.gd based on the title-screen "Map: Auto"
# toggle. Default false = use whatever tiles are already painted in the scene
# (the "Custom" / hand-edited workflow).
var regenerate_at_runtime: bool = false

const TERRAIN_TILESET := "res://resources/caraka_terrain_tileset.tres"

# Terrain set index per season (defined in caraka_terrain_tileset.tres)
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
const TREE_REGIONS := {
	Season.SPRING: [Rect2(0, 0, 32, 64), Rect2(256, 0, 32, 64)],
	Season.SUMMER: [Rect2(32, 0, 32, 64), Rect2(64, 0, 32, 64)],
	Season.FALL:   [Rect2(96, 0, 32, 64), Rect2(128, 0, 32, 64)],
	Season.WINTER: [Rect2(192, 0, 32, 64), Rect2(448, 0, 32, 64)],
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

# Dimensions are applied here (NOT in generate()) because Main.gd calls
# camera.refresh_map_bounds() between scene instantiation and generate(); if
# the dimensions weren't already set, the camera would clamp to the inherited
# MapGenerator @export defaults and trap the viewport in the wrong corner.
func _ready() -> void:
	if Engine.is_editor_hint():
		return
	map_width  = Balance.MAP_HANDCRAFTED_WIDTH
	map_height = Balance.MAP_HANDCRAFTED_HEIGHT
	tile_size  = Balance.MAP_HANDCRAFTED_TILE_SIZE
	super._ready()
	# Force painted tiles to render below enemies / obstacles / mission props.
	if tile_map:
		tile_map.z_index = -1
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

# ---------------------------------------------------------------------------
# Runtime entry point. Scans whatever tiles the scene already has (including
# any hand-painted additions), bakes navigation, then spawns mission content.
# ---------------------------------------------------------------------------
func generate(seed_value: int = 0) -> void:
	_objective_nodes.clear()
	_enemy_exclusion_radius = 0
	_resolve_layers()
	if regenerate_at_runtime:
		_setup_tileset()
		_generate_terrain(seed_value)
		_place_props(seed_value)
	_scan_passable_from_tiles()
	_bake_navigation()
	# Custom mission scenes can pre-place their objective nodes (structures /
	# escort NPC / walls / extraction) directly in the .tscn — see mission_4
	# and mission_5. _adopt_scene_objectives registers any it finds; the
	# procedural spawners then no-op when their slot is already filled.
	_adopt_scene_objectives()
	match GameManager.current_level:
		4:
			if not _objective_nodes.has("fortified_structure"):
				_spawn_fortified_structure()
		5:
			if not _objective_nodes.has("escort_npc"):
				_spawn_escort_mission()
	var lv: int = GameManager.current_level
	if lv == 2 or lv == 4 or lv == 5:
		_spawn_mission_parent_and_fragment()
	_spawn_enemies()

# Picks up objective nodes that the .tscn placed by hand (instead of relying
# on the procedural spawners). Detection is by group membership filtered to
# direct children so other levels' own structures don't get harvested.
func _adopt_scene_objectives() -> void:
	var structs: Array[Node2D] = []
	for c in get_children():
		if c.is_in_group("structures"):
			structs.append(c)
	if not structs.is_empty():
		_objective_nodes["fortified_structure"] = structs

	var npc: Node = null
	var walls: Array[Node2D] = []
	var extraction: Node = null
	for c in get_children():
		if npc == null and c.is_in_group("escort_npc"):
			npc = c
		elif c.is_in_group("escort_walls"):
			walls.append(c)
		elif c.scene_file_path != "" and c.scene_file_path.ends_with("extraction_zone.tscn"):
			extraction = c
	if npc != null:
		_objective_nodes["escort_npc"] = npc
		# Block enemy spawns around the placed NPC so it isn't immediately swarmed.
		var npc_local: Vector2 = (npc as Node2D).position
		var world_tile: float = float(tile_size) * 2.0
		_enemy_exclusion_centre = Vector2i(int(npc_local.x / world_tile), int(npc_local.y / world_tile))
		_enemy_exclusion_radius = 6
	if not walls.is_empty():
		_objective_nodes["escort_walls"] = walls
	if extraction != null:
		_objective_nodes["extraction_zone"] = extraction

# Rebuilds _passable_cells from the actual painted tiles in the scene. A cell
# is passable when the ground layer has a tile AND the water layer doesn't.
# Captures both auto-generated and hand-painted edits.
func _scan_passable_from_tiles() -> void:
	_passable_cells.clear()
	for x in map_width:
		for y in map_height:
			var cell := Vector2i(x, y)
			var ground_id := tile_map.get_cell_source_id(cell)
			if ground_id == -1:
				continue  # no ground tile = not passable
			if _water_layer and _water_layer.get_cell_source_id(cell) != -1:
				continue  # water tile present = not passable
			_passable_cells.append(cell)

# Topography is a per-tile _draw() loop — too slow at 110×100. The Caraka
# tileset has built-in shading so the procedural overlay isn't needed.
func _spawn_topography() -> void:
	pass

# Procedural maps use elevation noise for range/slope modifiers. Handcrafted
# maps don't have elevation data, so return neutral values.
func get_range_modifier_at(_world_pos: Vector2) -> float:
	return 1.0

func get_slope_speed_mult(_world_pos: Vector2, _direction: Vector2) -> float:
	return 1.0

func get_elevation_at(_world_pos: Vector2) -> float:
	return 0.0

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

	for x in map_width:
		for y in map_height:
			var cell := Vector2i(x, y)
			var tv := (terrain_noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			var wv := (water_noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			var cx := float(x) / map_width
			var cy := float(y) / map_height
			var in_spawn := cx > 0.35 and cx < 0.65 and cy > 0.35 and cy < 0.65

			if wv < 0.25 and not in_spawn:
				_terrain_grid[cell] = "water"
			elif tv < 0.40:
				_terrain_grid[cell] = "dirt"
			else:
				_terrain_grid[cell] = "grass"

	_smooth_terrain(2)

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

	# Water layer: single static animated water tile per cell. The dirt layer
	# below provides the visible shoreline via its terrain-driven edges.
	if _water_layer and not water_cells.is_empty():
		var water_src_id := _find_water_source_id()
		if water_src_id >= 0:
			# Atlas (8, 1) = solid fill water tile (original col=1 row=1, frame 0
			# of an 8-frame animation; animation playback handles the rest).
			var water_atlas := Vector2i(8, 1)
			for cell in water_cells:
				_water_layer.set_cell(cell, water_src_id, water_atlas)

# Looks up the atlas source ID for the current season's water texture.
func _find_water_source_id() -> int:
	var ts: TileSet = tile_map.tile_set
	if ts == null:
		return -1
	var filename: String
	match season:
		Season.SPRING:                filename = "water - spring - shallow.png"
		Season.SUMMER, Season.WINTER: filename = "water - summer - shallow.png"
		Season.FALL:                  filename = "water - fall - shallow.png"
		_:                            filename = "water - summer - shallow.png"
	for i in ts.get_source_count():
		var src_id: int = ts.get_source_id(i)
		var src: TileSetAtlasSource = ts.get_source(src_id) as TileSetAtlasSource
		if src and src.texture and src.texture.resource_path.ends_with(filename):
			return src_id
	return -1

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

func _place_props(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value if seed_value != 0 else randi()

	var tree_tex: Texture2D = load(TREE_TEXTURE)
	var rock_tex: Texture2D = load(ROCK_TEXTURE)
	var bush_tex: Texture2D = load(BUSH_TEXTURE)
	var flower_tex: Texture2D = load(FLOWER_TEXTURE)
	var tree_regs: Array = TREE_REGIONS.get(season, TREE_REGIONS[Season.SPRING])
	var bush_regs: Array = BUSH_REGIONS.get(season, BUSH_REGIONS[Season.SPRING])
	var scene_owner: Node = owner if owner else self

	for cell in _terrain_grid:
		if _terrain_grid[cell] == "water":
			continue
		var cx := float(cell.x) / map_width
		var cy := float(cell.y) / map_height
		if cx > 0.35 and cx < 0.65 and cy > 0.35 and cy < 0.65:
			continue

		var roll := rng.randf()
		if _terrain_grid[cell] == "grass" and roll < 0.04:
			var region: Rect2 = tree_regs[rng.randi() % tree_regs.size()]
			_spawn_prop(tree_tex, region, cell, Vector2(2.0, 2.0), true, scene_owner)
		elif roll >= 0.04 and roll < 0.055:
			var rock_x := (rng.randi() % 4) * 32
			_spawn_prop(rock_tex, Rect2(rock_x, 0, 32, 32), cell, Vector2(1.5, 1.5), true, scene_owner)
		elif _terrain_grid[cell] == "grass" and roll >= 0.055 and roll < 0.07:
			var breg: Rect2 = bush_regs[rng.randi() % bush_regs.size()]
			_spawn_prop(bush_tex, breg, cell, Vector2(1.5, 1.5), false, scene_owner)
		elif _terrain_grid[cell] == "grass" and roll >= 0.07 and roll < 0.09:
			var fx := (rng.randi() % 8) * 16
			var fy := (rng.randi() % 6) * 16
			_spawn_prop(flower_tex, Rect2(fx, fy, 16, 16), cell, Vector2(1.5, 1.5), false, scene_owner)

func _spawn_prop(tex: Texture2D, region: Rect2, cell: Vector2i, prop_scale: Vector2, has_collision: bool, scene_owner: Node) -> void:
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
func _editor_generate_caraka() -> void:
	if not Engine.is_editor_hint():
		return
	map_width  = Balance.MAP_HANDCRAFTED_WIDTH
	map_height = Balance.MAP_HANDCRAFTED_HEIGHT
	tile_size  = Balance.MAP_HANDCRAFTED_TILE_SIZE

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
