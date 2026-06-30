# =============================================================================
# Portal.gd
# Shared exit portal used by the tutorial ("gold" kind) and the Blighted Marsh
# ("swamp" kind, the default). The marsh squad must FIND it in the dark to win
# — reaching it ends the mission (so the level is winnable regardless of which
# kids are alive, unlike a parent-cage win). Built entirely in code: a
# detection Area2D, a PixelLab swirl animation (kind-dependent art), and —
# for the swamp — an eerie beacon light that only reads once the squad's own
# lights get close in the gloom.
# =============================================================================
extends Area2D

const LightingUtil = preload("res://scripts/LightingUtil.gd")
const PortalVisualScript = preload("res://scripts/PortalVisual.gd")

signal entered

const RADIUS := 46.0

# "swamp" (toxic-green, Blighted Marsh) or "tutorial" (warm gold). Set BEFORE
# adding the portal to the tree.
@export var kind: String = "swamp"

var _triggered: bool = false

func _ready() -> void:
	add_to_group("portal")
	var col := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = RADIUS
	col.shape = shape
	add_child(col)
	# Soldiers are on collision layer 2 — make sure we detect them.
	set_collision_mask_value(2, true)
	body_entered.connect(_on_body_entered)

	var sprite := AnimatedSprite2D.new()
	sprite.sprite_frames = PortalVisualScript.build_sprite_frames(
			"res://resources/portals/%s_portal.png" % kind)
	sprite.scale = Vector2(0.7, 0.7)
	add_child(sprite)
	sprite.play(&"idle")

	if kind == "swamp":
		# Eerie toxic beacon so a squad that wanders close finally spots it in the dark.
		var light := LightingUtil.make_light(Color(0.4, 1.0, 0.7), 1.5, 1.4)
		add_child(light)

func _on_body_entered(body: Node2D) -> void:
	if _triggered or not body.is_in_group("soldiers"):
		return
	_triggered = true
	entered.emit()
