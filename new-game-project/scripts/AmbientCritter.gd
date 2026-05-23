# =============================================================================
# AmbientCritter.gd
# A small rabbit-ish silhouette that wanders the map between brief pauses.
# Purely visual — no collision and no gameplay effect. Reacts to bullets
# whizzing past by sprinting away for a moment, and refuses to wander into
# water tiles.
# =============================================================================
class_name AmbientCritter
extends Node2D

const MOVE_SPEED     := 55.0
const SPRINT_SPEED   := 160.0   # speed when scared
const PAUSE_MIN      := 1.5
const PAUSE_MAX      := 4.0
const WANDER_MIN     := 60.0
const WANDER_MAX     := 180.0
const SPOOK_RADIUS   := 80.0
const SCARED_TIME    := 1.5
const FLEE_DIST      := 130.0
const WATER_RETRIES  := 5        # attempts to find a non-water target

var _target:       Vector2 = Vector2.ZERO
var _pause_timer:  float   = 0.0
var _scared_timer: float   = 0.0
var _map_rect:     Rect2   = Rect2()
var _facing_left:  bool    = false
var _hop_phase:    float   = 0.0

# Called once right after instantiate. `map_rect` clamps the wander targets
# so the critter doesn't head off the map edge.
func setup(spawn_pos: Vector2, map_rect: Rect2) -> void:
	global_position = spawn_pos
	_map_rect = map_rect
	_target = spawn_pos
	_pause_timer = randf_range(0.0, PAUSE_MAX)
	z_index = 1
	_pick_new_target()

func _process(delta: float) -> void:
	_hop_phase += delta * 8.0
	_scared_timer = maxf(_scared_timer - delta, 0.0)
	_check_for_bullets()

	if _pause_timer > 0.0:
		_pause_timer -= delta
		queue_redraw()
		return

	var diff: Vector2 = _target - global_position
	if diff.length() < 4.0:
		# Only pause if we're not actively fleeing — sprint feels broken if
		# we hit our flee target and immediately freeze.
		_pause_timer = 0.0 if _scared_timer > 0.0 else randf_range(PAUSE_MIN, PAUSE_MAX)
		_pick_new_target()
		return

	var speed: float = SPRINT_SPEED if _scared_timer > 0.0 else MOVE_SPEED
	var step: Vector2 = diff.normalized() * speed * delta
	global_position += step
	_facing_left = step.x < 0.0
	queue_redraw()

# Polls the "bullets" group (populated by Bullet._ready) and flees from the
# first one inside SPOOK_RADIUS. Cheap — 4 critters × handful of bullets.
func _check_for_bullets() -> void:
	var r_sq: float = SPOOK_RADIUS * SPOOK_RADIUS
	for b in get_tree().get_nodes_in_group("bullets"):
		if not is_instance_valid(b):
			continue
		if global_position.distance_squared_to((b as Node2D).global_position) < r_sq:
			_flee_from((b as Node2D).global_position)
			return

func _flee_from(threat_pos: Vector2) -> void:
	var flee_dir: Vector2 = (global_position - threat_pos).normalized()
	if flee_dir == Vector2.ZERO:
		flee_dir = Vector2.RIGHT
	var t: Vector2 = global_position + flee_dir * FLEE_DIST
	t.x = clampf(t.x, _map_rect.position.x + 32.0, _map_rect.end.x - 32.0)
	t.y = clampf(t.y, _map_rect.position.y + 32.0, _map_rect.end.y - 32.0)
	_target = t
	_pause_timer = 0.0
	_scared_timer = SCARED_TIME

# Picks a wander destination, re-rolling up to WATER_RETRIES times if it
# lands on a water tile. Falls back to the last attempt if all roll water,
# so the critter never freezes from indecision.
func _pick_new_target() -> void:
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	var t: Vector2 = global_position
	for attempt in WATER_RETRIES:
		var angle: float = randf() * TAU
		var dist: float  = randf_range(WANDER_MIN, WANDER_MAX)
		t = global_position + Vector2(cos(angle), sin(angle)) * dist
		t.x = clampf(t.x, _map_rect.position.x + 32.0, _map_rect.end.x - 32.0)
		t.y = clampf(t.y, _map_rect.position.y + 32.0, _map_rect.end.y - 32.0)
		if map_gen == null or not map_gen.has_method("is_water_at"):
			break
		if not map_gen.is_water_at(t):
			break
	_target = t

func _draw() -> void:
	var bob: float = 0.0
	if _pause_timer <= 0.0:
		bob = sin(_hop_phase) * 1.5
	var body  := Color(0.45, 0.30, 0.22)
	var belly := Color(0.78, 0.66, 0.55)
	var ear_x_offset: float = 2.0 if _facing_left else -2.0
	var head_x:       float = -5.0 if _facing_left else 5.0
	draw_circle(Vector2(0, 0 + bob), 6.0, body)
	draw_circle(Vector2(0, 2 + bob), 3.0, belly)
	draw_circle(Vector2(head_x, -3 + bob), 3.5, body)
	draw_line(Vector2(head_x - 1.0 + ear_x_offset, -6 + bob),
			Vector2(head_x - 1.0 + ear_x_offset, -10 + bob), body, 1.5)
	draw_line(Vector2(head_x + 1.0 + ear_x_offset, -6 + bob),
			Vector2(head_x + 1.0 + ear_x_offset, -10 + bob), body, 1.5)
