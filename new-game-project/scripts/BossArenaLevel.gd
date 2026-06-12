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
const ROOM_HEIGHT:    float = 700.0   # boss room / corridor boundary
# Winding Z-path from the spawn strip (bottom) up into the boss room.
# Upper vertical enters the boss room at AX; a horizontal band crosses to BX;
# the lower vertical drops to the spawn point at the bottom.  PATH_HW gives a
# 300 px wide passage — enough for the whole 6-soldier formation to walk together.
const PATH_HW:    float = 160.0    # half-width of the path (5 tiles × 32 px = 320 px wide)
const PATH_AX_FRAC: float = 0.30   # upper vertical centre (boss-room entry)
const PATH_BX_FRAC: float = 0.70   # lower vertical centre (spawn exit)
const BAND_Y0:    float = 864.0    # horizontal band top  (27 × 32 — tile-aligned)
const BAND_Y1:    float = 1024.0   # horizontal band bottom (32 × 32 — tile-aligned)
const TERRAIN_TILESET := "res://resources/caraka_terrain_tileset.tres"
const PATH_SEASON_SET: int = 9     # terrain_set_9 in the Caraka tileset
const TERRAIN_PATH:    int = 2     # pavement terrain in set 9
const TILE_PX:         float = 32.0  # 16 px art × 2.0 layer scale

@onready var background:      ColorRect          = $Background
@onready var nav_region:      NavigationRegion2D = $NavigationRegion2D
@onready var spawn_point:     Node2D             = $SpawnPoint
@onready var boss:            Node               = $Boss
@onready var corridor_border: ColorRect          = $CorridorBorder
@onready var corridor_floor:  ColorRect          = $CorridorFloor

var _map_w_px:         float          = 0.0
var _map_h_px:         float          = 0.0
var _ax:               float          = 0.0   # upper vertical centre x
var _bx:               float          = 0.0   # lower vertical centre x
var _path_layer:       TileMapLayer   = null
var _boss_active:      bool           = false
var _soldiers_in_room: Array[Node2D]  = []

# =============================================================================
# READY
# =============================================================================
func _ready() -> void:
	add_to_group("map_generator")
	add_to_group("boss_arena")
	_compute_map_bounds()
	_spawn_boundary_walls()
	_spawn_corridor_walls()
	_bake_nav()
	_spawn_room_trigger()
	if boss and boss.has_signal("boss_defeated"):
		boss.boss_defeated.connect(func() -> void: boss_defeated.emit())
	_add_floor_texture()
	_setup_corridor_visuals()

func _add_floor_texture() -> void:
	var tex_path := "res://resources/boss/floor.png"
	if not ResourceLoader.exists(tex_path):
		return
	var spr := Sprite2D.new()
	spr.texture = load(tex_path)
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.position = Vector2(_map_w_px * 0.5, ROOM_HEIGHT * 0.5)
	var t := spr.texture
	spr.scale = Vector2(_map_w_px / t.get_width(), ROOM_HEIGHT / t.get_height())
	spr.z_index = 0
	add_child(spr)
	move_child(spr, 1)  # just after Background, behind walls and entities

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
	if spawn_point:
		spawn_point.position = Vector2(_bx, _map_h_px - 80.0)
	base = to_global(Vector2(_bx, _map_h_px - 80.0))
	# Squad spawns at the bottom of the lower vertical, below the winding path.
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
	_ax = _map_w_px * PATH_AX_FRAC
	_bx = _map_w_px * PATH_BX_FRAC

func _spawn_boundary_walls() -> void:
	const T := WALL_THICKNESS
	_add_wall(-T,        -T,         _map_w_px + 2.0 * T, T)            # top
	_add_wall(-T,        _map_h_px,  _map_w_px + 2.0 * T, T)            # bottom
	_add_wall(-T,        0.0,        T,                   _map_h_px)     # left
	_add_wall(_map_w_px, 0.0,        T,                   _map_h_px)     # right

# Winding Z-path collision. The lower region (ROOM_HEIGHT..map bottom) splits
# into three horizontal slabs; the walkable path occupies a different x-band in
# each, so six rectangles wall off everything to the sides of the passage.
func _spawn_corridor_walls() -> void:
	var hw := PATH_HW
	var aL := _ax - hw
	var aR := _ax + hw
	var bL := _bx - hw
	var bR := _bx + hw
	var y0 := ROOM_HEIGHT     # top slab top
	var yt := BAND_Y0         # band top
	var yb_band := BAND_Y1    # band bottom
	var yb := _map_h_px       # bottom slab bottom
	# Top slab (y0..yt): walkable only in the upper vertical [aL, aR].
	_add_wall(0.0, y0, aL,               yt - y0)
	_add_wall(aR,  y0, _map_w_px - aR,   yt - y0)
	# Band slab (yt..yb_band): walkable across [aL, bR].
	_add_wall(0.0, yt, aL,               yb_band - yt)
	_add_wall(bR,  yt, _map_w_px - bR,   yb_band - yt)
	# Bottom slab (yb_band..yb): walkable only in the lower vertical [bL, bR].
	_add_wall(0.0, yb_band, bL,             yb - yb_band)
	_add_wall(bR,  yb_band, _map_w_px - bR, yb - yb_band)

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

# Nav polygon: wide boss room on top, then the winding Z-path traced as a
# single concave outline down to the spawn strip. INSET keeps the path edges
# off the collision walls so agents don't snag.
func _bake_nav() -> void:
	if nav_region == null:
		return
	const INSET := 18.0
	var hw       := PATH_HW - INSET
	var aL := _ax - hw
	var aR := _ax + hw
	var bL := _bx - hw
	var bR := _bx + hw
	var left  := INSET
	var right := _map_w_px - INSET
	var top   := INSET
	var rbot  := ROOM_HEIGHT
	var yt    := BAND_Y0
	var yb_band := BAND_Y1
	var pbot  := _map_h_px - INSET

	# Boss room rectangle (full width) joined to the Z-path. Clockwise.
	var nav_poly := NavigationPolygon.new()
	nav_poly.add_outline(PackedVector2Array([
		nav_region.to_local(to_global(Vector2(left,  top))),
		nav_region.to_local(to_global(Vector2(right, top))),
		nav_region.to_local(to_global(Vector2(right, rbot))),
		nav_region.to_local(to_global(Vector2(aR,    rbot))),    # right edge of upper vertical
		nav_region.to_local(to_global(Vector2(aR,    yt))),      # down to band top
		nav_region.to_local(to_global(Vector2(bR,    yt))),      # along band top to lower vertical
		nav_region.to_local(to_global(Vector2(bR,    pbot))),    # down to spawn strip bottom-right
		nav_region.to_local(to_global(Vector2(bL,    pbot))),    # spawn strip bottom-left
		nav_region.to_local(to_global(Vector2(bL,    yb_band))), # up to band bottom
		nav_region.to_local(to_global(Vector2(aL,    yb_band))), # along band bottom to upper vertical
		nav_region.to_local(to_global(Vector2(aL,    rbot))),    # up left edge of upper vertical
		nav_region.to_local(to_global(Vector2(left,  rbot))),
	]))
	nav_poly.make_polygons_from_outlines()
	nav_region.navigation_polygon = nav_poly

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
	# Seal the upper vertical entrance so the squad can't retreat back out.
	_add_wall(_ax - PATH_HW, ROOM_HEIGHT, PATH_HW * 2.0, 20.0)
	arena_locked.emit()

func _setup_corridor_visuals() -> void:
	# Hide the old straight ColorRect corridor elements.
	if corridor_border: corridor_border.hide()
	if corridor_floor:  corridor_floor.hide()

	var y0 := ROOM_HEIGHT
	var yb := _map_h_px

	# Brambles backdrop — fills the entire lower region; the path tiles draw on
	# top, so brambles only show to the sides of the winding passage.
	var bram_path := "res://resources/boss/brambles.png"
	if ResourceLoader.exists(bram_path):
		var bram := Sprite2D.new()
		bram.texture = load(bram_path)
		bram.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		bram.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		bram.region_enabled = true
		# scale 2× → region in texture space is half the on-screen size; tiles the
		# 384-wide art ~2× across the map, one full height down.
		bram.region_rect = Rect2(0.0, 0.0, _map_w_px * 0.5, (yb - y0) * 0.5)
		bram.scale = Vector2(2.0, 2.0)
		bram.centered = false
		bram.position = Vector2(0.0, y0)
		bram.z_index = 0
		add_child(bram)

	_paint_path_tiles()

# Paints the winding Z-path with the Caraka "path" terrain (grass verges peer
# over the dirt path), on a 2×-scaled TileMapLayer above the brambles backdrop.
func _paint_path_tiles() -> void:
	_path_layer = TileMapLayer.new()
	_path_layer.name = "PathLayer"
	_path_layer.tile_set = load(TERRAIN_TILESET)
	_path_layer.scale = Vector2(2.0, 2.0)
	_path_layer.z_index = 0
	add_child(_path_layer)

	var path_cells: Array[Vector2i] = []
	var col_max := int(ceil(_map_w_px / TILE_PX))
	var row_lo  := int(floor(ROOM_HEIGHT / TILE_PX))
	var row_hi  := int(ceil(_map_h_px / TILE_PX))
	for col in range(0, col_max):
		for row in range(row_lo, row_hi):
			var centre := Vector2((col + 0.5) * TILE_PX, (row + 0.5) * TILE_PX)
			if _in_path(centre):
				path_cells.append(Vector2i(col, row))
	_path_layer.set_cells_terrain_connect(path_cells, PATH_SEASON_SET, TERRAIN_PATH, false)

# True if a world-space point lies inside the walkable Z-path.
func _in_path(p: Vector2) -> bool:
	var hw := PATH_HW
	var in_upper := p.x >= _ax - hw and p.x <= _ax + hw and p.y >= ROOM_HEIGHT and p.y <= BAND_Y1
	var in_lower := p.x >= _bx - hw and p.x <= _bx + hw and p.y >= BAND_Y0 and p.y <= _map_h_px
	var in_band  := p.x >= _ax - hw and p.x <= _bx + hw and p.y >= BAND_Y0 and p.y <= BAND_Y1
	return in_upper or in_lower or in_band
