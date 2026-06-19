# =============================================================================
# NPCEscort.gd  (Level 5 objective)
# A friendly NPC that must survive and reach the extraction zone.
# - "soldiers" group: enemies detect and target it automatically.
# - "escort_npc" group: ExtractionZone watches for this group.
# - escort_killed signal: Main.gd connects this to mission-fail.
# =============================================================================
extends CharacterBody2D

signal health_changed(current_hp: int, max_hp: int)
signal escort_killed
signal joined_squad

const MAX_HEALTH: int   = 5
const MOVE_SPEED: float = 130.0
# Stop this far from the nearest squad member rather than diving into the
# centroid — pushing into the middle of the formation knocked soldiers around
# and made the NPC physically jam against squad capsules.
const FOLLOW_DIST: float = 70.0

# Animated unicorn: a 4-direction quadruped (PixelLab horse character) with
# idle + walk strips per facing, so it animates like the squad while following.
# Files: unicorn_<idle|walk>_<down|up|left|right>.png (horizontal strips of
# square frames). Falls back to the _draw circle until the art is imported.
const UNICORN_ART_DIR  := "res://resources/environment/"
const UNICORN_FACINGS  := ["down", "up", "left", "right",
		"down_right", "down_left", "up_right", "up_left"]
const UNICORN_SCALE     := 1.15   # shown near 1:1 from the ~112px native frame
const UNICORN_Y_OFFSET  := 28.0   # nudge down so it stands on the stall floor
const UNICORN_WALK_FPS  := 10.0
const UNICORN_IDLE_FPS  := 6.0
var _anim:   AnimatedSprite2D = null
var _facing: String = "down"

var _health: int = MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE
var _dead:   bool = false
var _freed:  bool = false   # set true once a sheltering wall is destroyed
var _joined: bool = false   # set true the first time we reach the squad

# Stuck-recovery — same escalation pattern as Soldier/Enemy. The VIP getting
# wedged forever was the most disruptive case because the mission stalls.
const Balance = preload("res://scripts/BalanceConfig.gd")
var _stuck_timer:     float   = 0.0
var _stuck_check_pos: Vector2 = Vector2.ZERO
var _stuck_strikes:   int     = 0

@onready var nav_agent:  NavigationAgent2D = $NavigationAgent2D
@onready var health_bar: ProgressBar       = $HealthBar

func _ready() -> void:
	add_to_group("soldiers")    # enemies detect + target this
	add_to_group("escort_npc")  # extraction zone watches for this group
	_health              = MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE
	health_bar.max_value = _health
	health_bar.value     = _health
	_style_health_bar()
	_build_unicorn_sprite()
	# Disable our body collision while caged so the prison's StaticBody2D doesn't
	# eject us out the side on spawn — the VIP must sit visibly INSIDE the stable.
	# It's invulnerable until freed anyway; release() turns collision back on.
	$CollisionShape2D.disabled = true
	queue_redraw()
	await get_tree().physics_frame

# Build the 4-direction unicorn AnimatedSprite2D from the idle/walk strips.
# Each file is a horizontal strip of SQUARE frames (frame size == strip height),
# so the frame count is width/height — no hardcoded dimensions. Leaves _anim
# null (so the _draw fallback shows) if no art is present yet.
func _build_unicorn_sprite() -> void:
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	var added := 0
	for facing in UNICORN_FACINGS:
		added += _add_unicorn_anim(frames, "idle_" + facing,
				UNICORN_ART_DIR + "unicorn_idle_" + facing + ".png", UNICORN_IDLE_FPS)
		added += _add_unicorn_anim(frames, "walk_" + facing,
				UNICORN_ART_DIR + "unicorn_walk_" + facing + ".png", UNICORN_WALK_FPS)
	if added == 0:
		return   # art not imported yet — keep the _draw fallback
	_anim = AnimatedSprite2D.new()
	_anim.sprite_frames   = frames
	_anim.scale           = Vector2(UNICORN_SCALE, UNICORN_SCALE)
	_anim.position        = Vector2(0, UNICORN_Y_OFFSET)
	_anim.texture_filter  = CanvasItem.TEXTURE_FILTER_NEAREST
	_anim.z_index         = 1
	add_child(_anim)
	_play_unicorn("idle_down")

# Slices a horizontal strip of square frames into one looping animation.
# Returns 1 if the strip exists and was added, else 0.
func _add_unicorn_anim(frames: SpriteFrames, anim: String, path: String, fps: float) -> int:
	if not ResourceLoader.exists(path):
		return 0
	var tex: Texture2D = load(path)
	if tex == null or tex.get_height() <= 0:
		return 0
	var fh: int = tex.get_height()
	@warning_ignore("integer_division")
	var cols: int = maxi(1, tex.get_width() / fh)
	frames.add_animation(anim)
	frames.set_animation_loop(anim, true)
	frames.set_animation_speed(anim, fps)
	for i in cols:
		var atlas := AtlasTexture.new()
		atlas.atlas  = tex
		atlas.region = Rect2(i * fh, 0, fh, fh)
		frames.add_frame(anim, atlas)
	return 1

# Plays an animation if present, else falls back to idle_down (then any).
func _play_unicorn(anim: String) -> void:
	if _anim == null or _anim.sprite_frames == null:
		return
	if not _anim.sprite_frames.has_animation(anim):
		anim = "idle_down"
		if not _anim.sprite_frames.has_animation(anim):
			return
	if _anim.animation != anim:
		_anim.play(anim)

# 8-way facing from a movement vector (Godot y is down, so positive angle = down).
# Buckets the heading into 45° octants. Returns the current facing for a zero
# vector so a stopped unicorn keeps its last orientation.
func _dir_to_facing(dir: Vector2) -> String:
	if dir == Vector2.ZERO:
		return _facing
	var deg := rad_to_deg(dir.angle())
	if deg < 0.0:
		deg += 360.0
	var idx: int = int(round(deg / 45.0)) % 8
	return ["right", "down_right", "down", "down_left",
			"left", "up_left", "up", "up_right"][idx]

# Clean green-on-dark fill so the VIP reads at a glance, matching the other
# unit health bars rather than the default grey ProgressBar.
func _style_health_bar() -> void:
	health_bar.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.05, 0.07, 0.75)
	bg.set_corner_radius_all(2)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.92, 0.45)
	fill.set_corner_radius_all(2)
	health_bar.add_theme_stylebox_override("background", bg)
	health_bar.add_theme_stylebox_override("fill", fill)

func _physics_process(delta: float) -> void:
	if _dead:
		return
	# Stay put inside the shelter until the squad blows open a wall.
	if not _freed:
		velocity = Vector2.ZERO
		_play_unicorn("idle_down")   # face the camera while waiting in the stable
		move_and_slide()
		return
	# Track the nearest live squad member rather than the centroid so the NPC
	# trails on the edge of the formation instead of jamming into it.
	var nearest: Node2D = _nearest_soldier()
	if nearest != null:
		var dist: float = global_position.distance_to(nearest.global_position)
		if dist > FOLLOW_DIST:
			nav_agent.target_position = nearest.global_position
		elif not _joined:
			_joined = true
			joined_squad.emit()
	_tick_stuck_check(delta)
	if not nav_agent.is_navigation_finished():
		var next: Vector2 = nav_agent.get_next_path_position()
		velocity = (next - global_position).normalized() * MOVE_SPEED
	else:
		velocity = Vector2.ZERO
	# Drive the directional walk/idle animation from movement.
	if velocity.length() > 5.0:
		_facing = _dir_to_facing(velocity)
		_play_unicorn("walk_" + _facing)
	else:
		_play_unicorn("idle_" + _facing)
	move_and_slide()

# Same stuck-recovery escalation as Soldier/Enemy. Important here because a
# wedged VIP halts the mission outright — without the hard-unstick the only
# fix was to retry the level.
func _tick_stuck_check(delta: float) -> void:
	if nav_agent.is_navigation_finished():
		_stuck_strikes = 0
		_stuck_check_pos = global_position
		return
	_stuck_timer -= delta
	if _stuck_timer > 0.0:
		return
	_stuck_timer = Balance.NPC_STUCK_CHECK_INTERVAL
	var moved: bool = global_position.distance_to(_stuck_check_pos) >= Balance.NPC_STUCK_THRESHOLD
	_stuck_check_pos = global_position
	if moved:
		_stuck_strikes = 0
		return
	_stuck_strikes += 1
	if _stuck_strikes >= Balance.NPC_STUCK_HARD_STRIKES:
		_hard_unstick()
		_stuck_strikes = 0

func _hard_unstick() -> void:
	if nav_agent.is_navigation_finished():
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var diff: Vector2 = next - global_position
	if diff.length() < 1.0:
		return
	global_position += diff.normalized() * minf(diff.length(), 64.0)

func _nearest_soldier() -> Node2D:
	var best: Node2D = null
	var best_d: float = INF
	for s in get_tree().get_nodes_in_group("soldiers"):
		if s == self or not is_instance_valid(s):
			continue
		# Skip downed soldiers — the NPC chasing a corpse looks broken.
		if s.has_method("is_downed") and s.is_downed():
			continue
		var d: float = (s as Node2D).global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best   = s
	return best

func release() -> void:
	_freed = true
	# Re-enable body collision now that the stable is gone, so the freed VIP can
	# take fire and be blocked by terrain like a normal unit. Deferred because the
	# prison is queue_free'd in the same frame this is called.
	$CollisionShape2D.set_deferred("disabled", false)
	# Raised above the prison sprite while caged so the captive is visible inside
	# it; drop back to the normal band once freed so it blends with the squad.
	z_index = 0

func is_freed() -> bool:
	return _freed

func has_joined_squad() -> bool:
	return _joined

func get_health() -> int:
	return _health

func get_max_health() -> int:
	return MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE

func take_damage(amount: int, _element: int = 0) -> void:
	# Invulnerable inside the shelter — a stray enemy shot before the squad
	# arrives shouldn't be able to kill the NPC before they can be freed.
	if _dead or not _freed:
		return
	_health -= amount
	health_bar.value = _health
	health_changed.emit(_health, get_max_health())
	if _health <= 0:
		_die()

func _die() -> void:
	_dead    = true
	velocity = Vector2.ZERO
	$CollisionShape2D.set_deferred("disabled", true)
	escort_killed.emit()
	queue_free()

func _draw() -> void:
	# Fallback marker shown only until the unicorn sprite is generated/imported.
	if _anim != null:
		return
	draw_circle(Vector2.ZERO, 14.0, Color(0.1, 0.85, 0.85))
	draw_arc(Vector2.ZERO, 14.0, 0.0, TAU, 24, Color(0.0, 0.5, 0.6), 2.5)
	draw_circle(Vector2.ZERO, 4.0, Color(0.0, 0.4, 0.5))
