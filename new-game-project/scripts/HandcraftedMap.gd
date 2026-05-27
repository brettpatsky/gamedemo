# =============================================================================
# HandcraftedMap.gd
# Drop-in replacement for MapGenerator used by hand-authored mission scenes
# (see scenes/handcrafted/mission_*.tscn). The scene file owns the static
# content — tiles, trees, rocks, boundary walls — and runtime only handles
# the dynamic stuff: passable-cell scan, navigation bake, topography overlay,
# mission objects, and enemies.
#
# Extends MapGenerator so all the gameplay queries (is_water_at, slope
# multipliers, range modifiers, spawn-position picker) work unchanged.
#
# Editor workflow:
#   1. Open scenes/handcrafted/mission_X.tscn in Godot.
#   2. Click the "Regenerate Random Map" button in the inspector to seed a
#      fresh random layout into the scene.
#   3. Edit the result freely — paint tiles on the TileMapLayer, drag
#      trees/rocks/walls in the scene tree, place mission props.
#   4. Save (Ctrl+S). The .tscn captures everything you placed.
# =============================================================================
@tool
extends MapGenerator
class_name HandcraftedMap

# Inspector button — only available in the editor. Clears any obstacles /
# walls owned by the scene root and re-runs the bake step. After clicking,
# review the result and Ctrl+S to persist.
@warning_ignore("unused_private_class_variable")
@export_tool_button("Regenerate Random Map", "Reload") var _regen_btn: Callable = _editor_regenerate

# Set this to the atlas coordinate of your water / impassable tile in whatever
# tileset this scene uses. Cells with this atlas coord are excluded from
# _passable_cells so enemies and mission objects don't spawn on them.
# Leave at (-1, -1) to treat every painted tile as passable (useful when
# your tileset has no water, or you're using Obstacle nodes for blocking).
@export var water_tile_atlas: Vector2i = Vector2i(-1, -1)

# Suppress the parent's _ready in editor — we don't want add_to_group("map_generator")
# or any runtime setup running while you're editing the .tscn.
#
# Dimensions are applied here (NOT in generate()) because Main.gd calls
# camera.refresh_map_bounds() between scene instantiation and generate(); if
# the dimensions weren't already set, the camera would clamp to the inherited
# MapGenerator @export defaults (55×50 @ 64px) and trap the viewport in the
# wrong corner of the world.
func _ready() -> void:
	if Engine.is_editor_hint():
		if tile_config == null:
			tile_config = TileConfig.new()
		return
	map_width  = Balance.MAP_HANDCRAFTED_WIDTH
	map_height = Balance.MAP_HANDCRAFTED_HEIGHT
	tile_size  = Balance.MAP_HANDCRAFTED_TILE_SIZE
	super._ready()
	# Force painted tiles to render below enemies / obstacles / mission props.
	# Enemies are added to this node as siblings of TileMapLayer and default to
	# z_index = 0; if the tileset has y_sort_enabled or per-tile z overrides,
	# tiles can end up drawn on top. Dropping the layer to -1 sidesteps all of
	# that — anything spawned at runtime stays visible.
	if tile_map:
		tile_map.z_index = -1

# ---------------------------------------------------------------------------
# Runtime entry point. Skips tile-fill / obstacle / wall baking because the
# scene already provides those. Topography is skipped — see below.
# ---------------------------------------------------------------------------
func generate(_seed_value: int = 0) -> void:
	_objective_nodes.clear()
	_enemy_exclusion_radius = 0
	# Skip _configure_noise — handcrafted maps don't use noise-driven terrain.
	# Range / slope queries are overridden below to return neutral values.
	_scan_existing_tiles()
	_bake_navigation()
	match GameManager.current_level:
		4: _spawn_fortified_structure()
		5: _spawn_escort_mission()
	var lv: int = GameManager.current_level
	if lv == 2 or lv == 4 or lv == 5:
		_spawn_mission_parent_and_fragment()
	_spawn_enemies()

# Topography is a GDScript _draw() loop that renders one polygon per tile
# every frame. At 110×100 tiles that's 11,000 draw calls/frame — too slow.
# Hand-authored maps use custom tile art that doesn't need procedural hillshade,
# so the overlay is skipped entirely.
func _spawn_topography() -> void:
	pass

# Procedural maps use elevation noise to give shooters on hills a range bonus
# and movers on slopes a speed penalty. Hand-authored maps have no elevation
# data, so both queries return neutral (1.0 = no modifier) — bullets travel
# their base distance and characters move at their base speed regardless of
# position. Override is_water_at() too if you want to disable water wading.
func get_range_modifier_at(_world_pos: Vector2) -> float:
	return 1.0

func get_slope_speed_mult(_world_pos: Vector2, _direction: Vector2) -> float:
	return 1.0

func get_elevation_at(_world_pos: Vector2) -> float:
	return 0.0

# Walks the pre-baked TileMapLayer and rebuilds _passable_cells based on
# whatever the author painted. Anything that isn't water counts as passable —
# obstacle nodes provide their own collision so they don't need to be excluded
# from the cell list (mission spawns shouldn't land inside a tree, but the
# random-position pickers retry on failure).
func _scan_existing_tiles() -> void:
	_passable_cells.clear()
	# Use water_tile_atlas if set; otherwise fall back to tile_config.water.
	# If both are (-1,-1) / unset, skip the water check entirely.
	var water_atlas: Vector2i = water_tile_atlas
	if water_atlas == Vector2i(-1, -1) and tile_config != null:
		water_atlas = tile_config.water
	for x in map_width:
		for y in map_height:
			var atlas := tile_map.get_cell_atlas_coords(Vector2i(x, y))
			if atlas == Vector2i(-1, -1):
				continue  # empty cell — not passable
			if water_atlas != Vector2i(-1, -1) and atlas == water_atlas:
				continue  # water tile — not passable
			_passable_cells.append(Vector2i(x, y))

# ===========================================================================
# EDITOR-ONLY: seed a random layout into the scene.
# ===========================================================================
func _editor_regenerate() -> void:
	if not Engine.is_editor_hint():
		return
	map_width  = Balance.MAP_HANDCRAFTED_WIDTH
	map_height = Balance.MAP_HANDCRAFTED_HEIGHT
	tile_size  = Balance.MAP_HANDCRAFTED_TILE_SIZE
	var scene_root: Node = self if owner == null else owner
	if tile_config == null:
		tile_config = TileConfig.new()
	if tile_map == null:
		tile_map = get_node_or_null("TileMapLayer_ground") as TileMapLayer
		if tile_map == null:
			tile_map = get_node_or_null("TileMapLayer") as TileMapLayer
	if tile_map == null or tile_map.tile_set == null:
		push_warning("[HandcraftedMap] No TileMapLayer_ground / tile_set — can't regenerate.")
		return

	# Wipe previously generated obstacles / walls so repeated clicks don't pile up.
	# Only deletes nodes owned by the scene root (i.e. saved as part of this scene).
	# TileMapLayer / NavigationRegion2D are kept; the tilemap gets re-filled below.
	for child in get_children():
		if child == tile_map or child == nav_region:
			continue
		if child.owner == scene_root:
			child.queue_free()

	_passable_cells.clear()
	_configure_noise(randi())
	_fill_tiles()
	_editor_spawn_obstacles(scene_root)
	_editor_spawn_boundary_walls(scene_root)
	print("[HandcraftedMap] Regenerated layout. Save the scene (Ctrl+S) to persist.")

# Mirrors MapGenerator._spawn_obstacles but sets `owner` on each spawned node
# so they're written into the .tscn when the user saves. Obstacle.gd's _ready
# is NOT @tool, so its collision-shape children won't be created in the editor
# (they're set up fresh at runtime instead — no duplicates).
func _editor_spawn_obstacles(scene_owner: Node) -> void:
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
	var tree_budget := total / 2
	var rock_budget := total - tree_budget

	var eligible_set: Dictionary = {}
	for c in eligible:
		eligible_set[c] = true

	const MIN_CLUSTER_SIZE := 5
	const MAX_CLUSTER_SIZE := 14
	var trees_placed := 0
	var seed_idx     := 0
	while trees_placed < tree_budget and seed_idx < eligible.size():
		var seed_cell: Vector2i = eligible[seed_idx]
		seed_idx += 1
		if not eligible_set.has(seed_cell):
			continue
		var remaining := tree_budget - trees_placed
		var target_size: int = mini(randi_range(MIN_CLUSTER_SIZE, MAX_CLUSTER_SIZE), remaining)
		if target_size < MIN_CLUSTER_SIZE and remaining >= MIN_CLUSTER_SIZE:
			target_size = MIN_CLUSTER_SIZE
		var cluster: Array[Vector2i] = []
		var frontier: Array[Vector2i] = [seed_cell]
		while cluster.size() < target_size and not frontier.is_empty():
			var pick: int = randi() % frontier.size()
			var cell: Vector2i = frontier[pick]
			frontier.remove_at(pick)
			if not eligible_set.has(cell):
				continue
			eligible_set.erase(cell)
			cluster.append(cell)
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = cell + off
				if eligible_set.has(n):
					frontier.append(n)
		if cluster.size() < MIN_CLUSTER_SIZE:
			for c in cluster:
				eligible_set[c] = true
			continue
		for cell in cluster:
			var tree: StaticBody2D = ObstacleClass.new()
			tree.is_tree  = true
			tree.name     = "Tree_%d_%d" % [cell.x, cell.y]
			tree.position = tile_map.map_to_local(cell)
			add_child(tree)
			tree.owner = scene_owner
			trees_placed += 1

	var rocks_placed := 0
	for cell in eligible:
		if rocks_placed >= rock_budget:
			break
		if not eligible_set.has(cell):
			continue
		eligible_set.erase(cell)
		var rock: StaticBody2D = ObstacleClass.new()
		rock.is_tree  = false
		rock.name     = "Rock_%d_%d" % [cell.x, cell.y]
		rock.position = tile_map.map_to_local(cell)
		add_child(rock)
		rock.owner = scene_owner
		rocks_placed += 1

# Mirrors MapGenerator._spawn_boundary_walls but writes the wall bodies +
# collision shapes into the scene tree with owner set so they save.
func _editor_spawn_boundary_walls(scene_owner: Node) -> void:
	var half_tile: Vector2 = Vector2(tile_size, tile_size) * 0.5
	var tl_local: Vector2 = tile_map.position + tile_map.map_to_local(Vector2i(0, 0)) - half_tile
	var br_local: Vector2 = tile_map.position + tile_map.map_to_local(Vector2i(map_width - 1, map_height - 1)) + half_tile
	var w: float = br_local.x - tl_local.x
	var h: float = br_local.y - tl_local.y
	const T := 256.0
	_editor_add_wall(scene_owner, "BoundaryWallTop",    tl_local.x - T, tl_local.y - T, w + T * 2.0, T)
	_editor_add_wall(scene_owner, "BoundaryWallBottom", tl_local.x - T, br_local.y,     w + T * 2.0, T)
	_editor_add_wall(scene_owner, "BoundaryWallLeft",   tl_local.x - T, tl_local.y,     T,           h)
	_editor_add_wall(scene_owner, "BoundaryWallRight",  br_local.x,     tl_local.y,     T,           h)

func _editor_add_wall(scene_owner: Node, name_: String, x: float, y: float, w: float, h: float) -> void:
	var body := StaticBody2D.new()
	body.name             = name_
	body.collision_layer  = 1
	body.collision_mask   = 0
	add_child(body)
	body.owner = scene_owner
	var shape := RectangleShape2D.new()
	shape.size = Vector2(w, h)
	var col := CollisionShape2D.new()
	col.shape    = shape
	col.position = Vector2(x + w * 0.5, y + h * 0.5)
	body.add_child(col)
	col.owner = scene_owner
