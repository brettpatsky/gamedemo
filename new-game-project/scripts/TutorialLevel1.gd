# =============================================================================
# TutorialLevel1.gd
# Hand-authored Level 1 — six puzzles laid out in a vertical corridor, each
# teaching one core control. After Puzzle 6 the squad reaches the final
# room with Kid 1's parent cage + the School Photo artifact.
#
# Layout (rooms bottom to top):
#   R0  Combat        — kill the three enemies in the doorway
#   R1  Grenade Wall  — staff/wand bounces; throwables break it
#   R2  Ritual Circle — Pentagram formation; 5 kids on 5 circles
#   R3  Pressure Plates — split into 3 groups, one kid per plate
#   R4  Identity Gate — only Kid 1 may stand on the marked tile
#   R5  Elements      — fire / ice / lightning braziers
#   R6  Blood Ward    — only Sacrifice does enough damage
#   R7  Final Room    — parent cage + memory fragment
#
# Acts as a drop-in replacement for MapGenerator on Level 1; Main.gd swaps
# it in the same way it does for the maze and boss levels.
# =============================================================================
extends Node2D

const _ROCK_SCENE:    PackedScene = preload("res://scenes/mazes/maze_rock.tscn")
const _PORTAL_SCRIPT: GDScript    = preload("res://scripts/Portal.gd")

# Reaching the portal in the final room ends the tutorial (Main wires this to win).
signal portal_reached

const TILE              := 64
const ROOM_W_TILES      := 22
const ROOM_H_TILES      := 12
const NUM_ROOMS         := 8    # 7 puzzles + final room
const WALL_THICKNESS    := 1
const DOORWAY_COL_LEFT  := 9   # interior col indices (0..ROOM_W_TILES-1)
const DOORWAY_COL_RIGHT := 12  # 4-tile gap centred in the 22-tile room width

# Pre-computed half-tile counts so per-room positioning uses tidy int math.
const ROOM_HALF_W_TILES := ROOM_W_TILES >> 1   # 11
const ROOM_HALF_H_TILES := ROOM_H_TILES >> 1   # 6

const MAP_W_TILES := ROOM_W_TILES + WALL_THICKNESS * 2                              # 24
const MAP_H_TILES := NUM_ROOMS * (ROOM_H_TILES + WALL_THICKNESS) + WALL_THICKNESS   # 105
const MAP_W       := MAP_W_TILES * TILE   # 1536
const MAP_H       := MAP_H_TILES * TILE   # 6720

# --- Caraka painted background --------------------------------------------
# The trials are framed by a Caraka-tiled landscape: a tree line down the LEFT,
# a flowing stream + waterfalls down the RIGHT, and the floor itself painted with
# seasonal grass that ALTERNATES per room as the squad climbs. The playfield/walls
# are untouched; these decorative strips live just outside the playfield and the
# camera bounds are widened to frame them.
const CARAKA_TILESET := "res://resources/caraka_terrain_tileset.tres"
const CARAKA_SCALE   := 4.0   # tileset cells are 16px → 16×4 = 64 = one tutorial tile
const LEFT_STRIP_TILES  := 5  # tree border width (tutorial tiles)
const RIGHT_STRIP_TILES := 5  # stream border width
# Season per room cycles SPRING→SUMMER→FALL→WINTER going up (room 0 is the bottom).
enum Season { SPRING, SUMMER, FALL, WINTER }
# Terrain-set indices in caraka_terrain_tileset.tres (mirrors HandcraftedMap).
const SEASON_GRASS_SET := {Season.SPRING: 2, Season.SUMMER: 3, Season.FALL: 4, Season.WINTER: 5}
const WATER_TERRAIN_SET := 6
const SEASON_WATER := {Season.SPRING: 0, Season.SUMMER: 2, Season.FALL: 4, Season.WINTER: 2}
const DIRT_TERRAIN_SET := 0
# Tree.png (512×192) regions — one 32×48 tree per season (from HandcraftedMap).
const TREE_TEX := "res://resources/caraka/Props/Tree.png"
const SEASON_TREE_REGION := {
	Season.SPRING: Rect2(0, 0, 32, 48),
	Season.SUMMER: Rect2(32, 0, 32, 48),
	Season.FALL:   Rect2(96, 0, 32, 48),
	Season.WINTER: Rect2(192, 0, 32, 48),
}

@onready var background: ColorRect          = $Background
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D

# Per-puzzle solve state (kept so signal handlers can no-op on duplicate fires).
# Indices: 0=combat, 1=grenade wall, 2=formation, 3=plates, 4=identity,
# 5=elements, 6=final trial (sacrifice + revive).
var _solved: Array[bool] = [false, false, false, false, false, false, false]
var _formation_active: int = 0
var _plate_active:     int = 0
var _braziers_lit:     int = 0
# Final Trial (puzzle 6) needs BOTH the ward broken via Sacrifice AND a kid
# revived. Track each event so the gate opens regardless of which fires first.
var _final_wall_broken:  bool = false
var _final_revive_done:  bool = false
# A failed sacrifice (ward still standing) must NOT hand back a fresh charge
# right away — that let the player chain sacrifices back-to-back, downing a
# second (or third) kid before the first was ever revived, with only one
# revive potion ever in play. This flag withholds the new charge until the
# downed kid is actually revived; see _build_room_sacrifice.
var _room6_awaiting_revive_before_retry: bool = false

# Room 1's barricade can ONLY be broken by a throwable, and the squad's whole
# grenade pool is a single shared resource — a string of missed throws (or
# grenades spent on Room 0's enemies) can drain it to zero before the wall is
# down. _resupply_room1_pending debounces the watcher in _process so a single
# depletion doesn't show the modal/refill on every frame while it's waiting
# to see whether an already-airborne grenade still lands the killing blow.
var _resupply_room1_pending: bool = false

# Gate refs for the multi-zone puzzles. Storing them as members instead of
# capturing them in the per-zone signal lambdas avoids "Lambda capture
# freed" spam: once the gate is opened (fade + queue_free), any further
# state_changed emits (soldiers wandering across already-lit zones) would
# pass the freed PuzzleGate into the lambda. Member access via `self` is
# fine because nulling them is explicit.
var _formation_gate: PuzzleGate = null
var _plates_gate:    PuzzleGate = null
var _elements_gate:  PuzzleGate = null

# Dedup set for wall placement. Perimeter and divider loops would otherwise
# spawn two walls at every corner and every doorway-stub tile, producing
# coincident outlines that break the nav-polygon convex partition.
var _wall_tiles: Dictionary = {}

# References Main.gd queries via get_objective_node.
var _portal:           Node = null

# Active tutorial modal — only one open at a time.
var _active_modal: CanvasLayer = null

# Sign world positions and texts — checked in _input for proximity clicks.
var _sign_positions: Array[Vector2] = []
var _sign_texts:     Array[String]  = []

# ---------------------------------------------------------------------------
func _ready() -> void:
	add_to_group("map_generator")
	add_to_group("tutorial_level")
	_resize_background()
	# Critical: the Background ColorRect (a Control) covers the whole level
	# and would consume every mouse click before SquadController could see
	# it, so the squad can't move or fire. IGNORE lets clicks pass through.
	if background:
		background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The actual layout build happens in generate() (see below) — Main.gd awaits
	# that call before spawning the squad, whereas _ready() isn't awaited at all.

# Watches the shared grenade pool for Room 1's sake — see _resupply_room1_pending.
func _process(_delta: float) -> void:
	if _solved[1] or _resupply_room1_pending or GameManager.grenade_ammo_pool > 0:
		return
	_resupply_room1_pending = true
	_resupply_room1_throwable()

# ---------------------------------------------------------------------------
# MapGenerator-compatible interface
# ---------------------------------------------------------------------------
# Camera bounds include the decorative side strips so the tree line + stream frame
# the trials on screen.
func get_map_centre() -> Vector2:
	return to_global(Vector2(MAP_W * 0.5, MAP_H * 0.5))

func get_map_rect() -> Rect2:
	var left := float(LEFT_STRIP_TILES * TILE)
	var right := float(RIGHT_STRIP_TILES * TILE)
	return Rect2(to_global(Vector2(-left, 0)), Vector2(MAP_W + left + right, MAP_H))

func is_water_at(_world_pos: Vector2) -> bool:
	return false

func get_range_modifier_at(_world_pos: Vector2) -> float:
	return 1.0

func get_slope_speed_mult(_world_pos: Vector2, _direction: Vector2) -> float:
	return 1.0

func get_spawn_positions(count: int) -> Array[Vector2]:
	# Squad spawns in Room 0 (bottom) slightly south of centre, facing the
	# enemies that block the doorway at the north wall.
	var room_centre := _room_centre(0)
	var formation := [
		Vector2(-80,  20), Vector2(0,  20), Vector2(80,  20),
		Vector2(-80,  80), Vector2(0,  80), Vector2(80,  80),
	]
	var out: Array[Vector2] = []
	for i in count:
		var offset: Vector2 = formation[i] if i < formation.size() else Vector2.ZERO
		out.append(to_global(room_centre + offset))
	return out

func get_objective_node(key: String) -> Variant:
	if key == "portal":
		return _portal
	return null

func generate(_seed_value: int = 0) -> void:
	# Layout isn't seed-driven, but it's built here (not _ready) so Main.gd's
	# `await map_gen.generate(...)` actually waits for it. The build is spread
	# across frames so it doesn't block the main thread long enough to trip
	# Android's ANR watchdog on low-end hardware.
	_build_caraka_background()   # seasonal grass floor under everything
	await get_tree().process_frame
	_build_left_trees()          # tree line bordering the left
	_build_right_stream()        # stream + waterfalls bordering the right
	await get_tree().process_frame
	_build_walls()
	await get_tree().process_frame
	_build_rooms()
	await get_tree().process_frame
	_bake_nav()

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
func _resize_background() -> void:
	if background == null:
		return
	# Dark base behind the Caraka tiles, spanning the widened bounds (side strips).
	background.color = Color(0.08, 0.10, 0.09)
	background.z_index = -20   # sit behind the Caraka ground layers (z -12..-10)
	background.offset_left   = -float(LEFT_STRIP_TILES * TILE)
	background.offset_top    = 0
	background.offset_right  = MAP_W + float(RIGHT_STRIP_TILES * TILE)
	background.offset_bottom = MAP_H

# Season per room, in pairs going UP from the bottom (room 0): the first two rooms
# are Summer, the next two Fall, then Winter, then Spring.
func _room_season(room_index: int) -> int:
	var pairs := [Season.SUMMER, Season.FALL, Season.WINTER, Season.SPRING]
	@warning_ignore("integer_division")
	var idx: int = room_index / 2
	return pairs[idx] if idx < pairs.size() else pairs[pairs.size() - 1]

# Maps a tutorial tile-row to the season of the room that contains it, so the
# floor (and side strips) change season at each room boundary.
func _season_for_row(tile_y: int) -> int:
	for r in NUM_ROOMS:
		var top: int = _room_top_y(r) - WALL_THICKNESS    # include the divider above
		var bot: int = _room_top_y(r) + ROOM_H_TILES      # exclusive
		if tile_y >= top and tile_y < bot:
			return _room_season(r)
	return _room_season(0)

# Builds a Caraka TileMapLayer scaled so one cell == one tutorial tile (64px),
# parked below the walls and actors.
func _make_caraka_layer(ts: TileSet, z: int) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	layer.scale = Vector2(CARAKA_SCALE, CARAKA_SCALE)
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layer.z_index = z
	add_child(layer)
	return layer

# Paints the floor: a dirt base across the whole widened map, then seasonal grass
# per room band (alternating up the corridor). Cells are in tutorial-tile coords
# because the layer is scaled ×4 (16px tileset cell → 64px).
func _build_caraka_background() -> void:
	var ts: TileSet = load(CARAKA_TILESET) if ResourceLoader.exists(CARAKA_TILESET) else null
	if ts == null:
		return
	var x0: int = -LEFT_STRIP_TILES
	var x1: int = MAP_W_TILES + RIGHT_STRIP_TILES
	var ground := _make_caraka_layer(ts, -12)
	var grass  := _make_caraka_layer(ts, -11)

	var dirt_cells: Array[Vector2i] = []
	# Group grass cells by season so each band autotiles as one terrain pass.
	var grass_by_season: Dictionary = {}
	for cy in range(0, MAP_H_TILES):
		var season: int = _season_for_row(cy)
		if not grass_by_season.has(season):
			grass_by_season[season] = [] as Array[Vector2i]
		for cx in range(x0, x1):
			var cell := Vector2i(cx, cy)
			dirt_cells.append(cell)
			grass_by_season[season].append(cell)

	ground.set_cells_terrain_connect(dirt_cells, DIRT_TERRAIN_SET, 0, false)
	for season in grass_by_season:
		grass.set_cells_terrain_connect(grass_by_season[season], SEASON_GRASS_SET[season], 0, false)

# A DENSE forest forming the left border — overlapping seasonal trees from the
# left strip right up to the playfield edge, depth-sorted so the canopy reads as
# solid woodland. The invisible left edge wall is what actually blocks the squad.
func _build_left_trees() -> void:
	var tex: Texture2D = load(TREE_TEX) if ResourceLoader.exists(TREE_TEX) else null
	if tex == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var x_min: float = -float(LEFT_STRIP_TILES) * TILE
	var x_max: float = float(TILE)            # up to the interior boundary (col 1)
	var span: float = x_max - x_min
	const PER_ROW := 4                          # dense: ~4 overlapping trees every row
	var per_row: int = 2 if OS.get_name() == "Android" else PER_ROW
	for ty in range(0, MAP_H_TILES):
		var region: Rect2 = SEASON_TREE_REGION[_season_for_row(ty)]
		for k in per_row:
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = region
			var spr := Sprite2D.new()
			spr.texture = at
			spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			var sc: float = rng.randf_range(3.2, 4.8)
			spr.scale = Vector2(sc, sc)
			spr.flip_h = rng.randf() < 0.5
			spr.offset = Vector2(0, -region.size.y * 0.5)   # stand on the ground
			var fx: float = (float(k) + rng.randf_range(0.0, 1.0)) / float(per_row)
			var y: float = float(ty) * TILE + rng.randf_range(-26.0, 26.0)
			spr.position = Vector2(x_min + fx * span, y)
			spr.z_index = 1 + int(y / 16.0)   # nearer (lower) trees overlap further ones
			add_child(spr)

# The RIGHT border is a plain seasonal water stream (no waterfall — it reads wrong
# on flat ground). Water is painted from the impassable edge column out through the
# strip, themed per room band.
func _build_right_stream() -> void:
	var ts: TileSet = load(CARAKA_TILESET) if ResourceLoader.exists(CARAKA_TILESET) else null
	if ts == null:
		return
	var water := _make_caraka_layer(ts, -10)   # above the grass floor
	var water_by_season: Dictionary = {}
	for cy in range(0, MAP_H_TILES):
		var season: int = _season_for_row(cy)
		if not water_by_season.has(season):
			water_by_season[season] = [] as Array[Vector2i]
		# Include the edge column so the impassable boundary itself reads as water.
		for cx in range(MAP_W_TILES - 1, MAP_W_TILES + RIGHT_STRIP_TILES):
			water_by_season[season].append(Vector2i(cx, cy))
	for season in water_by_season:
		water.set_cells_terrain_connect(water_by_season[season], WATER_TERRAIN_SET, SEASON_WATER[season], false)

func _build_walls() -> void:
	# Top + bottom perimeter rocks (interior columns only — the LEFT edge is a dense
	# forest and the RIGHT edge is a waterfall stream, both made impassable by the
	# invisible edge walls below instead of a rock column).
	for x in range(1, MAP_W_TILES - 1):
		_place_wall(x, 0)
		_place_wall(x, MAP_H_TILES - 1)
	_build_edge_collision()
	# Inner horizontal dividers between each adjacent pair of rooms, with a
	# centred doorway (DOORWAY_COL_LEFT..DOORWAY_COL_RIGHT, 4 tiles wide).
	# Interior columns only (1..MAP_W_TILES-2) — columns 0 and MAP_W_TILES-1 are
	# already covered full-height by _build_edge_collision()'s nav outlines, and
	# a divider wall tile there would overlap that outline and fail the convex
	# partition, breaking navigation across the whole level.
	for r in NUM_ROOMS - 1:
		var divider_y: int = _room_top_y(r) - 1
		for x in range(1, MAP_W_TILES - 1):
			var interior_x: int = x - 1
			if interior_x >= DOORWAY_COL_LEFT and interior_x <= DOORWAY_COL_RIGHT:
				continue
			_place_wall(x, divider_y)

# Invisible full-height collision walls down the left + right edge columns. These
# are the actual impassable boundary; the forest (left) and waterfall (right) are
# drawn over them. _bake_nav cuts a hole per StaticBody2D, so these keep the nav
# (and the squad) inside the interior just like the old rock columns did.
func _build_edge_collision() -> void:
	_add_collision_wall(Rect2(0, 0, TILE, MAP_H))               # left edge (col 0)
	_add_collision_wall(Rect2(MAP_W - TILE, 0, TILE, MAP_H))    # right edge (last col)

func _add_collision_wall(world_rect: Rect2) -> void:
	var body := StaticBody2D.new()
	body.position = world_rect.position + world_rect.size * 0.5
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = world_rect.size
	cs.shape = shape
	body.add_child(cs)
	add_child(body)

func _place_wall(tile_x: int, tile_y: int) -> void:
	# Dedup: perimeter and divider loops both want to occupy corners and the
	# x=0 / x=MAP_W_TILES-1 ends of every divider row. Two walls at the
	# same position would write coincident nav outlines, which fails the
	# convex partition and breaks navigation entirely.
	var key := Vector2i(tile_x, tile_y)
	if _wall_tiles.has(key):
		return
	_wall_tiles[key] = true
	var rock: Node2D = _ROCK_SCENE.instantiate()
	rock.position = Vector2(
		tile_x * TILE + TILE * 0.5,
		tile_y * TILE + TILE * 0.5,
	)
	add_child(rock)

# Returns the tile-row (y) of the top-left interior corner of a room.
# Room 0 is at the bottom, room NUM_ROOMS-1 is at the top.
func _room_top_y(room_index: int) -> int:
	return 1 + (NUM_ROOMS - 1 - room_index) * (ROOM_H_TILES + WALL_THICKNESS)

# Returns the world-space centre of a room (interior).
func _room_centre(room_index: int) -> Vector2:
	var row_top := _room_top_y(room_index)
	var row_centre: float = float(row_top) + ROOM_H_TILES * 0.5
	var col_centre: float = 1.0 + ROOM_W_TILES * 0.5
	return Vector2(col_centre * TILE, row_centre * TILE)

# Returns the world-space position of (dx, dy) tiles offset from the top-left
# interior corner of the given room.
func _room_position(room_index: int, dx_tiles: int, dy_tiles: int) -> Vector2:
	var row_start := _room_top_y(room_index)
	return Vector2(
		(1 + dx_tiles) * TILE + TILE * 0.5,
		(row_start + dy_tiles) * TILE + TILE * 0.5,
	)

# Returns the world-space centre of the horizontal doorway between room_index
# and room_index + 1 (one room higher) — where the puzzle gate sits.
func _doorway_position(room_index: int) -> Vector2:
	var divider_y: int = _room_top_y(room_index) - 1
	var centre_x: float = (1.0 + float(DOORWAY_COL_LEFT + DOORWAY_COL_RIGHT) * 0.5) * TILE
	return Vector2(centre_x, divider_y * TILE + TILE * 0.5)

func _spawn_gate(room_index: int) -> PuzzleGate:
	var gate := PuzzleGate.new()
	# Gate spans the full 4-tile doorway width and one tile tall.
	gate.width  = float(TILE * (DOORWAY_COL_RIGHT - DOORWAY_COL_LEFT + 1))
	gate.height = float(TILE)
	gate.position = _doorway_position(room_index)
	add_child(gate)
	return gate

# ---------------------------------------------------------------------------
# Room builders
# ---------------------------------------------------------------------------
func _build_rooms() -> void:
	_build_room_combat()
	_build_room_grenade_wall()
	_build_room_formation()
	_build_room_pressure_plates()
	_build_room_identity()
	_build_room_elements()
	_build_room_sacrifice()
	_build_room_final()

# Room 0 — three enemies block the passage north. Movement + fire tutorial.
func _build_room_combat() -> void:
	_add_sign(_room_position(0, 1, 0),
			"1.  COMBAT\nLeft-click to move\nRight-click (held) to fire")
	var enemy_scene: PackedScene = load("res://scenes/enemy.tscn")
	if enemy_scene == null:
		return
	var positions := [
		_room_position(0, 4, 2),
		_room_position(0, ROOM_HALF_W_TILES, 2),
		_room_position(0, ROOM_W_TILES - 5, 2),
	]
	for pos in positions:
		var enemy: Node2D = enemy_scene.instantiate()
		# Tutorial targets: don't shoot back, run from the squad, and take a
		# bunch of hits so the player has time to practise aiming.
		if "dummy_mode" in enemy:
			enemy.dummy_mode = true
		if "override_max_health" in enemy:
			enemy.override_max_health = 12
		enemy.position = pos
		add_child(enemy)
	GameManager.enemies_alive = positions.size()
	GameManager.enemies_changed.emit(GameManager.enemies_alive)

	var gate := _spawn_gate(0)
	GameManager.enemies_changed.connect(func(count: int) -> void:
		if _solved[0] or count > 0:
			return
		_solved[0] = true
		gate.open()
	)

# Room 1 — special wall that ignores small-arms damage. Cycle to throwable.
const _ROOM1_SIGN_TEXT := "2.  THROWABLES\nPress Q or click a throwable\nBreak the barricade"

func _build_room_grenade_wall() -> void:
	_add_sign(_room_position(1, 1, 0), _ROOM1_SIGN_TEXT)
	var wall := SpecialWall.new()
	wall.width                  = 96.0
	wall.height                 = 96.0
	wall.max_health             = 24      # two grenades or two sacrifices
	wall.min_damage_to_register = 5       # filters bullets (damage 1)
	wall.hint_text              = "Barricade"
	wall.kind                   = "barricade"
	wall.position = _room_position(1, ROOM_HALF_W_TILES, ROOM_HALF_H_TILES)
	add_child(wall)

	var gate := _spawn_gate(1)
	wall.destroyed.connect(func() -> void:
		if _solved[1]:
			return
		_solved[1] = true
		gate.open()
	)

# Safety net for the watcher in _process: the grenade pool can hit zero from
# missed throws (or grenades spent on Room 0's enemies) before the barricade
# is down, which would otherwise permanently lock the only room that can
# teach throwables. Wait out any already-airborne grenade (ammo is spent the
# instant it's thrown, not when it lands) before judging, then top the pool
# back up and re-show the room's sign so the player can simply try again.
func _resupply_room1_throwable() -> void:
	await get_tree().create_timer(1.0).timeout
	_resupply_room1_pending = false
	if _solved[1]:
		return
	GameManager.grenade_ammo_pool = 2
	_show_tutorial_modal(_ROOM1_SIGN_TEXT)

# Room 2 — five ritual circles in a pentagon. Pentagram formation fits exactly.
func _build_room_formation() -> void:
	_add_sign(_room_position(2, 1, 0),
			"3.  FORMATION\nPress F or click a formation\nLight all 5 circles together")
	_formation_gate = _spawn_gate(2)
	var centre := _room_centre(2)
	var radius := 110.0
	for i in 5:
		var angle: float = -PI * 0.5 + float(i) * TAU / 5.0
		var zone := TriggerZone.new()
		zone.radius = 32.0
		zone.style  = TriggerZone.Style.CIRCLE
		zone.position = centre + Vector2(cos(angle), sin(angle)) * radius
		add_child(zone)
		# Member ref avoids capturing the gate — see _formation_gate doc.
		zone.state_changed.connect(func(pressed: bool) -> void:
			if _solved[2]:
				return
			_formation_active += (1 if pressed else -1)
			if _formation_active >= 5:
				_solved[2] = true
				if _formation_gate:
					_formation_gate.open()
					_formation_gate = null
		)

# Room 3 — three pressure plates spread to the corners. Split into 3 groups.
func _build_room_pressure_plates() -> void:
	_add_sign(_room_position(3, 1, 0),
			"4.  SPLIT\nPress G to add a group\n1/2/3 to select\nAll 3 plates at once")
	_plates_gate = _spawn_gate(3)
	var positions := [
		_room_position(3, 2, 2),
		_room_position(3, ROOM_W_TILES - 3, 2),
		_room_position(3, ROOM_HALF_W_TILES, ROOM_H_TILES - 3),
	]
	for pos in positions:
		var plate := TriggerZone.new()
		plate.radius = 36.0
		plate.style  = TriggerZone.Style.PLATE
		plate.position = pos
		add_child(plate)
		# Member ref avoids capturing the gate — see _plates_gate doc.
		plate.state_changed.connect(func(pressed: bool) -> void:
			if _solved[3]:
				return
			_plate_active += (1 if pressed else -1)
			if _plate_active >= 3:
				_solved[3] = true
				if _plates_gate:
					_plates_gate.open()
					_plates_gate = null
		)

# Room 4 — only Kid 1 may stand on the marked tile. No feature unlock here;
# Sacrifice + Revive get unlocked one room later (after the Elements puzzle).
func _build_room_identity() -> void:
	_add_sign(_room_position(4, 1, 0),
			"5.  IDENTITY\nOnly Kid 1 can stand on the marked tile")
	var gate := _spawn_gate(4)
	var zone := TriggerZone.new()
	zone.radius = 40.0
	zone.style  = TriggerZone.Style.IDENTITY
	zone.required_slot = 0
	zone.position = _room_position(4, ROOM_HALF_W_TILES, ROOM_HALF_H_TILES)
	add_child(zone)
	zone.state_changed.connect(func(pressed: bool) -> void:
		if _solved[4] or not pressed:
			return
		_solved[4] = true
		gate.open()
	)

# Room 5 — three element braziers in a line: Fire, Ice, Lightning. Each
# only lights when hit by a matching-element bullet. Forces the player to
# coordinate which group is firing on which brazier. Solving also unlocks
# Sacrifice + Revive for the Final Trial (one room later).
func _build_room_elements() -> void:
	_add_sign(_room_position(5, 1, 0),
			"6.  ELEMENTS\nEach kid fires Fire / Ice / Lightning\nLight every brazier with the matching element")
	_elements_gate = _spawn_gate(5)
	# Spread three braziers across the room width.
	var elems: Array[int] = [Elements.E.FIRE, Elements.E.ICE, Elements.E.LIGHTNING]
	var col_offsets: Array[int] = [4, ROOM_HALF_W_TILES, ROOM_W_TILES - 5]
	for i in 3:
		var brazier := ElementBrazier.new()
		brazier.required_element = elems[i]
		brazier.position = _room_position(5, col_offsets[i], ROOM_HALF_H_TILES)
		add_child(brazier)
		# Member ref avoids capturing the gate — see _elements_gate doc.
		brazier.lit.connect(func(_e: int) -> void:
			if _solved[5]:
				return
			_braziers_lit += 1
			if _braziers_lit >= 3:
				_solved[5] = true
				if _elements_gate:
					_elements_gate.open()
					_elements_gate = null
				_unlock_final_trial_features()
		)

# Unlocks Sacrifice (weapon) and Revive (HUD button) and announces it.
# Called when the player solves the Elements puzzle; idempotent so re-entry
# is safe.
func _unlock_final_trial_features() -> void:
	GameManager.set_sacrifice_enabled(true)
	GameManager.set_revive_enabled(true)
	# Final Trial only needs one sacrifice — capping charges keeps a stray
	# second click from emptying the squad before Revive can be tried.
	GameManager.sacrifice_charges = 1
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("show_toast"):
		hud.show_toast("SACRIFICE & REVIVE UNLOCKED",
				Color(1.0, 0.85, 0.5), 3.5)

# Room 6 — FINAL TRIAL: blood ward + revive. Player must spend a kid via
# Sacrifice to break the ward AND bring that kid back with the Revive heart.
# Either event can fire first; the gate opens when both have happened.
const _ROOM6_SIGN_TEXT := "7.  FINAL TRIAL\nBreak the ward with Sacrifice\nThen Revive (♥) the fallen kid"

func _build_room_sacrifice() -> void:
	_add_sign(_room_position(6, 1, 0), _ROOM6_SIGN_TEXT)
	var wall := SpecialWall.new()
	wall.width                  = 96.0
	wall.height                 = 96.0
	wall.max_health             = 15      # sacrifice deals 15 → one-shot
	wall.min_damage_to_register = 13      # grenade deals 12 → filtered out
	wall.hint_text              = "Blood Ward — only Sacrifice breaks it"
	wall.kind                   = "sacrifice"
	wall.position = _room_position(6, ROOM_HALF_W_TILES, ROOM_HALF_H_TILES)
	add_child(wall)

	var gate := _spawn_gate(6)
	wall.destroyed.connect(func() -> void:
		_final_wall_broken = true
		_try_solve_final_trial(gate)
	)
	# Any revive within this mission counts — the player has to spend their
	# one potion here because they only just got it back, and there's nowhere
	# else in the tutorial where a kid can die. A revive is also the gate that
	# releases a new sacrifice charge after a failed attempt — see below.
	GameManager.soldier_revived.connect(func(_s: Node) -> void:
		_final_revive_done = true
		if _room6_awaiting_revive_before_retry:
			_room6_awaiting_revive_before_retry = false
			if not _final_wall_broken and not _solved[6]:
				GameManager.sacrifice_charges = 1
				GameManager.set_sacrifice_enabled(true)
		_try_solve_final_trial(gate)
	)
	# Safety net: Sacrifice has a blast radius (Balance.SACRIFICE_RADIUS) — a
	# kid who detonates too far from the ward burns the capped charge without
	# breaking it, which would otherwise permanently soft-lock the Final Trial
	# (charges hit 0 the moment the kid is armed, sacrifice disables, no way to
	# try again). Sacrifice is the only lethal mechanic in the tutorial, so any
	# death here means an attempt was just made. Grant a revive potion (if
	# needed) and re-show the sign, but DON'T hand back a new charge yet —
	# sacrifice stays disabled (consume_sacrifice_charge already did that)
	# until the downed kid is actually revived, via _room6_awaiting_revive_
	# before_retry above. Without this gate the player could chain sacrifices
	# back-to-back, downing kid after kid with only one revive ever granted,
	# permanently losing every kid past the first.
	GameManager.soldier_died.connect(func(_s: Node) -> void:
		if _final_wall_broken or _solved[6]:
			return
		_room6_awaiting_revive_before_retry = true
		if GameManager.revive_potions <= 0:
			GameManager.revive_potions = 1
			GameManager.revives_changed.emit(GameManager.revive_potions)
		_show_tutorial_modal(_ROOM6_SIGN_TEXT)
	)

func _try_solve_final_trial(gate: PuzzleGate) -> void:
	if _solved[6]:
		return
	if not _final_wall_broken or not _final_revive_done:
		return
	_solved[6] = true
	gate.open()

# Room 7 — the exit portal. Stepping into it ends the tutorial (no parent cage or
# fragment here; the tutorial is a teaching sandbox that leads straight onward).
func _build_room_final() -> void:
	_add_sign(_room_position(7, 1, 0),
			"The way onward.\nStep into the portal to begin the journey.")
	var portal: Area2D = _PORTAL_SCRIPT.new()
	portal.kind = "tutorial"
	portal.position = _room_centre(7)
	add_child(portal)
	portal.entered.connect(func() -> void: portal_reached.emit())
	_portal = portal

# ---------------------------------------------------------------------------
# Tutorial signpost — a clickable in-world prop.  Clicks are detected in
# _input() by proximity so they fire before SquadController._unhandled_input
# consumes the left-click for squad movement.
# ---------------------------------------------------------------------------
func _add_sign(world_pos: Vector2, text: String) -> void:
	_sign_positions.append(world_pos)
	_sign_texts.append(text)

	# Sign sprite — region picks a single 16×16 tile (top-left cell of the
	# 7-col × 4-row tilesheet).  Scale 5× → 80×80 world px (≈1.25 tiles).
	var spr := Sprite2D.new()
	spr.texture = load("res://resources/caraka/Props/Sign.png")
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.region_enabled = true
	spr.region_rect = Rect2(0, 0, 16, 16)
	spr.scale = Vector2(5.0, 5.0)
	spr.position = world_pos
	add_child(spr)

	# Blinking "?" above the sign to signal it is interactive.
	var hint := Label.new()
	hint.text = "?"
	hint.position = world_pos - Vector2(12, 90)
	hint.add_theme_font_size_override("font_size", 28)
	hint.add_theme_color_override("font_color",         Color(1.0, 0.92, 0.28))
	hint.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.1))
	hint.add_theme_constant_override("outline_size", 5)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)
	var tw := create_tween().set_loops()
	tw.tween_property(hint, "modulate:a", 0.2, 0.55)
	tw.tween_property(hint, "modulate:a", 1.0, 0.55)

# Left-clicks near any sign open the modal; marking the event as handled
# prevents SquadController from also issuing a move order.
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mbe := event as InputEventMouseButton
	if not (mbe.pressed and mbe.button_index == MOUSE_BUTTON_LEFT):
		return
	if _active_modal != null:
		return   # overlay's gui_input closes the modal via call_deferred
	var world_mouse := get_global_mouse_position()
	for i in _sign_positions.size():
		if (world_mouse - _sign_positions[i]).length() < 56.0:
			_show_tutorial_modal(_sign_texts[i])
			get_viewport().set_input_as_handled()
			return

# ---------------------------------------------------------------------------
# Modal — full-screen dimmed overlay with the tutorial_modal.png background
# and the instruction text. Click anywhere to dismiss.
# ---------------------------------------------------------------------------
const _MODAL_W := 500.0
const _MODAL_H := 340.0

func _show_tutorial_modal(text: String) -> void:
	if _active_modal != null:
		return

	var vp_size := get_viewport().get_visible_rect().size

	var modal := CanvasLayer.new()
	modal.layer = 50
	_active_modal = modal
	add_child(modal)

	# Transparent overlay — catches clicks to close without dimming the game.
	var overlay := ColorRect.new()
	overlay.size = vp_size
	overlay.color = Color(0, 0, 0, 0)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			# Deferred so _active_modal is still set when _input() runs this
			# frame — stops the same click from immediately re-opening a sign.
			_close_tutorial_modal.call_deferred()
	)
	modal.add_child(overlay)

	# Panel positioned at viewport centre.
	var panel := Control.new()
	panel.size = Vector2(_MODAL_W, _MODAL_H)
	panel.position = Vector2(
		vp_size.x * 0.5 - _MODAL_W * 0.5,
		vp_size.y * 0.5 - _MODAL_H * 0.5
	)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	modal.add_child(panel)

	# Background image.
	var bg_path := "res://resources/tutorial_modal.png"
	if ResourceLoader.exists(bg_path):
		var bg := TextureRect.new()
		bg.texture = load(bg_path)
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		bg.size = Vector2(_MODAL_W, _MODAL_H)
		bg.mouse_filter = Control.MOUSE_FILTER_PASS
		panel.add_child(bg)

	# Instruction text with generous inner margins.
	const MARGIN := 52.0
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size = Vector2(_MODAL_W - MARGIN * 2, _MODAL_H - MARGIN * 2 - 24)
	lbl.position = Vector2(MARGIN, MARGIN + 8)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", Color(0.18, 0.10, 0.04))
	lbl.add_theme_color_override("font_outline_color", Color(1.0, 0.9, 0.65, 0.35))
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lbl)

	# Fade in.
	panel.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, 0.22)

func _close_tutorial_modal() -> void:
	if _active_modal == null:
		return
	_active_modal.queue_free()
	_active_modal = null


# ---------------------------------------------------------------------------
# Navmesh — full background as the walkable outline, with one rectangular
# hole per StaticBody2D wall (rocks + puzzle gates + special walls). Same
# pattern as MazeLevel so the squad's NavigationAgent2D can path around them.
# ---------------------------------------------------------------------------
func _bake_nav() -> void:
	if nav_region == null:
		return
	# Recast / source-geometry bake (the same path HandcraftedMap uses) instead of
	# the deprecated NavigationPolygon.make_polygons_from_outlines(). The latter
	# does an EXACT convex partition that fails the ENTIRE bake — leaving an empty
	# navmesh, so the squad moves randomly and enemies can't path — if any two
	# outlines so much as share an edge. The perimeter + room-divider wall spans
	# (cols 1..MAP_W_TILES-2) unavoidably touch the full-height left/right
	# edge-collision outlines (cols 0 / MAP_W_TILES-1), so convex partition can
	# never succeed here. bake_from_source_geometry_data rasterises to a grid, so
	# touching/overlapping obstructions are fine.
	var src := NavigationMeshSourceGeometryData2D.new()
	src.add_traversable_outline(PackedVector2Array([
		Vector2(0,     0),
		Vector2(MAP_W, 0),
		Vector2(MAP_W, MAP_H),
		Vector2(0,     MAP_H),
	]))
	# Merge wall tiles into contiguous horizontal spans — one obstruction per run
	# instead of one per tile (~184 individual rock tiles otherwise).
	var rows: Dictionary = {}   # tile_y -> Array[int] of tile_x
	for key: Vector2i in _wall_tiles:
		if not rows.has(key.y):
			rows[key.y] = [] as Array[int]
		rows[key.y].append(key.x)
	for tile_y: int in rows:
		var xs: Array = rows[tile_y]
		xs.sort()
		var run_start: int = xs[0]
		var prev: int = xs[0]
		for i in range(1, xs.size()):
			var x: int = xs[i]
			if x == prev + 1:
				prev = x
				continue
			src.add_obstruction_outline(_tile_span_outline(run_start, prev, tile_y))
			run_start = x
			prev = x
		src.add_obstruction_outline(_tile_span_outline(run_start, prev, tile_y))
	# Left + right edge collision columns (full map height — mirrors
	# _build_edge_collision).
	src.add_obstruction_outline(PackedVector2Array([
		Vector2(0, 0), Vector2(TILE, 0), Vector2(TILE, MAP_H), Vector2(0, MAP_H),
	]))
	src.add_obstruction_outline(PackedVector2Array([
		Vector2(MAP_W - TILE, 0), Vector2(MAP_W, 0), Vector2(MAP_W, MAP_H), Vector2(MAP_W - TILE, MAP_H),
	]))
	var np := NavigationPolygon.new()
	np.agent_radius = 10.0
	np.cell_size = 16.0 if OS.get_name() == "Android" else 4.0
	NavigationServer2D.bake_from_source_geometry_data(np, src)
	nav_region.navigation_polygon = np

func _tile_span_outline(x0: int, x1: int, tile_y: int) -> PackedVector2Array:
	var left: float   = float(x0) * TILE
	var right: float  = float(x1 + 1) * TILE
	var top: float    = float(tile_y) * TILE
	var bottom: float = top + TILE
	return PackedVector2Array([
		Vector2(left, top), Vector2(right, top), Vector2(right, bottom), Vector2(left, bottom),
	])
