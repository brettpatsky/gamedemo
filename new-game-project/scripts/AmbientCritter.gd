# =============================================================================
# AmbientCritter.gd
# A small rabbit that wanders the map between pauses. Purely visual — no
# collision, no gameplay effect. Reacts to bullets by sprinting away briefly,
# and refuses to wander into water tiles.
# Uses AnimatedSprite2D with PixelLab-generated frames:
#   idle  — sitting, nose twitching (9 frames at 6 fps)
#   hop   — bounding forward       (9 frames at 12 fps)
# Falls back to the old circle-draw if textures are missing.
# =============================================================================
class_name AmbientCritter
extends Node2D

const Balance = preload("res://scripts/BalanceConfig.gd")

const DIR_RABBIT := "res://resources/environment/ambient/rabbit/"
const IDLE_BASE  := DIR_RABBIT + "idle_base.png"
const HOP_FRAMES := 9
const IDLE_FRAMES := 9

var _target:       Vector2 = Vector2.ZERO
var _pause_timer:  float   = 0.0
var _scared_timer: float   = 0.0
var _map_rect:     Rect2   = Rect2()
var _facing_left:  bool    = false

var _anim:    AnimatedSprite2D = null
var _has_tex: bool             = false

func setup(spawn_pos: Vector2, map_rect: Rect2) -> void:
	global_position = spawn_pos
	_map_rect       = map_rect
	_target         = spawn_pos
	_pause_timer    = randf_range(0.0, Balance.AMBIENT_CRITTER_PAUSE_MAX)
	z_index         = Balance.AMBIENT_CRITTER_Z
	_pick_new_target()

func _ready() -> void:
	_anim = AnimatedSprite2D.new()
	_anim.scale = Vector2(1.5, 1.5)
	add_child(_anim)
	_build_sprite_frames()
	if _has_tex:
		_anim.play("idle")

func _build_sprite_frames() -> void:
	# Check all frames exist before committing to the animated path.
	if not ResourceLoader.exists(IDLE_BASE):
		return
	for i in HOP_FRAMES:
		if not ResourceLoader.exists(DIR_RABBIT + "hop_%d.png" % i):
			return
	for i in IDLE_FRAMES:
		if not ResourceLoader.exists(DIR_RABBIT + "idle_%d.png" % i):
			return

	var sf := SpriteFrames.new()

	# ── idle ──────────────────────────────────────────────────────────────────
	sf.add_animation("idle")
	sf.set_animation_speed("idle", 6.0)
	sf.set_animation_loop("idle", true)
	for i in IDLE_FRAMES:
		sf.add_frame("idle", load(DIR_RABBIT + "idle_%d.png" % i))

	# ── hop ───────────────────────────────────────────────────────────────────
	sf.add_animation("hop")
	sf.set_animation_speed("hop", 12.0)
	sf.set_animation_loop("hop", true)
	for i in HOP_FRAMES:
		sf.add_frame("hop", load(DIR_RABBIT + "hop_%d.png" % i))

	_anim.sprite_frames = sf
	_has_tex = true

func _process(delta: float) -> void:
	_scared_timer = maxf(_scared_timer - delta, 0.0)
	_check_for_bullets()

	if not _has_tex:
		queue_redraw()

	if _pause_timer > 0.0:
		_pause_timer -= delta
		if _has_tex and _anim.animation != "idle":
			_anim.play("idle")
		_anim.flip_h = _facing_left
		return

	var diff: Vector2 = _target - global_position
	if diff.length() < 4.0:
		_pause_timer = 0.0 if _scared_timer > 0.0 else randf_range(
				Balance.AMBIENT_CRITTER_PAUSE_MIN,
				Balance.AMBIENT_CRITTER_PAUSE_MAX)
		_pick_new_target()
		return

	var speed: float = Balance.AMBIENT_CRITTER_SPRINT_SPEED if _scared_timer > 0.0 \
			else Balance.AMBIENT_CRITTER_MOVE_SPEED
	var step: Vector2 = diff.normalized() * speed * delta
	global_position += step
	_facing_left     = step.x < 0.0
	if _has_tex:
		if _anim.animation != "hop":
			_anim.play("hop")
		_anim.flip_h = _facing_left

func _check_for_bullets() -> void:
	var r_sq: float = Balance.AMBIENT_CRITTER_SPOOK_RADIUS * Balance.AMBIENT_CRITTER_SPOOK_RADIUS
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
	var t: Vector2 = global_position + flee_dir * Balance.AMBIENT_CRITTER_FLEE_DIST
	t.x = clampf(t.x, _map_rect.position.x + 32.0, _map_rect.end.x - 32.0)
	t.y = clampf(t.y, _map_rect.position.y + 32.0, _map_rect.end.y - 32.0)
	_target       = t
	_pause_timer  = 0.0
	_scared_timer = Balance.AMBIENT_CRITTER_SCARED_TIME

func _pick_new_target() -> void:
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	var t: Vector2 = global_position
	for attempt in Balance.AMBIENT_CRITTER_WATER_RETRIES:
		var angle: float = randf() * TAU
		var dist: float  = randf_range(Balance.AMBIENT_CRITTER_WANDER_MIN,
				Balance.AMBIENT_CRITTER_WANDER_MAX)
		t = global_position + Vector2(cos(angle), sin(angle)) * dist
		t.x = clampf(t.x, _map_rect.position.x + 32.0, _map_rect.end.x - 32.0)
		t.y = clampf(t.y, _map_rect.position.y + 32.0, _map_rect.end.y - 32.0)
		if map_gen == null or not map_gen.has_method("is_water_at"):
			break
		if not map_gen.is_water_at(t):
			break
	_target = t

func _draw() -> void:
	if _has_tex:
		return
	# Fallback circle silhouette shown until textures are imported.
	var body  := Color(0.45, 0.30, 0.22)
	var belly := Color(0.78, 0.66, 0.55)
	var ear_x: float  = 2.0 if _facing_left else -2.0
	var head_x: float = -5.0 if _facing_left else 5.0
	draw_circle(Vector2(0, 0),           6.0, body)
	draw_circle(Vector2(0, 2.0),         3.0, belly)
	draw_circle(Vector2(head_x, -3), 3.5, body)
	draw_line(Vector2(head_x - 1.0 + ear_x, -6),
			Vector2(head_x - 1.0 + ear_x, -10), body, 1.5)
	draw_line(Vector2(head_x + 1.0 + ear_x, -6),
			Vector2(head_x + 1.0 + ear_x, -10), body, 1.5)
