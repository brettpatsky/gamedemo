extends Node2D

const Balance = preload("res://scripts/BalanceConfig.gd")

# Parabolic grenade projectile.  Created programmatically by Soldier._throw_grenade().
# Call initialise() immediately after add_child().

# All grenade tuning (speed, arc, radius, damage, totem bonus, show time)
# lives in BalanceConfig under the GRENADE_* prefix.

var _start_pos:   Vector2
var _end_pos:     Vector2
var _shooter:     Node2D
var _travel_time: float
var _elapsed:     float = 0.0
var _exploded:    bool  = false

func initialise(from: Vector2, to: Vector2, shooter: Node2D) -> void:
	_start_pos   = from
	_end_pos     = to
	_shooter     = shooter
	_travel_time = maxf(from.distance_to(to) / Balance.GRENADE_SPEED, 0.3)

func _process(delta: float) -> void:
	if _exploded:
		return
	_elapsed += delta
	var t    := clampf(_elapsed / _travel_time, 0.0, 1.0)
	var flat := _start_pos.lerp(_end_pos, t)
	var arc: float = -Balance.GRENADE_ARC_HEIGHT * 4.0 * t * (1.0 - t)   # parabola peaking at t = 0.5
	global_position = flat + Vector2(0.0, arc)
	queue_redraw()
	if t >= 1.0:
		_explode()

func _explode() -> void:
	_exploded       = true
	global_position = _end_pos
	_deal_damage()
	queue_redraw()
	get_tree().create_timer(Balance.GRENADE_SHOW_TIME).timeout.connect(queue_free)

func _deal_damage() -> void:
	# enemy_projectiles included so grenades sweep away the Heart's
	# eldritch bolts during the meltdown phase (per the boss design).
	for group in ["enemies", "soldiers", "structures", "enemy_projectiles"]:
		for target in get_tree().get_nodes_in_group(group):
			if target == _shooter:
				continue
			# No friendly fire on soldiers (but structures and enemies always take damage)
			if _shooter != null and _shooter.is_in_group("soldiers") and target.is_in_group("soldiers"):
				continue
			if not target.has_method("take_damage"):
				continue
			if (target as Node2D).global_position.distance_to(_end_pos) > Balance.GRENADE_EXPLOSION_RADIUS:
				continue
			# Heavy bonus damage to memory totems — required to outpace their
			# 16 HP/s regen during the boss's Phase 2.
			var dmg: int = Balance.GRENADE_TOTEM_DAMAGE if target.is_in_group("memory_totems") else Balance.GRENADE_DAMAGE
			target.take_damage(dmg * Balance.COMBAT_NUMBER_SCALE)

func _draw() -> void:
	if _exploded:
		draw_circle(Vector2.ZERO, Balance.GRENADE_EXPLOSION_RADIUS, Color(1.0, 0.4, 0.0, 0.4))
		draw_arc(Vector2.ZERO, Balance.GRENADE_EXPLOSION_RADIUS, 0.0, TAU, 32, Color(1.0, 0.65, 0.0), 2.0)
	else:
		draw_circle(Vector2.ZERO, 5.0, Color(0.15, 0.75, 0.1))
