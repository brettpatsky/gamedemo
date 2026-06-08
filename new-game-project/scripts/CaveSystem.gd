# =============================================================================
# CaveSystem.gd
# A hidden cave per level. The level's captured parent is no longer dropped at a
# random world cell — instead it's hidden in an underground fairy garden reached
# through a cave mouth set into a plateau wall.
#
# How it works:
#   - A cave-entrance sprite + trigger Area2D sit at the foot of a plateau's
#     south wall (built by HandcraftedMap, which knows where the plateaus are).
#   - A separate "cave area" (fairy-garden backdrop + boundary walls + the parent
#     cage + an exit) is built FAR off the playfield, in the same viewport/world
#     space as the squad.
#   - Walking a soldier into the entrance teleports the whole squad into the cave,
#     locks the camera onto it and freezes the world combat. Stepping on the exit
#     reverses it. The parent cage is the level's real `parent_cage` objective, so
#     Main's existing wiring (toast + RunState) just works.
# =============================================================================
extends Node2D
class_name CaveSystem

const CAVE_PARENT_SCRIPT := preload("res://scripts/CaveParent.gd")
const CAVE_ENTRANCE_TEX := "res://resources/caves/cave_entrance.png"
const CAVE_GARDEN_TEX   := "res://resources/caves/cave_garden.png"

# Cave area is parked this far to the right of the playfield so the squad's
# teleport never overlaps the map's boundary walls or terrain.
const CAVE_GAP := 1200.0
const GARDEN_SCALE := 5.0          # 256×144 art → 1280×720 (16:9) walkable garden
const PATH_HALF := 84.0            # half-width of the walkable path corridor (world px)
const REVEAL_DIST := 360.0         # squad distance at which the hidden mouth fades in

var parent_cage: Node2D            # the parent NPC, registered as the "parent_cage" objective
var nav_outline_world: PackedVector2Array   # path corridor, baked into the map navmesh

var _entrance_world: Vector2       # squad return point (just outside the cave mouth)
var _cave_spawn: Vector2           # where the squad lands inside the cave
var _cave_rect: Rect2              # camera clamp rect for the cave (== garden, 16:9)
var _map_rect: Rect2               # camera clamp rect for the world
var _in_cave := false
var _busy := false                 # debounce during a fade/teleport
var _armed := true                 # triggers disabled briefly after a transition
var _fade: ColorRect
var _mouth_visual: Node2D          # cave mouth art (faded in by proximity)
var _entrance_area: Area2D
var _exit_area: Area2D
var _dwell := 0.0                  # how long the squad has lingered on the active trigger
const DWELL_TIME := 0.7            # must linger this long to cross — stops accidental brush-bys

# Build the entrance at `entrance_world` (foot of a south wall) and the cave area
# off-playfield. `child_slot` is which kid's parent waits inside.
func setup(entrance_world: Vector2, child_slot: int, map_rect: Rect2) -> void:
	_entrance_world = entrance_world
	_map_rect = map_rect

	_build_entrance()
	_build_cave_area(child_slot)
	_build_fade()

# ---------------------------------------------------------------------------
func _build_entrance() -> void:
	# _entrance_world is the walkable FOOT of the wall (also the squad's return
	# point). The mouth art sits up on the wall face; it stays hidden until the
	# squad gets close (proximity fade-in in _process).
	_mouth_visual = Node2D.new()
	_mouth_visual.name = "CaveMouth"
	_mouth_visual.position = _entrance_world + Vector2(0, -58)
	_mouth_visual.modulate = Color(1, 1, 1, 0)   # start hidden
	add_child(_mouth_visual)

	# Solid black opening behind the rocky ring so you see a dark cave, not the wall.
	var hole := Polygon2D.new()
	hole.color = Color(0.015, 0.01, 0.03)
	hole.polygon = _ellipse_points(22.0, 30.0, 20)
	hole.position = Vector2(0, 3)
	hole.z_index = 0
	hole.z_as_relative = false
	_mouth_visual.add_child(hole)

	var ent := Sprite2D.new()
	ent.scale = Vector2(1.35, 1.35)
	ent.z_index = 1
	ent.z_as_relative = false
	if ResourceLoader.exists(CAVE_ENTRANCE_TEX):
		ent.texture = load(CAVE_ENTRANCE_TEX)
	_mouth_visual.add_child(ent)

	var area := Area2D.new()
	area.name = "CaveEntranceTrigger"
	area.position = _entrance_world                    # at the walkable foot of the mouth
	area.collision_mask = 0
	area.set_collision_mask_value(2, true)             # detect soldiers (layer 2)
	var cs := CollisionShape2D.new()
	var sh := CircleShape2D.new()
	sh.radius = 30.0                                   # small — must be deliberately stood on
	cs.shape = sh
	area.add_child(cs)
	add_child(area)
	_entrance_area = area

# Fade the cave mouth in/out by proximity, and require the squad to LINGER on a
# trigger (not just brush it) before crossing — so the cave isn't entered by
# accident when pathing past the mouth.
func _process(delta: float) -> void:
	if _mouth_visual:
		var target := 0.0
		if not _in_cave:
			var nearest := INF
			for s in get_tree().get_nodes_in_group("soldiers"):
				nearest = minf(nearest, (s as Node2D).global_position.distance_to(_entrance_world))
			if nearest <= REVEAL_DIST:
				target = 1.0
		_mouth_visual.modulate.a = lerpf(_mouth_visual.modulate.a, target, clampf(delta * 5.0, 0.0, 1.0))

	if _busy or not _armed:
		_dwell = 0.0
		return
	var area: Area2D = _exit_area if _in_cave else _entrance_area
	if area == null:
		return
	var touching := false
	for b in area.get_overlapping_bodies():
		if (b as Node).is_in_group("soldiers"):
			touching = true
			break
	if touching:
		_dwell += delta
		if _dwell >= DWELL_TIME:
			_dwell = 0.0
			_transition(not _in_cave)
	else:
		_dwell = 0.0

func _ellipse_points(rx: float, ry: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		pts.append(Vector2(cos(a) * rx, sin(a) * ry))
	return pts

# ---------------------------------------------------------------------------
func _build_cave_area(child_slot: int) -> void:
	# The garden art is already 16:9, so the cave rect (camera bounds) == garden.
	var gw := 256.0 * GARDEN_SCALE      # 1280
	var gh := 144.0 * GARDEN_SCALE      # 720
	var g0 := Vector2(_map_rect.end.x + CAVE_GAP, _map_rect.get_center().y - gh * 0.5)
	_cave_rect = Rect2(g0, Vector2(gw, gh))

	# The walkable PATH — centre-line waypoints (normalised to the art) traced over
	# the painted cobblestone, bottom entrance up to the clearing where the parent
	# stands. Everything off this corridor is blocked.
	var wn := [
		Vector2(0.50, 0.99), Vector2(0.54, 0.78), Vector2(0.57, 0.60),
		Vector2(0.54, 0.45), Vector2(0.50, 0.34)]
	var cl: Array[Vector2] = []
	for n in wn:
		cl.append(g0 + Vector2(n.x * gw, n.y * gh))
	var left: Array[Vector2] = []
	var right: Array[Vector2] = []
	for p in cl:
		left.append(p - Vector2(PATH_HALF, 0))
		right.append(p + Vector2(PATH_HALF, 0))

	# Spawn 80% of the way from entrance to waypoint-1 so the southernmost
	# soldier (~56 px south of spawn) lands well clear of the 34-px exit trigger.
	_cave_spawn = cl[0].lerp(cl[1], 0.8)

	var root := Node2D.new()
	root.name = "CaveArea"
	add_child(root)

	# Dark cave backdrop + the garden painting.
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.03, 0.02, 0.06)
	backdrop.position = _cave_rect.position - Vector2(120, 120)
	backdrop.size = _cave_rect.size + Vector2(240, 240)
	backdrop.z_index = -20
	backdrop.z_as_relative = false
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE   # don't eat squad clicks!
	root.add_child(backdrop)

	var bg := Sprite2D.new()
	bg.centered = false
	bg.position = g0
	bg.scale = Vector2(GARDEN_SCALE, GARDEN_SCALE)
	bg.z_index = -19
	bg.z_as_relative = false
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if ResourceLoader.exists(CAVE_GARDEN_TEX):
		bg.texture = load(CAVE_GARDEN_TEX)
	root.add_child(bg)

	# Path corridor outline (L up one side, R down the other) → the map bakes this
	# into its navmesh so the squad can ONLY walk the path.
	nav_outline_world = PackedVector2Array()
	for p in left:
		nav_outline_world.append(p)
	for i in range(right.size() - 1, -1, -1):
		nav_outline_world.append(right[i])

	# Block everything off the path: left-of-path, right-of-path and above-clearing
	# collision polygons, so the squad can't walk over mushrooms/plants/water.
	var body := StaticBody2D.new()
	root.add_child(body)
	var tl := g0
	var tr_c := g0 + Vector2(gw, 0)
	var bl := g0 + Vector2(0, gh)
	var br := g0 + Vector2(gw, gh)
	var left_poly := PackedVector2Array([tl, bl])
	for p in left:
		left_poly.append(p)
	_add_poly(body, left_poly)
	var right_poly := PackedVector2Array([tr_c, br])
	for p in right:
		right_poly.append(p)
	_add_poly(body, right_poly)
	_add_poly(body, PackedVector2Array([left[left.size() - 1], tl, tr_c, right[right.size() - 1]]))

	# The captured parent (no cage) at the clearing, registered as the objective.
	var npc := Area2D.new()
	npc.set_script(CAVE_PARENT_SCRIPT)
	npc.position = cl[cl.size() - 1] + Vector2(0, 6)
	if "child_slot" in npc:
		npc.set("child_slot", child_slot)
	root.add_child(npc)
	parent_cage = npc

	# Exit back to the surface, at the path's entrance.
	var exit := Area2D.new()
	exit.name = "CaveExitTrigger"
	exit.position = cl[0] + Vector2(0, -6)
	exit.collision_mask = 0
	exit.set_collision_mask_value(2, true)
	var ecs := CollisionShape2D.new()
	var esh := CircleShape2D.new()
	esh.radius = 34.0
	ecs.shape = esh
	exit.add_child(ecs)
	root.add_child(exit)
	_exit_area = exit
	exit.add_child(_make_label("↑ Leave", Vector2(-34, -50), Color(0.9, 1.0, 0.9)))

# ---------------------------------------------------------------------------
# Fade out → reposition squad + camera + freeze/unfreeze world → fade in.
func _transition(into_cave: bool) -> void:
	_busy = true
	# Return the squad SOUTH of the entrance trigger so they don't instantly
	# re-enter; the cave spawn is up by the entrance, clear of the exit trigger.
	var dest_centre: Vector2 = _cave_spawn if into_cave else _entrance_world + Vector2(0, 96)
	var rect: Rect2 = _cave_rect if into_cave else _map_rect

	_fade.visible = true
	_fade.color.a = 0.0
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 1.0, 0.28)
	await tw.finished

	_in_cave = into_cave
	_set_world_frozen(into_cave)
	_move_squad_to(dest_centre)

	var cam := get_tree().get_first_node_in_group("main_camera") as Camera2D
	if cam:
		if into_cave and cam.has_method("enter_cave_view"):
			# Snaps to zoom=1.0 and centers on the full cave art.
			cam.enter_cave_view(rect)
		else:
			cam.position = dest_centre
			if cam.has_method("lock_to_rect"):
				cam.lock_to_rect(rect)

	var tw2 := create_tween()
	tw2.tween_property(_fade, "color:a", 0.0, 0.28)
	await tw2.finished
	_fade.visible = false
	_busy = false
	# Brief grace so the squad's landing spot doesn't instantly re-trigger.
	_armed = false
	await get_tree().create_timer(1.3).timeout
	_armed = true

func _move_squad_to(centre: Vector2) -> void:
	var i := 0
	for s in get_tree().get_nodes_in_group("soldiers"):
		var node := s as Node2D
		if node == null:
			continue
		@warning_ignore("integer_division")
		var ring := Vector2(float(i % 3 - 1) * 56.0, float(i / 3) * 56.0)
		var pos := centre + ring
		if node.has_method("halt"):
			node.call("halt")
		node.global_position = pos
		if node.has_method("move_to"):
			node.call("move_to", pos)   # clear any in-flight nav target
		i += 1

# Freeze enemies + their bullets while the squad is safely underground.
func _set_world_frozen(frozen: bool) -> void:
	var mode := Node.PROCESS_MODE_DISABLED if frozen else Node.PROCESS_MODE_INHERIT
	for grp in ["enemies", "bullets", "enemy_bullets"]:
		for n in get_tree().get_nodes_in_group(grp):
			(n as Node).process_mode = mode

# ---------------------------------------------------------------------------
func _build_fade() -> void:
	var cl := CanvasLayer.new()
	cl.layer = 80
	add_child(cl)
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.visible = false   # only present during a transition — never eats squad clicks
	cl.add_child(_fade)

func _add_poly(body: StaticBody2D, points: PackedVector2Array) -> void:
	var cp := CollisionPolygon2D.new()
	cp.polygon = points
	body.add_child(cp)

func _make_label(text: String, offset: Vector2, col: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.position = offset
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never eat squad clicks
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.z_index = 5
	lbl.z_as_relative = false
	return lbl
