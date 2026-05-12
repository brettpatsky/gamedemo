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

# ---------------------------------------------------------------------------
# Tunables — defaults used by enemy bullets and as a fallback. Soldiers
# override these per-shot via set_stats() so each squad member's pistol and
# rifle behave independently.
# ---------------------------------------------------------------------------
@export var speed:        float = 600.0   # pixels per second
@export var damage:       int   = 1       # hits dealt on impact
@export var max_distance: float = 1500.0  # pixels of travel before auto-free
@export var color:        Color = Color.YELLOW

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
func set_stats(p_damage: int, p_speed: float, p_distance: float, p_color: Color) -> void:
	damage       = p_damage
	speed        = p_speed
	max_distance = p_distance
	color        = p_color
	queue_redraw()

# ---------------------------------------------------------------------------
# _ready — connect screen-exit signal for auto-cleanup
# ---------------------------------------------------------------------------
func _ready() -> void:
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)
	$VisibleOnScreenNotifier2D.screen_exited.connect(queue_free)
	# Soldiers are on layer 2; include it so bullets can still hit them.
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
