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
#   - Right-clicking the cave mouth enters; right-clicking the exit marker leaves.
#     Both checks are distance-based so no Area2D collision-layer matching is needed.
#     The parent cage is the level's real `parent_cage` objective, so Main's
#     existing wiring (toast + RunState) just works.
# =============================================================================
extends Node2D
class_name CaveSystem

const CAVE_PARENT_SCRIPT := preload("res://scripts/CaveParent.gd")
const CAVE_ENTRANCE_TEX := "res://resources/caves/cave_entrance.png"
const CAVE_GARDEN_TEX   := "res://resources/caves/cave_garden.png"

# Cave area is parked this far to the right of the playfield so the squad's
# teleport never overlaps the map's boundary walls or terrain.
const CAVE_GAP := 1200.0
const GARDEN_SCALE := 5.0          # 256x144 art -> 1280x720 (16:9) walkable garden
const PATH_HALF := 84.0            # half-width of the walkable path corridor (world px)
const REVEAL_DIST := 360.0         # squad distance at which the hidden mouth fades in
const ENTER_CLICK_RADIUS := 100.0  # click must be within this world-px of the trigger
const ENTER_SQUAD_DIST   := 280.0  # at least one soldier must be this close to trigger

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
var _exit_area: Area2D             # kept for the visual label; detection is distance-based
var _exit_world: Vector2           # world-space centre of the exit click zone

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

# Fade the cave mouth in/out by proximity. Both entry and exit are click-based (see _input).
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

# Entry: right-click the cave mouth while at least one soldier is close enough.
# Exit:  right-click the exit marker while at least one soldier is close enough.
# Both checks are pure world-position distance — no Area2D overlap detection needed.
# Consuming the event stops SquadController from issuing a normal move order.
func _input(event: InputEvent) -> void:
	if _busy or not _armed:
		return
	if not event.is_action_pressed("squad_move"):
		return
	var screen_pos: Vector2 = event.get_position() if event is InputEventMouse \
			else get_viewport().get_mouse_position()
	var cam := get_tree().get_first_node_in_group("main_camera") as Camera2D
	var world_pos: Vector2 = cam.get_canvas_transform().affine_inverse() * screen_pos \
			if cam else get_viewport().canvas_transform.affine_inverse() * screen_pos

	if not _in_cave:
		# ENTRY: click near the cave mouth while at least one soldier is close.
		if world_pos.distance_to(_entrance_world) > ENTER_CLICK_RADIUS:
			return
		for s in get_tree().get_nodes_in_group("soldiers"):
			if (s as Node).is_in_group("escort_npc"):
				continue
			if (s as Node2D).global_position.distance_to(_entrance_world) <= ENTER_SQUAD_DIST:
				get_viewport().set_input_as_handled()
				_transition(true)
				return
	else:
		# EXIT: click near the exit marker while at least one soldier is close.
		if world_pos.distance_to(_exit_world) > ENTER_CLICK_RADIUS:
			return
		for s in get_tree().get_nodes_in_group("soldiers"):
			if (s as Node).is_in_group("escort_npc"):
				continue
			if (s as Node2D).global_position.distance_to(_exit_world) <= ENTER_SQUAD_DIST:
				get_viewport().set_input_as_handled()
				_transition(false)
				return

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

	# Spawn 92% of the way from entrance to waypoint-1.  At 80% the row-2
	# soldiers (56 px south of spawn) land with their capsule edge only ~1 px
	# clear of the 34-px exit marker, causing an immediate trigger.
	# 92% gives ~19 px clearance with the default capsule shape.
	_cave_spawn = cl[0].lerp(cl[1], 0.92)

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

	# Path corridor outline (L up one side, R down the other) — the map bakes this
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

	# Exit marker at the path entrance. Detection is now click-based (_input),
	# so no collision shape or layer matching is needed — the Area2D is kept only
	# for the visual label.
	var exit := Area2D.new()
	exit.name = "CaveExitMarker"
	exit.position = cl[0] + Vector2(0, -6)
	root.add_child(exit)
	_exit_area = exit
	_exit_world = exit.global_position   # world-space centre used in _input
	exit.add_child(_make_label("Leave (click)", Vector2(-44, -50), Color(0.9, 1.0, 0.9)))

# ---------------------------------------------------------------------------
# Fade out -> reposition squad + camera + freeze/unfreeze world -> fade in.
func _transition(into_cave: bool) -> void:
	_busy = true
	# Exit back to the entrance foot — HandcraftedMap verified this cell is
	# passable when it picked the cave site, so it's always safe to land here
	# regardless of how many plateaus surround it. Re-entry is blocked for 1.3 s
	# by the _armed timer; entry is click-gated so the squad can't stumble back
	# in just by standing here. Clamp Y so row-1 soldiers (56 px south) stay
	# inside the map boundary.
	var exit_y := minf(_entrance_world.y, _map_rect.end.y - 180.0)
	var dest_centre: Vector2 = _cave_spawn if into_cave else Vector2(_entrance_world.x, exit_y)
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
			# Snap camera to the squad's landing spot before re-enabling follow,
			# so the first frame of fade-in shows the squad - not the cave centre.
			cam.position = dest_centre
			if cam.has_method("exit_cave_view"):
				# Restores map rect and re-enables squad-follow WITHOUT resetting
				# zoom to min. At min-zoom _clamp_to_map centres on the map and
				# the squad goes off-screen; keeping cave zoom (1.0) avoids that.
				cam.exit_cave_view(rect)
			elif cam.has_method("lock_to_rect"):
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
		if node.is_in_group("escort_npc"):
			continue
		# Downed soldiers stay where they fell — they're still in the group so they
		# can be revived, but they must not be dragged into or out of the cave.
		if node.has_method("is_downed") and node.is_downed():
			continue
		@warning_ignore("integer_division")
		var ring := Vector2(float(i % 3 - 1) * 56.0, float(i / 3) * 56.0)
		node.global_position = centre + ring
		# halt() after teleport: zeros velocity, sets state=IDLE, and anchors the
		# nav agent's target to the new position without triggering path-seeking.
		# Calling move_to(pos) instead would put soldiers in MOVING state, causing
		# the nav agent to compute a path — soldiers placed off the navmesh (e.g.
		# near a cliff edge at the entrance) would immediately navigate away.
		if node.has_method("halt"):
			node.call("halt")
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
