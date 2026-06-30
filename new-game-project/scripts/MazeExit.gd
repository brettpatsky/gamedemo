# =============================================================================
# MazeExit.gd  (Level 3 / 6 escape goal — both mazes share it)
# Attached to the Area2D created by MazeLevel.gd. Emits `escaped` when the
# soldier (group "soldiers") steps inside. MazeLevel re-emits it on its own
# `escaped` signal so Main.gd can wire mission-win to a single source.
# =============================================================================
extends Area2D

const PortalVisualScript = preload("res://scripts/PortalVisual.gd")

signal escaped

var _triggered: bool = false

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	# Visual radius follows the CollisionShape2D so the user can resize the
	# trigger in the editor and the sprite stays roughly in sync.
	var r: float = 40.0
	var shape_node := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node and shape_node.shape is CircleShape2D:
		r = (shape_node.shape as CircleShape2D).radius
	var sprite := AnimatedSprite2D.new()
	sprite.sprite_frames = PortalVisualScript.build_sprite_frames(
			"res://resources/portals/maze_portal.png")
	sprite.scale = Vector2(r, r) / 64.0
	add_child(sprite)
	sprite.play(&"idle")

func _on_body_entered(body: Node2D) -> void:
	if _triggered:
		return
	if body.is_in_group("soldiers"):
		_triggered = true
		escaped.emit()
