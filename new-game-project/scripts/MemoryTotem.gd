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
var _orb_sprite:       Sprite2D = null
var _base_orb_scale:   Vector2  = Vector2.ONE

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
		_orb_sprite = spr
		_base_orb_scale = spr.scale
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
	# Living orb: breathe (scale pulse) and bob gently.
	if _orb_sprite:
		var breath: float = 1.0 + 0.07 * sin(_pulse_phase * 3.0)
		_orb_sprite.scale = _base_orb_scale * breath
		_orb_sprite.position.y = sin(_pulse_phase * 2.0) * 4.0
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
	var pulse: float = 0.5 + 0.5 * sin(_pulse_phase * 4.0)
	var ring_alpha: float = 0.35 + 0.50 * hp_ratio * pulse
	# Rotating segmented shield — six arc plates orbiting the orb, brighter and
	# faster at full health, faltering (more transparent) as the shield is worn down.
	var seg := 6
	var spin: float = _pulse_phase * (1.6 + 1.4 * hp_ratio)
	var gap: float = 0.22
	var span: float = TAU / float(seg) - gap
	var shield_col := Color(0.95, 0.5, 1.0, ring_alpha)
	for i in seg:
		var a0: float = spin + (TAU / float(seg)) * float(i)
		draw_arc(Vector2.ZERO, 54.0, a0, a0 + span, 8, shield_col, 6.0)
	# Inner counter-rotating ring.
	var inner_alpha: float = ring_alpha * 0.6
	for i in seg:
		var a0: float = -spin * 1.3 + (TAU / float(seg)) * float(i) + 0.4
		draw_arc(Vector2.ZERO, 44.0, a0, a0 + span * 0.7, 6, Color(0.7, 0.2, 1.0, inner_alpha), 2.5)
	# Faint energy halo that swells with the pulse.
	draw_circle(Vector2.ZERO, 36.0 + 4.0 * pulse, Color(0.6, 0.2, 1.0, 0.10 + 0.12 * hp_ratio * pulse))
