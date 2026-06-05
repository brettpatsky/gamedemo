# =============================================================================
# EscortWall.gd  (Level 5 — destructible barrier around the escort NPC)
# A small fortification surrounding the trapped NPC. When any wall is shot
# down, MapGenerator unseals the safe area and releases the NPC so it can
# follow the squad.
# =============================================================================
extends StaticBody2D

const Balance = preload("res://scripts/BalanceConfig.gd")

signal wall_destroyed

const MAX_HEALTH: int = 25
const TEX_WALL := "res://resources/environment/fairy_garden/garden_wall.png"

var _health: int
var _sprite: Sprite2D = null

@onready var health_bar: ProgressBar = $HealthBar

func _ready() -> void:
	add_to_group("escort_walls")
	_health = MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE
	health_bar.max_value = _health
	health_bar.value     = _health

	_sprite = Sprite2D.new()
	_sprite.scale   = Vector2(1.1, 1.1)
	_sprite.z_index = 1
	add_child(_sprite)
	if ResourceLoader.exists(TEX_WALL):
		_sprite.texture = load(TEX_WALL)

func take_damage(amount: int, _element: int = 0) -> void:
	_health -= amount
	health_bar.value = _health
	if _health <= 0:
		_destroy()

func _destroy() -> void:
	wall_destroyed.emit()
	queue_free()

func _draw() -> void:
	# Fallback placeholder shown if textures haven't been imported yet.
	if _sprite != null and _sprite.texture != null:
		return
	draw_rect(Rect2(-28, -28, 56, 56), Color(0.45, 0.32, 0.22))
	draw_rect(Rect2(-28, -28, 56, 56), Color(0.20, 0.13, 0.08), false, 2.5)
	for y in [-14, 0, 14]:
		draw_line(Vector2(-28, y), Vector2(28, y), Color(0.20, 0.13, 0.08), 1.5)
