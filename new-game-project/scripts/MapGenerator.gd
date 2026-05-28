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

# Subclass-controlled exclusion zone — cells within this radius of the centre
# are skipped during enemy spawn (used by the escort mission to keep the NPC's
# pocket clear of hostiles).
var _enemy_exclusion_centre: Vector2i = Vector2i.ZERO
var _enemy_exclusion_radius: int = 0

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
func get_map_centre() -> Vector2:
	@warning_ignore("integer_division")
	var centre_tile := Vector2i(map_width / 2, map_height / 2)
	return tile_map.to_global(tile_map.map_to_local(centre_tile))

func get_map_rect() -> Rect2:
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

func get_elevation_at(_world_pos: Vector2) -> float:
	return 0.0

func get_range_modifier_at(_world_pos: Vector2) -> float:
	return 1.0

func get_slope_speed_mult(_world_pos: Vector2, _direction: Vector2) -> float:
	return 1.0

# ---------------------------------------------------------------------------
# Objective lookup — subclasses store nodes in _objective_nodes during
# generate(); external systems (HUD, objective manager) read them by group.
# ---------------------------------------------------------------------------
func get_objective_node(group: String) -> Variant:
	return _objective_nodes.get(group, null)

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
		enemy.position = tile_map.map_to_local(spawn_zone[i])
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
