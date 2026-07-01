# =============================================================================
# CharacterRoster.gd
# The cosmetic-only cast the player can slot into their squad on the title
# screen. Picking a character for a slot swaps ONLY that soldier's in-game
# sprite (frames_dir) and its displayed name — stats, element, bullet colour
# and every other gameplay trait stay bound to the SLOT, not the character.
#
# The roster grows to twelve over time; for now it's the six kids plus "Mushy"
# (the corrupted-mushroom enemy art reused as a playable skin). A new character
# only needs a resources/<name>8/ folder with the standard 8-way strips
# (idle_/walk_/shoot_/die_ per facing) — the same layout Soldier._build_frames_
# from_dir already scans — plus one row added to ROSTER below.
# =============================================================================
class_name CharacterRoster
extends RefCounted

const ROSTER: Array = [
	{"id": "lua",     "name": "Lua",     "frames_dir": "res://resources/lua8/"},
	{"id": "cameron", "name": "Cameron", "frames_dir": "res://resources/cameron8/"},
	{"id": "siena",   "name": "Siena",   "frames_dir": "res://resources/siena8/"},
	{"id": "piper",   "name": "Piper",   "frames_dir": "res://resources/piper8/"},
	{"id": "livy",    "name": "Livy",    "frames_dir": "res://resources/livy8/"},
	{"id": "rindy",   "name": "Rindy",   "frames_dir": "res://resources/rindy8/"},
	{"id": "mushy",   "name": "Mushy",   "frames_dir": "res://resources/mushroom8/"},
]

# The character that fills a slot by default — slot i is the i-th kid, so a
# player who never opens the picker deploys the original six.
static func default_id_for_slot(slot: int) -> String:
	if slot >= 0 and slot < ROSTER.size():
		return String(ROSTER[slot]["id"])
	return String(ROSTER[0]["id"])

static func has_id(id: String) -> bool:
	for e in ROSTER:
		if String(e["id"]) == id:
			return true
	return false

static func _entry(id: String) -> Dictionary:
	for e in ROSTER:
		if String(e["id"]) == id:
			return e
	return ROSTER[0]

static func index_of(id: String) -> int:
	for i in ROSTER.size():
		if String(ROSTER[i]["id"]) == id:
			return i
	return -1

static func name_of(id: String) -> String:
	return String(_entry(id)["name"])

static func frames_dir_of(id: String) -> String:
	return String(_entry(id)["frames_dir"])

# Builds a square portrait from the first idle-down frame, auto-cropped to the
# character's opaque bounds (with a little breathing room) so any roster folder
# works without a hand-tuned atlas region. Returns null if the art is missing.
static func make_portrait(id: String) -> Texture2D:
	var path: String = frames_dir_of(id).path_join("idle_down.png")
	if not ResourceLoader.exists(path):
		return null
	var tex: Texture2D = load(path)
	if tex == null or tex.get_height() <= 0:
		return null
	var img: Image = tex.get_image()
	# Strips are horizontal rows of square frames — take just the first frame.
	var frame_h: int = img.get_height()
	var first: Image = img.get_region(Rect2i(0, 0, mini(frame_h, img.get_width()), frame_h))
	var used: Rect2i = first.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		used = Rect2i(0, 0, first.get_width(), first.get_height())
	# Pad slightly and clamp back inside the frame so the crop isn't skin-tight.
	used = used.grow(4).intersection(Rect2i(0, 0, first.get_width(), first.get_height()))
	return ImageTexture.create_from_image(first.get_region(used))
