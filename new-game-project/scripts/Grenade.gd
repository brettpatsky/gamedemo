extends Node2D

const Balance = preload("res://scripts/BalanceConfig.gd")
const _EXPLOSION_SCRIPT = preload("res://scripts/ExplosionFX.gd")

# Parabolic grenade projectile. Created programmatically by Soldier._throw_grenade().
# Call initialise() immediately after add_child().
#
# Visuals: AnimatedSprite2D for in-flight (sprite spins as it arcs), then an
# ExplosionFX node spawned on detonation. Both fall back to the old procedural
# circles when the PNGs haven't been dropped in yet.

var _start_pos:   Vector2
var _end_pos:     Vector2
var _shooter:     Node2D
var _travel_time: float
var _elapsed:     float = 0.0
var _exploded:    bool  = false

var _sprite: AnimatedSprite2D = null
var _spin_speed: float = TAU * 1.5   # radians/s — full spin every ~0.67 s

func initialise(from: Vector2, to: Vector2, shooter: Node2D) -> void:
	_start_pos   = from
	_end_pos     = to
	_shooter     = shooter
	_travel_time = maxf(from.distance_to(to) / Balance.GRENADE_SPEED, 0.3)

func _ready() -> void:
	_sprite = AnimatedSprite2D.new()
	_sprite.centered = true
	add_child(_sprite)
	var frames: SpriteFrames = ProjectileSpriteLoader.get_grenade_frames()
	if frames != null:
		_sprite.sprite_frames = frames
		_sprite.play(&"fly")
	else:
		_sprite.visible = false

func _process(delta: float) -> void:
	if _exploded:
		return
	_elapsed += delta
	var t    := clampf(_elapsed / _travel_time, 0.0, 1.0)
	var flat := _start_pos.lerp(_end_pos, t)
	var arc: float = -Balance.GRENADE_ARC_HEIGHT * 4.0 * t * (1.0 - t)
	global_position = flat + Vector2(0.0, arc)
	# Spin the sprite to sell the arc motion.
	if _sprite and _sprite.visible:
		_sprite.rotation += _spin_speed * delta
	else:
		queue_redraw()
	if t >= 1.0:
		_explode()

func _explode() -> void:
	_exploded       = true
	global_position = _end_pos
	if _sprite:
		_sprite.visible = false
	_deal_damage()
	_spawn_explosion()
	# Keep alive briefly so the explosion FX has a parent, then free.
	get_tree().create_timer(Balance.GRENADE_SHOW_TIME + 1.0).timeout.connect(queue_free)

func _spawn_explosion() -> void:
	var fx := Node2D.new()
	fx.set_script(_EXPLOSION_SCRIPT)
	get_viewport().add_child(fx)
	fx.global_position = global_position
	fx.start("grenade")

func _deal_damage() -> void:
	for group in ["enemies", "soldiers", "structures", "enemy_projectiles"]:
		for target in get_tree().get_nodes_in_group(group):
			if target == _shooter:
				continue
			if _shooter != null and _shooter.is_in_group("soldiers") and target.is_in_group("soldiers"):
				continue
			if not target.has_method("take_damage"):
				continue
			if (target as Node2D).global_position.distance_to(_end_pos) > Balance.GRENADE_EXPLOSION_RADIUS:
				continue
			var dmg: int = Balance.GRENADE_TOTEM_DAMAGE if target.is_in_group("memory_totems") else Balance.GRENADE_DAMAGE
			target.take_damage(dmg * Balance.COMBAT_NUMBER_SCALE)

func _draw() -> void:
	# Only used as fallback when no grenade PNG is present.
	if _sprite and _sprite.visible:
		return
	if _exploded:
		draw_circle(Vector2.ZERO, Balance.GRENADE_EXPLOSION_RADIUS, Color(1.0, 0.4, 0.0, 0.4))
		draw_arc(Vector2.ZERO, Balance.GRENADE_EXPLOSION_RADIUS, 0.0, TAU, 32, Color(1.0, 0.65, 0.0), 2.0)
	else:
		draw_circle(Vector2.ZERO, 5.0, Color(0.15, 0.75, 0.1))
