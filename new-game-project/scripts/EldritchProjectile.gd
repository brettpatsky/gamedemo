# =============================================================================
# EldritchProjectile.gd  (Boss Mission — Phase 3 spiral attack)
# A homing-ish purple bolt fired by the Heartstone during the meltdown phase.
# Travels in a straight line, damages any soldier it touches, and is destroyed
# by the player's grenade splash (the grenade's _deal_damage iterates the
# "enemies" group and calls take_damage — which kills this projectile cleanly).
# =============================================================================
extends Area2D

const Balance = preload("res://scripts/BalanceConfig.gd")

# Speed, damage, lifetime, and radius live in BalanceConfig (PROJECTILE_*).

var _direction: Vector2 = Vector2.RIGHT
var _lifetime:  float   = 0.0
var _hp:        int     = 1
var _trail:     Array[Vector2] = []

func _ready() -> void:
	# NOT in "enemies" — would otherwise pull soldier auto-defense fire toward
	# the projectile cloud. Grenade.gd iterates this group explicitly.
	add_to_group("enemy_projectiles")
	collision_layer = 0
	collision_mask  = 2   # soldiers only
	monitoring  = true
	monitorable = true
	var shape := CircleShape2D.new()
	shape.radius = Balance.PROJECTILE_RADIUS
	var cs := CollisionShape2D.new()
	cs.shape = shape
	add_child(cs)
	body_entered.connect(_on_body_entered)
	queue_redraw()

func initialise(direction: Vector2) -> void:
	_direction = direction.normalized()

func _process(delta: float) -> void:
	_lifetime += delta
	if _lifetime >= Balance.PROJECTILE_MAX_LIFETIME:
		queue_free()
		return
	# Trail of the last few positions for a comet streak.
	_trail.push_front(global_position)
	if _trail.size() > 6:
		_trail.resize(6)
	position += _direction * Balance.PROJECTILE_SPEED * delta
	queue_redraw()

func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("soldiers"):
		return
	if body.has_method("is_downed") and body.is_downed():
		return
	if body.has_method("take_damage"):
		body.take_damage(Balance.PROJECTILE_DAMAGE)
	queue_free()

# Grenades / sacrifice broadcast take_damage to the "enemies" group. Accepting
# damage here lets potions clear incoming projectiles, exactly per the design.
func take_damage(amount: int, _element: int = 0) -> void:
	_hp -= amount
	if _hp <= 0:
		queue_free()

func _draw() -> void:
	# Render trail in world space (we draw in local, so convert).
	for i in _trail.size():
		var t: float = 1.0 - float(i) / float(_trail.size())
		var p: Vector2 = to_local(_trail[i])
		draw_circle(p, Balance.PROJECTILE_RADIUS * (0.4 + 0.6 * t), Color(0.7, 0.3, 1.0, 0.25 * t))
	# Core bolt — bright violet pip with white-hot centre.
	draw_circle(Vector2.ZERO, Balance.PROJECTILE_RADIUS,        Color(0.6, 0.2, 1.0, 0.55))
	draw_circle(Vector2.ZERO, Balance.PROJECTILE_RADIUS * 0.65, Color(0.9, 0.6, 1.0, 0.85))
	draw_circle(Vector2.ZERO, Balance.PROJECTILE_RADIUS * 0.35, Color(1.0, 1.0, 1.0, 1.0))
