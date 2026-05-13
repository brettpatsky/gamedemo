extends Node2D

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

func _ready() -> void:
	GameManager.soldier_died.connect(_on_soldier_died)

# ---------------------------------------------------------------------------
# Input — runs after UI consumes its events
# ---------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if soldiers.is_empty():
		return

	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_issue_move_order(_screen_to_world(event.position))
					get_viewport().set_input_as_handled()

			MOUSE_BUTTON_RIGHT:
				if event.pressed:
					_issue_fire_order(_screen_to_world(event.position))
					_right_held = true
					_auto_timer = _current_auto_interval()
				else:
					_right_held = false
				get_viewport().set_input_as_handled()

	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_Q:
				_cycle_weapons()
				get_viewport().set_input_as_handled()
			KEY_F:
				_cycle_formation()
				get_viewport().set_input_as_handled()
			KEY_G:
				_cycle_group_count()
				get_viewport().set_input_as_handled()
			KEY_1:
				_select_group(0)
				get_viewport().set_input_as_handled()
			KEY_2:
				_select_group(1)
				get_viewport().set_input_as_handled()
			KEY_3:
				_select_group(2)
				get_viewport().set_input_as_handled()

# ---------------------------------------------------------------------------
# Process — drives continuous AUTO fire while right mouse is held
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	if not _right_held or soldiers.is_empty():
		return
	if not _is_continuous_weapon():
		return
	_auto_timer -= delta
	if _auto_timer <= 0.0:
		_auto_timer = _current_auto_interval()
		_issue_fire_order(_screen_to_world(get_viewport().get_mouse_position()))

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
	# Prune any references that have somehow been freed.
	_downed = _downed.filter(func(n: Node2D) -> bool: return is_instance_valid(n))
	if _downed.is_empty():
		return false
	if not GameManager.use_revive():
		return false
	var target: Node2D = _downed.pop_front()
	if target.has_method("revive"):
		target.revive()
	target.group_id = _active_group
	if not soldiers.has(target):
		soldiers.append(target)
	_update_group_hud()
	_update_ammo_hud()
	return true

# Returns true iff a revive potion + at least one downed soldier are available.
func can_revive() -> bool:
	return GameManager.revive_potions > 0 and not _downed.filter(
		func(n: Node2D) -> bool: return is_instance_valid(n)
	).is_empty()

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
			var spread := Vector2(cos(angle), sin(angle)) * 64.0
			var grp := _soldiers_in_group(g)
			for i in grp.size():
				grp[i].move_to(center + spread + _formation_offset(i, grp.size()))
	else:
		# Collapsing back to one group — automatically reform into formation so
		# soldiers regroup without the player having to issue a manual move.
		_issue_move_order(center)
	_update_group_hud()

func _select_group(group: int) -> void:
	if group >= _num_groups:
		return
	# Reject empty groups — selecting one would leave the squad un-orderable
	# and the HUD weapon/ammo readouts stuck on stale state.
	if not _alive_group_ids().has(group):
		return
	_active_group = group
	# Halt soldiers in groups that are no longer active so they hold position
	# and don't collide with the newly commanded group.
	for s in soldiers:
		if s.group_id != _active_group:
			s.halt()
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
	var group := _active_group_soldiers()
	var count := group.size()
	for i in count:
		group[i].move_to(target + _formation_offset(i, count))

func _issue_fire_order(target: Vector2) -> void:
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

	# Every soldier aims directly at the click point. Previously the squad
	# fired toward a single extended convergence point past the click, which
	# meant off-centre soldiers' bullet lines didn't actually pass through the
	# click — they missed.
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

func _formation_offset(index: int, _total: int) -> Vector2:
	var f: Array = FORMATIONS[_formation_index]
	return f[index] if index < f.size() else Vector2.ZERO

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

# Returns the average position of the active group (falls back to all soldiers).
# CameraController uses this to softly follow the group.
# Soldiers armed as walking bombs are excluded so the camera stays on the
# rest of the squad rather than chasing the bomber across the map.
func get_centroid() -> Vector2:
	var src := _active_group_soldiers()
	src = src.filter(func(s: Node2D) -> bool:
		return not (s.has_method("is_armed_bomb") and s.is_armed_bomb()))
	if src.is_empty():
		src = soldiers.filter(func(s: Node2D) -> bool:
			return not (s.has_method("is_armed_bomb") and s.is_armed_bomb()))
	if src.is_empty():
		src = soldiers
	if src.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for s in src:
		sum += s.global_position
	return sum / float(src.size())
