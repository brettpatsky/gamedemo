extends Node2D

const MAX_SOLDIERS     := 8
const FORMATION_RADIUS := 40.0
const AUTO_INTERVAL    := 0.5   # seconds between shots for the AUTO weapon

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

func _formation_offset(index: int, total: int) -> Vector2:
	if index == 0 or total == 1:
		return Vector2.ZERO
	var ring   := 1 if index <= 6 else 2
	var ring_r := FORMATION_RADIUS * ring
	var angle  := deg_to_rad(float(index - 1) * (360.0 / min(total - 1, 6)))
	return Vector2(cos(angle), sin(angle)) * ring_r

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
