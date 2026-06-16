# =============================================================================
# AmbientCritter.gd
# Wandering wildlife — bunny and fox variants. Purely visual, no gameplay.
#
# Threat priority (triggers sprint flee):
#   Bunny: bullets, soldiers, enemies, nearby fox
#   Fox:   bullets, soldiers, enemies
#
# Textures live in res://resources/environment/ambient/{bunny|fox}/.
# Falls back to a coloured circle silhouette while textures are missing.
# =============================================================================
class_name AmbientCritter
extends Node2D

const Balance = preload("res://scripts/BalanceConfig.gd")

enum Type { BUNNY, FOX }

const _TEX_DIR := {
	Type.BUNNY: "res://resources/environment/ambient/rabbit/",
	Type.FOX:   "res://resources/environment/ambient/fox/",
}
const _FRAME_COUNT := 9   # both animations have 9 frames each

var type: Type = Type.BUNNY

var _target:       Vector2 = Vector2.ZERO
var _pause_timer:  float   = 0.0
var _scared_timer: float   = 0.0
var _map_rect:     Rect2   = Rect2()
var _facing_left:  bool    = false

var _anim:    AnimatedSprite2D = null
var _has_tex: bool             = false

# ---------------------------------------------------------------------------
func setup(spawn_pos: Vector2, map_rect: Rect2, critter_type: Type = Type.BUNNY) -> void:
	type            = critter_type  # harmless if already set by spawner before add_child
	global_position = spawn_pos
	_map_rect       = map_rect
	_target         = spawn_pos
	var pause_max: float = Balance.AMBIENT_FOX_PAUSE_MAX if type == Type.FOX \
			else Balance.AMBIENT_CRITTER_PAUSE_MAX
	_pause_timer = randf_range(0.0, pause_max)
	z_index      = Balance.AMBIENT_CRITTER_Z
	_pick_new_target()

func _ready() -> void:
	match type:
		Type.BUNNY: add_to_group("critter_bunny")
		Type.FOX:   add_to_group("critter_fox")
	add_to_group("ambient_critters")

	_anim = AnimatedSprite2D.new()
	_anim.scale = Vector2(0.75, 0.75)
	add_child(_anim)
	_build_sprite_frames()
	if _has_tex:
		_anim.play("idle")

func _build_sprite_frames() -> void:
	var dir: String = _TEX_DIR[type]
	for i in _FRAME_COUNT:
		if not ResourceLoader.exists(dir + "hop_%d.png" % i):
			return
		if not ResourceLoader.exists(dir + "idle_%d.png" % i):
			return

	var sf := SpriteFrames.new()

	sf.add_animation("idle")
	sf.set_animation_speed("idle", 6.0)
	sf.set_animation_loop("idle", true)
	for i in _FRAME_COUNT:
		sf.add_frame("idle", load(dir + "idle_%d.png" % i))

	sf.add_animation("hop")
	sf.set_animation_speed("hop", 12.0)
	sf.set_animation_loop("hop", true)
	for i in _FRAME_COUNT:
		sf.add_frame("hop", load(dir + "hop_%d.png" % i))

	_anim.sprite_frames = sf
	_has_tex = true

# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	_scared_timer = maxf(_scared_timer - delta, 0.0)
	_check_for_threats()

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
		var pause_min: float = Balance.AMBIENT_FOX_PAUSE_MIN if type == Type.FOX \
				else Balance.AMBIENT_CRITTER_PAUSE_MIN
		var pause_max: float = Balance.AMBIENT_FOX_PAUSE_MAX if type == Type.FOX \
				else Balance.AMBIENT_CRITTER_PAUSE_MAX
		_pause_timer = 0.0 if _scared_timer > 0.0 else randf_range(pause_min, pause_max)
		_pick_new_target()
		return

	var move_speed:   float = Balance.AMBIENT_FOX_MOVE_SPEED   if type == Type.FOX \
			else Balance.AMBIENT_CRITTER_MOVE_SPEED
	var sprint_speed: float = Balance.AMBIENT_FOX_SPRINT_SPEED if type == Type.FOX \
			else Balance.AMBIENT_CRITTER_SPRINT_SPEED
	var speed: float = sprint_speed if _scared_timer > 0.0 else move_speed
	var step: Vector2 = diff.normalized() * speed * delta
	global_position += step
	_facing_left     = step.x < 0.0
	if _has_tex:
		if _anim.animation != "hop":
			_anim.play("hop")
		_anim.flip_h = _facing_left

# ---------------------------------------------------------------------------
func _check_for_threats() -> void:
	# Bullets — close range, very scary.
	var bullet_r_sq: float = Balance.AMBIENT_CRITTER_SPOOK_RADIUS \
			* Balance.AMBIENT_CRITTER_SPOOK_RADIUS
	for b in get_tree().get_nodes_in_group("bullets"):
		if not is_instance_valid(b):
			continue
		if global_position.distance_squared_to((b as Node2D).global_position) < bullet_r_sq:
			_flee_from((b as Node2D).global_position)
			return

	# Soldiers (player squad) and enemies — larger detection bubble.
	var threat_r_sq: float = Balance.AMBIENT_CRITTER_THREAT_RADIUS \
			* Balance.AMBIENT_CRITTER_THREAT_RADIUS
	for grp in ["soldiers", "enemies"]:
		for n in get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(n):
				continue
			if global_position.distance_squared_to((n as Node2D).global_position) < threat_r_sq:
				_flee_from((n as Node2D).global_position)
				return

	# Bunnies also flee from nearby foxes.
	if type == Type.BUNNY:
		for fox in get_tree().get_nodes_in_group("critter_fox"):
			if not is_instance_valid(fox):
				continue
			if global_position.distance_squared_to((fox as Node2D).global_position) < threat_r_sq:
				_flee_from((fox as Node2D).global_position)
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
	for _attempt in Balance.AMBIENT_CRITTER_WATER_RETRIES:
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

# ---------------------------------------------------------------------------
func _draw() -> void:
	if _has_tex:
		return
	# Coloured silhouette fallback — brown for bunny, orange for fox.
	var body: Color  = Color(0.85, 0.40, 0.08) if type == Type.FOX \
			else Color(0.45, 0.30, 0.22)
	var belly: Color = Color(0.95, 0.70, 0.45) if type == Type.FOX \
			else Color(0.78, 0.66, 0.55)
	var ear_x: float  = 2.0 if _facing_left else -2.0
	var head_x: float = -5.0 if _facing_left else 5.0
	draw_circle(Vector2(0, 0),        6.0, body)
	draw_circle(Vector2(0, 2.0),      3.0, belly)
	draw_circle(Vector2(head_x, -3),  3.5, body)
	if type == Type.FOX:
		# Pointed fox ears
		draw_line(Vector2(head_x + ear_x - 1.0, -6),
				Vector2(head_x + ear_x - 2.0, -10), body, 2.0)
		draw_line(Vector2(head_x + ear_x + 1.0, -6),
				Vector2(head_x + ear_x + 2.0, -10), body, 2.0)
	else:
		# Long bunny ears
		draw_line(Vector2(head_x - 1.0 + ear_x, -6),
				Vector2(head_x - 1.0 + ear_x, -10), body, 1.5)
		draw_line(Vector2(head_x + 1.0 + ear_x, -6),
				Vector2(head_x + 1.0 + ear_x, -10), body, 1.5)
