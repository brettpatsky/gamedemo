# =============================================================================
# TutorialLevel1.gd
# Hand-authored Level 1 — six puzzles laid out in a linear corridor, each
# teaching one core control. After Puzzle 6 the squad reaches the final
# room with Kid 1's parent cage + the School Photo artifact.
#
# Layout (rooms left to right):
#   R0  Combat        — kill the three enemies in the doorway
#   R1  Grenade Wall  — staff/wand bounces; throwables break it
#   R2  Ritual Circle — Pentagram formation; 5 kids on 5 circles
#   R3  Pressure Plates — split into 3 groups, one kid per plate
#   R4  Identity Gate — only Kid 1 may stand on the marked tile
#   R5  Blood Ward    — only Sacrifice does enough damage
#   R6  Final Room    — parent cage + memory fragment
#
# Acts as a drop-in replacement for MapGenerator on Level 1; Main.gd swaps
# it in the same way it does for the maze and boss levels.
# =============================================================================
extends Node2D

const _ROCK_SCENE:            PackedScene = preload("res://scenes/mazes/maze_rock.tscn")
const _PARENT_CAGE_SCENE:     PackedScene = preload("res://scenes/parent_cage.tscn")
const _MEMORY_FRAGMENT_SCENE: PackedScene = preload("res://scenes/memory_fragment.tscn")

const TILE             := 64
const ROOM_W_TILES     := 10
const ROOM_H_TILES     := 12
const NUM_ROOMS        := 8    # 7 puzzles + final room
const WALL_THICKNESS   := 1
const DOORWAY_ROW_TOP  := 4    # interior row indices (0..ROOM_H_TILES-1)
const DOORWAY_ROW_BOT  := 7    # 4-tile gap so a 1×6 vertical line streams through

# Pre-computed half-tile counts so per-room positioning uses tidy int math.
# Bit-shift instead of `/ 2` so the compiler doesn't re-fire the
# integer-division warning at every use site after inlining the constant.
const ROOM_HALF_W_TILES := ROOM_W_TILES >> 1
const ROOM_HALF_H_TILES := ROOM_H_TILES >> 1

const MAP_W_TILES := NUM_ROOMS * (ROOM_W_TILES + WALL_THICKNESS) + WALL_THICKNESS
const MAP_H_TILES := ROOM_H_TILES + WALL_THICKNESS * 2
const MAP_W       := MAP_W_TILES * TILE
const MAP_H       := MAP_H_TILES * TILE

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
var _parent_cage:      Node = null
var _memory_fragment:  Node = null

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
	_build_walls()
	_build_rooms()
	_bake_nav()

# ---------------------------------------------------------------------------
# MapGenerator-compatible interface
# ---------------------------------------------------------------------------
func get_map_centre() -> Vector2:
	return to_global(Vector2(MAP_W * 0.5, MAP_H * 0.5))

func get_map_rect() -> Rect2:
	return Rect2(to_global(Vector2.ZERO), Vector2(MAP_W, MAP_H))

func is_water_at(_world_pos: Vector2) -> bool:
	return false

func get_range_modifier_at(_world_pos: Vector2) -> float:
	return 1.0

func get_slope_speed_mult(_world_pos: Vector2, _direction: Vector2) -> float:
	return 1.0

func get_spawn_positions(count: int) -> Array[Vector2]:
	# Spawn the squad in Room 0 in the default 3×2 formation so SquadController's
	# snap_to_formation() doesn't have to move them far afterwards.
	var room_centre := _room_centre(0)
	var formation := [
		Vector2(-80, -40), Vector2(0, -40), Vector2(80, -40),
		Vector2(-80,  40), Vector2(0,  40), Vector2(80,  40),
	]
	var out: Array[Vector2] = []
	for i in count:
		var offset: Vector2 = formation[i] if i < formation.size() else Vector2.ZERO
		out.append(to_global(room_centre + offset))
	return out

func get_objective_node(key: String) -> Variant:
	if key == "parent_cage":
		return _parent_cage
	if key == "memory_fragment":
		return _memory_fragment
	return null

func generate(_seed_value: int = 0) -> void:
	# Layout is built in _ready; nothing seed-driven here.
	pass

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
func _resize_background() -> void:
	if background == null:
		return
	background.offset_left   = 0
	background.offset_top    = 0
	background.offset_right  = MAP_W
	background.offset_bottom = MAP_H

func _build_walls() -> void:
	# Outer perimeter.
	for x in MAP_W_TILES:
		_place_wall(x, 0)
		_place_wall(x, MAP_H_TILES - 1)
	for y in MAP_H_TILES:
		_place_wall(0, y)
		_place_wall(MAP_W_TILES - 1, y)
	# Inner dividers — vertical walls between each adjacent pair of rooms,
	# with a wide doorway in the middle (DOORWAY_ROW_TOP..DOORWAY_ROW_BOT
	# inclusive — 4 tiles wide so a 1×6 vertical line can pass).
	for r in NUM_ROOMS - 1:
		var divider_x: int = 1 + (r + 1) * (ROOM_W_TILES + 1) - 1
		for y in MAP_H_TILES:
			var interior_y: int = y - 1
			if interior_y >= DOORWAY_ROW_TOP and interior_y <= DOORWAY_ROW_BOT:
				continue
			_place_wall(divider_x, y)

func _place_wall(tile_x: int, tile_y: int) -> void:
	# Dedup: perimeter and divider loops both want to occupy corners and the
	# y=0 / y=MAP_H_TILES-1 ends of every divider column. Two walls at the
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

# Returns the world-space centre of a room (interior).
func _room_centre(room_index: int) -> Vector2:
	var col_start: int = 1 + room_index * (ROOM_W_TILES + 1)
	var col_centre: float = float(col_start) + ROOM_W_TILES * 0.5
	var row_centre: float = 1.0 + ROOM_H_TILES * 0.5
	return Vector2(col_centre * TILE, row_centre * TILE)

# Returns the world-space position of (dx, dy) tiles offset from the top-left
# interior corner of the given room.
func _room_position(room_index: int, dx_tiles: int, dy_tiles: int) -> Vector2:
	var col_start: int = 1 + room_index * (ROOM_W_TILES + 1)
	return Vector2(
		(col_start + dx_tiles) * TILE + TILE * 0.5,
		(1 + dy_tiles) * TILE + TILE * 0.5,
	)

# Returns the world-space centre of the doorway between room_index and
# room_index + 1 — where the puzzle gate sits.
func _doorway_position(room_index: int) -> Vector2:
	var divider_x: int = 1 + (room_index + 1) * (ROOM_W_TILES + 1) - 1
	var centre_y_tiles: float = 1.0 + (DOORWAY_ROW_TOP + DOORWAY_ROW_BOT + 1) * 0.5
	return Vector2(divider_x * TILE + TILE * 0.5, centre_y_tiles * TILE)

func _spawn_gate(room_index: int) -> PuzzleGate:
	var gate := PuzzleGate.new()
	gate.width  = float(TILE)
	# Gate spans the full doorway so the squad can't slip past unsolved puzzles.
	gate.height = float(TILE * (DOORWAY_ROW_BOT - DOORWAY_ROW_TOP + 1))
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

# Room 0 — three enemies block the door. Movement + fire tutorial.
func _build_room_combat() -> void:
	_add_sign(_room_position(0, 1, 0),
			"1.  COMBAT\nLeft-click to move\nRight-click (held) to fire")
	var enemy_scene: PackedScene = load("res://scenes/enemy.tscn")
	if enemy_scene == null:
		return
	var positions := [
		_room_position(0, ROOM_W_TILES - 2, 2),
		_room_position(0, ROOM_W_TILES - 2, ROOM_H_TILES - 3),
		_room_position(0, ROOM_W_TILES - 2, ROOM_HALF_H_TILES),
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
func _build_room_grenade_wall() -> void:
	_add_sign(_room_position(1, 1, 0),
			"2.  THROWABLES\nPress Q or click a throwable\nBreak the heavy door")
	var wall := SpecialWall.new()
	wall.width                  = 96.0
	wall.height                 = 96.0
	wall.max_health             = 24      # two grenades or two sacrifices
	wall.min_damage_to_register = 5       # filters bullets (damage 1)
	wall.hint_text              = "Heavy Door"
	wall.position = _room_position(1, ROOM_HALF_W_TILES, ROOM_HALF_H_TILES)
	add_child(wall)

	var gate := _spawn_gate(1)
	wall.destroyed.connect(func() -> void:
		if _solved[1]:
			return
		_solved[1] = true
		gate.open()
	)

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
	# Spread three braziers across the room so the player can shoot them
	# from different angles without one shot hitting two at once.
	var elems: Array[int] = [Elements.E.FIRE, Elements.E.ICE, Elements.E.LIGHTNING]
	var col_offsets: Array[int] = [2, 5, 8]
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
func _build_room_sacrifice() -> void:
	_add_sign(_room_position(6, 1, 0),
			"7.  FINAL TRIAL\nBreak the ward with Sacrifice\nThen Revive (♥) the fallen kid")
	var wall := SpecialWall.new()
	wall.width                  = 96.0
	wall.height                 = 96.0
	wall.max_health             = 15      # sacrifice deals 15 → one-shot
	wall.min_damage_to_register = 13      # grenade deals 12 → filtered out
	wall.hint_text              = "Blood Ward — only Sacrifice breaks it"
	wall.position = _room_position(6, ROOM_HALF_W_TILES, ROOM_HALF_H_TILES)
	add_child(wall)

	var gate := _spawn_gate(6)
	wall.destroyed.connect(func() -> void:
		_final_wall_broken = true
		_try_solve_final_trial(gate)
	)
	# Any revive within this mission counts — the player has to spend their
	# one potion here because they only just got it back, and there's nowhere
	# else in the tutorial where a kid can die.
	GameManager.soldier_revived.connect(func(_s: Node) -> void:
		_final_revive_done = true
		_try_solve_final_trial(gate)
	)

func _try_solve_final_trial(gate: PuzzleGate) -> void:
	if _solved[6]:
		return
	if not _final_wall_broken or not _final_revive_done:
		return
	_solved[6] = true
	gate.open()

# Room 7 — parent cage and the School Photo artifact.
func _build_room_final() -> void:
	_add_sign(_room_position(7, 1, 0),
			"Free your parent.\nCollect the photo to keep its memory.")
	var cage: Node2D = _PARENT_CAGE_SCENE.instantiate()
	if "child_slot" in cage:
		cage.set("child_slot", 0)
	cage.position = _room_position(7, ROOM_HALF_W_TILES - 2, ROOM_HALF_H_TILES)
	add_child(cage)
	_parent_cage = cage

	var frag: Node2D = _MEMORY_FRAGMENT_SCENE.instantiate()
	if "fragment_id" in frag:
		frag.set("fragment_id", "school_photo")
	if "display_name" in frag:
		frag.set("display_name", "School Photo")
	frag.position = _room_position(7, ROOM_HALF_W_TILES + 2, ROOM_HALF_H_TILES)
	add_child(frag)
	_memory_fragment = frag

# ---------------------------------------------------------------------------
# Tutorial sign — a single-line floating instruction. Replace with proper
# in-world prop sprites once art lands.
# ---------------------------------------------------------------------------
func _add_sign(world_pos: Vector2, text: String) -> void:
	var label := Label.new()
	label.text = text
	# Render glyphs at a larger size, then scale the Control down so the on-
	# screen footprint stays roughly the same. The SubViewport upscales its
	# render with bilinear filtering — small font sizes get blurred badly,
	# so we rasterize big and shrink. Net result: sharper text, same layout.
	label.add_theme_font_size_override("font_size", 28)
	label.scale = Vector2(0.5, 0.5)
	label.position = world_pos - Vector2(80, 12)
	label.size = Vector2(440, 180)
	# Don't let signs swallow clicks — soldiers need to be able to walk
	# under them and the player needs to be able to click through them.
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Color(1, 0.95, 0.7))
	label.add_theme_color_override("font_outline_color", Color(0.1, 0.1, 0.15))
	label.add_theme_constant_override("outline_size", 5)
	add_child(label)

# ---------------------------------------------------------------------------
# Navmesh — full background as the walkable outline, with one rectangular
# hole per StaticBody2D wall (rocks + puzzle gates + special walls). Same
# pattern as MazeLevel so the squad's NavigationAgent2D can path around them.
# ---------------------------------------------------------------------------
func _bake_nav() -> void:
	if nav_region == null:
		return
	var nav_poly := NavigationPolygon.new()
	nav_poly.add_outline(PackedVector2Array([
		Vector2(0,     0),
		Vector2(MAP_W, 0),
		Vector2(MAP_W, MAP_H),
		Vector2(0,     MAP_H),
	]))
	for child in get_children():
		if not (child is StaticBody2D):
			continue
		var cs := child.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if cs == null or not (cs.shape is RectangleShape2D):
			continue
		var half: Vector2 = (cs.shape as RectangleShape2D).size * 0.5
		var c: Vector2 = (child as Node2D).position + cs.position
		nav_poly.add_outline(PackedVector2Array([
			c + Vector2(-half.x, -half.y),
			c + Vector2( half.x, -half.y),
			c + Vector2( half.x,  half.y),
			c + Vector2(-half.x,  half.y),
		]))
	nav_poly.make_polygons_from_outlines()
	nav_region.navigation_polygon = nav_poly
