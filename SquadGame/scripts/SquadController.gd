# =============================================================================
# SquadController.gd
# Attach to a Node2D called "SquadController" in Main.tscn.
#
# RESPONSIBILITIES:
#   - Maintains a list of active Soldier nodes (up to MAX_SOLDIERS = 8).
#   - LEFT CLICK  → move the whole squad to the clicked world position.
#   - RIGHT CLICK → fire projectiles toward the clicked world position.
#   - Lays out soldiers in a staggered formation around the target point.
#   - Handles adding / removing soldiers dynamically at runtime.
# =============================================================================
extends Node2D

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
const MAX_SOLDIERS     := 8    # Cannon Fodder-style hard cap
const FORMATION_RADIUS := 40.0 # pixels; spread between soldiers in formation

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var soldiers: Array[Node2D] = []    # live Soldier nodes managed by this controller

# Reference to the camera so we can convert screen → world coordinates
@onready var camera: Camera2D = get_tree().get_first_node_in_group("main_camera")

# ---------------------------------------------------------------------------
# _ready — wire up the GameManager signal so dead soldiers auto-remove
# ---------------------------------------------------------------------------
func _ready() -> void:
	GameManager.soldier_died.connect(_on_soldier_died)

# ---------------------------------------------------------------------------
# _unhandled_input — runs AFTER UI controls consume their events
# (prevents clicks on HUD buttons from moving soldiers)
# ---------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if soldiers.is_empty():
		return

	# ---- LEFT CLICK → MOVE ORDER ----------------------------------------
	if event is InputEventMouseButton \
	and event.button_index == MOUSE_BUTTON_LEFT \
	and event.pressed:
		var world_pos := _screen_to_world(event.position)
		_issue_move_order(world_pos)
		get_viewport().set_input_as_handled()   # consume event

	# ---- RIGHT CLICK → FIRE ORDER ----------------------------------------
	elif event is InputEventMouseButton \
	and event.button_index == MOUSE_BUTTON_RIGHT \
	and event.pressed:
		var world_pos := _screen_to_world(event.position)
		_issue_fire_order(world_pos)
		get_viewport().set_input_as_handled()

# =============================================================================
# PUBLIC API
# =============================================================================

# Add a Soldier node to the squad (called during map setup / reinforcements)
func add_soldier(soldier: Node2D) -> void:
	if soldiers.size() >= MAX_SOLDIERS:
		push_warning("[SquadController] Squad full — cannot add more soldiers.")
		return
	soldiers.append(soldier)
	GameManager.soldiers_alive += 1

# Remove a soldier from the managed list (called from _on_soldier_died)
func remove_soldier(soldier: Node2D) -> void:
	soldiers.erase(soldier)

# =============================================================================
# PRIVATE — ORDER LOGIC
# =============================================================================

# Distribute soldiers to staggered positions around the target
func _issue_move_order(target: Vector2) -> void:
	var count := soldiers.size()
	for i in count:
		var offset := _formation_offset(i, count)
		var dest   := target + offset
		# Each soldier exposes a move_to(destination) method
		soldiers[i].move_to(dest)

# Tell every soldier to aim and shoot toward the target position
func _issue_fire_order(target: Vector2) -> void:
	for soldier in soldiers:
		# Each soldier handles bullet spawning internally
		soldier.fire_at(target)

# =============================================================================
# PRIVATE — FORMATION MATH
# =============================================================================

# Returns a 2D offset so soldiers fan out in a rough arc / grid.
# Soldier 0 is centred; others spiral outward in a hexagonal ring pattern.
func _formation_offset(index: int, total: int) -> Vector2:
	if index == 0 or total == 1:
		return Vector2.ZERO  # lead soldier goes exactly to the target

	# Arrange extras in a ring: angle evenly distributed, radius = FORMATION_RADIUS
	# Ring 1 holds up to 6 soldiers, ring 2 the remainder.
	var ring    := 1 if index <= 6 else 2
	var ring_r  := FORMATION_RADIUS * ring
	# Evenly space within ring (index 1-6 gives 0°..300°)
	var angle   := deg_to_rad(float(index - 1) * (360.0 / min(total - 1, 6)))
	return Vector2(cos(angle), sin(angle)) * ring_r

# =============================================================================
# PRIVATE — COORDINATE CONVERSION
# =============================================================================

# Converts a viewport pixel position to world space, respecting camera zoom/pan.
func _screen_to_world(screen_pos: Vector2) -> Vector2:
	if camera:
		return camera.get_canvas_transform().affine_inverse() * screen_pos
	# Fallback if camera not found
	return get_viewport().canvas_transform.affine_inverse() * screen_pos

# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_soldier_died(soldier: Node2D) -> void:
	remove_soldier(soldier)
