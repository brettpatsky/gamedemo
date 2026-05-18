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
func set_stats(p_damage: int, p_speed: float, p_distance: float, p_color: Color) -> void:
	damage       = p_damage
	speed        = p_speed
	max_distance = p_distance * _elevation_range_mult()
	color        = p_color
	queue_redraw()

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
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)
	$VisibleOnScreenNotifier2D.screen_exited.connect(queue_free)
	# Layer 2 = soldiers/enemies; layer 1 = environment obstacles and walls.
	set_collision_mask_value(1, true)
	set_collision_mask_value(2, true)
	queue_redraw()

func _draw() -> void:
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
	# Prevent soldiers from hitting their own squad mates
	if _shooter != null and _shooter.is_in_group("soldiers") and target.is_in_group("soldiers"):
		return
	if target.has_method("take_damage"):
		target.take_damage(damage)
		if _shooter != null and _shooter.has_method("on_bullet_hit"):
			_shooter.on_bullet_hit(target)
		_spawn_hit_particles()
		queue_free()

# ---------------------------------------------------------------------------
# Small particle burst when bullet connects (purely cosmetic)
# ---------------------------------------------------------------------------
func _spawn_hit_particles() -> void:
	# If you have a GPUParticles2D / CPUParticles2D scene, instantiate it here.
	# For now we simply print a debug hit marker.
	# Example:
	#   var fx = preload("res://scenes/HitEffect.tscn").instantiate()
	#   get_tree().current_scene.add_child(fx)
	#   fx.global_position = global_position
	#   fx.emitting = true
	pass
