# =============================================================================
# Portal.gd
# Hidden escape portal for the Blighted Marsh. The squad must FIND it in the dark
# to win — reaching it ends the mission (so the level is winnable regardless of
# which kids are alive, unlike a parent-cage win). Built entirely in code:
# a detection Area2D, a swirling drawn visual, and an eerie beacon light that only
# reads once the squad's own lights get close in the gloom.
# =============================================================================
extends Area2D

const LightingUtil = preload("res://scripts/LightingUtil.gd")

signal entered

const RADIUS := 46.0

var _triggered: bool = false
var _spin: float = 0.0

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

	# Eerie toxic beacon so a squad that wanders close finally spots it in the dark.
	var light := LightingUtil.make_light(Color(0.4, 1.0, 0.7), 1.5, 1.4)
	add_child(light)
	set_process(true)

func _process(delta: float) -> void:
	_spin += delta * 1.5
	queue_redraw()

func _on_body_entered(body: Node2D) -> void:
	if _triggered or not body.is_in_group("soldiers"):
		return
	_triggered = true
	entered.emit()

func _draw() -> void:
	# Swirling toxic-green rings — a rift in the world (deliberately NOT a purple orb).
	for i in 3:
		var r: float = RADIUS * (0.4 + 0.3 * i)
		var a: float = 0.5 - 0.12 * i
		draw_arc(Vector2.ZERO, r, _spin + i * 1.3, _spin + i * 1.3 + TAU * 0.75,
				32, Color(0.4, 1.0, 0.65, a), 3.0)
	draw_circle(Vector2.ZERO, RADIUS * 0.32, Color(0.3, 0.9, 0.6, 0.55))
	draw_circle(Vector2.ZERO, RADIUS * 0.16, Color(0.85, 1.0, 0.9, 0.85))
