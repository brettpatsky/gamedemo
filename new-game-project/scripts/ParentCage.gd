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

var _opened: bool = false
# Throttle "wrong kid" hints — multiple soldiers can pile into the cage at
# once and we don't want a stream of duplicate toasts.
var _last_wrong_kid_time: float = -INF

func _ready() -> void:
	add_to_group("parent_cages")
	body_entered.connect(_on_body_entered)
	queue_redraw()

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
	RunState.free_parent(slot)
	emit_signal("parent_freed", slot)
	queue_redraw()

func is_opened() -> bool:
	return _opened

# Placeholder visuals — bars before opening, a warm glow after. Replace with
# real art when available.
func _draw() -> void:
	draw_circle(Vector2.ZERO, 36.0, Color(0.18, 0.16, 0.20, 0.85))
	draw_arc(Vector2.ZERO, 36.0, 0.0, TAU, 48, Color(0.7, 0.6, 0.4), 2.0)
	if _opened:
		draw_circle(Vector2.ZERO, 24.0, Color(1.0, 0.85, 0.35, 0.55))
		draw_colored_polygon(PackedVector2Array([
			Vector2(0, -14), Vector2(14, 0), Vector2(0, 14), Vector2(-14, 0),
		]), Color(1.0, 0.95, 0.5))
	else:
		var col_bars := Color(0.55, 0.35, 0.15)
		for i in range(-2, 3):
			var x: float = float(i) * 8.0
			draw_line(Vector2(x, -22), Vector2(x, 22), col_bars, 2.5)
		draw_line(Vector2(-22, -22), Vector2(22, -22), col_bars, 2.5)
		draw_line(Vector2(-22,  22), Vector2(22,  22), col_bars, 2.5)
		draw_string(
			ThemeDB.fallback_font,
			Vector2(-60, -32),
			"Kid %d's parent" % (child_slot + 1),
			HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(1, 1, 0.7)
		)
