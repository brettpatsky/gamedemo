# =============================================================================
# Minotaur.gd
# Elite melee bruiser — a large, slow, relentless brute with a massive HP pool
# and NO ranged attack. It permanently hunts whichever squad GROUP the player is
# currently controlling (the soldiers flagged is_active), closing to melee range
# and throwing a heavy fist/slam for big AOE damage.
#
# CHASE → ATTACK(windup → strike → recovery) → CHASE state machine. The swing is
# telegraphed (windup) so the squad can scatter, and lands as an arc/AOE so a
# clustered group all gets hit — the whole point is to FORCE the commanded group
# to keep relocating across the map and into the other enemies.
#
# All stats live in BalanceConfig under the MINOTAUR_* prefix. The 8-direction
# art pipeline (frames_dir → idle/walk/attack/die strips) mirrors Enemy.gd; see
# docs/pixellab_8dir_character_guide.md.
# =============================================================================
extends CharacterBody2D

const Balance = preload("res://scripts/BalanceConfig.gd")
const _FLOATING_NUMBER_SCRIPT = preload("res://scripts/FloatingNumberFX.gd")

# Stat numbers live in BalanceConfig; held as instance vars so the rest of the
# script reads by the same names. Resolved in _ready.
var move_speed:    float
var max_health:    int
var attack_range:  float
var melee_radius:  float
var attack_damage: int
var score_value:   int

# Build the AnimatedSprite2D's SpriteFrames at runtime from per-anim strip PNGs
# in this folder (<idle|walk|attack|die>_<facing>.png). Mirrors Enemy.frames_dir.
# Leaving it empty keeps the .tscn-embedded fallback frames.
@export var frames_dir: String = ""

# Soft elemental counters, same system as Enemy.gd. Randomised in _ready unless
# overridden before add_child.
@export var weakness:   int = 0   # Elements.E.NONE
@export var resistance: int = 0   # Elements.E.NONE

@onready var nav_agent:  NavigationAgent2D   = $NavigationAgent2D
@onready var sprite:     AnimatedSprite2D    = $AnimatedSprite2D
@onready var health_bar: ProgressBar         = $HealthBar
@onready var roar_audio: AudioStreamPlayer2D = $RoarAudio

# Built programmatically in _ready (null until the audio file is dropped in).
var _hit_audio: AudioStreamPlayer2D = null

# Cached map-generator lookup — water/slope queries run every physics frame.
var _map_gen_cache: Node = null

func _map_gen() -> Node:
	if _map_gen_cache == null or not is_instance_valid(_map_gen_cache):
		_map_gen_cache = get_tree().get_first_node_in_group("map_generator")
	return _map_gen_cache

enum State { CHASE, ATTACK, DEAD }
var _state: State = State.CHASE

# Attack sub-phases — WINDUP telegraphs the swing, STRIKE applies damage once,
# RECOVERY is the committed/vulnerable tail before returning to CHASE.
enum AtkPhase { WINDUP, RECOVERY }
var _atk_phase: AtkPhase = AtkPhase.WINDUP
var _atk_timer: float    = 0.0
var _attack_cooldown: float = 0.0

# Last direction faced — drives directional idle/walk/attack/die anims.
var _facing: String = "down"
var _use_8way: bool = false

var _health: int
var _target: Node2D = null
var _scan_timer: float = 0.0

# True only on frames where _tick_chase actually issued a nav-driven move this
# step. The NavigationAgent2D keeps emitting velocity_computed every physics
# frame using its LAST desired velocity, so without this gate the avoidance
# callback would re-apply a stale chase velocity on standing-still frames —
# which slid the minotaur off to a boundary after it wiped a squad that still
# had a revive (target goes null, but the body kept coasting). Reset each frame.
var _issued_nav_move: bool = false

# Stuck tracking — escalates to a hard path-teleport, mirrors Enemy.gd.
var _stuck_timer:     float   = 0.0
var _stuck_check_pos: Vector2 = Vector2.ZERO
var _stuck_strikes:   int     = 0

func _ready() -> void:
	add_to_group("enemies")
	move_speed    = Balance.MINOTAUR_MOVE_SPEED
	max_health    = Balance.MINOTAUR_MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE
	attack_range  = Balance.MINOTAUR_ATTACK_RANGE
	melee_radius  = Balance.MINOTAUR_MELEE_RADIUS
	attack_damage = Balance.MINOTAUR_ATTACK_DAMAGE * Balance.COMBAT_NUMBER_SCALE
	score_value   = Balance.MINOTAUR_SCORE_VALUE
	_health              = max_health
	health_bar.max_value = max_health
	health_bar.value     = _health
	_style_health_bar()

	if frames_dir != "":
		_build_frames_from_dir(frames_dir)
	_use_8way = sprite.sprite_frames != null \
			and sprite.sprite_frames.has_animation(&"walk_up_right")
	_hit_audio = _build_hit_audio("res://resources/audio/sfx/enemy_hit.ogg")

	# Randomise weakness + resistance like the regular enemies so the elemental
	# system reads against the minotaur too.
	if weakness == Elements.E.NONE and resistance == Elements.E.NONE:
		var pool: Array[int] = [Elements.E.FIRE, Elements.E.ICE, Elements.E.LIGHTNING]
		pool.shuffle()
		weakness   = pool[0]
		resistance = pool[1]

	# Nav setup mirrors the enemy's RVO avoidance, but with a much larger radius and
	# neighbour window so the big body is steered WIDE around tree colliders (the
	# forest navmesh isn't carved around trees — see MINOTAUR_NAV_* in BalanceConfig).
	nav_agent.path_desired_distance  = 8.0
	nav_agent.target_desired_distance = attack_range * 0.6
	nav_agent.radius             = Balance.MINOTAUR_NAV_RADIUS
	nav_agent.avoidance_enabled  = true
	nav_agent.neighbor_distance  = Balance.MINOTAUR_NAV_NEIGHBOR_DIST
	nav_agent.max_neighbors      = Balance.MINOTAUR_NAV_MAX_NEIGHBORS
	nav_agent.max_speed          = move_speed
	if not nav_agent.velocity_computed.is_connected(_on_safe_velocity):
		nav_agent.velocity_computed.connect(_on_safe_velocity)

	await get_tree().physics_frame

func _physics_process(delta: float) -> void:
	_scan_timer       = max(_scan_timer - delta, 0.0)
	_attack_cooldown  = max(_attack_cooldown - delta, 0.0)
	_issued_nav_move  = false

	if _state == State.DEAD:
		return

	# Stand idle until the player issues their first move order, matching the
	# regular enemies so the squad isn't hunted before it has oriented.
	if not GameManager.squad_has_moved:
		_play_idle()
		return

	# Re-pick the target (closest soldier in the controlled group) periodically.
	if _scan_timer <= 0.0:
		_scan_timer = Balance.MINOTAUR_TARGET_SCAN_PERIOD
		_acquire_target()

	match _state:
		State.CHASE:  _tick_chase(delta)
		State.ATTACK: _tick_attack(delta)
		State.DEAD:   pass

# =============================================================================
# STATE TICKS
# =============================================================================

func _tick_chase(delta: float) -> void:
	if not _is_target_engageable():
		velocity = Vector2.ZERO
		move_and_slide()
		_play_idle()
		_reset_stuck()
		return
	var dist: float = global_position.distance_to(_target.global_position)
	# Close enough and the axe is ready → commit to a swing.
	if dist <= attack_range and _attack_cooldown <= 0.0:
		_begin_attack()
		return
	# Within striking range but waiting out the cooldown — it's positioning, not
	# stuck, so don't let the escape logic count these frames.
	if dist <= attack_range:
		_reset_stuck()
		velocity = Vector2.ZERO
		move_and_slide()
		_play_idle()
		return
	nav_agent.target_position = _target.global_position
	_move_toward_nav_target()
	# Only watch for wedging while genuinely closing distance on a far target.
	_tick_stuck_check(delta)

func _begin_attack() -> void:
	_state = State.ATTACK
	_atk_phase = AtkPhase.WINDUP
	_atk_timer = Balance.MINOTAUR_ATTACK_WINDUP
	velocity = Vector2.ZERO
	move_and_slide()
	# Face the victim and play the one-shot swing from frame 0.
	if _target != null:
		var dir: Vector2 = (_target.global_position - global_position).normalized()
		_face(dir)
	if _use_8way:
		sprite.play("attack_" + _facing)
		sprite.set_frame_and_progress(0, 0.0)
	else:
		_play_anim("attack")
	if roar_audio != null and roar_audio.stream != null:
		roar_audio.pitch_scale = randf_range(0.9, 1.05)
		roar_audio.play()

# Rooted while swinging — the commitment is what gives the squad room to escape.
func _tick_attack(delta: float) -> void:
	velocity = Vector2.ZERO
	move_and_slide()
	_atk_timer -= delta
	if _atk_timer > 0.0:
		return
	match _atk_phase:
		AtkPhase.WINDUP:
			# The fist lands — damage every engageable soldier in the arc.
			_strike()
			_atk_phase = AtkPhase.RECOVERY
			_atk_timer = Balance.MINOTAUR_ATTACK_RECOVERY
		AtkPhase.RECOVERY:
			_attack_cooldown = Balance.MINOTAUR_ATTACK_COOLDOWN
			_state = State.CHASE

# Applies the swing's damage to all engageable soldiers within melee_radius.
# AOE on purpose — a bunched-up group all gets clobbered.
func _strike() -> void:
	for s in get_tree().get_nodes_in_group("soldiers"):
		if not _is_soldier_engageable(s):
			continue
		var sd: Node2D = s as Node2D
		if sd.global_position.distance_to(global_position) <= melee_radius:
			if sd.has_method("take_damage"):
				sd.take_damage(attack_damage)

# Target = the closest engageable soldier in the GROUP the player is currently
# controlling (is_active). Falls back to any engageable soldier if the active
# group is wiped/empty so the minotaur is never left idle with prey on the map.
func _acquire_target() -> void:
	var best_active: Node2D = null
	var best_active_d := INF
	var best_any: Node2D = null
	var best_any_d := INF
	for s in get_tree().get_nodes_in_group("soldiers"):
		if not _is_soldier_engageable(s):
			continue
		var sd: Node2D = s as Node2D
		var d: float = sd.global_position.distance_to(global_position)
		if d < best_any_d:
			best_any_d = d
			best_any   = sd
		if "is_active" in sd and sd.is_active and d < best_active_d:
			best_active_d = d
			best_active   = sd
	_target = best_active if best_active != null else best_any

# Mirrors Enemy._is_soldier_engageable: skips downed soldiers and the sheltered
# escort NPC (in "soldiers" for the HUD but not a valid target until freed).
func _is_soldier_engageable(s: Node) -> bool:
	if not is_instance_valid(s):
		return false
	if s.has_method("is_downed") and s.is_downed():
		return false
	if s.has_method("is_freed") and not s.is_freed():
		return false
	return true

func _is_target_engageable() -> bool:
	return _is_soldier_engageable(_target)

# =============================================================================
# MOVEMENT HELPERS  (mirror Enemy.gd)
# =============================================================================

func _move_toward_nav_target() -> void:
	if nav_agent.is_navigation_finished():
		_play_idle()
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var dir:  Vector2 = (next - global_position).normalized()
	var desired := dir * move_speed * _water_speed_mult() * _slope_speed_mult(dir)
	nav_agent.max_speed = move_speed
	_issued_nav_move = true
	nav_agent.set_velocity(desired)
	_play_walk_anim(dir)

func _on_safe_velocity(safe_velocity: Vector2) -> void:
	# Guard ATTACK/DEAD so a stale chase velocity can't drag the minotaur mid-swing,
	# and only move on frames where _tick_chase actually requested a nav move — the
	# agent re-emits this signal every frame with its last desired velocity, which
	# otherwise coasted the minotaur off-map once its target was gone.
	if _state == State.ATTACK or _state == State.DEAD or not _issued_nav_move:
		return
	velocity = safe_velocity
	move_and_slide()

func _water_speed_mult() -> float:
	var map_gen: Node = _map_gen()
	if map_gen and map_gen.has_method("is_water_at") and map_gen.is_water_at(global_position):
		return Balance.MINOTAUR_WATER_SPEED_MULT
	return 1.0

func _slope_speed_mult(direction: Vector2) -> float:
	var map_gen: Node = _map_gen()
	if map_gen and map_gen.has_method("get_slope_speed_mult"):
		return map_gen.get_slope_speed_mult(global_position, direction)
	return 1.0

# =============================================================================
# ANIMATION  (mirror Enemy.gd; "attack" replaces the enemy's "shoot")
# =============================================================================

func _face(dir: Vector2) -> void:
	if _use_8way:
		_facing = _dir_to_facing(dir)
		sprite.flip_h = false
	else:
		if dir.x != 0:
			sprite.flip_h = dir.x < 0

func _play_walk_anim(direction: Vector2) -> void:
	if _use_8way:
		_facing = _dir_to_facing(direction)
		sprite.flip_h = false
		_play_anim("walk_" + _facing)
		return
	if abs(direction.y) > abs(direction.x):
		sprite.flip_h = false
		_play_anim("walk_up" if direction.y < 0 else "walk_down")
	else:
		sprite.flip_h = direction.x < 0
		_play_anim("walk_side")

func _play_anim(anim_name: String) -> void:
	if sprite.sprite_frames == null or not sprite.sprite_frames.has_animation(anim_name):
		return
	# `or not is_playing()` matters on the very first idle: assigning sprite_frames
	# at runtime leaves `animation` on the new set's first anim (idle_down) but NOT
	# playing, so a name-only guard would freeze the sprite on frame 0 until it
	# first moved. Looping anims keep playing once started — no spurious restart.
	if sprite.animation != anim_name or not sprite.is_playing():
		sprite.play(anim_name)

func _play_idle() -> void:
	if _use_8way:
		_play_anim("idle_" + _facing)
	else:
		_play_anim("idle")

func _dir_to_facing(dir: Vector2) -> String:
	if _use_8way:
		if dir == Vector2.ZERO:
			return _facing
		var deg := rad_to_deg(dir.angle())
		if deg < 0.0:
			deg += 360.0
		var idx: int = int(round(deg / 45.0)) % 8
		return ["right", "down_right", "down", "down_left",
				"left", "up_left", "up", "up_right"][idx]
	if abs(dir.y) > abs(dir.x):
		return "up" if dir.y < 0 else "down"
	return "left" if dir.x < 0 else "right"

# Builds SpriteFrames from per-anim strip PNGs in `dir`. Same builder shape as
# Enemy._build_frames_from_dir, with "attack" in place of "shoot" and a larger
# normalised target height (MINOTAUR_SPRITE_HEIGHT) so it towers over the kids.
func _build_frames_from_dir(dir: String) -> void:
	var specs := {
		"idle":   {"fps": 6.0,  "loop": true},
		"walk":   {"fps": 9.0,  "loop": true},
		"attack": {"fps": 12.0, "loop": false},
		"die":    {"fps": 10.0, "loop": false},
	}
	var facings := ["down", "up", "left", "right",
			"down_right", "down_left", "up_right", "up_left"]
	var nf := SpriteFrames.new()
	nf.remove_animation(&"default")
	var frame_h := 0
	var added := 0
	var die_added := 0
	for prefix in specs:
		for facing in facings:
			var path: String = dir.path_join("%s_%s.png" % [prefix, facing])
			if not ResourceLoader.exists(path):
				continue
			var tex: Texture2D = load(path)
			if tex == null or tex.get_height() <= 0:
				continue
			frame_h = tex.get_height()
			var strip_img: Image = tex.get_image()
			@warning_ignore("integer_division")
			var cols: int = maxi(1, tex.get_width() / frame_h)
			var anim := "%s_%s" % [prefix, facing]
			nf.add_animation(anim)
			nf.set_animation_loop(anim, specs[prefix]["loop"])
			nf.set_animation_speed(anim, specs[prefix]["fps"])
			for i in cols:
				var sub: Image = strip_img.get_region(Rect2i(i * frame_h, 0, frame_h, frame_h))
				sub.generate_mipmaps()
				nf.add_frame(anim, ImageTexture.create_from_image(sub))
			added += 1
			if prefix == "die":
				die_added += 1
	if added == 0:
		return
	# Preserve the embedded single "die" pose if no directional die strips exist.
	if die_added == 0:
		var old := sprite.sprite_frames
		if old != null and old.has_animation(&"die"):
			nf.add_animation(&"die")
			nf.set_animation_loop(&"die", old.get_animation_loop(&"die"))
			nf.set_animation_speed(&"die", old.get_animation_speed(&"die"))
			for i in old.get_frame_count(&"die"):
				nf.add_frame(&"die", old.get_frame_texture(&"die", i),
						old.get_frame_duration(&"die", i))
	sprite.sprite_frames = nf
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Normalise by the figure's opaque bounds so it isn't rendered tiny. Target
	# MINOTAUR_SPRITE_HEIGHT (≈1.5× the kids) so it reads large and intimidating.
	var ref_path: String = dir.path_join("idle_down.png")
	if not ResourceLoader.exists(ref_path):
		ref_path = dir.path_join("walk_down.png")
	var char_h: int = frame_h
	if ResourceLoader.exists(ref_path):
		var rimg: Image = (load(ref_path) as Texture2D).get_image()
		if rimg != null:
			var ur: Rect2i = rimg.get_used_rect()
			if ur.size.y > 0:
				char_h = ur.size.y
	if char_h > 0:
		var s := Balance.MINOTAUR_SPRITE_HEIGHT / float(char_h)
		sprite.scale = Vector2(s, s)

# =============================================================================
# DAMAGE / DEATH  (mirror Enemy.gd)
# =============================================================================

func _build_hit_audio(path: String) -> AudioStreamPlayer2D:
	if not ResourceLoader.exists(path):
		return null
	var player := AudioStreamPlayer2D.new()
	player.stream = load(path)
	player.bus = &"sfx"
	player.max_distance = 2000.0
	player.max_polyphony = 3
	add_child(player)
	return player

# Larger health bar than the regular enemy's to match the bigger silhouette.
func _style_health_bar() -> void:
	health_bar.show_percentage = false
	health_bar.custom_minimum_size = Vector2(60, 6)
	health_bar.size = Vector2(60, 6)
	health_bar.position = Vector2(-30, -52)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.1, 0.85)
	bg.border_color = Color(0, 0, 0, 0.9)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(2)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.85, 0.2, 0.2)
	fill.set_corner_radius_all(2)
	health_bar.add_theme_stylebox_override("background", bg)
	health_bar.add_theme_stylebox_override("fill", fill)

func _spawn_damage_number(amount: int, color: Color) -> void:
	var fx := Node2D.new()
	fx.set_script(_FLOATING_NUMBER_SCRIPT)
	get_viewport().add_child(fx)
	fx.global_position = global_position + Vector2(0, -56)
	fx.start(amount, color)

func take_damage(amount: int, element: int = 0) -> void:
	if _state == State.DEAD:
		return
	var net: int = Elements.apply_damage(amount, element, weakness, resistance)
	_health -= net
	health_bar.value = _health
	var crit: bool = element != 0 and element == weakness
	var num_color: Color = Color(1.0, 0.95, 0.3) if not crit else Color(1.0, 0.7, 0.15)
	_spawn_damage_number(net, num_color)
	if _hit_audio != null:
		_hit_audio.pitch_scale = randf_range(0.85, 1.05)
		_hit_audio.play()
	if _health <= 0:
		_die()

func _die() -> void:
	_state = State.DEAD
	velocity = Vector2.ZERO
	if _use_8way and sprite.sprite_frames.has_animation("die_" + _facing):
		_play_anim("die_" + _facing)
	else:
		_play_anim("die")
	remove_from_group("enemies")

	$CollisionShape2D.set_deferred("disabled", true)

	GameManager.add_score(score_value)
	GameManager.on_enemy_died()

	await sprite.animation_finished

	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 2.0)
	await tween.finished
	queue_free()

# =============================================================================
# STUCK RECOVERY  (mirror Enemy.gd, MINOTAUR_STUCK_*)
# =============================================================================

func _reset_stuck() -> void:
	_stuck_strikes = 0
	_stuck_check_pos = global_position

func _tick_stuck_check(delta: float) -> void:
	if nav_agent.is_navigation_finished():
		_reset_stuck()
		return
	_stuck_timer -= delta
	if _stuck_timer > 0.0:
		return
	_stuck_timer = Balance.MINOTAUR_STUCK_CHECK_INTERVAL
	var moved: bool = global_position.distance_to(_stuck_check_pos) >= Balance.MINOTAUR_STUCK_THRESHOLD
	_stuck_check_pos = global_position
	if moved:
		_stuck_strikes = 0
		return
	# Two-tier escape: nudge along the path first; if it's still wedged several
	# checks later (a real pinch between trees the big body can't thread), blink a
	# short hop onto a navmesh point toward the target — a guaranteed way out.
	_stuck_strikes += 1
	if _stuck_strikes >= Balance.MINOTAUR_STUCK_TELEPORT_STRIKES:
		_blink_unstick()
		_reset_stuck()
	elif _stuck_strikes >= Balance.MINOTAUR_STUCK_HARD_STRIKES:
		_hard_unstick()

# Tier 1: slide toward the next path waypoint with move_and_collide so it rounds
# prop corners but can't punch through a wall / cliff face.
func _hard_unstick() -> void:
	if nav_agent.is_navigation_finished():
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var diff: Vector2 = next - global_position
	if diff.length() < 1.0:
		return
	move_and_collide(diff.normalized() * minf(diff.length(), 64.0))

# Tier 2: short teleport toward the target, landing on the nearest navmesh point,
# with a quick fade-in so the hop reads as intentional rather than a glitch. This
# is the escape from any pinch the big body physically can't squeeze through.
func _blink_unstick() -> void:
	var dir: Vector2 = _blink_dir()
	if dir == Vector2.ZERO:
		return
	var dest: Vector2 = global_position + dir * Balance.MINOTAUR_STUCK_TELEPORT_DIST
	dest = NavigationServer2D.map_get_closest_point(get_world_2d().navigation_map, dest)
	global_position = dest
	velocity = Vector2.ZERO
	modulate.a = 0.25
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, Balance.MINOTAUR_TELEPORT_FADE_TIME)

# Blink direction: toward the next path waypoint if there is one (follows the
# route out of the pinch), else straight at the target.
func _blink_dir() -> Vector2:
	if not nav_agent.is_navigation_finished():
		var nxt: Vector2 = nav_agent.get_next_path_position()
		var d: Vector2 = nxt - global_position
		if d.length() > 4.0:
			return d.normalized()
	if _target != null and is_instance_valid(_target):
		var dt: Vector2 = _target.global_position - global_position
		if dt.length() > 1.0:
			return dt.normalized()
	return Vector2.ZERO
