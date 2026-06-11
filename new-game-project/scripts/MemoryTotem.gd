# =============================================================================
# MemoryTotem.gd  (Boss Mission — Phase 2 objective)
# Pillars summoned by the Heartstone that guard the boss while it's invulnerable.
# The squad must destroy all three to bring the Heartstone back into Phase 3.
#
# Balance: the shield regenerates *continuously* (not on a hit-delay timer).
# A six-soldier pistol volley puts out ~12 dps, and the totem heals 16 hp/s —
# so pistol alone can never kill a totem. Rifle (~50 dps with full squad) or a
# grenade burst (12 instant) are required, exactly per the boss design.
# A delay-based regen failed because six asynchronous pistols hit too densely
# to ever trigger the "no recent hit" condition.
# =============================================================================
extends StaticBody2D

const Balance = preload("res://scripts/BalanceConfig.gd")

signal totem_destroyed

# HP and regen rate live in BalanceConfig (TOTEM_MAX_HEALTH / TOTEM_REGEN_RATE).
# Regen sits below all-pistol DPS so the squad can always grind a totem down
# with pistols, while rifle + grenades remain the fast path.
var _health:           float = 0.0
var _destroyed:        bool  = false
var _pulse_phase:      float = 0.0
var _contact_timer:    float = 0.0
var _touching_soldiers: Array = []

@onready var health_bar: ProgressBar = $HealthBar

func _ready() -> void:
	add_to_group("structures")    # damaged by bullets/grenades; ignored by auto-defend
	add_to_group("memory_totems")
	collision_layer = 1
	collision_mask  = 0
	_health = float(Balance.TOTEM_MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE)
	health_bar.max_value = _health
	health_bar.value     = _health
	var tex_path := "res://resources/boss/memory_totem.png"
	if ResourceLoader.exists(tex_path):
		var spr := Sprite2D.new()
		spr.texture = load(tex_path)
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var t := spr.texture
		spr.scale = Vector2(100.0 / t.get_width(), 100.0 / t.get_height())
		add_child(spr)
	var dmg_area := Area2D.new()
	dmg_area.collision_layer = 0
	dmg_area.collision_mask  = 2
	var dmg_shape := CircleShape2D.new()
	dmg_shape.radius = 46.0
	var dmg_cs := CollisionShape2D.new()
	dmg_cs.shape = dmg_shape
	dmg_area.add_child(dmg_cs)
	dmg_area.body_entered.connect(func(b: Node2D) -> void:
		if b.is_in_group("soldiers"): _touching_soldiers.append(b))
	dmg_area.body_exited.connect(func(b: Node2D) -> void:
		_touching_soldiers.erase(b))
	add_child(dmg_area)
	queue_redraw()

func _process(delta: float) -> void:
	if _destroyed:
		return
	_pulse_phase += delta
	_contact_timer -= delta
	if _contact_timer <= 0.0:
		_contact_timer = Balance.TOTEM_CONTACT_INTERVAL
		_touching_soldiers = _touching_soldiers.filter(func(s: Node2D) -> bool: return is_instance_valid(s))
		for s: Node2D in _touching_soldiers:
			if s.has_method("is_downed") and s.is_downed():
				continue
			if s.has_method("take_damage"):
				s.take_damage(Balance.TOTEM_CONTACT_DAMAGE)
	var max_hp: float = float(Balance.TOTEM_MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE)
	if _health < max_hp:
		_health = minf(_health + Balance.TOTEM_REGEN_RATE * Balance.COMBAT_NUMBER_SCALE * delta, max_hp)
		health_bar.value = _health
	queue_redraw()

func take_damage(amount: int, _element: int = 0) -> void:
	if _destroyed:
		return
	_health -= amount
	health_bar.value = _health
	queue_redraw()
	if _health <= 0:
		_destroyed = true
		totem_destroyed.emit()
		queue_free()

func _draw() -> void:
	var hp_ratio: float = clampf(_health / float(Balance.TOTEM_MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE), 0.0, 1.0)
	# Pulsing shield ring — bright when at full health, dims as health drops.
	var pulse: float = 0.5 + 0.5 * sin(_pulse_phase * 4.0)
	var ring_alpha: float = 0.35 + 0.50 * hp_ratio * pulse
	draw_arc(Vector2.ZERO, 54.0, 0.0, TAU, 40, Color(0.95, 0.5, 1.0, ring_alpha), 6.0)
	draw_arc(Vector2.ZERO, 44.0, 0.0, TAU, 40, Color(0.7, 0.2, 1.0, ring_alpha * 0.6), 2.5)
