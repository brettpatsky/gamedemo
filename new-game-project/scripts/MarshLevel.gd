# =============================================================================
# MarshLevel.gd  (level 7 — Blighted Marsh)
# A dark, night-time EXPLORATION level. The map is a toxic swamp: poison-blight
# pools (slow + HP tick) sprawl across it, dead trees and totems loom, and the
# only way forward is a PORTAL hidden somewhere in the gloom — find it to win.
# Because the win is the portal (not a parent rescue), the level is always
# winnable no matter which kids are alive.
#
# Visibility is the core challenge: a CanvasModulate drops the whole map to
# night, so the squad can only see by the small light each member carries (added
# by Main on night levels) plus scattered lantern/totem beacons. A parent cave is
# hidden too — freeing the parent is an OPTIONAL bonus, not required to progress.
#
# Reuses: HandcraftedMap terrain/nav, the hidden cave (parent), the blight query
# Soldier reads each frame (is_blight_at, mirroring is_water_at), and LightingUtil.
# =============================================================================
@tool
extends HandcraftedMap
class_name MarshLevel

const LightingUtil = preload("res://scripts/LightingUtil.gd")
const _PORTAL_SCRIPT := preload("res://scripts/Portal.gd")
const _BONSAI_TEX    := "res://resources/boss/tree_bonsai.png"
const _LAMP_TEX      := "res://resources/boss/lamp_post.png"
# PixelLab-generated toxic-swamp Wang tileset: the raw 4×4 spritesheet (16 corner
# tiles, 32px) + its metadata. We paint it by hand (set_cell with a corner lookup)
# rather than Godot's terrain solver, which the generated set doesn't fully satisfy.
const _SWAMP_SHEET := "res://resources/swamp/swamp_image.png"
const _SWAMP_META  := "res://resources/swamp/swamp_metadata.json"

# Night ambient — deep, sickly blue-green so lights read as pools in the murk.
const NIGHT_AMBIENT := Color(0.17, 0.22, 0.20)

# Reaching the portal wins. Main connects this for level 7.
signal portal_reached

# Cells flagged as poison blight (slow + HP tick on soldiers; enemies ignore it).
var _blight_cells: Dictionary = {}

func generate(seed_value: int = 0) -> void:
	# Base builds terrain + nav + collision + light guards (our _spawn_enemies
	# override). For level 7 it spawns no parent, so we add the cave + portal here.
	@warning_ignore("redundant_await")
	await super.generate(seed_value)
	_build_blight(seed_value)
	_paint_swamp()                         # full-map toxic swamp skin; hides the Caraka tiles
	_spawn_mission_parent_and_fragment()   # hidden parent (OPTIONAL) + fragments
	_spawn_portal(seed_value)              # the win — hidden in the dark
	_setup_night_lighting(seed_value)

# Flat swamp — no plateaus/cliffs. Keeps it a pure exploration level and stops
# Caraka cliff tiles from poking through. Overrides the tiered heightmap so every
# cell is ground level (which makes _carve_stairs / _paint_cliffs no-ops).
func _build_tier_grid() -> void:
	_tier_grid.clear()
	_cliff_cells.clear()
	for x in map_width:
		for y in map_height:
			_tier_grid[Vector2i(x, y)] = 0

# Main checks this to give each squad member a personal light on dark levels.
func is_night_level() -> bool:
	return true

# No Caraka props in the swamp — the tree/rock sprites don't read at night and
# clashed with the toxic-ground tiles. Overriding the placement skips them
# entirely (also leaves the nav fully open).
func _place_props(_seed_value: int) -> void:
	pass

# Light guard presence — the swamp + the dark are the real obstacles, not a mob
# fight. These don't gate the win (finding the portal does).
func _spawn_enemies() -> void:
	var enemy_scene: PackedScene = load("res://scenes/enemy.tscn")
	if enemy_scene == null:
		return
	var cells: Array = _passable_cells.filter(func(c: Vector2i) -> bool:
		if c.x < 2 or c.x > map_width - 3 or c.y < 2 or c.y > map_height - 3:
			return false
		var cx := float(c.x) / map_width
		var cy := float(c.y) / map_height
		return not (cx > 0.36 and cx < 0.64 and cy > 0.36 and cy < 0.64)  # keep squad spawn clear
	)
	cells.shuffle()
	var n: int = mini(Balance.MARSH_GUARD_COUNT, cells.size())
	GameManager.enemies_alive = n
	GameManager.enemies_changed.emit(n)
	for i in n:
		var e: Node2D = enemy_scene.instantiate()
		e.position = _tile_to_world(cells[i])
		add_child(e)

# Flags blight cells from a noise field over the open ground, keeping the central
# squad-spawn island clear. The pools are RENDERED by _paint_swamp (toxic-water
# tiles); here we just record the cells (for is_blight_at) and drop a handful of
# faint green glows so a few pools read from a distance in the dark.
func _build_blight(seed_value: int) -> void:
	_blight_cells.clear()
	var noise := FastNoiseLite.new()
	noise.seed = (seed_value if seed_value != 0 else 12345) + 5150
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.06
	noise.fractal_octaves = 3

	for c: Vector2i in _passable_cells:
		var cx := float(c.x) / map_width
		var cy := float(c.y) / map_height
		if cx > 0.36 and cx < 0.64 and cy > 0.36 and cy < 0.64:
			continue  # squad spawn island stays safe
		if noise.get_noise_2d(float(c.x), float(c.y)) <= Balance.MARSH_BLIGHT_THRESHOLD:
			continue
		_blight_cells[c] = true

	# Sparse sickly-green glows over some pools so the hazard reads in the gloom.
	var keys: Array = _blight_cells.keys()
	keys.shuffle()
	for i in mini(10, keys.size()):
		var light := LightingUtil.make_light(Color(0.45, 0.95, 0.4), 0.6, 1.0)
		light.position = _tile_to_world(keys[i])
		add_child(light)

# Lays the PixelLab toxic-swamp tileset over the walkable ground on its own layer:
# muddy ground on land, toxic acid water on blight cells, with shoreline tiles
# blending between them. Hand-painted (set_cell) using a corner→tile lookup built
# from the tileset metadata. Painted only on passable cells so the Caraka cliffs
# (collision) still show through unpainted.
func _paint_swamp() -> void:
	var tex: Texture2D = load(_SWAMP_SHEET) if ResourceLoader.exists(_SWAMP_SHEET) else null
	var wang: Dictionary = _load_wang_lookup()   # corner-bits → atlas Vector2i
	if tex == null or wang.is_empty():
		return
	# Hide the Caraka tile layers so ONLY the swamp shows — no stray dirt/grass.
	for n in ["TileMapLayer_ground", "TileMapLayer_objects", "TileMapLayer_Overlay",
			"TileMapLayer_cliff", "TileMapLayer_plateau", "TileMapLayer_block",
			"TileMapLayer_reference"]:
		var lyr := get_node_or_null(n) as CanvasItem
		if lyr:
			lyr.visible = false

	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile_size, tile_size)
	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = Vector2i(tile_size, tile_size)
	for key in wang.values():
		if not src.has_tile(key):
			src.create_tile(key)
	var sid: int = ts.add_source(src)
	var layer := TileMapLayer.new()
	layer.name = "SwampGround"
	layer.tile_set = ts
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layer.z_index = -10   # below the actors (enemies/soldiers at z 0) so they aren't buried
	add_child(layer)
	# Paint the WHOLE map so no Caraka shows through: muddy ground everywhere, toxic
	# water on the blight cells, with the shoreline tiles blending between them.
	for x in map_width:
		for y in map_height:
			var c := Vector2i(x, y)
			var nw := 0 if _vertex_is_water(c.x,     c.y)     else 1
			var ne := 0 if _vertex_is_water(c.x + 1, c.y)     else 1
			var sw := 0 if _vertex_is_water(c.x,     c.y + 1) else 1
			var se := 0 if _vertex_is_water(c.x + 1, c.y + 1) else 1
			var key: int = (nw << 3) | (ne << 2) | (sw << 1) | se
			if wang.has(key):
				layer.set_cell(c, sid, wang[key])

# A grid vertex is "water" if any cell touching it is blight — so pools render
# with a half-cell muddy shoreline rather than hard square edges.
func _vertex_is_water(vx: int, vy: int) -> bool:
	return _blight_cells.has(Vector2i(vx - 1, vy - 1)) \
		or _blight_cells.has(Vector2i(vx,     vy - 1)) \
		or _blight_cells.has(Vector2i(vx - 1, vy)) \
		or _blight_cells.has(Vector2i(vx,     vy))

# Builds {corner-bit-key → atlas coords} from the tileset metadata. Key bit order
# matches _paint_swamp: (NW<<3)|(NE<<2)|(SW<<1)|SE, 1 = upper (mud), 0 = lower.
func _load_wang_lookup() -> Dictionary:
	var out: Dictionary = {}
	if not FileAccess.file_exists(_SWAMP_META):
		return out
	var txt := FileAccess.get_file_as_string(_SWAMP_META)
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		return out
	var tiles: Variant = data.get("tileset_data", {}).get("tiles", [])
	if typeof(tiles) != TYPE_ARRAY:
		return out
	for t in tiles:
		var corners: Dictionary = t.get("corners", {})
		var bb: Dictionary = t.get("bounding_box", {})
		if corners.is_empty() or bb.is_empty():
			continue
		var nw := 1 if corners.get("NW", "lower") == "upper" else 0
		var ne := 1 if corners.get("NE", "lower") == "upper" else 0
		var sw := 1 if corners.get("SW", "lower") == "upper" else 0
		var se := 1 if corners.get("SE", "lower") == "upper" else 0
		var key: int = (nw << 3) | (ne << 2) | (sw << 1) | se
		@warning_ignore("integer_division")
		var atlas := Vector2i(int(bb.get("x", 0)) / tile_size, int(bb.get("y", 0)) / tile_size)
		out[key] = atlas
	return out

# Mirrors is_water_at: true when the given world point sits on a blighted cell.
# Queried every physics frame by Soldier to apply the slow + damage tick.
func is_blight_at(world_pos: Vector2) -> bool:
	if _blight_cells.is_empty() or tile_map == null:
		return false
	var cell: Vector2i = tile_map.local_to_map(tile_map.to_local(world_pos))
	return _blight_cells.has(cell)

# The escape portal — the WIN. Placed on a far, non-blight passable cell well away
# from the squad's spawn so it has to be hunted down in the dark.
func _spawn_portal(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = (seed_value if seed_value != 0 else 999) + 4242
	var candidates: Array = _passable_cells.filter(func(c: Vector2i) -> bool:
		if _blight_cells.has(c):
			return false
		if c.x < 4 or c.x > map_width - 5 or c.y < 4 or c.y > map_height - 5:
			return false
		var cx := float(c.x) / map_width
		var cy := float(c.y) / map_height
		# Far ring only — keep it out of the central spawn band.
		return cx < 0.22 or cx > 0.78 or cy < 0.22 or cy > 0.78
	)
	if candidates.is_empty():
		candidates = _passable_cells.duplicate()
	if candidates.is_empty():
		return
	var cell: Vector2i = candidates[rng.randi() % candidates.size()]
	var portal: Area2D = _PORTAL_SCRIPT.new()
	portal.position = _tile_to_world(cell)
	add_child(portal)
	portal.entered.connect(func() -> void: portal_reached.emit())
	_objective_nodes["portal"] = portal

# Night: darken everything (CanvasModulate) so the squad's own lights matter, then
# scatter a few warm lantern beacons (bonsai / lamp posts) across the swamp as
# distant pools of light to navigate toward.
func _setup_night_lighting(seed_value: int) -> void:
	var cm := CanvasModulate.new()
	cm.color = NIGHT_AMBIENT
	add_child(cm)

	var bonsai_tex: Texture2D = load(_BONSAI_TEX) if ResourceLoader.exists(_BONSAI_TEX) else null
	var lamp_tex: Texture2D   = load(_LAMP_TEX) if ResourceLoader.exists(_LAMP_TEX) else null
	var rng := RandomNumberGenerator.new()
	rng.seed = (seed_value if seed_value != 0 else 11) + 8080
	var cells: Array = _passable_cells.filter(func(c: Vector2i) -> bool:
		if _blight_cells.has(c):
			return false
		return c.x >= 5 and c.x < map_width - 5 and c.y >= 5 and c.y < map_height - 5
	)
	cells.shuffle()
	var count: int = mini(10, cells.size())
	for i in count:
		var pos: Vector2 = _tile_to_world(cells[i])
		var use_bonsai: bool = (i % 2 == 0 and bonsai_tex != null)
		var tex: Texture2D = bonsai_tex if use_bonsai else lamp_tex
		if tex:
			var spr := Sprite2D.new()
			spr.texture = tex
			spr.position = pos
			spr.z_index = 3
			spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			# Both are landmarks in the dark — render them large and readable.
			var target_h := float(tile_size) * (6.0 if use_bonsai else 4.5)
			var s := target_h / float(maxi(tex.get_height(), 1))
			spr.scale = Vector2(s, s)
			# Anchor tall sprites by their base so they sit on the ground, not centred.
			spr.offset = Vector2(0, -float(tex.get_height()) * 0.5)
			add_child(spr)
		var light := LightingUtil.make_light(Color(1.0, 0.72, 0.36), 1.2, 1.6)
		light.position = pos + Vector2(0, -14)
		add_child(light)
