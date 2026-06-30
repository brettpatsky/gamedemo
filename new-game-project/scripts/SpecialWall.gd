# =============================================================================
# SpecialWall.gd
# A destructible wall that ignores damage below a configurable threshold.
# Used by the tutorial for two distinct puzzles:
#
#   Grenade Wall   — min_damage = 5  (pistol/staff = 1 ignored; grenade = 12 breaks it)
#   Sacrifice Wall — min_damage = 13 (grenade = 12 ignored; sacrifice = 15 breaks it)
#
# In group "structures" so Soldier._explode and Grenade._deal_damage find it
# via their normal group iteration.
# =============================================================================
class_name SpecialWall
extends StaticBody2D

const Balance = preload("res://scripts/BalanceConfig.gd")

const _TEX := {
	"barricade": "res://resources/tutorial/barricade.png",
	"sacrifice": "res://resources/tutorial/sacrifice_block.png",
}

# Art reads as a bigger, more imposing obstacle than the (unchanged) collision
# footprint — collision/positioning stays tied to width/height so puzzle layout
# math elsewhere doesn't need to change.
const _VISUAL_SCALE_MULT := 2.2

signal destroyed

@export var width:                  float  = 96.0
@export var height:                 float  = 96.0
@export var max_health:             int    = 24
@export var min_damage_to_register: int    = 5
@export var hint_text:              String = ""
# "door" (heavy wooden door, R1's grenade puzzle) or "sacrifice" (crimson ward,
# the Final Trial). Set BEFORE adding the wall to the tree.
@export var kind:                   String = "barricade"
# Tutorial trial this wall gates (shared with its PuzzleGate). -1 = not adopted.
@export var trial_index:            int    = -1
# Final-Trial rule: the gate only opens once the ward is destroyed AND a kid has
# been revived this mission. When false, destroying the wall alone solves it.
@export var also_requires_revive:   bool   = false

var _health:    int
var _destroyed: bool = false
var _sprite:    Sprite2D

func _ready() -> void:
	add_to_group("structures")
	# Scale HP and damage threshold by COMBAT_NUMBER_SCALE so the tutorial
	# weapons keep their original "this breaks it / this doesn't" relationship
	# after the global damage scale-up.
	max_health = max_health * Balance.COMBAT_NUMBER_SCALE
	min_damage_to_register = min_damage_to_register * Balance.COMBAT_NUMBER_SCALE
	_health = max_health
	var shape := RectangleShape2D.new()
	shape.size = Vector2(width, height)
	var cs := CollisionShape2D.new()
	cs.shape = shape
	add_child(cs)
	collision_layer = 1
	collision_mask  = 0

	_sprite = Sprite2D.new()
	var tex_path: String = _TEX.get(kind, _TEX["barricade"])
	if ResourceLoader.exists(tex_path):
		var tex: Texture2D = load(tex_path)
		_sprite.texture = tex
		var tex_size: Vector2 = tex.get_size()
		if tex_size.x > 0.0 and tex_size.y > 0.0:
			_sprite.scale = Vector2(width / tex_size.x, height / tex_size.y) * _VISUAL_SCALE_MULT
	add_child(_sprite)

	if hint_text != "":
		var lbl := Label.new()
		lbl.text = hint_text
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(1, 1, 0.75))
		lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		lbl.add_theme_constant_override("outline_size", 3)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var visual_half_h: float = height * _VISUAL_SCALE_MULT * 0.5
		lbl.position = Vector2(-width * 0.6, -visual_half_h - 22)
		lbl.custom_minimum_size = Vector2(width * 1.2, 0)
		add_child(lbl)

func take_damage(amount: int, _element: int = 0) -> void:
	if _destroyed or amount < min_damage_to_register:
		return
	_health -= amount
	# Darken + redden toward "cracked" as it nears breaking — no health bar needed.
	var ratio: float = float(_health) / float(max_health)
	_sprite.modulate = Color(1, 1, 1).lerp(Color(0.45, 0.15, 0.15), 1.0 - ratio)
	if _health <= 0:
		_destroyed = true
		destroyed.emit()
		queue_free()
