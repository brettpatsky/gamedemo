extends Node2D

const MAX_SOLDIERS  := 8
const AUTO_INTERVAL := 0.5

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

@onready var camera: Camera2D = get_tree().get_first_node_in_group("main_camera") as Camera2D

var _right_held: bool  = false   # is right mouse button currently held?
var _auto_timer: float = 0.0     # countdown to next AUTO shot

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
					_auto_timer = AUTO_INTERVAL   # first repeat fires after one interval
				else:
					_right_held = false
				get_viewport().set_input_as_handled()

	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q:
			_cycle_weapons()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F:
			_cycle_formation()
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
		_auto_timer = AUTO_INTERVAL
		_issue_fire_order(_screen_to_world(get_viewport().get_mouse_position()))

# =============================================================================
# PUBLIC API
# =============================================================================

func add_soldier(soldier: Node2D) -> void:
	if soldiers.size() >= MAX_SOLDIERS:
		push_warning("[SquadController] Squad full — cannot add more soldiers.")
		return
	soldiers.append(soldier)
	GameManager.soldiers_alive += 1

func remove_soldier(soldier: Node2D) -> void:
	soldiers.erase(soldier)

# =============================================================================
# PRIVATE — ORDER LOGIC
# =============================================================================

func _issue_move_order(target: Vector2) -> void:
	var count := soldiers.size()
	for i in count:
		soldiers[i].move_to(target + _formation_offset(i, count))

func _issue_fire_order(target: Vector2) -> void:
	for soldier in soldiers:
		soldier.fire_at(target)

# =============================================================================
# PRIVATE — WEAPON CYCLING
# =============================================================================

func _cycle_weapons() -> void:
	for s in soldiers:
		if s.has_method("cycle_weapon"):
			s.cycle_weapon()
	_update_weapon_hud()

func _update_weapon_hud() -> void:
	if soldiers.is_empty():
		return
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud == null or not hud.has_method("update_weapon"):
		return
	var idx: int = soldiers[0].get_weapon()
	var names := ["Pistol", "Auto", "Grenade"]
	hud.update_weapon(names[idx])

func _is_continuous_weapon() -> bool:
	return not soldiers.is_empty() \
		and soldiers[0].has_method("is_continuous_fire") \
		and soldiers[0].is_continuous_fire()

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
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("update_formation"):
		hud.update_formation(FORMATION_NAMES[_formation_index])

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

func get_centroid() -> Vector2:
	if soldiers.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for s in soldiers:
		sum += s.global_position
	return sum / float(soldiers.size())
