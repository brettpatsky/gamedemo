# =============================================================================
# TutorialLayoutMarkers.gd
# Pure visual guide for hand-painting the custom version of Mission 1.
# Mirrors TutorialLevel1.gd's room/doorway/puzzle layout as semi-transparent
# overlays with text labels, so the designer can see where each tutorial
# element belongs while painting terrain into mission_1_tutorial.tscn.
#
# No gameplay — this only draws. Delete or hide this node once the tilework
# is in place. The constants below are kept in sync with TutorialLevel1.gd
# (TILE, ROOM_W_TILES, ROOM_H_TILES, NUM_ROOMS, doorway rows).
# =============================================================================
@tool
extends Node2D

const TILE             := 64
const ROOM_W_TILES     := 10
const ROOM_H_TILES     := 12
const NUM_ROOMS        := 8
const WALL_THICKNESS   := 1
const DOORWAY_ROW_TOP  := 4
const DOORWAY_ROW_BOT  := 7

const ROOM_HALF_W_TILES := ROOM_W_TILES >> 1
const ROOM_HALF_H_TILES := ROOM_H_TILES >> 1

const MAP_W_TILES := NUM_ROOMS * (ROOM_W_TILES + WALL_THICKNESS) + WALL_THICKNESS
const MAP_H_TILES := ROOM_H_TILES + WALL_THICKNESS * 2

# Room titles + puzzle-element hints. Mirrors TutorialLevel1._build_room_*.
const ROOM_INFO := [
	{"title": "1. COMBAT",      "hint": "3 dummy enemies on right wall"},
	{"title": "2. GRENADE",     "hint": "Special wall, centre"},
	{"title": "3. FORMATION",   "hint": "5 pentagram circles"},
	{"title": "4. PLATES",      "hint": "3 pressure plates"},
	{"title": "5. IDENTITY",    "hint": "1 floor marker (Kid 1)"},
	{"title": "6. ELEMENTS",    "hint": "3 elemental braziers"},
	{"title": "7. FINAL TRIAL", "hint": "Blood ward + revive"},
	{"title": "8. FINAL ROOM",  "hint": "Parent cage + memory fragment"},
]

const WALL_COLOR  := Color(0.6, 0.4, 0.3, 0.55)
const FLOOR_COLOR := Color(0.35, 0.6, 0.35, 0.18)
const DOOR_COLOR  := Color(0.9, 0.85, 0.4, 0.6)
const ELEM_COLOR  := Color(0.4, 0.7, 1.0, 0.6)

func _ready() -> void:
	# Defer label spawning to runtime — @tool draws on the editor canvas, but
	# child Labels via _draw() would have to be rebuilt every frame. Adding
	# them as child nodes once is cleaner and survives the editor reload.
	if Engine.is_editor_hint():
		return
	_spawn_labels()

func _draw() -> void:
	# Outer perimeter floor tint so the corridor is visible against unpainted
	# background.
	var map_rect := Rect2(
		Vector2.ZERO,
		Vector2(MAP_W_TILES * TILE, MAP_H_TILES * TILE))
	draw_rect(map_rect, FLOOR_COLOR)

	# Outer walls — top, bottom, left, right strips one tile thick.
	draw_rect(Rect2(0, 0, MAP_W_TILES * TILE, TILE), WALL_COLOR)
	draw_rect(Rect2(0, (MAP_H_TILES - 1) * TILE, MAP_W_TILES * TILE, TILE), WALL_COLOR)
	draw_rect(Rect2(0, 0, TILE, MAP_H_TILES * TILE), WALL_COLOR)
	draw_rect(Rect2((MAP_W_TILES - 1) * TILE, 0, TILE, MAP_H_TILES * TILE), WALL_COLOR)

	# Inner dividers + doorways. Each divider is a vertical strip with a gap
	# in the middle for the 4-tile-wide doorway.
	for r in NUM_ROOMS - 1:
		var divider_x: int = 1 + (r + 1) * (ROOM_W_TILES + 1) - 1
		# Top stub
		var top_stub_h: int = (1 + DOORWAY_ROW_TOP) * TILE
		draw_rect(Rect2(divider_x * TILE, 0, TILE, top_stub_h), WALL_COLOR)
		# Doorway band
		var door_y: int = (1 + DOORWAY_ROW_TOP) * TILE
		var door_h: int = (DOORWAY_ROW_BOT - DOORWAY_ROW_TOP + 1) * TILE
		draw_rect(Rect2(divider_x * TILE, door_y, TILE, door_h), DOOR_COLOR)
		# Bottom stub
		var bot_y: int = (1 + DOORWAY_ROW_BOT + 1) * TILE
		var bot_h: int = MAP_H_TILES * TILE - bot_y
		draw_rect(Rect2(divider_x * TILE, bot_y, TILE, bot_h), WALL_COLOR)

	# Puzzle element marker — small circle at each room's centre.
	for r in NUM_ROOMS:
		var centre := _room_centre(r)
		draw_circle(centre, 14.0, ELEM_COLOR)

func _spawn_labels() -> void:
	# Title above each room, hint below the puzzle element marker. Spawned as
	# child Labels so they render in-game without needing a Font in _draw().
	for r in NUM_ROOMS:
		if r >= ROOM_INFO.size():
			continue
		var info: Dictionary = ROOM_INFO[r]
		var centre := _room_centre(r)
		_add_label(info["title"], centre + Vector2(-60, -110), Color(1, 0.95, 0.6))
		_add_label(info["hint"],  centre + Vector2(-70,  30), Color(0.8, 0.9, 1.0))

func _add_label(text: String, local_pos: Vector2, colour: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.position = local_pos
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.scale = Vector2(0.5, 0.5)
	lbl.add_theme_color_override("font_color", colour)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)

func _room_centre(room_index: int) -> Vector2:
	var col_start: int = 1 + room_index * (ROOM_W_TILES + 1)
	return Vector2(
		(col_start + ROOM_HALF_W_TILES) * TILE,
		(1 + ROOM_HALF_H_TILES) * TILE)
