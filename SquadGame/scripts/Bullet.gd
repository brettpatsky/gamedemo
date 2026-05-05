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
# Tunables
# ---------------------------------------------------------------------------
@export var speed:        float = 400.0   # pixels per second
@export var damage:       int   = 1       # hits dealt on impact
@export var lifetime_sec: float = 2.5     # seconds before auto-free (safety net)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _direction: Vector2 = Vector2.RIGHT
var _shooter: Node2D    = null            # who fired this (to avoid self-hits)
var _lifetime: float    = 0.0

# ---------------------------------------------------------------------------
# Called by SquadController or Enemy immediately after instantiate()
# ---------------------------------------------------------------------------
func initialise(direction: Vector2, shooter: Node2D) -> void:
	_direction = direction.normalized()
	_shooter   = shooter
	# Rotate the bullet sprite to match travel direction (optional visual nicety)
	rotation   = _direction.angle()

# ---------------------------------------------------------------------------
# _ready — connect screen-exit signal for auto-cleanup
# ---------------------------------------------------------------------------
func _ready() -> void:
	# body_entered fires when this Area2D overlaps another physics body / area
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)
	$VisibleOnScreenNotifier2D.screen_exited.connect(queue_free)

# ---------------------------------------------------------------------------
# _process — move bullet each frame; cull after lifetime expires
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	position  += _direction * speed * delta
	_lifetime += delta
	if _lifetime >= lifetime_sec:
		queue_free()

# ---------------------------------------------------------------------------
# Hit detection — Area2D overlap with CharacterBody2D or another Area2D
# ---------------------------------------------------------------------------
func _on_body_entered(body: Node2D) -> void:
	_try_hit(body)

func _on_area_entered(area: Node2D) -> void:
	_try_hit(area)

func _try_hit(target: Node2D) -> void:
	# Don't hit the soldier that fired this bullet
	if target == _shooter:
		return

	# Deal damage if the target has a take_damage() method (duck typing)
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
