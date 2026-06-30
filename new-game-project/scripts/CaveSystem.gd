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
#     cage + an exit portal) is built FAR off the playfield, in the same
#     viewport/world space as the squad.
#   - Both the cave mouth and the exit portal are small Area2D overlap zones:
#     walking a soldier onto one triggers the transition. This is input-method
#     agnostic (no click/tap action involved), which matters because the old
#     click+distance approach shared an input action with touch movement/joystick
#     controls and could misfire on Android.
#     The parent cage is the level's real `parent_cage` objective, so Main's
#     existing wiring (toast + RunState) just works.
# =============================================================================
extends Node2D
class_name CaveSystem

const CAVE_PARENT_SCRIPT := preload("res://scripts/CaveParent.gd")
const PortalVisual := preload("res://scripts/PortalVisual.gd")
const CAVE_ENTRANCE_TEX := "res://resources/caves/cave_entrance.png"
const CAVE_GARDEN_TEX   := "res://resources/caves/cave_garden.png"

# Cave area is parked this far to the right of the playfield so the squad's
# teleport never overlaps the map's boundary walls or terrain.
const CAVE_GAP := 1200.0
const GARDEN_SCALE := 5.0          # 256x144 art -> 1280x720 (16:9) walkable garden
const PATH_HALF := 84.0            # half-width of the walkable path corridor (world px)
const REVEAL_DIST := 360.0         # squad distance at which the hidden mouth fades in
const TRIGGER_RADIUS := 30.0       # overlap radius for both the mouth and the exit portal

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
var _exit_area: Area2D             # the exit portal's overlap trigger
var _exit_world: Vector2           # world-space centre of the exit portal

# Dedicated navmesh for the cave corridor. The corridor is a disjoint island
# parked CAVE_GAP px off the playfield; folding it into the world bake silently
# drops it (recast discards the far island), so the squad's path clamped back to
# the map edge and marched off-screen. Instead we bake the corridor into its own
# compact NavigationServer map and repoint the squad's agents + path queries onto
# it while underground (see _transition / _move_squad_to).
var _cave_nav_map: RID
var _cave_nav_region: NavigationRegion2D

# Build the entrance at `entrance_world` (foot of a south wall) and the cave area
# off-playfield. `child_slot` is which kid's parent waits inside.
func setup(entrance_world: Vector2, child_slot: int, map_rect: Rect2) -> void:
	_entrance_world = entrance_world
	_map_rect = map_rect

	_build_entrance()
	_build_cave_area(child_slot)
	_build_cave_navmesh()
	_build_fade()

# Bake the corridor outline into a dedicated NavigationServer map, positioned so
# its local navmesh lines up with the corridor's world location. Agents repointed
# onto this map (via Soldier.set_nav_map) path correctly inside the cave.
func _build_cave_navmesh() -> void:
	if nav_outline_world.size() < 3:
		return
	_cave_nav_region = NavigationRegion2D.new()
	_cave_nav_region.name = "CaveNavRegion"
	# Park the region at the corridor's first vertex so the baked geometry sits
	# near local origin — the most baker-friendly case, and what makes the compact
	# island bake reliably where the far-off world-fold did not.
	_cave_nav_region.global_position = nav_outline_world[0]
	add_child(_cave_nav_region)
	_cave_nav_map = NavigationServer2D.map_create()
	var cell := 16.0 if OS.get_name() == "Android" else 4.0
	NavigationServer2D.map_set_cell_size(_cave_nav_map, cell)
	NavigationServer2D.map_set_active(_cave_nav_map, true)
	_cave_nav_region.set_navigation_map(_cave_nav_map)

	var src := NavigationMeshSourceGeometryData2D.new()
	var local := PackedVector2Array()
	for p in nav_outline_world:
		local.append(_cave_nav_region.to_local(p))
	src.add_traversable_outline(local)
	var np := NavigationPolygon.new()
	np.agent_radius = 10.0
	np.cell_size = cell
	NavigationServer2D.bake_from_source_geometry_data(np, src)
	_cave_nav_region.navigation_polygon = np

# NavigationServer maps are resources, not nodes — free the cave map explicitly
# on teardown or every cave (one per level) leaks a map RID.
func _exit_tree() -> void:
	if _cave_nav_map.is_valid():
		NavigationServer2D.free_rid(_cave_nav_map)
		_cave_nav_map = RID()

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
	sh.radius = TRIGGER_RADIUS                         # small — must be deliberately walked onto
	cs.shape = sh
	area.add_child(cs)
	add_child(area)
	_entrance_area = area
	area.body_entered.connect(_on_entrance_body_entered)

# Fade the cave mouth in/out by proximity.
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

# Entry/exit both happen by walking a soldier onto the trigger Area2D — no click or
# tap action involved, so touch movement/joystick controls can't misfire the
# transition the way the old click+distance check could on Android.
func _on_entrance_body_entered(body: Node) -> void:
	if _in_cave or _busy or not _armed:
		return
	if not body.is_in_group("soldiers") or body.is_in_group("escort_npc"):
		return
	_transition(true)

func _on_exit_body_entered(body: Node) -> void:
	if not _in_cave or _busy or not _armed:
		return
	if not body.is_in_group("soldiers") or body.is_in_group("escort_npc"):
		return
	_transition(false)

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

	# Exit portal at the path entrance — walking a soldier onto it leaves the cave.
	var exit := Area2D.new()
	exit.name = "CaveExitMarker"
	exit.position = cl[0] + Vector2(0, -6)
	exit.collision_mask = 0
	exit.set_collision_mask_value(2, true)             # detect soldiers (layer 2)
	var ecs := CollisionShape2D.new()
	var esh := CircleShape2D.new()
	esh.radius = TRIGGER_RADIUS
	ecs.shape = esh
	exit.add_child(ecs)
	root.add_child(exit)
	_exit_area = exit
	_exit_world = exit.global_position
	exit.body_entered.connect(_on_exit_body_entered)
	_build_portal_visual(exit)
	exit.add_child(_make_label("Exit", Vector2(-14, -52), Color(0.9, 1.0, 0.9)))

# Swirling cyan/fairy-garden portal swirl (PixelLab-generated, see
# resources/portals/cave_portal.png) marking the exit as "step here."
func _build_portal_visual(parent: Node2D) -> void:
	var sprite := AnimatedSprite2D.new()
	sprite.sprite_frames = PortalVisual.build_sprite_frames(
			"res://resources/portals/cave_portal.png")
	sprite.scale = Vector2(0.7, 0.7)
	sprite.z_index = 1
	sprite.z_as_relative = false
	parent.add_child(sprite)
	sprite.play(&"idle")

# ---------------------------------------------------------------------------
# Fade out -> reposition squad + camera + freeze/unfreeze world -> fade in.
func _transition(into_cave: bool) -> void:
	_busy = true
	# Exit back to the entrance foot — HandcraftedMap verified this cell is
	# passable when it picked the cave site, so it's always safe to land here
	# regardless of how many plateaus surround it. Re-entry is blocked for 1.3 s
	# by the _armed timer — the squad lands standing right on top of the trigger,
	# so this grace period is what stops an immediate re-trigger. Clamp Y so
	# row-1 soldiers (56 px south) stay inside the map boundary.
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
	# Repoint pathfinding onto the cave corridor's dedicated navmesh (or back to the
	# world map). Must run AFTER the teleport so the soldiers are already standing on
	# the cave navmesh when their agents switch maps.
	_apply_nav_map(into_cave)
	# Drop any in-flight march (e.g. the half-finished walk to the exit marker)
	# so a stale leader can't make _check_stragglers rescue-teleport the squad
	# off-field ~1 s after the transition. Must run AFTER the teleport so the
	# halt anchors each soldier to its new position.
	var squad := get_tree().get_first_node_in_group("squad_controller")
	if squad and squad.has_method("halt_all"):
		squad.halt_all()

	var cam := get_tree().get_first_node_in_group("main_camera") as Camera2D
	if cam:
		if into_cave and cam.has_method("enter_cave_view"):
			# Fits the whole cave art in frame (zoom <= 1.0) and centers on it.
			cam.enter_cave_view(rect)
		else:
			# Snap camera to the squad's landing spot before re-enabling follow,
			# so the first frame of fade-in shows the squad - not the cave centre.
			cam.position = dest_centre
			if cam.has_method("exit_cave_view"):
				# Restores map rect and re-enables squad-follow WITHOUT resetting
				# zoom to min. At min-zoom _clamp_to_map centres on the map and
				# the squad goes off-screen; keeping the cave's fit-zoom avoids that.
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

# Repoint the squad's pathfinding onto the cave navmesh (entering) or the world
# navmesh (leaving). Switches every living soldier's agent map AND the squad
# controller's group-path / straggler query map, so both the rigid march and the
# rescue net resolve against the corridor instead of clamping to the playfield.
func _apply_nav_map(into_cave: bool) -> void:
	var map: RID = _cave_nav_map if (into_cave and _cave_nav_map.is_valid()) else RID()
	for s in get_tree().get_nodes_in_group("soldiers"):
		var node := s as Node2D
		if node == null or node.is_in_group("escort_npc"):
			continue
		if node.has_method("set_nav_map"):
			node.call("set_nav_map", map)
	var squad := get_tree().get_first_node_in_group("squad_controller")
	if squad and squad.has_method("set_nav_map_override"):
		squad.call("set_nav_map_override", map)

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
