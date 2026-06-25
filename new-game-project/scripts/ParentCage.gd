# =============================================================================
# ParentCage.gd
# One of the kids' parents is imprisoned here. Only the matching child can
# unlock the cage. When the right kid's Area2D enters, the cage opens,
# RunState.free_parent() flips the run-state bit, and the parent_freed signal
# fires so Main can hand it off to mission-win.
#
# Set `child_slot` (0..5) when spawning. MapGenerator does this for mission 1.
# =============================================================================
extends Area2D

signal parent_freed(slot: int)
signal wrong_kid_entered(slot: int)

@export var child_slot: int = 0
# When false the cage still opens + emits parent_freed (so a level can win on it),
# but does NOT flip the RunState parent bit. The optional tutorial uses this so it
# teaches without consuming Kid 1's rescue — the 6 main levels free all 6 parents.
@export var frees_parent: bool = true

const TEX_GARDEN   := "res://resources/environment/fairy_garden/garden_bg.png"
const TEX_CAGE_ON  := "res://resources/environment/fairy_garden/cage_closed.png"
const TEX_CAGE_OFF := "res://resources/environment/fairy_garden/cage_open.png"
const SHADER_BLEND := "res://resources/environment/fairy_garden/garden_blend.gdshader"

var _opened: bool = false
var _last_wrong_kid_time: float = -INF
var _cage_sprite: Sprite2D = null

func _ready() -> void:
	add_to_group("parent_cages")
	body_entered.connect(_on_body_entered)

	# Fairy garden background — rendered just above the terrain with a soft
	# circular fade shader so it blends into any surrounding tile texture.
	if ResourceLoader.exists(TEX_GARDEN):
		var bg := Sprite2D.new()
		bg.texture  = load(TEX_GARDEN)
		bg.z_index  = 0
		bg.z_as_relative = false   # absolute z so it reliably sits above tilemap
		if ResourceLoader.exists(SHADER_BLEND):
			var mat := ShaderMaterial.new()
			mat.shader = load(SHADER_BLEND)
			bg.material = mat
		add_child(bg)

	# Cage sprite — swaps between closed and open on unlock.
	_cage_sprite = Sprite2D.new()
	_cage_sprite.scale   = Vector2(1.5, 1.5)
	_cage_sprite.z_index = 1
	add_child(_cage_sprite)
	_refresh_cage()

	# Floating label so players know which kid to send here.
	var lbl := Label.new()
	lbl.text = "Kid %d's parent" % (child_slot + 1)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-60, -108)
	lbl.custom_minimum_size = Vector2(120, 0)
	add_child(lbl)

func _refresh_cage() -> void:
	if _cage_sprite == null:
		return
	var path := TEX_CAGE_OFF if _opened else TEX_CAGE_ON
	if ResourceLoader.exists(path):
		_cage_sprite.texture = load(path)

func _on_body_entered(body: Node2D) -> void:
	if _opened or not body.is_in_group("soldiers"):
		return
	var slot: int = body.slot_index if "slot_index" in body else -1
	if slot == child_slot:
		_open(slot)
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_wrong_kid_time < 1.0:
		return
	_last_wrong_kid_time = now
	emit_signal("wrong_kid_entered", slot)

func _open(slot: int) -> void:
	_opened = true
	if frees_parent:
		RunState.free_parent(slot)
	emit_signal("parent_freed", slot)
	_refresh_cage()

func is_opened() -> bool:
	return _opened

func _draw() -> void:
	# Fallback placeholder shown if textures haven't been imported yet.
	if _cage_sprite != null and _cage_sprite.texture != null:
		return
	draw_circle(Vector2.ZERO, 36.0, Color(0.18, 0.16, 0.20, 0.85))
	draw_arc(Vector2.ZERO, 36.0, 0.0, TAU, 48, Color(0.7, 0.6, 0.4), 2.0)
	if not _opened:
		var col_bars := Color(0.55, 0.35, 0.15)
		for i in range(-2, 3):
			draw_line(Vector2(float(i) * 8.0, -22), Vector2(float(i) * 8.0, 22), col_bars, 2.5)
		draw_line(Vector2(-22, -22), Vector2(22, -22), col_bars, 2.5)
		draw_line(Vector2(-22,  22), Vector2(22,  22), col_bars, 2.5)
	else:
		draw_circle(Vector2.ZERO, 24.0, Color(1.0, 0.85, 0.35, 0.55))
