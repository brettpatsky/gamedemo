# =============================================================================
# Enemy.gd
# Procedural-enemy actor — PATROL / ALERT / ATTACK state machine with
# strafing in ATTACK, RVO avoidance for movement, and a sight-radius gate
# that pulses every nearby patrolling enemy into ALERT when one spots the
# squad. All stats live in BalanceConfig under the ENEMY_* prefix.
# =============================================================================
extends CharacterBody2D

const Balance = preload("res://scripts/BalanceConfig.gd")
const _FLOATING_NUMBER_SCRIPT = preload("res://scripts/FloatingNumberFX.gd")

# Stat numbers (move speed, HP, ranges, bullet stats) live in BalanceConfig.gd.
# Held as instance vars so the rest of the script keeps reading by the same
# names without indirection.
var move_speed:      float
var max_health:      int
var sight_range:     float
var attack_range:    float
var score_value:     int
var aim_jitter:      float
var bullet_speed:    float
var bullet_distance: float
var bullet_damage:   int

@export var bullet_scene: PackedScene

# When set, build the AnimatedSprite2D's SpriteFrames at runtime from per-anim
# strip PNGs in this folder (<idle|walk|shoot|die>_<facing>.png). Used for the
# corrupted mushroom's high-quality 8-direction set; leaving it empty keeps the
# .tscn-embedded 4-way frames. Mirrors Soldier.gd's frames_dir but also builds
# an 8-way directional `die` (the kids share a single death pose; enemies don't).
@export var frames_dir: String = ""

# -----------------------------------------------------------------------------
# Dummy / training-target mode — tutorial Puzzle 1 uses this so the squad
# has stationary practice targets that retreat instead of shooting back.
#  - never fires
#  - never enters ATTACK state
#  - flees from the closest soldier (capped distance so they don't run off-map)
# Set BEFORE adding the enemy to the tree so _ready picks up the HP override.
# -----------------------------------------------------------------------------
@export var dummy_mode: bool         = false
@export var override_max_health: int = 0
# Tutorial combat trial this enemy belongs to. TutorialMap counts living enemies
# per index and opens the matching gate when the group is wiped. -1 = not adopted
# (every normal mission spawn leaves this at -1).
@export var trial_index: int         = -1

# Brief invulnerability after spawn — guards reinforcements spawned by a
# structure destruction against grenades still in flight from the same
# barrage. Default 0 means "no protection"; set BEFORE add_child to use it.
@export var spawn_protection: float  = 0.0

# Soft elemental counters. NONE means "no preference" for either side; the
# random init in _ready picks one weakness and one (different) resistance
# from {FIRE, ICE, LIGHTNING} for every non-dummy enemy so the player feels
# the system across normal mob spawns. Override per-instance via Inspector
# or by setting before add_child for hand-placed encounters.
@export var weakness:   int = 0   # Elements.E.NONE
@export var resistance: int = 0   # Elements.E.NONE

@onready var nav_agent:  NavigationAgent2D   = $NavigationAgent2D
@onready var sprite:     AnimatedSprite2D    = $AnimatedSprite2D
@onready var health_bar: ProgressBar         = $HealthBar
@onready var detection:  Area2D              = $DetectionArea
@onready var gunshot:    AudioStreamPlayer2D = $GunShotAudio

# Built programmatically in _ready so the enemy.tscn doesn't need a new node.
# Null until the audio file is dropped at the convention path.
var _hit_audio: AudioStreamPlayer2D = null

# Cached map-generator lookup — water/slope queries run every physics frame for
# every moving enemy (~50), so the group lookup is hoisted out of the hot path.
# Enemies are re-instantiated each mission, so the cache can't span maps.
var _map_gen_cache: Node = null

func _map_gen() -> Node:
	if _map_gen_cache == null or not is_instance_valid(_map_gen_cache):
		_map_gen_cache = get_tree().get_first_node_in_group("map_generator")
	return _map_gen_cache

enum State { PATROL, ALERT, ATTACK, DEAD }
var _state: State = State.PATROL

# Last direction the enemy was facing — drives directional idle/walk/shoot/die
# anims when an 8-way frames_dir set is loaded. Stays "down" for the legacy
# 4-way embedded frames (which use flip_h instead).
var _facing: String = "down"
# True when the active SpriteFrames has diagonal animations (the mushroom's
# 8-way set). Legacy enemies keep 4-way frames, so _dir_to_facing stays 4-way.
var _use_8way: bool = false

var _health:           int
var _target:           Node2D = null
var _patrol_timer:     float  = 0.0
var _shoot_cooldown:   float  = 0.0
var _patrol_dest:      Vector2

# Patrol/shoot/scan rates and water slowdown live in BalanceConfig (ENEMY_*).
var _scan_timer: float = 0.0

# Stuck tracking — escalates from "not moving" to a hard teleport along the
# planned path after a few consecutive failed checks. Mirrors Soldier.gd's
# escalation, scaled by Balance.ENEMY_STUCK_*.
var _stuck_timer:     float   = 0.0
var _stuck_check_pos: Vector2 = Vector2.ZERO
var _stuck_strikes:   int     = 0

# Strafing — picks a perpendicular direction to slide while in ATTACK.
# Resets on each ATTACK entry by the timer hitting zero.
var _strafe_timer: float   = 0.0
var _strafe_dir:   Vector2 = Vector2.ZERO

# Counts down from `spawn_protection` after _ready; while > 0, take_damage
# is a no-op. Lets reinforcements appear inside an active grenade barrage
# without being deleted before the player even sees them.
var _spawn_protection_timer: float = 0.0

func _ready() -> void:
	add_to_group("enemies")
	move_speed      = Balance.ENEMY_MOVE_SPEED
	max_health      = (override_max_health if override_max_health > 0 else Balance.ENEMY_MAX_HEALTH) * Balance.COMBAT_NUMBER_SCALE
	sight_range     = Balance.ENEMY_SIGHT_RANGE
	attack_range    = Balance.ENEMY_ATTACK_RANGE
	score_value     = Balance.ENEMY_SCORE_VALUE
	aim_jitter      = Balance.ENEMY_AIM_JITTER
	bullet_speed    = Balance.ENEMY_BULLET_SPEED
	bullet_distance = Balance.ENEMY_BULLET_DISTANCE
	bullet_damage   = Balance.ENEMY_BULLET_DAMAGE * Balance.COMBAT_NUMBER_SCALE
	_health              = max_health
	health_bar.max_value = max_health
	health_bar.value     = _health
	_style_health_bar()

	# Build the high-quality 8-direction SpriteFrames from strip PNGs if a
	# frames_dir is set (the corrupted mushroom). Diagonal anims present ->
	# drive movement/aim/death with 8-way facing; otherwise keep 4-way flip_h.
	if frames_dir != "":
		_build_frames_from_dir(frames_dir)
	_use_8way = sprite.sprite_frames != null \
			and sprite.sprite_frames.has_animation(&"walk_up_right")
	_hit_audio = _build_hit_audio("res://resources/audio/sfx/enemy_hit.ogg")
	_spawn_protection_timer = spawn_protection
	# Randomise weakness + resistance for combat enemies if the spawner
	# didn't override them. Tutorial dummies stay neutral so Puzzle 1 is
	# pure target practice without elemental noise.
	if not dummy_mode and weakness == Elements.E.NONE and resistance == Elements.E.NONE:
		var pool: Array[int] = [Elements.E.FIRE, Elements.E.ICE, Elements.E.LIGHTNING]
		pool.shuffle()
		weakness   = pool[0]
		resistance = pool[1]

	if bullet_scene == null:
		bullet_scene = load("res://scenes/bullet.tscn")

	detection.body_entered.connect(_on_body_entered_detection)
	detection.body_exited.connect(_on_body_exited_detection)
	# Soldiers are on collision layer 2; detection area must include it.
	detection.set_collision_mask_value(2, true)

	# Mirror the soldier nav setup so enemies route around dense trees/rocks via
	# RVO avoidance instead of grinding straight through the prop collision.
	# Dummies are in the flat tutorial map and don't need avoidance.
	if not dummy_mode:
		nav_agent.path_desired_distance  = 4.0
		nav_agent.target_desired_distance = 12.0
		nav_agent.radius             = 18.0
		nav_agent.avoidance_enabled  = true
		nav_agent.neighbor_distance  = 80.0   # cheaper than soldiers (fewer active agents nearby)
		nav_agent.max_neighbors      = 5
		nav_agent.max_speed          = move_speed
		if not nav_agent.velocity_computed.is_connected(_on_safe_velocity):
			nav_agent.velocity_computed.connect(_on_safe_velocity)

	await get_tree().physics_frame
	_set_new_patrol_dest()

func _physics_process(delta: float) -> void:
	_shoot_cooldown          = max(_shoot_cooldown - delta, 0.0)
	_scan_timer              = max(_scan_timer     - delta, 0.0)
	_spawn_protection_timer  = max(_spawn_protection_timer - delta, 0.0)

	if _state == State.DEAD:
		return

	# Stand completely idle until the player issues their first move order.
	# Prevents the squad getting swarmed before they've had a chance to look around.
	if not GameManager.squad_has_moved and not dummy_mode:
		_play_idle()
		return

	# Dummy targets bypass the normal AI entirely.
	if dummy_mode:
		_tick_stuck_check(delta)
		_tick_flee(delta)
		return

	# Periodically actively look for soldiers within sight_range. This lets
	# enemies engage from much farther than the DetectionArea radius would
	# allow, and re-acquire a target if one slipped away unnoticed.
	if _scan_timer <= 0.0:
		_scan_timer = Balance.ENEMY_TARGET_SCAN_PERIOD
		_acquire_target()

	_tick_stuck_check(delta)

	match _state:
		State.PATROL:  _tick_patrol(delta)
		State.ALERT:   _tick_alert(delta)
		State.ATTACK:  _tick_attack(delta)
		State.DEAD:    pass

# Dummy AI — wander around the room with a panic-flee bias when the squad
# gets too close. Used by tutorial Puzzle 1 to give the player MOVING
# practice targets. Pure-flee was broken: dummies sprinted to the farthest
# wall, hit nav-finished, and stood still in corners.
const _DUMMY_PANIC_DIST:        float = 180.0    # squad within this → flee
const _DUMMY_REPICK_MIN:        float = 0.7
const _DUMMY_REPICK_MAX:        float = 1.6
const _DUMMY_WANDER_STEP_MIN:   float = 80.0
const _DUMMY_WANDER_STEP_MAX:   float = 160.0
const _DUMMY_FLEE_STEP_MIN:     float = 120.0
const _DUMMY_FLEE_STEP_MAX:     float = 220.0
var _dummy_repick_timer: float = 0.0

func _tick_flee(delta: float) -> void:
	# Find the nearest soldier so we know whether to panic-flee or just wander.
	var closest: Node2D = null
	var closest_d: float = INF
	for s in get_tree().get_nodes_in_group("soldiers"):
		if not _is_soldier_engageable(s):
			continue
		var d: float = (s as Node2D).global_position.distance_to(global_position)
		if d < closest_d:
			closest_d = d
			closest   = s

	# Repick the wander destination on a timer OR when we've arrived. Without
	# the timer reset on arrival, dummies sat at corners until the timer
	# happened to fire; with both, they're constantly in motion.
	_dummy_repick_timer -= delta
	if _dummy_repick_timer <= 0.0 or nav_agent.is_navigation_finished():
		_dummy_repick_timer = randf_range(_DUMMY_REPICK_MIN, _DUMMY_REPICK_MAX)
		var target_pos: Vector2
		if closest != null and closest_d < _DUMMY_PANIC_DIST:
			# Squad is breathing down our neck — flee, but with a ±45° arc so
			# different dummies don't all stampede in the same direction.
			var flee_dir: Vector2 = (global_position - closest.global_position).normalized()
			flee_dir = flee_dir.rotated(randf_range(-PI * 0.25, PI * 0.25))
			target_pos = global_position + flee_dir * randf_range(_DUMMY_FLEE_STEP_MIN, _DUMMY_FLEE_STEP_MAX)
		else:
			# No immediate threat — just wander to keep the player aiming.
			var angle: float = randf() * TAU
			var step:  float = randf_range(_DUMMY_WANDER_STEP_MIN, _DUMMY_WANDER_STEP_MAX)
			target_pos = global_position + Vector2(cos(angle), sin(angle)) * step
		nav_agent.target_position = target_pos

	if nav_agent.is_navigation_finished():
		velocity = Vector2.ZERO
		move_and_slide()
		_play_idle()
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var dir:  Vector2 = (next - global_position).normalized()
	velocity = dir * move_speed * _water_speed_mult() * _slope_speed_mult(dir)
	move_and_slide()
	_play_walk_anim(dir)

# =============================================================================
# STATE TICKS
# =============================================================================

func _tick_patrol(delta: float) -> void:
	_patrol_timer -= delta
	if _patrol_timer <= 0.0:
		_set_new_patrol_dest()
	_move_toward_nav_target()

func _tick_alert(_delta: float) -> void:
	if not _is_target_engageable():
		_target = null
		_state = State.PATROL
		return
	var dist: float = global_position.distance_to(_target.global_position)
	if dist <= attack_range:
		_state = State.ATTACK
		return
	# Close the distance while opportunistically shooting if roughly in range.
	nav_agent.target_position = _target.global_position
	_move_toward_nav_target()
	if dist <= attack_range * 1.4 and _shoot_cooldown <= 0.0:
		var dir: Vector2 = (_target.global_position - global_position).normalized()
		_fire(dir)
		_shoot_cooldown = Balance.ENEMY_SHOOT_COOLDOWN

func _tick_attack(delta: float) -> void:
	if not _is_target_engageable():
		_target = null
		_state = State.PATROL
		return
	# Pick a fresh perpendicular strafe direction every STRAFE_MIN..MAX_TIME
	# seconds, randomly flipping sides. Replaces the old "stand still and
	# trade shots" feel with actual movement during the firefight.
	_strafe_timer -= delta
	if _strafe_timer <= 0.0:
		_strafe_timer = randf_range(Balance.ENEMY_STRAFE_MIN_TIME, Balance.ENEMY_STRAFE_MAX_TIME)
		var to_target: Vector2 = _target.global_position - global_position
		var perp: Vector2 = Vector2(-to_target.y, to_target.x)
		if perp.length() > 0.01:
			perp = perp.normalized()
			if randf() < 0.5:
				perp = -perp
			_strafe_dir = perp
	velocity = _strafe_dir * move_speed * Balance.ENEMY_STRAFE_SPEED_MULT * _water_speed_mult()
	move_and_slide()
	var dir: Vector2 = (_target.global_position - global_position).normalized()
	if _use_8way:
		# Face the target while strafing. Replay the one-shot spit from frame 0 on
		# each actual shot; between shots (once the spit has finished) hold an aim
		# idle facing the target so the muzzle splatter doesn't linger on screen.
		_facing = _dir_to_facing(dir)
		sprite.flip_h = false
		if _shoot_cooldown <= 0.0:
			_fire(dir)
			_shoot_cooldown = Balance.ENEMY_SHOOT_COOLDOWN
			sprite.play("shoot_" + _facing)
			sprite.set_frame_and_progress(0, 0.0)
		elif not (String(sprite.animation).begins_with("shoot_") and sprite.is_playing()):
			_play_anim("idle_" + _facing)
	else:
		if dir.x != 0:
			sprite.flip_h = dir.x < 0
		_play_anim("shoot")
		if _shoot_cooldown <= 0.0:
			_fire(dir)
			_shoot_cooldown = Balance.ENEMY_SHOOT_COOLDOWN
	var dist: float = global_position.distance_to(_target.global_position)
	if dist > attack_range * 1.2:
		_state = State.ALERT

# Active soldier search — picks the closest live soldier within sight_range.
# Runs at Balance.ENEMY_TARGET_SCAN_PERIOD so the enemy can engage well before the
# physics-based DetectionArea would notice an approach.
func _acquire_target() -> void:
	var best: Node2D = null
	var best_d := sight_range
	for s in get_tree().get_nodes_in_group("soldiers"):
		if not _is_soldier_engageable(s):
			continue
		var d: float = (s as Node2D).global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best   = s
	if best != null:
		_target = best
		if _state == State.PATROL:
			_state = State.ALERT
			# Wake nearby patrolling enemies so the squad doesn't get to
			# pick them off one at a time. Eliminates the trickle and
			# replaces it with proper waves.
			_broadcast_alert()

# Downed soldiers are still in the "soldiers" group (they remain on the field
# so they can be revived), but enemies must not target them.
# The level-3 escort NPC is also in "soldiers" (so the HUD/extraction logic
# picks it up), but enemies must ignore it while it's sheltered behind walls —
# otherwise they shoot the barricade down before the squad arrives.
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
# PRIVATE HELPERS
# =============================================================================

func _move_toward_nav_target() -> void:
	if nav_agent.is_navigation_finished():
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var dir:  Vector2 = (next - global_position).normalized()
	var desired := dir * move_speed * _water_speed_mult() * _slope_speed_mult(dir)
	if nav_agent.avoidance_enabled:
		nav_agent.max_speed = move_speed
		nav_agent.set_velocity(desired)
	else:
		velocity = desired
		move_and_slide()
	_play_walk_anim(dir)

# RVO callback for enemy avoidance. Guards ATTACK and DEAD so a stale
# patrol/alert velocity can't clobber strafing or corpse drift. (Soldiers run
# without RVO — see Soldier._ready — so this pattern lives only on enemies now.)
func _on_safe_velocity(safe_velocity: Vector2) -> void:
	if _state == State.ATTACK or _state == State.DEAD:
		return
	velocity = safe_velocity
	move_and_slide()

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

func _water_speed_mult() -> float:
	var map_gen: Node = _map_gen()
	if map_gen and map_gen.has_method("is_water_at") and map_gen.is_water_at(global_position):
		return Balance.ENEMY_WATER_SPEED_MULT
	return 1.0

# Slope speed multiplier — slower going uphill, faster going downhill.
# MapGenerator clamps the result to ±25 %.
func _slope_speed_mult(direction: Vector2) -> float:
	var map_gen: Node = _map_gen()
	if map_gen and map_gen.has_method("get_slope_speed_mult"):
		return map_gen.get_slope_speed_mult(global_position, direction)
	return 1.0

func _set_new_patrol_dest() -> void:
	var offset := Vector2(randf_range(-150, 150), randf_range(-150, 150))
	_patrol_dest = global_position + offset
	nav_agent.target_position = _patrol_dest
	_patrol_timer = Balance.ENEMY_PATROL_INTERVAL

func _fire(direction: Vector2) -> void:
	if bullet_scene == null:
		return
	# Apply a small random spread so enemies miss occasionally instead of
	# laser-aiming every shot.
	var spread := randf_range(-aim_jitter, aim_jitter)
	var aim    := direction.rotated(spread)
	var b: Node2D = bullet_scene.instantiate()
	get_viewport().add_child(b)
	b.global_position = global_position
	b.initialise(aim, self)
	# Cap travel distance so enemy weapons are strictly out-ranged by the squad.
	if b.has_method("set_stats"):
		b.set_stats(bullet_damage, bullet_speed, bullet_distance, Color(0.3, 1.0, 0.2))
	gunshot.pitch_scale = randf_range(0.9, 1.1)
	gunshot.play()

func _play_anim(anim_name: String) -> void:
	if sprite.sprite_frames == null or not sprite.sprite_frames.has_animation(anim_name):
		return
	if sprite.animation != anim_name:
		sprite.play(anim_name)

# Idle in the last-faced direction (8-way set) or the plain "idle" (4-way).
func _play_idle() -> void:
	if _use_8way:
		_play_anim("idle_" + _facing)
	else:
		_play_anim("idle")

# Maps a movement/aim vector to a facing string. 8-way returns one of eight
# octants (matching the mushroom's directional anims); 4-way collapses to
# up/down/left/right. A zero vector keeps the current facing so a stopped
# enemy doesn't snap. Mirrors Soldier._dir_to_facing.
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

# Builds the AnimatedSprite2D's SpriteFrames at runtime from per-anim strip PNGs
# in `dir` (<idle|walk|shoot|die>_<facing>.png — horizontal strips of square
# frames). Unlike Soldier._build_frames_from_dir, `die` is built as a full 8-way
# one-shot set (enemies have a directional death, not a single shared pose);
# falls back to carrying over the embedded single "die" if no die strips exist.
# No-ops (keeps embedded frames) if nothing loads.
func _build_frames_from_dir(dir: String) -> void:
	var specs := {
		"idle":  {"fps": 6.0,  "loop": true},
		"walk":  {"fps": 8.0,  "loop": true},
		# One-shot: _tick_attack restarts it from frame 0 on each actual shot so the
		# spore-spit (and its muzzle splatter) plays once per shot, then the enemy
		# drops back to idle_<facing> between shots. Looping it left the splatter on
		# screen the whole time while strafing; freezing it (no restart) stuck the
		# enemy mid-spit.
		"shoot": {"fps": 12.0, "loop": false},
		"die":   {"fps": 10.0, "loop": false},
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
				# Each frame becomes its OWN mipmapped texture (not an atlas region)
				# so mipmaps don't bleed neighbouring frames and linear+mipmap
				# filtering stays crisp zoomed in, shimmer-free zoomed out.
				var sub: Image = strip_img.get_region(Rect2i(i * frame_h, 0, frame_h, frame_h))
				sub.generate_mipmaps()
				nf.add_frame(anim, ImageTexture.create_from_image(sub))
			added += 1
			if prefix == "die":
				die_added += 1
	if added == 0:
		return
	# If no directional die strips were supplied, preserve the embedded single
	# "die" pose so death still animates. (With the mushroom's 8-way die set
	# this branch is skipped — _die plays die_<facing> instead.)
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
	# Linear + mipmaps: a detailed (non-pixel-art) sprite reads far better with
	# smooth filtering than nearest at any zoom.
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Normalise scale by the figure's ACTUAL drawn height (opaque bounds), not the
	# padded v3 canvas, so it isn't rendered tiny. Target ~96 px tall so the
	# enemy reads slightly larger/heavier than the 77 px kids.
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
		var s := 96.0 / float(char_h)
		sprite.scale = Vector2(s, s)

# =============================================================================
# PUBLIC — damage / death
# =============================================================================

# Spawns a fresh AudioStreamPlayer2D for one-shot hit grunts. Skips silently
# if the audio file isn't present so the project still runs before the SFX
# drop lands. Pitch wobble matches gunshot for consistency.
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

# Visual styling for the health bar — hides the default "100%" label and
# gives the bar a small red silhouette above the enemy sprite.
func _style_health_bar() -> void:
	health_bar.show_percentage = false
	health_bar.custom_minimum_size = Vector2(32, 4)
	health_bar.size = Vector2(32, 4)
	health_bar.position = Vector2(-16, -26)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.1, 0.85)
	bg.border_color = Color(0, 0, 0, 0.9)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(2)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.9, 0.3, 0.3)
	fill.set_corner_radius_all(2)
	health_bar.add_theme_stylebox_override("background", bg)
	health_bar.add_theme_stylebox_override("fill", fill)

func _spawn_damage_number(amount: int, color: Color) -> void:
	var fx := Node2D.new()
	fx.set_script(_FLOATING_NUMBER_SCRIPT)
	get_viewport().add_child(fx)
	fx.global_position = global_position + Vector2(0, -32)
	fx.start(amount, color)

func take_damage(amount: int, element: int = 0) -> void:
	if _state == State.DEAD:
		return
	# Reinforcements get a brief invulnerability so an in-flight grenade or
	# bullet from the salvo that destroyed their parent structure doesn't
	# delete them before the player even sees them appear.
	if _spawn_protection_timer > 0.0:
		return
	# Element multiplier — soft ×2 / ×0.5. NONE bypasses entirely so grenades
	# and sacrifice still hit for their advertised damage.
	var net: int = Elements.apply_damage(amount, element, weakness, resistance)
	_health -= net
	health_bar.value = _health
	# Yellow on a neutral hit, brighter element-tinted gold when the weakness
	# multiplier kicked in so the player gets visual confirmation crits landed.
	var crit: bool = element != 0 and element == weakness
	var num_color: Color = Color(1.0, 0.95, 0.3) if not crit else Color(1.0, 0.7, 0.15)
	_spawn_damage_number(net, num_color)
	if _hit_audio != null:
		_hit_audio.pitch_scale = randf_range(0.9, 1.1)
		_hit_audio.play()
	if _health <= 0:
		_die()

func _die() -> void:
	_state = State.DEAD
	velocity = Vector2.ZERO
	# 8-way set has a directional death (die_<facing>); fall back to the single
	# "die" pose for the legacy 4-way frames.
	if _use_8way and sprite.sprite_frames.has_animation("die_" + _facing):
		_play_anim("die_" + _facing)
	else:
		_play_anim("die")
	# Remove from the "enemies" group immediately so the HUD's closest-enemy
	# arrow (and any other live-enemy query) stops considering this corpse.
	# Otherwise the node lingers in the group for ~2s while the fade tween
	# runs, and the arrow keeps pointing at a dead body.
	remove_from_group("enemies")

	# set_deferred so Godot applies the change AFTER the physics step
	# finishes — changing collision mid-step throws the flush error.
	$CollisionShape2D.set_deferred("disabled", true)
	$DetectionArea/CollisionShape2D.set_deferred("disabled", true)

	GameManager.add_score(score_value)
	GameManager.on_enemy_died()

	await sprite.animation_finished

	# Fade out over 2 seconds before removing from scene
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 2.0)
	await tween.finished
	queue_free()

# =============================================================================
# Stuck-recovery + alert broadcast
# =============================================================================

# Runs every physics frame. Watches movement progress whenever the agent has
# an unfinished path; after Balance.ENEMY_STUCK_HARD_STRIKES consecutive
# checks of no real movement, teleports along the path to unwedge.
func _tick_stuck_check(delta: float) -> void:
	if nav_agent.is_navigation_finished():
		_stuck_strikes = 0
		_stuck_check_pos = global_position
		return
	_stuck_timer -= delta
	if _stuck_timer > 0.0:
		return
	_stuck_timer = Balance.ENEMY_STUCK_CHECK_INTERVAL
	var moved: bool = global_position.distance_to(_stuck_check_pos) >= Balance.ENEMY_STUCK_THRESHOLD
	_stuck_check_pos = global_position
	if moved:
		_stuck_strikes = 0
		return
	_stuck_strikes += 1
	if _stuck_strikes >= Balance.ENEMY_STUCK_HARD_STRIKES:
		_hard_unstick()
		_stuck_strikes = 0

# Final-resort unstick: nudge toward the next path waypoint. Uses move_and_collide
# (NOT a raw position set) so it slides past prop corners but can never punch
# through a wall / cliff face onto a plateau.
func _hard_unstick() -> void:
	if nav_agent.is_navigation_finished():
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var diff: Vector2 = next - global_position
	if diff.length() < 1.0:
		return
	move_and_collide(diff.normalized() * minf(diff.length(), 64.0))

# Called when this enemy first spots the squad: nudges patrolling neighbours
# inside ENEMY_ALERT_PULSE_RADIUS into ALERT focusing the same target.
func _broadcast_alert() -> void:
	if _target == null:
		return
	var radius_sq: float = Balance.ENEMY_ALERT_PULSE_RADIUS * Balance.ENEMY_ALERT_PULSE_RADIUS
	for e in get_tree().get_nodes_in_group("enemies"):
		if e == self or not is_instance_valid(e):
			continue
		var d_sq: float = (e as Node2D).global_position.distance_squared_to(global_position)
		if d_sq <= radius_sq and e.has_method("alert_to"):
			e.alert_to(_target)

# Receiver for a neighbour's alert pulse. Only pulls in patrolling enemies;
# anyone already ALERT/ATTACK keeps their existing target.
func alert_to(target: Node2D) -> void:
	if _state != State.PATROL:
		return
	if not _is_soldier_engageable(target):
		return
	_target = target
	_state = State.ALERT

# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_body_entered_detection(body: Node2D) -> void:
	if body.is_in_group("soldiers") and _state != State.DEAD:
		if not _is_soldier_engageable(body):
			return
		_target = body
		_state  = State.ALERT

func _on_body_exited_detection(body: Node2D) -> void:
	if body == _target:
		_target = null
		if _state != State.DEAD:
			_state = State.PATROL
