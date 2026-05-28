@tool
extends HandcraftedMap
class_name CarakaAutoGen

enum Season { SPRING, SUMMER, FALL, WINTER }

@export var season: Season = Season.SUMMER
@export_tool_button("Generate Caraka Map", "Reload") var _caraka_btn: Callable = _editor_generate_caraka

const TERRAIN_TILESET := "res://resources/caraka_terrain_tileset.tres"

# Terrain set index per season (defined in caraka_terrain_tileset.tres)
const SEASON_TERRAIN_SET := {
	Season.SPRING: 2,
	Season.SUMMER: 3,
	Season.FALL:   4,
	Season.WINTER: 5,
}

# Water terrain indices within terrain set 6
const SEASON_WATER_TERRAIN := {
	Season.SPRING: 0,
	Season.SUMMER: 2,
	Season.FALL:   4,
	Season.WINTER: 2,
}

const TREE_TEXTURE := "res://resources/caraka/Props/Tree.png"
const ROCK_TEXTURE := "res://resources/caraka/Props/Rock/rock.png"
const BUSH_TEXTURE := "res://resources/caraka/Props/Bush.png"
const FLOWER_TEXTURE := "res://resources/caraka/Props/Flower.png"

# Tree.png is a 32×64 grid. Seasons: col 0=spring, 1-2=summer, 3-5=fall, 6=winter.
# Row 0 (y=0) = conifers, row 2 (y=128) = deciduous. Cols 8-14 repeat with variant shapes.
const TREE_REGIONS := {
	Season.SPRING: [Rect2(0, 0, 32, 64), Rect2(256, 0, 32, 64), Rect2(0, 128, 32, 64)],
	Season.SUMMER: [Rect2(32, 0, 32, 64), Rect2(64, 0, 32, 64), Rect2(32, 128, 32, 64)],
	Season.FALL:   [Rect2(96, 0, 32, 64), Rect2(128, 0, 32, 64), Rect2(96, 128, 32, 64)],
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

func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint() and tile_map:
		_resolve_layers()
		_setup_tileset()

func _resolve_layers() -> void:
	if _objects_layer == null:
		_objects_layer = get_node_or_null("TileMapLayer_objects") as TileMapLayer
	if _water_layer == null:
		_water_layer = get_node_or_null("TileMapLayer_Overlay") as TileMapLayer

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

func generate(seed_value: int = 0) -> void:
	_objective_nodes.clear()
	_enemy_exclusion_radius = 0
	_resolve_layers()
	if tile_map.tile_set == null:
		_setup_tileset()
	_generate_terrain(seed_value)
	_place_props(seed_value)
	_scan_caraka_passable()
	_bake_navigation()
	match GameManager.current_level:
		4: _spawn_fortified_structure()
		5: _spawn_escort_mission()
	var lv: int = GameManager.current_level
	if lv == 2 or lv == 4 or lv == 5:
		_spawn_mission_parent_and_fragment()
	_spawn_enemies()

func _scan_caraka_passable() -> void:
	_passable_cells.clear()
	for cell in _terrain_grid:
		if _terrain_grid[cell] != "water":
			_passable_cells.append(cell)

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

	# Water layer: seasonal water with auto-tiled shorelines
	if _water_layer and not water_cells.is_empty():
		var water_terrain: int = SEASON_WATER_TERRAIN[season]
		_water_layer.set_cells_terrain_connect(water_cells, 6, water_terrain, false)

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
		push_warning("[CarakaAutoGen] No TileMapLayer_ground found.")
		return

	_resolve_layers()

	var scene_root: Node = owner if owner else self
	for child in get_children():
		if child is TileMapLayer or child is NavigationRegion2D:
			continue
		if child.owner == scene_root:
			child.queue_free()

	_setup_tileset()
	_generate_terrain(randi())
	print("[CarakaAutoGen] Generated %s terrain with auto-tiled edges. Save (Ctrl+S) to persist." % Season.keys()[season])
