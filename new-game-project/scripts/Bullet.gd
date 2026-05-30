# =============================================================================
# Bullet.gd
# Attach to scenes/Bullet.tscn.
#
# SCENE NODE TREE:
#   Bullet (Area2D)               ← Area2D lets us detect overlaps without physics
#   ├── Sprite2D                  ← tiny oval / star sprite for cute look
#   ├── CollisionShape2D          ← small circle
#   └── VisibleOnScreenNotifier2D ← auto-frees bullet when it leaves the screen
#
# USAGE:
#   var b = bullet_scene.instantiate()
#   scene.add_child(b)
#   b.global_position = spawn_pos
#   b.initialise(direction, shooter_node)
# =============================================================================
extends Area2D

const Balance = preload("res://scripts/BalanceConfig.gd")
const _EXPLOSION_SCRIPT = preload("res://scripts/ExplosionFX.gd")

# ---------------------------------------------------------------------------
# Tunables — defaults pulled from BalanceConfig in _ready(). Soldiers override
# these per-shot via set_stats() so each squad member's pistol and rifle
# behave independently. Enemy bullets keep the BalanceConfig defaults until
# they call set_stats() with enemy-bullet values.
# ---------------------------------------------------------------------------
var speed:        float
var damage:       int
var max_distance: float
var color:        Color = Color.YELLOW
# Elemental tag — defaults to NONE so enemy bullets and tests that bypass
# set_stats keep the old neutral-damage behaviour.
var element:      int   = 0   # Elements.E.NONE
# Trail emitter — built once when set_stats lands a non-NONE element.
# Enemy bullets (which never set an element) stay particle-free.
var _trail:       CPUParticles2D = null
# Sprite — built in _ready, updated in set_stats. When the relevant PNG
# exists in resources/fx/projectiles the circle draw is suppressed.
var _sprite:      AnimatedSprite2D = null

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _direction: Vector2 = Vector2.RIGHT
var _shooter: Node2D    = null            # who fired this (to avoid self-hits)
var _distance_travelled: float = 0.0

# ---------------------------------------------------------------------------
# Called by SquadController or Enemy immediately after instantiate()
# ---------------------------------------------------------------------------
func initialise(direction: Vector2, shooter: Node2D) -> void:
	_direction = direction.normalized()
	_shooter   = shooter
	# Rotate the bullet sprite to match travel direction (optional visual nicety)
	rotation   = _direction.angle()

# Per-shot stat override. Called by Soldier so each squad member's pistol and
# rifle can have independent damage / speed / range / color values.
#
# Applies the shooter's terrain-elevation range modifier here so high-ground
# bullets fly further and valley-fired bullets fly shorter — _shooter is set
# in initialise() which Soldier/Enemy always call before set_stats().
func set_stats(p_damage: int, p_speed: float, p_distance: float, p_color: Color, p_element: int = 0) -> void:
	damage       = p_damage
	speed        = p_speed
	max_distance = p_distance * _elevation_range_mult()
	color        = p_color
	element      = p_element
	_update_sprite()
	queue_redraw()
	# Trail only fires for squad bullets — enemy bullets pass element = NONE.
	_ensure_trail()

# Spawns an element-specific trail emitter once. Every bullet gets a trail —
# including enemy (NONE) bullets. Idempotent: repeated set_stats calls won't
# stack emitters. Particles use world space so they hang behind the bullet.
func _ensure_trail() -> void:
	if _trail != null:
		return
	var back: Vector2 = (-_direction).normalized() if _direction != Vector2.ZERO else Vector2.LEFT
	var perp: Vector2 = Vector2(-back.y, back.x)   # perpendicular to travel
	var trail := CPUParticles2D.new()
	trail.local_coords = false
	trail.emitting     = true
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.0))
	trail.scale_amount_curve = shrink
	match element:
		1: # ─── FIRE — rising ember shower ──────────────────────────────────
			trail.amount              = 22
			trail.lifetime            = 0.35
			trail.direction           = back + Vector2(0, -0.5)
			trail.spread              = 28.0
			trail.initial_velocity_min = 30.0
			trail.initial_velocity_max = 80.0
			trail.gravity             = Vector2(0.0, -90.0)   # embers rise
			trail.angular_velocity_min = -200.0
			trail.angular_velocity_max =  200.0
			trail.scale_amount_min    = 3.0
			trail.scale_amount_max    = 6.0
			var fg := Gradient.new()
			fg.set_color(0, Color(1.0, 1.0, 0.6, 1.0))
			fg.set_color(1, Color(0.6, 0.0, 0.0, 0.0))
			fg.add_point(0.35, Color(1.0, 0.45, 0.05, 0.85))
			trail.color_ramp = fg
		2: # ─── ICE — spinning crystal shards ─────────────────────────────
			trail.amount              = 14
			trail.lifetime            = 0.50
			trail.direction           = back
			trail.spread              = 40.0
			trail.initial_velocity_min = 15.0
			trail.initial_velocity_max = 50.0
			trail.gravity             = Vector2.ZERO
			trail.angular_velocity_min = -240.0
			trail.angular_velocity_max =  240.0   # crystals tumble
			trail.scale_amount_min    = 2.0
			trail.scale_amount_max    = 5.0
			var ig := Gradient.new()
			ig.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
			ig.set_color(1, Color(0.1, 0.25, 0.9, 0.0))
			ig.add_point(0.45, Color(0.5, 0.9, 1.0, 0.7))
			trail.color_ramp = ig
		3: # ─── LIGHTNING — electric sparks crackling perpendicular ────────
			trail.amount              = 28
			trail.lifetime            = 0.08   # ultra-short flicker
			trail.direction           = perp   # crackle sideways
			trail.spread              = 180.0  # full random burst
			trail.initial_velocity_min = 60.0
			trail.initial_velocity_max = 200.0
			trail.gravity             = Vector2.ZERO
			trail.scale_amount_min    = 1.0
			trail.scale_amount_max    = 3.5
			var lg := Gradient.new()
			lg.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
			lg.set_color(1, Color(0.8, 0.6, 0.0, 0.0))
			lg.add_point(0.4, Color(1.0, 0.95, 0.3, 0.9))
			trail.color_ramp = lg
		_: # ─── NONE / enemy — green toxic drip ──────────────────────────
			trail.amount              = 12
			trail.lifetime            = 0.30
			trail.direction           = back
			trail.spread              = 22.0
			trail.initial_velocity_min = 18.0
			trail.initial_velocity_max = 45.0
			trail.gravity             = Vector2(0.0, 40.0)   # drips downward
			trail.scale_amount_min    = 2.0
			trail.scale_amount_max    = 4.5
			var eg := Gradient.new()
			eg.set_color(0, Color(0.6, 1.0, 0.3, 0.9))
			eg.set_color(1, Color(0.0, 0.25, 0.0, 0.0))
			eg.add_point(0.5, Color(0.15, 0.75, 0.1, 0.6))
			trail.color_ramp = eg
	add_child(trail)
	_trail = trail

func _elevation_range_mult() -> float:
	if _shooter == null:
		return 1.0
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	if map_gen == null or not map_gen.has_method("get_range_modifier_at"):
		return 1.0
	return map_gen.get_range_modifier_at(_shooter.global_position)

# ---------------------------------------------------------------------------
# _ready — connect screen-exit signal for auto-cleanup
# ---------------------------------------------------------------------------
func _ready() -> void:
	speed        = Balance.BULLET_SPEED
	damage       = Balance.BULLET_DAMAGE
	max_distance = Balance.BULLET_MAX_DISTANCE
	# Ambient critters poll this group to scatter when shots whiz past.
	add_to_group("bullets")
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)
	$VisibleOnScreenNotifier2D.screen_exited.connect(queue_free)
	# Layer 2 = soldiers/enemies; layer 1 = environment obstacles and walls.
	set_collision_mask_value(1, true)
	set_collision_mask_value(2, true)
	# Sprite node created once; _update_sprite() populates it after set_stats.
	_sprite = AnimatedSprite2D.new()
	_sprite.centered = true
	_sprite.visible  = false
	add_child(_sprite)
	queue_redraw()

func _update_sprite() -> void:
	if _sprite == null:
		return
	var frames: SpriteFrames = ProjectileSpriteLoader.get_bullet_frames(element)
	if frames != null:
		_sprite.sprite_frames = frames
		_sprite.play(&"fly")
		_sprite.flip_h   = true   # sheets face left; bullet rotation faces right
		_sprite.visible  = true
		_sprite.modulate = Color.WHITE
	else:
		_sprite.visible = false

func _draw() -> void:
	# Skip the circle when a sprite is showing — the AnimatedSprite2D takes over.
	if _sprite != null and _sprite.visible:
		return
	draw_circle(Vector2.ZERO, 3.0, color)

# ---------------------------------------------------------------------------
# _process — move bullet each frame; cull after travelling max_distance
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	var step := speed * delta
	position             += _direction * step
	_distance_travelled  += step
	if _distance_travelled >= max_distance:
		queue_free()

# ---------------------------------------------------------------------------
# Hit detection — Area2D overlap with CharacterBody2D or another Area2D
# ---------------------------------------------------------------------------
func _on_body_entered(body: Node2D) -> void:
	if body is StaticBody2D:
		# Damageable structures (e.g. FortifiedStructure) absorb the bullet
		# and take damage. Plain walls and obstacles just stop it.
		if body.has_method("take_damage"):
			_try_hit(body)
		else:
			queue_free()
		return
	_try_hit(body)

func _on_area_entered(area: Area2D) -> void:
	_try_hit(area)

func _try_hit(target: Node2D) -> void:
	if target == _shooter:
		return
	# Prevent friendly fire on both teams — soldier bullets can't hit other
	# soldiers, enemy bullets can't hit other enemies.
	if _shooter != null:
		if _shooter.is_in_group("soldiers") and target.is_in_group("soldiers"):
			return
		if _shooter.is_in_group("enemies") and target.is_in_group("enemies"):
			return
	if target.has_method("take_damage"):
		target.take_damage(damage, element)
		if _shooter != null and _shooter.has_method("on_bullet_hit"):
			_shooter.on_bullet_hit(target)
		_spawn_hit_particles()
		queue_free()

# ---------------------------------------------------------------------------
# Small particle burst when bullet connects (purely cosmetic)
# ---------------------------------------------------------------------------
func _spawn_hit_particles() -> void:
	var fx := Node2D.new()
	fx.set_script(_EXPLOSION_SCRIPT)
	get_viewport().add_child(fx)
	fx.global_position = global_position
	fx.start("hit", color)
