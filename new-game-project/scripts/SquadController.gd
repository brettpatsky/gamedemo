extends Node2D

const Balance = preload("res://scripts/BalanceConfig.gd")

const MAX_SOLDIERS  := 8
# Per-weapon resend cadence for held-fire. Pistols stream slower than rifle.
const AUTO_INTERVAL_RIFLE  := 0.07
const AUTO_INTERVAL_PISTOL := 0.2

const FORMATION_NAMES := ["2×3", "3×2", "1×6", "6×1", "Pentagram"]

const FORMATIONS: Array = [
	# 0: 2×3 — 2 columns, 3 rows, 80 px gap throughout
	[Vector2(-40, -80), Vector2( 40, -80),
	 Vector2(-40,   0), Vector2( 40,   0),
	 Vector2(-40,  80), Vector2( 40,  80)],
	# 1: 3×2 — 3 columns, 2 rows, 80 px gap throughout (mission start)
	[Vector2(-80, -40), Vector2(0, -40), Vector2(80, -40),
	 Vector2(-80,  40), Vector2(0,  40), Vector2(80,  40)],
	# 2: 1×6 — single file, 80 px between each soldier
	[Vector2(0, -200), Vector2(0, -120), Vector2(0, -40),
	 Vector2(0,   40), Vector2(0,  120), Vector2(0, 200)],
	# 3: 6×1 — line abreast, 80 px between each soldier
	[Vector2(-200, 0), Vector2(-120, 0), Vector2(-40, 0),
	 Vector2(  40, 0), Vector2( 120, 0), Vector2(200, 0)],
	# 4: Pentagram — 1 centre + 5 equally-spaced pentagon points, radius 110
	[Vector2(   0,    0),
	 Vector2(   0, -110), Vector2( 105, -34), Vector2( 64,  89),
	 Vector2(-64,   89), Vector2(-105, -34)],
]

var _formation_index: int = 1   # 3×2 on every mission start

var soldiers: Array[Node2D] = []
# Downed (revivable) soldiers, most-recent first. Populated by remove_soldier.
var _downed:  Array[Node2D] = []

@onready var camera: Camera2D = get_tree().get_first_node_in_group("main_camera") as Camera2D

var _right_held: bool  = false
var _auto_timer: float = 0.0

# ---------------------------------------------------------------------------
# Squad group system
# G cycles group count: 1 → 2 → 3 → 1
# Keys 1/2/3 select which group receives orders.
# Groups not currently selected are stationary and do not fire back.
# ---------------------------------------------------------------------------
const MAX_GROUPS  := 3
var _num_groups:   int = 1   # how many groups the squad is split into
var _active_group: int = 0   # 0-indexed; this group receives all orders

# Active formation marches, keyed by group_id. Each entry drives one group's
# soldiers as a rigid formation gliding along a shared navmesh path — see
# _begin_march / _tick_marches. Multiple groups can march at once (a non-active
# group keeps marching toward its last order), hence the per-group dictionary.
var _marches: Dictionary = {}

func _ready() -> void:
	GameManager.soldier_died.connect(_on_soldier_died)

# Drives active formation marches and the stranded-soldier rescue check.
func _physics_process(delta: float) -> void:
	if not _marches.is_empty():
		_tick_marches(delta)
	if not soldiers.is_empty():
		_check_stragglers(delta)

# Per-group safety net: any soldier that stays too far from its group's leader
# (the march leader while moving, the group centroid while idle) for
# SQUAD_STRAGGLER_TELEPORT_TIME gets rescue-teleported onto a navmesh point at
# its formation slot. Runs per group so a split squad rescues each group against
# its own leader, never dragging a soldier to a different group's position.
func _check_stragglers(delta: float) -> void:
	var nav_map: RID = get_world_2d().navigation_map
	for g in _num_groups:
		var grp := _soldiers_in_group(g)
		if grp.size() <= 1:
			# A lone soldier has no squad to be "far" from — clear any timer.
			for s in grp:
				if s.has_method("clear_straggler"):
					s.clear_straggler()
			continue
		var marching: bool = _marches.has(g)
		var ref_point: Vector2
		if marching:
			var m: Dictionary = _marches[g]
			ref_point = _point_along(m.path, m.cum, m.total, m.d)
		else:
			ref_point = get_group_centroid(g)
		if ref_point == Vector2.ZERO:
			continue
		var count := grp.size()
		var offs := _group_offsets(grp)
		for i in count:
			var s = grp[i]
			if not is_instance_valid(s) or (s.has_method("is_downed") and s.is_downed()):
				continue
			if not s.has_method("tick_straggler"):
				continue
			var too_far: bool = s.global_position.distance_to(ref_point) > Balance.SQUAD_STRAGGLER_MAX_DIST
			if s.tick_straggler(too_far, delta):
				var slot: Vector2 = ref_point + offs[i]
				s.snap_to(NavigationServer2D.map_get_closest_point(nav_map, slot))

# ---------------------------------------------------------------------------
# Input — runs after UI consumes its events.
# Action-based so the same handler responds to mouse/keyboard AND gamepad.
# Bindings live in project.godot under [input].
# ---------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if soldiers.is_empty():
		return

	if event.is_action_pressed("squad_move"):
		_issue_move_order(_screen_to_world(_event_cursor_pos(event)))
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("squad_fire"):
		_issue_fire_order(_screen_to_world(_event_cursor_pos(event)))
		_right_held = true
		_auto_timer = _current_auto_interval()
		get_viewport().set_input_as_handled()
	elif event.is_action_released("squad_fire"):
		_right_held = false
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("cycle_weapon"):
		_cycle_weapons()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("cycle_formation"):
		_cycle_formation()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("cycle_groups"):
		_cycle_group_count()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("select_group_1"):
		_select_group(0)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("select_group_2"):
		_select_group(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("select_group_3"):
		_select_group(2)
		get_viewport().set_input_as_handled()

# Mouse events carry their click position; gamepad events do not. Fall back to
# the current cursor (kept current by Reticle's right-stick warp).
func _event_cursor_pos(event: InputEvent) -> Vector2:
	if event is InputEventMouse:
		return (event as InputEventMouse).position
	return get_viewport().get_mouse_position()

# ---------------------------------------------------------------------------
# Process — drives continuous AUTO fire while right mouse is held
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	if soldiers.is_empty():
		return
	# Touch aim pad (directional): stream fire in the aimed direction while held.
	# Single-shot weapons fire on release (see set_touch_aim), not here. Takes
	# priority over the mouse path so a tablet player never depends on a cursor.
	if _touch_aim_active:
		if not _is_continuous_weapon():
			return                       # grenade / sacrifice fire on release
		_auto_timer -= delta
		if _auto_timer <= 0.0:
			_auto_timer = _current_auto_interval()
			_issue_fire_order(_resolve_touch_target())
		return
	if not _right_held:
		return
	if not _is_continuous_weapon():
		return
	_auto_timer -= delta
	if _auto_timer <= 0.0:
		_auto_timer = _current_auto_interval()
		_issue_fire_order(_screen_to_world(get_viewport().get_mouse_position()))

# ---------------------------------------------------------------------------
# Touch aim control (tablet/phone). The HUD's on-screen AIM pad calls
# set_touch_aim() on press / drag / release, passing a raw drag offset in pixels.
# The squad fires in that DIRECTION (so doors and structures are valid targets,
# not just enemies, and firing works with nothing on screen). A press with almost
# no drag falls back to auto-aiming the nearest enemy. Continuous weapons stream
# while held (see _process); single-shot weapons throw on release so the player
# can aim first.
# ---------------------------------------------------------------------------
const TOUCH_AIM_DEADZONE := 18.0     # px; below this, fall back to auto-aim
const TOUCH_FIRE_RANGE   := 2200.0   # how far down the aim ray bullets are aimed
const TOUCH_AIM_MAX      := 78.0     # = TouchAimStick.RADIUS; full-drag magnitude
const TOUCH_LOB_MIN      := 120.0    # shortest lobbed throw at the smallest drag

var _touch_aim_active: bool    = false
var _touch_aim_vec:    Vector2 = Vector2.ZERO    # raw drag offset from pad centre
var _last_aim_dir:     Vector2 = Vector2(0, -1)  # remembered direction; default up

func set_touch_aim(active: bool, vec: Vector2) -> void:
	if soldiers.is_empty():
		_touch_aim_active = false
		return
	if active:
		if not _touch_aim_active:
			_auto_timer = 0.0            # fire ASAP once for continuous weapons
		_touch_aim_active = true
		_touch_aim_vec = vec
	else:
		# Release — single-shot weapons throw now, in the aimed direction.
		if _touch_aim_active and not _is_continuous_weapon():
			_issue_fire_order(_resolve_touch_target())
		_touch_aim_active = false
		_touch_aim_vec = Vector2.ZERO

# Turns the current aim pad state into a world target point. A real drag aims in
# that direction; an in-deadzone press auto-aims the nearest enemy; with neither,
# it fires along the last-aimed direction so FIRE always does something.
func _resolve_touch_target() -> Vector2:
	var origin: Vector2 = get_centroid()
	var mag: float = _touch_aim_vec.length()
	if mag >= TOUCH_AIM_DEADZONE:
		_last_aim_dir = _touch_aim_vec.normalized()
		# Lobbed / single-shot weapons read drag LENGTH as throw distance so the
		# player can place the landing point (e.g. on the heavy door). Bullets fly
		# straight, so continuous weapons just need a far point on the aim ray.
		if not _is_continuous_weapon():
			var frac: float = clampf(mag / TOUCH_AIM_MAX, 0.0, 1.0)
			return origin + _last_aim_dir * lerpf(TOUCH_LOB_MIN, Balance.GRENADE_MAX_RANGE, frac)
		return origin + _last_aim_dir * TOUCH_FIRE_RANGE
	# In-deadzone press — auto-aim the nearest enemy for effortless combat.
	var enemy: Vector2 = _auto_aim_target()
	if enemy != Vector2.INF:
		_last_aim_dir = (enemy - origin).normalized()
		return enemy
	# Nothing aimed and no enemy in range — still fire along the last direction.
	if not _is_continuous_weapon():
		return origin + _last_aim_dir * Balance.GRENADE_MAX_RANGE
	return origin + _last_aim_dir * TOUCH_FIRE_RANGE

# World position of the closest living enemy to the squad, or Vector2.INF if none.
func _auto_aim_target() -> Vector2:
	var origin: Vector2 = get_centroid()
	var best: Vector2 = Vector2.INF
	var best_d: float = INF
	for e in get_tree().get_nodes_in_group("enemies"):
		if not (e is Node2D):
			continue
		var d: float = origin.distance_to((e as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = (e as Node2D).global_position
	return best

# Resend cadence depends on which weapon the active group is holding.
func _current_auto_interval() -> float:
	if _active_weapon() == 0:   # WeaponType.PISTOL
		return AUTO_INTERVAL_PISTOL
	return AUTO_INTERVAL_RIFLE

# =============================================================================
# PUBLIC API
# =============================================================================

func add_soldier(soldier: Node2D) -> void:
	if soldiers.size() >= MAX_SOLDIERS:
		push_warning("[SquadController] Squad full — cannot add more soldiers.")
		return
	soldier.group_id = 0   # all soldiers start in group 0
	soldiers.append(soldier)
	GameManager.soldiers_alive += 1
	_refresh_group_state()
	_update_weapon_hud()
	_update_ammo_hud()
	_update_formation_hud()
	_update_group_hud()

func remove_soldier(soldier: Node2D) -> void:
	soldiers.erase(soldier)
	# Keep a reference for revive — the soldier is still on the field. Newest
	# downed soldier goes to the front of the list so try_revive() restores the
	# most recent casualty first.
	if soldier != null and not _downed.has(soldier):
		_downed.push_front(soldier)
	# If the active group is now empty, switch to the first non-empty group.
	if _active_group_soldiers().is_empty() and not soldiers.is_empty():
		_active_group = soldiers[0].group_id
	_refresh_group_state()
	# SACRIFICE refuses to fire when only one soldier remains (it would empty
	# the squad). Force any survivor still holding SACRIFICE onto the pistol so
	# they can actually shoot.
	if soldiers.size() == 1:
		var last: Node2D = soldiers[0]
		if last.has_method("get_weapon") and last.get_weapon() == 3 and last.has_method("set_weapon"):
			last.set_weapon(0)
	_update_group_hud()
	_update_weapon_hud()
	_update_ammo_hud()   # SACRIFICE 'ammo' depends on remaining squad size

# Spends one revive potion to bring the most recently downed soldier back.
# Returns true on success. Called by the HUD revive button.
func try_revive() -> bool:
	# Hard gate — tutorial pre-Puzzle 5 has Revive locked. HUD button is
	# disabled there, but guard here in case the call reaches us anyway.
	if not GameManager.revive_enabled:
		return false
	# Prune any references that have somehow been freed.
	_downed = _downed.filter(func(n: Node2D) -> bool: return is_instance_valid(n))
	if _downed.is_empty():
		return false
	if not GameManager.use_revive():
		return false
	# Capture the group's current weapon BEFORE adding the revived soldier so
	# _active_weapon() reads from already-alive squad members, not the returnee.
	var grp_weapon := _active_weapon()
	if grp_weapon < 0:
		grp_weapon = 0  # default to pistol if the whole group was wiped
	# Snapshot the centroid before re-adding the soldier so the corpse's
	# position doesn't skew the rally point.
	var rally := get_centroid()
	var target: Node2D = _downed.pop_front()
	if target.has_method("revive"):
		target.revive()
	target.group_id = _active_group
	if not soldiers.has(target):
		soldiers.append(target)
	# Sync weapon so the returning soldier doesn't wield whatever they had when
	# they died — the player may have switched weapons since then.
	if target.has_method("set_weapon"):
		target.set_weapon(grp_weapon)
	_refresh_group_state()
	_update_group_hud()
	_update_ammo_hud()
	# Auto-move the revived soldier toward the group so they rejoin without the
	# player having to issue a manual move order.
	if rally != Vector2.ZERO and target.has_method("move_to"):
		target.move_to(rally)
	return true

# Returns true iff a revive potion + at least one downed soldier are available.
func can_revive() -> bool:
	return GameManager.revive_potions > 0 and not _downed.filter(
		func(n: Node2D) -> bool: return is_instance_valid(n)
	).is_empty()

# Cancels every in-flight formation march and stops all soldiers where they
# stand. Called by CaveSystem around a cave teleport: a march still running when
# the squad enters/leaves (e.g. the unfinished walk to the exit marker) would
# otherwise linger as a stale leader far off-field. _check_stragglers then
# measures the relocated squad against that off-field leader, finds everyone
# "too far", and rescue-teleports the whole squad away ~1 s after they exit.
# Mirrors the _marches.clear() + halt() pattern in _cycle_group_count.
func halt_all() -> void:
	_marches.clear()
	for s in soldiers:
		if is_instance_valid(s) and s.has_method("halt"):
			s.halt()

# =============================================================================
# PRIVATE — GROUP MANAGEMENT
# =============================================================================

func _cycle_group_count() -> void:
	# Snapshot the true centre of the whole squad before reassigning group ids,
	# so the spread / formation targets are anchored to the current position.
	var center := Vector2.ZERO
	if not soldiers.is_empty():
		for s in soldiers:
			center += (s as Node2D).global_position
		center /= float(soldiers.size())

	_num_groups   = (_num_groups % MAX_GROUPS) + 1
	_active_group = 0
	# Group membership is changing — drop every in-flight march so none keeps
	# driving soldiers that now belong to a different group.
	_marches.clear()
	# Redistribute soldiers round-robin across all groups.
	for i in soldiers.size():
		soldiers[i].group_id = i % _num_groups
	for s in soldiers:
		s.halt()

	if _num_groups > 1:
		# Fan each group out 1 tile (64 px) from the squad centre so the split
		# is immediately obvious at a glance.
		for g in _num_groups:
			var angle := (TAU / _num_groups) * g - PI / 2.0
			var spread := Vector2(cos(angle), sin(angle)) * 160.0
			var grp := _soldiers_in_group(g)
			var offs := _group_offsets(grp)
			for i in grp.size():
				grp[i].move_to(center + spread + offs[i])
	else:
		# Collapsing back to one group — automatically reform into formation so
		# soldiers regroup without the player having to issue a manual move.
		_issue_move_order(center)
	_refresh_group_state()
	_update_group_hud()

func _select_group(group: int) -> void:
	if group >= _num_groups:
		return
	# Reject empty groups — selecting one would leave the squad un-orderable
	# and the HUD weapon/ammo readouts stuck on stale state.
	if not _alive_group_ids().has(group):
		return
	_active_group = group
	# Deliberately do NOT halt the other groups here. They keep marching toward
	# whatever destination they were last ordered to — that's the whole point
	# of multi-group control. (Soldiers don't physically block each other, so
	# no risk of two groups jamming when they cross paths.)
	_refresh_group_state()
	_update_group_hud()

# Returns soldiers in any specific group (0-indexed group id).
func _soldiers_in_group(g: int) -> Array:
	var result: Array = []
	for s in soldiers:
		if s.group_id == g:
			result.append(s)
	return result

# Returns only the soldiers that belong to the currently active group.
func _active_group_soldiers() -> Array:
	return _soldiers_in_group(_active_group)

# Syncs per-soldier active flag and group-number label in one pass.
# Call whenever group membership, active group, or group count changes.
func _refresh_group_state() -> void:
	for s in soldiers:
		if "is_active" in s:
			s.is_active = (s.group_id == _active_group)
		if _num_groups > 1:
			if s.has_method("show_group_label"):
				s.show_group_label(s.group_id + 1)
		else:
			if s.has_method("hide_group_label"):
				s.hide_group_label()

# Returns the set of group_ids that still contain at least one alive soldier.
# Used by the HUD to grey-out buttons for groups that have been wiped.
func _alive_group_ids() -> Array:
	var ids: Array = []
	for s in soldiers:
		if not ids.has(s.group_id):
			ids.append(s.group_id)
	return ids

# =============================================================================
# PRIVATE — ORDER LOGIC
# =============================================================================

func _issue_move_order(target: Vector2) -> void:
	if not GameManager.squad_has_moved:
		GameManager.squad_has_moved = true
		GameManager.squad_first_moved.emit()
	var group := _active_group_soldiers()
	var count := group.size()
	if count == 0:
		return
	# ONE navmesh path for the whole group (centroid → click). A virtual leader
	# walks it and every soldier is pinned at leader + its (stable, index-based)
	# formation slot, so the squad rounds obstacles together without splitting
	# and holds its formation shape without bunching — no soldier runs its own
	# pathfinder. Stable slot i → kid i keeps each kid in a consistent position.
	var start := Vector2.ZERO
	for s in group:
		start += (s as Node2D).global_position
	start /= float(count)
	var path: PackedVector2Array = NavigationServer2D.map_get_path(
			get_world_2d().navigation_map, start, target, true)
	# Maze soldiers own their own movement; an empty/degenerate path means no
	# route or a reform-in-place — either way fall back to plain move_to, which
	# lands each kid directly on its slot.
	var is_maze: bool = "maze_mode" in group[0] and group[0].maze_mode
	if is_maze or path.size() < 2 or not group[0].has_method("formation_begin"):
		_marches.erase(_active_group)
		var offs := _group_offsets(group)
		for i in count:
			group[i].move_to(target + offs[i], offs[i])
		return
	_begin_march(_active_group, group, path, target)

# =============================================================================
# PRIVATE — FORMATION MARCH (rigid leader-follower; see BalanceConfig SQUAD_*)
# =============================================================================

# Sets up a march for one group: precomputes the path's cumulative arc length
# (so the leader can be sampled at any distance), captures each soldier's stable
# slot offset, and flips every soldier into formation mode.
func _begin_march(gid: int, group: Array, path: PackedVector2Array, target: Vector2) -> void:
	var count := group.size()
	var cum := PackedFloat32Array()
	cum.resize(path.size())
	cum[0] = 0.0
	for k in range(1, path.size()):
		cum[k] = cum[k - 1] + path[k - 1].distance_to(path[k])
	# Leader speed = slowest soldier's base speed so it never outruns the group;
	# terrain lag on top of that is handled by the gate in _advance_march.
	var base := INF
	var offsets: Array = _group_offsets(group)
	for i in count:
		var ms: float = group[i].move_speed if "move_speed" in group[i] else 215.0
		base = minf(base, ms)
	if base == INF:
		base = 215.0
	_marches[gid] = {
		"path": path, "cum": cum, "total": cum[path.size() - 1], "base": base,
		"d": 0.0, "soldiers": group.duplicate(), "offsets": offsets,
		"target": target, "settle": 0.0, "best_dist": INF,
	}
	for i in count:
		group[i].formation_begin(offsets[i])

func _tick_marches(delta: float) -> void:
	var finished: Array = []
	for gid in _marches:
		if _advance_march(_marches[gid], delta):
			finished.append(gid)
	for gid in finished:
		for s in _marches[gid].soldiers:
			if is_instance_valid(s) and s.has_method("formation_end"):
				s.formation_end()
		_marches.erase(gid)

# Advances one march by delta and pushes each soldier its slot for this frame.
# The leader moves at full speed and NEVER waits for stragglers — a stuck soldier
# rejoins on its own (see Soldier._do_formation_move). Returns true when the
# march is complete: everyone settled, or (leader already home) no straggler has
# gotten any closer for SETTLE_TIMEOUT — covering a slot stuck in a wall.
func _advance_march(m: Dictionary, delta: float) -> bool:
	m.d = minf(m.d + m.base * delta, m.total)
	var leader: Vector2 = _point_along(m.path, m.cum, m.total, m.d)
	var live := 0
	var all_settled := true
	var max_dist := 0.0
	for i in m.soldiers.size():
		var s = m.soldiers[i]
		if not is_instance_valid(s) or (s.has_method("is_downed") and s.is_downed()):
			continue
		live += 1
		var slot: Vector2 = leader + m.offsets[i]
		s.set_formation_goal(slot)
		var d_slot: float = s.global_position.distance_to(slot)
		max_dist = maxf(max_dist, d_slot)
		if d_slot > Balance.SQUAD_FORMATION_ARRIVE_EPS:
			all_settled = false
	if live == 0:
		return true
	# Never end mid-path — the squad keeps marching until the leader reaches the
	# destination, even if everyone is momentarily within EPS of their moving slots.
	if m.d < m.total:
		return false
	# Leader is home. Done once everyone has settled onto their final slots.
	if all_settled:
		return true
	# Keep waiting while a straggler is still closing the gap; give up only once
	# no progress has been made for SETTLE_TIMEOUT.
	if max_dist < m.best_dist - 1.0:
		m.best_dist = max_dist
		m.settle = 0.0
		return false
	m.settle += delta
	if m.settle < Balance.SQUAD_MARCH_SETTLE_TIMEOUT:
		return false
	# Given up. Any soldier still beyond rejoin range is wedged with no path back
	# (boxed in by forest, slot in a wall) — hard-teleport it onto a navmesh point
	# at its slot so it rejoins instead of being stranded. Soldiers merely blocked
	# a little short of their slot are left where they are.
	var nav_map: RID = get_world_2d().navigation_map
	for i in m.soldiers.size():
		var s = m.soldiers[i]
		if not is_instance_valid(s) or (s.has_method("is_downed") and s.is_downed()):
			continue
		var slot: Vector2 = leader + m.offsets[i]
		if s.global_position.distance_to(slot) > Balance.SQUAD_FORMATION_REPATH_DIST and s.has_method("snap_to"):
			s.snap_to(NavigationServer2D.map_get_closest_point(nav_map, slot))
	return true

# Point at arc-length `d` along the polyline (linear scan — paths are short).
func _point_along(path: PackedVector2Array, cum: PackedFloat32Array, total: float, d: float) -> Vector2:
	if path.size() == 1 or total <= 0.0:
		return path[path.size() - 1]
	d = clampf(d, 0.0, total)
	for k in range(1, path.size()):
		if d <= cum[k]:
			var seg := cum[k] - cum[k - 1]
			var t := 0.0 if seg <= 0.0 else (d - cum[k - 1]) / seg
			return path[k - 1].lerp(path[k], t)
	return path[path.size() - 1]

func _issue_fire_order(target: Vector2) -> void:
	if not GameManager.squad_has_moved:
		GameManager.squad_has_moved = true
		GameManager.squad_first_moved.emit()
	var group := _active_group_soldiers()
	if group.is_empty():
		return

	# SACRIFICE: closest soldier in the active group becomes a walking bomb.
	# Refuse if it would leave the entire squad empty.
	if _active_weapon() == 3:  # WeaponType.SACRIFICE
		if soldiers.size() <= 1:
			return
		var bomber: Node2D = _closest_to(group, target)
		if bomber != null and bomber.has_method("arm_as_bomb"):
			bomber.arm_as_bomb(target)
		return

	# GRENADE: one throw per fire order — the closest soldier is the thrower.
	# Firing one-per-soldier was redundant and wasted 5 ammo per click.
	if _active_weapon() == 2:  # WeaponType.GRENADE
		# Pool drained between clicks? Flip the whole active group onto pistol
		# so the HUD weapon icon updates and this click pistol-fires instead of
		# silently doing nothing on the empty-pool guard inside _throw_grenade.
		if GameManager.grenade_ammo_pool <= 0:
			for s in group:
				if s.has_method("set_weapon"):
					s.set_weapon(0)
			_update_ammo_hud()
			_update_weapon_hud()
			# Fall through into the standard pistol path so this click still fires.
		else:
			var thrower: Node2D = _closest_to(group, target)
			if thrower != null:
				thrower.fire_at(target, target)
			_update_ammo_hud()
			_update_weapon_hud()
			return

	# Every soldier aims directly at the click point.
	for soldier in group:
		soldier.fire_at(target, target)
	_update_ammo_hud()
	_update_weapon_hud()   # weapon may auto-switch when ammo runs out

# Returns the weapon index of the first soldier in the active group, or -1.
func _active_weapon() -> int:
	var group := _active_group_soldiers()
	if group.is_empty() or not group[0].has_method("get_weapon"):
		return -1
	return group[0].get_weapon()

func _closest_to(group: Array, target: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for s in group:
		var d: float = (s as Node2D).global_position.distance_to(target)
		if d < best_d:
			best_d = d
			best   = s
	return best

# =============================================================================
# PRIVATE — WEAPON CYCLING
# =============================================================================

func _cycle_weapons() -> void:
	for s in _active_group_soldiers():
		if s.has_method("cycle_weapon"):
			s.cycle_weapon()
	_update_weapon_hud()
	_update_ammo_hud()

# Public: set every active-group soldier's weapon to a specific index (used by the
# HUD weapon grid). Index matches Soldier.WeaponType ordering.
func set_weapon(idx: int) -> void:
	for s in _active_group_soldiers():
		if s.has_method("set_weapon"):
			s.set_weapon(idx)
	_update_weapon_hud()
	_update_ammo_hud()

# Public: set the formation directly (used by the HUD formation grid).
func set_formation(idx: int) -> void:
	if idx < 0 or idx >= FORMATIONS.size():
		return
	_formation_index = idx
	if not soldiers.is_empty():
		_issue_move_order(get_centroid())
	_update_formation_hud()

func _update_weapon_hud() -> void:
	var group := _active_group_soldiers()
	if group.is_empty():
		return
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud == null or not hud.has_method("update_weapon"):
		return
	hud.update_weapon(group[0].get_weapon())

func _update_ammo_hud() -> void:
	var group := _active_group_soldiers()
	if group.is_empty():
		return
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud == null or not hud.has_method("update_ammo"):
		return
	var s: Node2D = group[0]
	if s.has_method("get_rifle_ammo") and s.has_method("get_grenade_ammo"):
		# Sacrifice "ammo" = squad members that can be spent (must leave 1 alive).
		var sac_avail: int = max(soldiers.size() - 1, 0)
		hud.update_ammo(s.get_rifle_ammo(), s.get_grenade_ammo(), sac_avail)

func _update_group_hud() -> void:
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("update_group_info"):
		hud.update_group_info(_active_group + 1, _num_groups, _alive_group_ids())

func _is_continuous_weapon() -> bool:
	var group := _active_group_soldiers()
	return not group.is_empty() \
		and group[0].has_method("is_continuous_fire") \
		and group[0].is_continuous_fire()

# =============================================================================
# PRIVATE — FORMATION MATH
# =============================================================================

# Returns one formation offset per soldier in `group`, in the same order.
# Each kid's slot is keyed off its STABLE slot_index (its identity), NOT its
# position in the live array — so when a squadmate dies and the array compacts,
# every survivor keeps the exact spot it already held instead of being shuffled
# onto a neighbour's slot (which made the squad lurch sideways on the next move).
# The offsets are then re-centred on the group so their mean is zero for any set
# of survivors, keeping the formation balanced on the leader (a lone soldier
# sits exactly on it).
func _group_offsets(group: Array) -> Array:
	var f: Array = FORMATIONS[_formation_index]
	var raw: Array = []
	var mean := Vector2.ZERO
	for s in group:
		var slot: int = s.slot_index if "slot_index" in s and s.slot_index >= 0 else 0
		var off: Vector2 = f[slot] if slot < f.size() else Vector2.ZERO
		raw.append(off)
		mean += off
	if not raw.is_empty():
		mean /= float(raw.size())
	var out: Array = []
	for off in raw:
		out.append(off - mean)
	return out

func _cycle_formation() -> void:
	_formation_index = (_formation_index + 1) % FORMATIONS.size()
	if not soldiers.is_empty():
		_issue_move_order(get_centroid())
	_update_formation_hud()

func _update_formation_hud() -> void:
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("update_formation"):
		hud.update_formation(_formation_index)

func snap_to_formation() -> void:
	if soldiers.is_empty():
		return
	var center := get_centroid()
	var f: Array = FORMATIONS[_formation_index]
	for i in soldiers.size():
		var offset: Vector2 = f[i] if i < f.size() else Vector2.ZERO
		soldiers[i].global_position = center + offset

# =============================================================================
# PRIVATE — COORDINATE CONVERSION
# =============================================================================

func _screen_to_world(screen_pos: Vector2) -> Vector2:
	if camera:
		return camera.get_canvas_transform().affine_inverse() * screen_pos
	return get_viewport().canvas_transform.affine_inverse() * screen_pos

# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_soldier_died(soldier: Node2D) -> void:
	remove_soldier(soldier)

# Average position of one group's soldiers (bombers excluded). Used by each
# soldier's formation-cohesion speed control, so it must reflect the soldier's
# OWN group — get_centroid() below tracks the ACTIVE group for the camera.
func get_group_centroid(gid: int) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for s in soldiers:
		if s.group_id != gid:
			continue
		if s.has_method("is_armed_bomb") and s.is_armed_bomb():
			continue
		sum += s.global_position
		n += 1
	return sum / float(n) if n > 0 else Vector2.ZERO

# Returns the average position of the active group (falls back to all soldiers).
# CameraController uses this to softly follow the group.
# Soldiers armed as walking bombs are excluded so the camera stays on the
# rest of the squad rather than chasing the bomber across the map. Downed
# soldiers are excluded too: they stay where they fell, so after a cave exit
# (which teleports only the living back to the entrance) they would otherwise
# drag the centroid toward the dead bodies and leave the live squad off-screen.
func get_centroid() -> Vector2:
	var usable := func(s: Node2D) -> bool:
		if s.has_method("is_armed_bomb") and s.is_armed_bomb():
			return false
		if s.has_method("is_downed") and s.is_downed():
			return false
		return true
	var src := _active_group_soldiers().filter(usable)
	if src.is_empty():
		src = soldiers.filter(usable)
	if src.is_empty():
		src = soldiers
	if src.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for s in src:
		sum += s.global_position
	return sum / float(src.size())
