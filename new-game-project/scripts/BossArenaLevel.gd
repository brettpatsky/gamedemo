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

const WALL_THICKNESS:     float = 96.0
const ROOM_HEIGHT:        float = 700.0    # y bound between boss room (above) and corridor (below)
const CORRIDOR_BOTTOM_Y:  float = 900.0    # y bound between corridor (above) and outside area (below)
const CORRIDOR_HALF_W:    float = 100.0    # corridor is 200 px wide, centred horizontally

@onready var background: ColorRect          = $Background
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D
@onready var spawn_point: Node2D            = $SpawnPoint
@onready var boss: Node                     = $Boss

var _map_w_px: float = 0.0
var _map_h_px: float = 0.0

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

# =============================================================================
# MapGenerator-compatible interface — same names Main.gd / Camera / Bullet expect
# =============================================================================
func get_map_centre() -> Vector2:
	return to_global(Vector2(_map_w_px * 0.5, _map_h_px * 0.5))

func get_map_rect() -> Rect2:
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
		base = spawn_point.global_position
	else:
		base = to_global(Vector2(_map_w_px * 0.5, _map_h_px - 80.0))
	# 3-wide formation — outside area is full width, so there's room to fan out.
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

func _spawn_boundary_walls() -> void:
	const T := WALL_THICKNESS
	_add_wall(-T,        -T,         _map_w_px + 2.0 * T, T)            # top
	_add_wall(-T,        _map_h_px,  _map_w_px + 2.0 * T, T)            # bottom
	_add_wall(-T,        0.0,        T,                   _map_h_px)     # left
	_add_wall(_map_w_px, 0.0,        T,                   _map_h_px)     # right

# Carves the corridor by walling off the bottom-left and bottom-right of the
# boss room (everything outside the narrow vertical band that connects room to
# outside area). Two inner wall blocks on collision_layer 1 — bullets stop on
# them and soldiers can't squeeze past.
func _spawn_corridor_walls() -> void:
	var centre_x: float = _map_w_px * 0.5
	var corr_left:  float = centre_x - CORRIDOR_HALF_W
	var corr_right: float = centre_x + CORRIDOR_HALF_W
	var height:     float = _map_h_px - ROOM_HEIGHT
	_add_wall(0.0,        ROOM_HEIGHT, corr_left,              height)   # left wall of corridor
	_add_wall(corr_right, ROOM_HEIGHT, _map_w_px - corr_right, height)   # right wall of corridor

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

# Concave nav-mesh outline that traces the boss room → narrow corridor →
# outside area shape. Twelve vertices (clockwise from top-left). The corridor
# pinch is what forces NavigationAgent2D to thread the squad through the
# opening rather than walking through a wall.
func _bake_nav() -> void:
	if nav_region == null:
		return
	const INSET := 24.0
	var centre_x:   float = _map_w_px * 0.5
	var corr_left:  float = centre_x - CORRIDOR_HALF_W + INSET
	var corr_right: float = centre_x + CORRIDOR_HALF_W - INSET
	var left:       float = INSET
	var right:      float = _map_w_px - INSET
	var top:        float = INSET
	var room_bot:   float = ROOM_HEIGHT
	var path_bot:   float = _map_h_px - INSET

	# Inverted-T shape: wide boss room on top, narrow corridor below.
	var nav_poly := NavigationPolygon.new()
	nav_poly.add_outline(PackedVector2Array([
		nav_region.to_local(to_global(Vector2(left,        top))),
		nav_region.to_local(to_global(Vector2(right,       top))),
		nav_region.to_local(to_global(Vector2(right,       room_bot))),
		nav_region.to_local(to_global(Vector2(corr_right,  room_bot))),
		nav_region.to_local(to_global(Vector2(corr_right,  path_bot))),
		nav_region.to_local(to_global(Vector2(corr_left,   path_bot))),
		nav_region.to_local(to_global(Vector2(corr_left,   room_bot))),
		nav_region.to_local(to_global(Vector2(left,        room_bot))),
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

func _on_room_entered(body: Node2D) -> void:
	if not body.is_in_group("soldiers"):
		return
	if boss and boss.has_method("activate"):
		boss.activate()
