# =============================================================================
# FortifiedStructure.gd  (Level 4 objective — Destroy Structures)
# A heavily armoured static building. The squad must destroy it to win.
# Main.gd connects to the structure_destroyed signal after map generation.
# =============================================================================
extends StaticBody2D

const Balance = preload("res://scripts/BalanceConfig.gd")

signal structure_destroyed

const MAX_HEALTH: int = 90

# Damage-state textures swapped at health thresholds.
const TEX_INTACT   := "res://resources/structures/castle_intact.png"
const TEX_DAMAGED1 := "res://resources/structures/castle_damaged1.png"
const TEX_DAMAGED2 := "res://resources/structures/castle_damaged2.png"
const TEX_RUBBLE   := "res://resources/structures/castle_rubble.png"

# Brief rubble display before the node is freed.
const RUBBLE_LINGER := 0.6

var _health: int
var _destroyed: bool  = false
var _rubble_timer: float = -1.0
var _sprite: Sprite2D = null

@onready var health_bar: ProgressBar = $HealthBar

func _ready() -> void:
	add_to_group("structures")
	_health = MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE
	health_bar.max_value = _health
	health_bar.value     = _health

	# Resize collision to match the 2.5× visual footprint of the 128×128 sprite.
	var col_shape := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if col_shape:
		var rect := RectangleShape2D.new()
		rect.size = Vector2(220, 220)
		col_shape.shape = rect

	_sprite = Sprite2D.new()
	_sprite.scale   = Vector2(2.5, 2.5)
	_sprite.z_index = 1
	add_child(_sprite)
	_update_visual()

func take_damage(amount: int, _element: int = 0) -> void:
	if _destroyed:
		return
	_health -= amount
	health_bar.value = _health
	_update_visual()
	if _health <= 0:
		_destroyed = true
		_destroy()

func _update_visual() -> void:
	if _sprite == null:
		return
	var hp_ratio: float = float(max(_health, 0)) / float(MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE)
	var tex_path: String
	if hp_ratio > 0.60:
		tex_path = TEX_INTACT
	elif hp_ratio > 0.25:
		tex_path = TEX_DAMAGED1
	else:
		tex_path = TEX_DAMAGED2
	if ResourceLoader.exists(tex_path):
		_sprite.texture = load(tex_path)

func _destroy() -> void:
	health_bar.hide()
	var shape := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape:
		shape.set_deferred("disabled", true)
	if _sprite and ResourceLoader.exists(TEX_RUBBLE):
		_sprite.texture = load(TEX_RUBBLE)
	_rubble_timer = RUBBLE_LINGER

func _process(delta: float) -> void:
	if _rubble_timer < 0.0:
		return
	_rubble_timer -= delta
	if _rubble_timer <= 0.0:
		structure_destroyed.emit()
		queue_free()

func _draw() -> void:
	# Fallback shown if textures have not been imported by Godot yet.
	if _sprite != null and _sprite.texture != null:
		return
	draw_rect(Rect2(-40, -40, 80, 80), Color(0.2, 0.08, 0.25))
	draw_rect(Rect2(-40, -40, 80, 80), Color(0.6, 0.2, 0.8), false, 3.0)
	var hp_ratio: float = float(_health) / float(MAX_HEALTH * Balance.COMBAT_NUMBER_SCALE)
	var a := 0.3 + 0.7 * (1.0 - hp_ratio)
	draw_line(Vector2(-28, -28), Vector2(28, 28), Color(0.9, 0.1, 0.1, a), 5.0)
	draw_line(Vector2(28, -28), Vector2(-28, 28), Color(0.9, 0.1, 0.1, a), 5.0)
