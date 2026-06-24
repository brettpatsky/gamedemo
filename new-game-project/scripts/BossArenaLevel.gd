# =============================================================================
# BossArenaLevel.gd  (Boss Mission — level 6)
# Root script for scenes/bosses/boss_arena.tscn. Drop-in replacement for
# MapGenerator on the boss level, matching the same public interface so
# CameraController and Main.gd treat it identically.
#
# Layout:
#   ┌─────────────────────────────────┐
#   │       Boss room (wide)          │   y = 0 .. ROOM_HEIGHT          (room)
#   │              [Boss]             │
#   ├──────────────┬──┬───────────────┤
#   │   wall       │  │     wall      │   y = ROOM_HEIGHT .. CORRIDOR_BOTTOM
#   │              │  │               │   (narrow corridor between walls)
#   ├──────────────┘  └───────────────┤
#   │                                 │   y = CORRIDOR_BOTTOM .. _map_h_px
#   │       Outside area              │   (squad spawns here)
#   └─────────────────────────────────┘
#
# The boss is DORMANT until the squad crosses into the boss-room region. A
# full-room trigger Area2D handles the activation handshake — see
# _spawn_room_trigger() below.
#
# Scene layout (edit in Godot editor):
#   BossArena (Node2D, this script)
#   ├── Background        (ColorRect — defines map extents)
#   ├── OutsideFloor      (ColorRect — visual tint for the spawn zone)
#   ├── CorridorBorder    (ColorRect — magenta glow framing the corridor)
#   ├── CorridorFloor     (ColorRect — stone tan path floor)
#   ├── NavigationRegion2D
#   ├── SpawnPoint        (Node2D, position bottom-centre of outside area)
#   └── Boss              (boss_heartstone.tscn instance, centred in room)
# =============================================================================
extends Node2D

signal boss_defeated
signal arena_locked


const WALL_THICKNESS: float = 96.0
const ROOM_HEIGHT:    float = 700.0   # boss room / approach boundary
# Serpentine path from the spawn stem (bottom) winding up into the boss room.
# The centreline is a sampled sine wave (see _build_path); PATH_HW is its
# half-width — ~300 px wide, enough for the whole 6-soldier formation to walk
# together. Collision + navmesh + cobblestone painting are all derived from the
# same polyline so they always agree (WYSIWYG).
const PATH_HW:        float = 120.0    # half-width of the walkable path (~240 px)
const PATH_AMP_FRAC:  float = 0.09     # sine amplitude as a fraction of map width
const PATH_WIND_WAVELENGTH: float = 345.0  # px per half-wind; keeps the wind frequency
										   # constant however long the approach gets
const PATH_STEM:      float = 150.0    # straight vertical run at the spawn (bottom)
# Haunted-woods + corrupted-chamber tilesets (PixelLab-generated, 32 px native).
# Each is a corner-match terrain set: terrain 0 = base ground, terrain 1 = path/dais.
const WOODS_TILESET   := "res://resources/boss/haunted_woods.tres"
const LEAVES_TILESET  := "res://resources/boss/boss_leaves.tres"
const WOODS_FOREST_TERRAIN:  int = 0   # dark haunted forest floor (approach backdrop)
const WOODS_PATH_TERRAIN:    int = 1   # pale cobblestone road (the winding Z-path)
const LEAVES_SAKURA_TERRAIN: int = 0   # fallen pink sakura petals (boss-room floor)
const LEAVES_AUTUMN_TERRAIN: int = 1   # orange/gold autumn leaf drifts (variation + hill)
const TILE_PX:         float = 32.0    # native tile size; layers drawn at scale 1.0
# Central raised mound the boss stands on. ONLY this footprint is non-walkable, so
# the squad can flank up the LEFT and RIGHT of the room — they just can't get
# behind the tree. MOUND_FRONT is the mound's lower (front) edge; MOUND_HALF_W its
# half-width about the room centre.
const MOUND_FRONT:    float = 355.0
const MOUND_HALF_W:   float = 270.0
const DEAD_TREE_TEX   := "res://resources/boss/dead_tree.png"
const FACE_TREE_TEX   := "res://resources/boss/tree_face.png"
const BONSAI_TEX      := "res://resources/boss/tree_bonsai.png"
const LAMP_TEX        := "res://resources/boss/lamp_post.png"
const CARAKA_TREE_TEX := "res://resources/caraka/Props/Tree.png"
# Caraka Tree.png cells are 32×48; summer conifers in cols 1-2, autumn in cols 3-4.
const CARAKA_TREE_REGIONS := [
	Rect2(32, 0, 32, 48), Rect2(64, 0, 32, 48),    # summer
	Rect2(96, 0, 32, 48), Rect2(128, 0, 32, 48),   # autumn
]
const GROUND_DECALS   := [
	"res://resources/boss/ground_bones.png",
	"res://resources/boss/ground_roots.png",
]
# Ambient darkness so the lantern lights actually read (haunted-woods dusk) while
# keeping the squad/path readable between the lit pools.
const ARENA_AMBIENT := Color(0.52, 0.49, 0.60)

@onready var background:      ColorRect          = $Background
@onready var nav_region:      NavigationRegion2D = $NavigationRegion2D
@onready var spawn_point:     Node2D             = $SpawnPoint
@onready var boss:            Node               = $Boss
@onready var corridor_border: ColorRect          = $CorridorBorder
@onready var corridor_floor:  ColorRect          = $CorridorFloor

var _map_w_px:         float            = 0.0
var _map_h_px:         float            = 0.0
var _path_pts:         PackedVector2Array = PackedVector2Array()  # serpentine centreline
var _path_cells:       Dictionary       = {}   # Vector2i grid cells the path covers
var _entrance_rect:    Rect2            = Rect2()  # opening where the path meets the room
var _path_layer:       TileMapLayer     = null
var _light_tex:        Texture2D        = null   # cached radial gradient for Light2Ds
var _boss_active:      bool             = false
var _soldiers_in_room: Array[Node2D]    = []

# =============================================================================
# READY
# =============================================================================
func _ready() -> void:
	add_to_group("map_generator")
	add_to_group("boss_arena")
	_compute_map_bounds()
	_compute_path_cells()
	_spawn_boundary_walls()
	_spawn_path_walls()
	_bake_nav()
	_spawn_room_trigger()
	if boss and boss.has_signal("boss_defeated"):
		boss.boss_defeated.connect(func() -> void: boss_defeated.emit())
	_paint_boss_room_floor()
	_border_boss_room()
	_add_room_lamps()
	_setup_corridor_visuals()
	# No memory fragments on level 7 — it's the final mission, nothing to carry
	# into a next run.

# Boss room floor: a forest clearing carpeted in fallen pink sakura petals, with
# drifts of autumn leaves scattered for variation and gathered into a raised mound
# (the "hill") at the top of the room where the boss stands.
func _paint_boss_room_floor() -> void:
	if not ResourceLoader.exists(LEAVES_TILESET):
		return
	var layer := TileMapLayer.new()
	layer.name = "BossFloorLayer"
	layer.tile_set = load(LEAVES_TILESET)
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layer.scale = Vector2(2.0, 2.0)   # 16 px leaf tiles → 32 px grid cells
	add_child(layer)
	move_child(layer, 1)  # just after Background, behind walls and entities

	var cols := int(ceil(_map_w_px / TILE_PX))
	var rows := int(ROOM_HEIGHT / TILE_PX)
	var sakura_cells: Array[Vector2i] = []
	for col in range(0, cols):
		for row in range(0, rows):
			sakura_cells.append(Vector2i(col, row))
	layer.set_cells_terrain_connect(sakura_cells, 0, LEAVES_SAKURA_TERRAIN, false)

	# Autumn drifts gathered into the rounded MOUND footprint at top-centre (the
	# raised ground the boss stands on) plus a few scattered patches for variation.
	var autumn: Dictionary = {}
	var mcx := (_map_w_px * 0.5) / TILE_PX
	var mrx := MOUND_HALF_W / TILE_PX
	var mry := MOUND_FRONT / TILE_PX
	for col in range(0, cols):
		for row in range(0, int(MOUND_FRONT / TILE_PX) + 1):
			var nx := (float(col) - mcx) / mrx
			var ny := float(row) / mry
			if nx * nx + ny * ny <= 1.0:
				autumn[Vector2i(col, row)] = true
	# Deliberate leaf drifts banked against the LEFT and RIGHT sides of the room so
	# both flanks read as autumn, not just the centre mound.
	var side_y := int((MOUND_FRONT + ROOM_HEIGHT) * 0.5 / TILE_PX)
	for side in [Vector2i(int(cols * 0.16), side_y), Vector2i(int(cols * 0.84), side_y)]:
		for dx in range(-6, 7):
			for dy in range(-4, 5):
				if Vector2(float(dx) / 6.0, float(dy) / 4.0).length() <= 1.0:
					autumn[Vector2i(side.x + dx, side.y + dy)] = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EA1
	for i in 9:
		var pc := Vector2i(rng.randi_range(2, cols - 3), rng.randi_range(int(MOUND_FRONT / TILE_PX) + 2, rows - 3))
		var pr := rng.randi_range(1, 3)
		for dx in range(-pr, pr + 1):
			for dy in range(-pr, pr + 1):
				if Vector2(dx, dy).length() <= float(pr) + rng.randf() * 0.6:
					autumn[Vector2i(pc.x + dx, pc.y + dy)] = true
	var autumn_cells: Array[Vector2i] = []
	for c in autumn:
		autumn_cells.append(c)
	layer.set_cells_terrain_connect(autumn_cells, 0, LEAVES_AUTUMN_TERRAIN, false)

# Frames the boss room with a wall of Caraka summer + autumn trees: a deep band
# across the top (behind the boss on the hill), full columns down both sides, and
# a row along the bottom flanking the path entrance. Decorative only.
func _border_boss_room() -> void:
	if not ResourceLoader.exists(CARAKA_TREE_TEX):
		return
	var tex: Texture2D = load(CARAKA_TREE_TEX)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x7A11
	var w := _map_w_px
	# Top band — two staggered rows so it reads as deep forest behind the boss.
	for row in 2:
		var y := 26.0 + float(row) * 58.0
		var x := 30.0 + float(row) * 32.0
		while x < w - 30.0:
			_place_caraka_tree(tex, Vector2(x, y), rng)
			x += 64.0
	# Side columns.
	var y2 := 96.0
	while y2 < ROOM_HEIGHT - 30.0:
		_place_caraka_tree(tex, Vector2(34.0, y2), rng)
		_place_caraka_tree(tex, Vector2(w - 34.0, y2), rng)
		_place_caraka_tree(tex, Vector2(78.0, y2 + 28.0), rng)
		_place_caraka_tree(tex, Vector2(w - 78.0, y2 + 28.0), rng)
		y2 += 80.0
	# Bottom row flanking the path entrance.
	var ent_l := _entrance_rect.position.x - 50.0 if _entrance_rect.size.x > 0 else w * 0.5 - 180.0
	var ent_r := _entrance_rect.end.x + 50.0 if _entrance_rect.size.x > 0 else w * 0.5 + 180.0
	var bx := 40.0
	while bx < w - 30.0:
		if bx < ent_l or bx > ent_r:
			_place_caraka_tree(tex, Vector2(bx, ROOM_HEIGHT - 28.0), rng)
		bx += 66.0

func _place_caraka_tree(tex: Texture2D, pos: Vector2, rng: RandomNumberGenerator) -> void:
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = CARAKA_TREE_REGIONS[rng.randi() % CARAKA_TREE_REGIONS.size()]
	var spr := Sprite2D.new()
	spr.texture = at
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.position = pos
	spr.scale = Vector2.ONE * rng.randf_range(2.3, 3.0)
	spr.flip_h = rng.randf() < 0.5
	spr.z_index = int(pos.y / 10.0)
	add_child(spr)

# Decrepit lamp posts around the boss room casting an eerie cold glow.
func _add_room_lamps() -> void:
	if not ResourceLoader.exists(LAMP_TEX):
		return
	var tex: Texture2D = load(LAMP_TEX)
	var cx := _map_w_px * 0.5
	# Two SMALL lamps tucked up beside the tree (it overlaps them, z below the boss),
	# plus two larger lamps lighting the lower corners of the fighting floor.
	var spots: Array[Dictionary] = [
		{"pos": Vector2(cx - 175.0, 300.0), "scale": 0.8},
		{"pos": Vector2(cx + 175.0, 300.0), "scale": 0.8},
		{"pos": Vector2(_map_w_px * 0.12, ROOM_HEIGHT - 90.0), "scale": 1.45},
		{"pos": Vector2(_map_w_px * 0.88, ROOM_HEIGHT - 90.0), "scale": 1.45},
	]
	for s in spots:
		var p: Vector2 = s["pos"]
		var sc: float = s["scale"]
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.position = p
		spr.scale = Vector2.ONE * sc
		spr.z_index = int(p.y / 10.0)   # < boss z (100) so the tree overlaps the flanking pair
		add_child(spr)
		var light := PointLight2D.new()
		light.texture = _light_texture()
		light.position = p - Vector2(0, 20.0 * sc)   # glow at the lantern head
		light.color = Color(0.45, 0.9, 0.85)         # eerie cold cyan-green
		light.energy = 0.95
		light.texture_scale = 1.0 + 0.4 * sc
		add_child(light)

# --- Play-area queries (used by the boss to keep hazards where the squad can go) ---
# The walkable fighting floor: the wide band in front of the mound.
func get_play_rect() -> Rect2:
	return Rect2(to_global(Vector2(50.0, MOUND_FRONT + 8.0)),
			Vector2(_map_w_px - 100.0, ROOM_HEIGHT - MOUND_FRONT - 40.0))

func get_combat_centre() -> Vector2:
	return to_global(Vector2(_map_w_px * 0.5, (MOUND_FRONT + ROOM_HEIGHT) * 0.5))

# True if a world point is somewhere the squad can actually stand (inside the room,
# clear of the central mound). Used to reject hazard spawns that pose no threat.
func is_in_play_area(world_pos: Vector2) -> bool:
	var l := to_local(world_pos)
	if l.x < 40.0 or l.x > _map_w_px - 40.0 or l.y < 30.0 or l.y > ROOM_HEIGHT - 30.0:
		return false
	if absf(l.x - _map_w_px * 0.5) <= MOUND_HALF_W and l.y <= MOUND_FRONT:
		return false   # on/behind the mound
	return true

# Pushes a world point into the playable area (out of the mound, inside the room).
func clamp_to_play(world_pos: Vector2) -> Vector2:
	var l := to_local(world_pos)
	l.x = clampf(l.x, 60.0, _map_w_px - 60.0)
	l.y = clampf(l.y, 50.0, ROOM_HEIGHT - 45.0)
	if absf(l.x - _map_w_px * 0.5) <= MOUND_HALF_W and l.y <= MOUND_FRONT:
		l.y = MOUND_FRONT + 24.0
	return to_global(l)

# =============================================================================
# MapGenerator-compatible interface — same names Main.gd / Camera / Bullet expect
# =============================================================================
func get_map_centre() -> Vector2:
	if _boss_active:
		return to_global(Vector2(_map_w_px * 0.5, ROOM_HEIGHT * 0.5))
	return to_global(Vector2(_map_w_px * 0.5, _map_h_px * 0.5))

func get_map_rect() -> Rect2:
	if _boss_active:
		return Rect2(to_global(Vector2.ZERO), Vector2(_map_w_px, ROOM_HEIGHT))
	return Rect2(to_global(Vector2.ZERO), Vector2(_map_w_px, _map_h_px))

func is_water_at(_world_pos: Vector2) -> bool:
	return false

func get_elevation_at(_world_pos: Vector2) -> float:
	return 0.0

func get_range_modifier_at(_world_pos: Vector2) -> float:
	return 1.0

func get_slope_speed_mult(_world_pos: Vector2, _direction: Vector2) -> float:
	return 1.0

# Squad spawns clustered in the outside area south of the corridor mouth, so
# they begin OUTSIDE the boss room and have to walk up through the passage.
func get_spawn_positions(count: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var base: Vector2
	# Spawn on the straight stem at the bottom of the serpentine (its first point).
	var sx: float = _path_pts[0].x if _path_pts.size() > 0 else _map_w_px * 0.5
	if spawn_point:
		spawn_point.position = Vector2(sx, _map_h_px - 80.0)
	base = to_global(Vector2(sx, _map_h_px - 80.0))
	# Squad spawns clustered on the stem, then walks up the winding path.
	for i in count:
		@warning_ignore("integer_division")
		var col: int = i % 3
		@warning_ignore("integer_division")
		var row: int = i / 3
		var offset := Vector2(float(col - 1) * 80.0, (float(row) - 0.5) * 80.0)
		result.append(base + offset)
	return result

func get_objective_node(key: String) -> Variant:
	if key == "boss":
		return boss
	return null

func generate(_seed_value: int = 0) -> void:
	# Boss counts as a single "enemy" so the HUD enemy counter / off-screen
	# arrow both light up while the boss is alive.
	GameManager.enemies_alive = 1
	GameManager.enemies_changed.emit(1)

# =============================================================================
# PRIVATE
# =============================================================================
func _compute_map_bounds() -> void:
	if background:
		_map_w_px = background.size.x
		_map_h_px = background.size.y
	_build_path()

# Builds the serpentine centreline: a short straight stem at the spawn (bottom),
# then a sampled sine wave winding up into the boss room. Sampling at 20 px keeps
# the polyline smooth for distance tests.
func _build_path() -> void:
	_path_pts = PackedVector2Array()
	var cx := _map_w_px * 0.5
	var amp := _map_w_px * PATH_AMP_FRAC
	var stem_to := _map_h_px - PATH_STEM      # straight run from the bottom up to here
	var top_y := ROOM_HEIGHT - 48.0           # reach a little into the room to connect
	var span := stem_to - top_y
	# Scale the number of winds with the length so the trail weaves at a constant
	# frequency no matter how long the approach is.
	var waves: float = maxf(2.0, span / PATH_WIND_WAVELENGTH)
	var y := _map_h_px
	while y > stem_to:
		_path_pts.append(Vector2(cx, y))
		y -= 20.0
	while y > top_y:
		var t := (stem_to - y) / span
		_path_pts.append(Vector2(cx + amp * sin(t * PI * waves), y))
		y -= 20.0
	_path_pts.append(Vector2(cx + amp * sin(PI * waves), top_y))

# Rasterises the path polyline to grid cells (used by collision, navmesh and the
# cobblestone painting so they always agree), and records the entrance opening
# where the path meets the room (sealed on arena lock).
func _compute_path_cells() -> void:
	_path_cells.clear()
	var cols := int(ceil(_map_w_px / TILE_PX))
	var row_lo := int(ROOM_HEIGHT / TILE_PX)
	var row_hi := int(ceil(_map_h_px / TILE_PX))
	var top_min := 1 << 30
	var top_max := -(1 << 30)
	for col in range(0, cols):
		for row in range(row_lo, row_hi):
			var centre := Vector2((col + 0.5) * TILE_PX, (row + 0.5) * TILE_PX)
			if _in_path(centre):
				_path_cells[Vector2i(col, row)] = true
				if row == row_lo:
					top_min = mini(top_min, col)
					top_max = maxi(top_max, col)
	if top_max >= top_min:
		_entrance_rect = Rect2(top_min * TILE_PX, ROOM_HEIGHT,
				(top_max - top_min + 1) * TILE_PX, TILE_PX)

func _spawn_boundary_walls() -> void:
	const T := WALL_THICKNESS
	_add_wall(-T,        -T,         _map_w_px + 2.0 * T, T)            # top (outside)
	_add_wall(-T,        _map_h_px,  _map_w_px + 2.0 * T, T)            # bottom (outside)
	_add_wall(-T,        0.0,        T,                   _map_h_px)     # left (outside)
	_add_wall(_map_w_px, 0.0,        T,                   _map_h_px)     # right (outside)
	# The decorative edge columns inside the boss room are visual-only; block them
	# so the squad can't walk into them.
	_add_wall(0.0,              0.0, T, ROOM_HEIGHT)                     # inside left edge
	_add_wall(_map_w_px - T,    0.0, T, ROOM_HEIGHT)                     # inside right edge

# Collision for the approach: every cell in the lower region that ISN'T on the
# serpentine path becomes a wall, so the forest physically funnels the squad
# along the winding cobblestone (cells merged into a few big rectangles).
func _spawn_path_walls() -> void:
	var cols := int(ceil(_map_w_px / TILE_PX))
	var row_lo := int(ROOM_HEIGHT / TILE_PX)
	var row_hi := int(ceil(_map_h_px / TILE_PX))
	var obstacles: Dictionary = {}
	for col in range(0, cols):
		for row in range(row_lo, row_hi):
			if not _path_cells.has(Vector2i(col, row)):
				obstacles[Vector2i(col, row)] = true
	for r in _merge_cells_to_rects(obstacles):
		_add_wall(r.position.x * TILE_PX, r.position.y * TILE_PX,
				r.size.x * TILE_PX, r.size.y * TILE_PX)

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

# Navmesh: the open boss room joined to the winding path. Both are fed in as
# traversable outlines (room rectangle + the merged path-cell rectangles) and
# baked from source geometry, so the agents follow the serpentine exactly.
func _bake_nav() -> void:
	if nav_region == null:
		return
	const INSET := 18.0
	var src := NavigationMeshSourceGeometryData2D.new()
	# Whole boss room is walkable (flush to ROOM_HEIGHT so it welds to the path top)…
	src.add_traversable_outline(_rect_local(
			Rect2(INSET, INSET, _map_w_px - 2.0 * INSET, ROOM_HEIGHT - INSET)))
	for r in _merge_cells_to_rects(_path_cells):
		src.add_traversable_outline(_rect_local(
				Rect2(r.position.x * TILE_PX, r.position.y * TILE_PX,
						r.size.x * TILE_PX, r.size.y * TILE_PX)))
	# …except the central mound under the boss (carved out), so the squad can flank
	# up the left and right but not get behind the tree.
	src.add_obstruction_outline(_rect_local(
			Rect2(_map_w_px * 0.5 - MOUND_HALF_W, 0.0, MOUND_HALF_W * 2.0, MOUND_FRONT)))
	var np := NavigationPolygon.new()
	np.agent_radius = 14.0
	np.cell_size = 4.0
	NavigationServer2D.bake_from_source_geometry_data(np, src)
	nav_region.navigation_polygon = np

# World-space Rect2 → nav_region-local outline (4 corners, clockwise).
func _rect_local(world: Rect2) -> PackedVector2Array:
	var p := world.position
	var s := world.size
	return PackedVector2Array([
		nav_region.to_local(to_global(p)),
		nav_region.to_local(to_global(p + Vector2(s.x, 0.0))),
		nav_region.to_local(to_global(p + s)),
		nav_region.to_local(to_global(p + Vector2(0.0, s.y))),
	])

# Greedy-merge a set of grid cells into maximal rectangles, so collision /
# navmesh use a handful of shapes instead of one per cell.
func _merge_cells_to_rects(cells: Dictionary) -> Array[Rect2i]:
	var rects: Array[Rect2i] = []
	if cells.is_empty():
		return rects
	var minx := 1 << 30
	var maxx := -(1 << 30)
	var miny := 1 << 30
	var maxy := -(1 << 30)
	for c: Vector2i in cells:
		minx = mini(minx, c.x); maxx = maxi(maxx, c.x)
		miny = mini(miny, c.y); maxy = maxi(maxy, c.y)
	var covered: Dictionary = {}
	for y in range(miny, maxy + 1):
		for x in range(minx, maxx + 1):
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
				for dx in range(rw):
					var cc := Vector2i(x + dx, ny)
					if not cells.has(cc) or covered.has(cc):
						grow = false
						break
				if grow:
					rh += 1
			for dy in range(rh):
				for dx in range(rw):
					covered[Vector2i(x + dx, y + dy)] = true
			rects.append(Rect2i(x, y, rw, rh))
	return rects

# Full-room trigger — boss stays dormant in _ready and only wakes up when the
# first soldier enters the boss room. The trigger is large (covers the whole
# room interior) so it fires no matter which part of the boundary the squad
# crosses, and idempotent — boss.activate() short-circuits after the first call.
func _spawn_room_trigger() -> void:
	var trigger := Area2D.new()
	trigger.collision_layer = 0
	trigger.collision_mask  = 2   # soldiers only
	add_child(trigger)
	var shape := RectangleShape2D.new()
	# Slightly inset from the room walls so spurious overlaps at the edge can't
	# fire before the squad has actually crossed in.
	shape.size = Vector2(_map_w_px - 80.0, ROOM_HEIGHT - 40.0)
	var cs := CollisionShape2D.new()
	cs.shape    = shape
	cs.position = Vector2(_map_w_px * 0.5, ROOM_HEIGHT * 0.5)
	trigger.add_child(cs)
	trigger.body_entered.connect(_on_room_entered)
	trigger.body_exited.connect(_on_room_exited)

func _on_room_entered(body: Node2D) -> void:
	if not body.is_in_group("soldiers"):
		return
	if not _soldiers_in_room.has(body):
		_soldiers_in_room.append(body)
	_check_all_in_room()

func _on_room_exited(body: Node2D) -> void:
	if _boss_active:
		return
	_soldiers_in_room.erase(body)

func _check_all_in_room() -> void:
	if _boss_active:
		return
	var alive_total: int = GameManager.soldiers_alive
	if alive_total <= 0:
		return
	# Rebuild list keeping only valid, living soldiers that are inside.
	var still_valid: Array[Node2D] = []
	var alive_inside: int = 0
	for s: Node2D in _soldiers_in_room:
		if not is_instance_valid(s):
			continue
		if s.has_method("is_downed") and s.is_downed():
			continue
		still_valid.append(s)
		alive_inside += 1
	_soldiers_in_room = still_valid
	if alive_inside >= alive_total:
		_lock_arena()
		if boss and boss.has_method("activate"):
			boss.activate()

func _lock_arena() -> void:
	if _boss_active:
		return
	_boss_active = true
	# Seal the path opening so the squad can't retreat back down the woods.
	if _entrance_rect.size.x > 0.0:
		_add_wall(_entrance_rect.position.x, ROOM_HEIGHT - 4.0, _entrance_rect.size.x, 24.0)
	arena_locked.emit()

func _setup_corridor_visuals() -> void:
	# Hide the old straight ColorRect corridor elements.
	if corridor_border: corridor_border.hide()
	if corridor_floor:  corridor_floor.hide()

	_paint_approach()
	_scatter_ground_detail()
	_scatter_props()
	_setup_lighting()

# Paints the whole approach (the lower region) as the haunted-woods tileset: dark
# forest floor everywhere, with the winding Z-path overpainted as the cobblestone
# road terrain so the auto-tiler blends mossy verges where the road meets the
# woods. Replaces the old flat brambles backdrop + Caraka path.
func _paint_approach() -> void:
	if not ResourceLoader.exists(WOODS_TILESET):
		return
	_path_layer = TileMapLayer.new()
	_path_layer.name = "WoodsLayer"
	_path_layer.tile_set = load(WOODS_TILESET)
	_path_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_path_layer)
	move_child(_path_layer, 1)  # after Background, behind entities

	var forest_cells: Array[Vector2i] = []
	var path_cells: Array[Vector2i] = []
	var col_max := int(ceil(_map_w_px / TILE_PX))
	var row_lo  := int(ROOM_HEIGHT / TILE_PX)
	var row_hi  := int(ceil(_map_h_px / TILE_PX))
	for col in range(0, col_max):
		for row in range(row_lo, row_hi):
			var cell := Vector2i(col, row)
			forest_cells.append(cell)
			if _path_cells.has(cell):
				path_cells.append(cell)
	_path_layer.set_cells_terrain_connect(forest_cells, 0, WOODS_FOREST_TERRAIN, false)
	_path_layer.set_cells_terrain_connect(path_cells, 0, WOODS_PATH_TERRAIN, false)

# Scatters dead trees + corrupted-mushroom clusters through the woods to either
# side of the winding path, so the approach reads as a haunted forest with depth
# instead of a flat field. Deterministic placement (fixed seed) so the layout is
# stable between runs. Props are decoration only — no collision (the corridor
# walls already constrain movement to the path).
func _scatter_props() -> void:
	var dead_tex: Texture2D = load(DEAD_TREE_TEX) if ResourceLoader.exists(DEAD_TREE_TEX) else null
	var face_tex: Texture2D = load(FACE_TREE_TEX) if ResourceLoader.exists(FACE_TREE_TEX) else null
	var bonsai_tex: Texture2D = load(BONSAI_TEX) if ResourceLoader.exists(BONSAI_TEX) else null
	# Weighted tree pool — plain dead trees overwhelmingly dominate (a real forest),
	# face trees an occasional scare, the lantern bonsai a rare glowing landmark.
	# No mushrooms — they read as out of place in the canopy.
	var tree_pool: Array = []
	if dead_tex:
		for n in 8: tree_pool.append(dead_tex)
	if face_tex:
		tree_pool.append(face_tex)
	if bonsai_tex:
		tree_pool.append(bonsai_tex)
	if tree_pool.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xB055
	const MARGIN  := 40.0    # how far a prop centre must clear the walkable path
	const MIN_DIST := 58.0   # min spacing between prop centres (dense overlap canopy)
	const BONSAI_MIN_DIST := 460.0   # keep the glowing lantern bonsai well spread out
	# Density scales with the approach length so a longer walk stays a dense forest.
	var approach: float = _map_h_px - ROOM_HEIGHT
	var max_props: int = int(200.0 * approach / 860.0)
	var tries: int = max_props * 20
	var placed: Array[Vector2] = []
	var bonsai_spots: Array[Vector2] = []
	for i in tries:
		var p := Vector2(
			rng.randf_range(40.0, _map_w_px - 40.0),
			rng.randf_range(ROOM_HEIGHT + 24.0, _map_h_px - 24.0))
		# Skip anything on (or hugging) the walkable path.
		if _dist_to_path(p) <= PATH_HW + MARGIN:
			continue
		var too_close := false
		for q in placed:
			if p.distance_to(q) < MIN_DIST:
				too_close = true
				break
		if too_close:
			continue
		placed.append(p)
		var tex: Texture2D = tree_pool[rng.randi() % tree_pool.size()]
		# A bonsai (light source) only stands if it's far from every other lantern;
		# otherwise it demotes to a plain dead tree so the glows never clump.
		if tex == bonsai_tex:
			for b in bonsai_spots:
				if p.distance_to(b) < BONSAI_MIN_DIST:
					tex = dead_tex
					break
		var spr := Sprite2D.new()
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.position = p
		spr.texture = tex
		if tex == bonsai_tex:
			# Tidy landmark — upright, consistent size, and it casts warm lantern light.
			spr.scale = Vector2.ONE * rng.randf_range(0.85, 1.05)
			bonsai_spots.append(p)
			_add_lantern_light(p)
		else:
			spr.scale = Vector2.ONE * rng.randf_range(0.8, 1.5)
			spr.flip_h = rng.randf() < 0.5   # mirror some trees for variety
		# y-sort-ish: props lower on screen draw in front of higher ones.
		spr.z_index = int(p.y / 10.0)
		add_child(spr)
		if placed.size() >= max_props:
			break

# Flat ground-detail decals (bones/leaf litter, roots/moss) scattered across the
# forest floor so it isn't a uniform tile. Drawn just above the floor and below
# the trees; decorative only.
func _scatter_ground_detail() -> void:
	var decals: Array = []
	for path in GROUND_DECALS:
		if ResourceLoader.exists(path):
			decals.append(load(path))
	if decals.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x6D0D
	const MIN_DIST := 64.0
	# Scale decal count with the approach length to keep an even ground litter.
	var approach: float = _map_h_px - ROOM_HEIGHT
	var max_decals: int = int(110.0 * approach / 860.0)
	var tries: int = max_decals * 27
	var placed: Array[Vector2] = []
	for i in tries:
		var p := Vector2(
			rng.randf_range(30.0, _map_w_px - 30.0),
			rng.randf_range(ROOM_HEIGHT + 16.0, _map_h_px - 16.0))
		if _dist_to_path(p) <= PATH_HW + 8.0:
			continue   # keep the cobblestone clean
		var too_close := false
		for q in placed:
			if p.distance_to(q) < MIN_DIST:
				too_close = true
				break
		if too_close:
			continue
		placed.append(p)
		var spr := Sprite2D.new()
		spr.texture = decals[rng.randi() % decals.size()]
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.position = p
		spr.rotation = rng.randf() * TAU
		spr.scale = Vector2.ONE * rng.randf_range(0.6, 1.1)
		spr.modulate = Color(1, 1, 1, rng.randf_range(0.55, 0.9))
		spr.z_index = 0   # above the floor layers, below the trees (z ≈ p.y/10)
		add_child(spr)
		if placed.size() >= max_decals:
			break

# Lighting: darken the whole arena to a haunted dusk (CanvasModulate) so the
# lantern bonsai actually cast warm pools of light, and give the boss room a soft
# central glow so the fight stays readable in the gloom.
func _setup_lighting() -> void:
	var cm := CanvasModulate.new()
	cm.color = ARENA_AMBIENT
	add_child(cm)
	# Big soft light over the boss room so the encounter isn't fought in the dark.
	var room_light := PointLight2D.new()
	room_light.texture = _light_texture()
	room_light.position = Vector2(_map_w_px * 0.5, ROOM_HEIGHT * 0.55)
	room_light.color = Color(0.85, 0.6, 0.95)
	room_light.energy = 0.5          # gentle fill — the pale petal floor is already bright
	room_light.texture_scale = 8.0
	add_child(room_light)
	# Focused spotlight on the boss itself (its bark is dark) so it stays the clear
	# centrepiece — kept tight/soft so it doesn't blow out the pale floor.
	var boss_light := PointLight2D.new()
	boss_light.texture = _light_texture()
	boss_light.position = (boss.position if boss else Vector2(_map_w_px * 0.5, 220.0)) + Vector2(0, 20)
	boss_light.color = Color(1.0, 0.82, 0.92)
	boss_light.energy = 1.0
	boss_light.texture_scale = 1.7
	add_child(boss_light)

# Warm flickering lantern light at a bonsai's position.
func _add_lantern_light(pos: Vector2) -> void:
	var light := PointLight2D.new()
	light.texture = _light_texture()
	light.position = pos
	light.color = Color(1.0, 0.72, 0.36)   # warm paper-lantern orange
	light.energy = 1.4
	light.texture_scale = 1.6
	add_child(light)

# Lazily build a soft radial gradient texture shared by every Light2D.
func _light_texture() -> Texture2D:
	if _light_tex:
		return _light_tex
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 256
	gt.height = 256
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	_light_tex = gt
	return _light_tex

# True if a world-space point lies within the serpentine path (within PATH_HW of
# its centreline).
func _in_path(p: Vector2) -> bool:
	return _dist_to_path(p) <= PATH_HW

# Shortest distance from a point to the path polyline.
func _dist_to_path(p: Vector2) -> float:
	var best := INF
	for i in range(_path_pts.size() - 1):
		best = minf(best, _seg_dist(p, _path_pts[i], _path_pts[i + 1]))
	return best

func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var d := ab.length_squared()
	var t := 0.0
	if d > 0.0:
		t = clampf((p - a).dot(ab) / d, 0.0, 1.0)
	return p.distance_to(a + ab * t)
