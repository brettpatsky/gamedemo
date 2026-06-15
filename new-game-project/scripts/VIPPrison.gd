# =============================================================================
# VIPPrison.gd  (Level 5 — the destructible cell the escort VIP is trapped in)
# A single sturdy structure dropped on the open map. The squad shoots it down to
# free the VIP, who then follows them to the extraction zone. Joins the
# "escort_walls" group and emits wall_destroyed so the existing Main.gd escort
# wiring (release the VIP + clear the barrier) works unchanged — it replaces the
# old four-wall ring with one proper prison.
# =============================================================================
extends StaticBody2D

const Balance = preload("res://scripts/BalanceConfig.gd")

signal wall_destroyed

const MAX_HEALTH: int = 40
# Pixel-art prison sprite (generate via PixelLab into this path). Until it's
# present the _draw fallback below renders a cage so the mission still reads.
const TEX_PRISON := "res://resources/environment/vip_prison.png"

var _health: int
var _sprite: Sprite2D = null

@onready var health_bar: ProgressBar = $HealthBar

func _ready() -> void:
	add_to_group("escort_walls")
	_health = MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE
	health_bar.show_percentage = false
	health_bar.max_value = _health
	health_bar.value     = _health

	_sprite = Sprite2D.new()
	_sprite.z_index = 1
	_sprite.scale = Vector2(2.0, 2.0)
	add_child(_sprite)
	if ResourceLoader.exists(TEX_PRISON):
		_sprite.texture = load(TEX_PRISON)
	queue_redraw()

func take_damage(amount: int, _element: int = 0) -> void:
	_health -= amount
	health_bar.value = _health
	if _health <= 0:
		_destroy()

func _destroy() -> void:
	wall_destroyed.emit()
	queue_free()

func _draw() -> void:
	# Placeholder cage shown until vip_prison.png is generated/imported: a stone
	# cell with iron bars and a dark interior, sized to the collision box.
	if _sprite != null and _sprite.texture != null:
		return
	const S := 112.0
	draw_rect(Rect2(-S, -S, 2.0 * S, 2.0 * S), Color(0.16, 0.14, 0.18))
	var bar := Color(0.62, 0.64, 0.72)
	for i in range(-3, 4):
		draw_line(Vector2(float(i) * 16.0, -S), Vector2(float(i) * 16.0, S), bar, 3.0)
	for j in range(-3, 4):
		draw_line(Vector2(-S, float(j) * 16.0), Vector2(S, float(j) * 16.0), bar, 1.5)
	draw_rect(Rect2(-S, -S, 2.0 * S, 2.0 * S), Color(0.5, 0.45, 0.5), false, 4.0)
