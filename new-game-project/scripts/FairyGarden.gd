# =============================================================================
# FairyGarden.gd
# Between-mission hub scene shown after every non-final mission win.
# The squad appears in a magical fairy clearing. Any items collected during the
# mission are placed here for the player to walk to and claim. Walking the squad
# up the central path to the EXIT portal begins the next mission.
#
# Added as a CanvasLayer child of Main so it renders over the frozen game world.
# =============================================================================
class_name FairyGarden
extends CanvasLayer

signal garden_exited

# ── Layout (screen-space pixels) ───────────────────────────────────────────────
# Values are computed at runtime from the actual viewport size; these are the
# defaults used before _ready() has access to the viewport rect.
var SW: float = 1152.0
var SH: float = 602.0

const SQUAD_SPEED     := 100.0
const COLLECT_RADIUS  := 44.0    # distance at which an item is auto-collected
const EXIT_Y          := 72.0    # squad y below this value triggers exit

# Clearing: circle in lower-centre.
var CLEARING_CENTER: Vector2
const CLEARING_RADIUS := 165.0

# Path: vertical strip from clearing top to screen top.
const PATH_HALF_W := 58.0        # half-width of the walkable path

# Per-slot colours for the squad dots (mirrors HUD.GROUP_COLORS, extended).
const KID_COLORS: Array[Color] = [
	Color(1.0, 0.90, 0.12),   # slot 0 — yellow
	Color(0.28, 0.90, 1.0),   # slot 1 — cyan
	Color(0.45, 1.0,  0.38),  # slot 2 — green
	Color(1.0, 0.55, 0.20),   # slot 3 — orange
	Color(0.88, 0.32, 1.0),   # slot 4 — purple
	Color(1.0, 0.32, 0.50),   # slot 5 — pink
]

# ── State ──────────────────────────────────────────────────────────────────────
var _squad_pos:    Vector2
var _squad_target: Vector2
var _squad_node:   Node2D = null
var _exiting:      bool   = false

var _fragment_nodes: Array   = []
var _fragment_ids:   Array[String] = []

var _notify_label:  Label = null
var _hint_timer:    float = 0.0
var _fade_rect:     ColorRect = null

# ── Public setup ───────────────────────────────────────────────────────────────

func setup(fragment_ids: Array[String]) -> void:
	_fragment_ids = fragment_ids

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 20   # above HUD (layer 1) and everything else

	# Resolve actual screen dimensions.
	var vp_rect := get_viewport().get_visible_rect()
	SW = vp_rect.size.x
	SH = vp_rect.size.y
	CLEARING_CENTER = Vector2(SW * 0.5, SH * 0.72)
	_squad_pos    = CLEARING_CENTER
	_squad_target = CLEARING_CENTER

	_build_scene()
	# _fade_rect is the top-most child; fade it from black to transparent to reveal the garden.
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", 0.0, 1.1)

func _process(delta: float) -> void:
	if _exiting:
		return
	_move_squad(delta)
	_check_fragment_collection()
	_check_exit()
	if _hint_timer > 0.0:
		_hint_timer -= delta
		if _hint_timer <= 0.0 and _notify_label:
			_notify_label.visible = false

# ── Scene construction ─────────────────────────────────────────────────────────

func _build_scene() -> void:
	# ── Full-screen input-eating backdrop (also black fallback) ──────────────
	var blocker := ColorRect.new()
	blocker.size = Vector2(SW, SH)
	blocker.color = Color(0.04, 0.06, 0.04)   # very dark green fallback
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	blocker.gui_input.connect(func(ev: InputEvent) -> void: _on_garden_input(ev))
	add_child(blocker)

	# ── Garden background ────────────────────────────────────────────────────
	var bg_path := "res://resources/fairy_garden.png"
	if ResourceLoader.exists(bg_path):
		var bg := Sprite2D.new()
		var tex: Texture2D = load(bg_path)
		bg.texture = tex
		bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		bg.position = Vector2(SW * 0.5, SH * 0.5)
		# Scale uniformly to cover the screen (may crop slightly on one axis).
		var s := maxf(SW / float(tex.get_width()), SH / float(tex.get_height()))
		bg.scale = Vector2(s, s)
		add_child(bg)

	# ── Fragment items ───────────────────────────────────────────────────────
	_place_fragments()

	# ── Exit label at top of path ────────────────────────────────────────────
	_build_exit_sign()

	# ── Squad ────────────────────────────────────────────────────────────────
	_squad_node = _SquadDot.new()
	(_squad_node as _SquadDot).init_kids(RunState.living_slots(), KID_COLORS)
	_squad_node.position = CLEARING_CENTER
	add_child(_squad_node)

	# ── Notification label ───────────────────────────────────────────────────
	_notify_label = Label.new()
	_notify_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notify_label.custom_minimum_size = Vector2(SW, 0)
	_notify_label.position = Vector2(0, SH * 0.08)
	_notify_label.add_theme_font_size_override("font_size", 20)
	_notify_label.add_theme_color_override("font_color", Color(0.85, 1.0, 0.75))
	_notify_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_notify_label.add_theme_constant_override("outline_size", 5)
	_notify_label.visible = false
	add_child(_notify_label)

	# ── Instruction strip at the bottom ─────────────────────────────────────
	var inst := Label.new()
	inst.text = "CLICK TO MOVE   ·   COLLECT MEMORIES   ·   WALK TO EXIT"
	inst.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inst.custom_minimum_size = Vector2(SW, 0)
	inst.position = Vector2(0, SH - 30)
	inst.add_theme_font_size_override("font_size", 13)
	inst.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	inst.add_theme_color_override("font_outline_color", Color.BLACK)
	inst.add_theme_constant_override("outline_size", 3)
	add_child(inst)

	# ── Black fade overlay — on top of everything; faded out on entry, in on exit ─
	_fade_rect = ColorRect.new()
	_fade_rect.size = Vector2(SW, SH)
	_fade_rect.color = Color.BLACK
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade_rect)


func _place_fragments() -> void:
	if _fragment_ids.is_empty():
		return
	var count := _fragment_ids.size()
	for i in count:
		var angle := (float(i) / float(count)) * TAU - PI * 0.5
		var pos   := CLEARING_CENTER + Vector2(cos(angle), sin(angle)) * 100.0
		_spawn_item(_fragment_ids[i], pos)

func _spawn_item(id: String, pos: Vector2) -> void:
	var node := Node2D.new()
	node.position = pos
	node.set_meta("fragment_id", id)

	# Item sprite
	var img := "res://resources/fragments/%s.png" % id
	if ResourceLoader.exists(img):
		var spr := Sprite2D.new()
		spr.texture = load(img)
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.scale = Vector2(2.2, 2.2)
		node.add_child(spr)
		var tw := create_tween().set_loops()
		tw.tween_property(spr, "scale", Vector2(2.55, 2.55), 0.65)
		tw.tween_property(spr, "scale", Vector2(1.85, 1.85), 0.65)

	# Name label below item
	var lbl := Label.new()
	lbl.text = FragmentEffects.get_display_name(id)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(140, 0)
	lbl.position = Vector2(-70, 32)
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.65))
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 3)
	node.add_child(lbl)

	_fragment_nodes.append(node)
	add_child(node)

func _build_exit_sign() -> void:
	var lbl := Label.new()
	lbl.text = "▲   NEXT MISSION   ▲"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(SW, 0)
	lbl.position = Vector2(0, 10)
	lbl.add_theme_font_size_override("font_size", 24)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.28))
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 7)
	add_child(lbl)
	# Blink
	var tw := create_tween().set_loops()
	tw.tween_property(lbl, "modulate:a", 0.40, 0.70)
	tw.tween_property(lbl, "modulate:a", 1.00, 0.70)

# ── Input ──────────────────────────────────────────────────────────────────────

func _on_garden_input(event: InputEvent) -> void:
	if _exiting:
		return
	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		if mbe.pressed and mbe.button_index == MOUSE_BUTTON_LEFT:
			var target := mbe.position
			if _is_walkable(target):
				_squad_target = target

# ── Walkability ────────────────────────────────────────────────────────────────

func _is_walkable(pos: Vector2) -> bool:
	if (pos - CLEARING_CENTER).length() < CLEARING_RADIUS:
		return true
	# Path connects clearing to exit; allow slight overlap with clearing top.
	var cx := SW * 0.5
	if absf(pos.x - cx) <= PATH_HALF_W and pos.y < CLEARING_CENTER.y - CLEARING_RADIUS + 30.0:
		return true
	return false

# ── Squad movement ─────────────────────────────────────────────────────────────

func _move_squad(delta: float) -> void:
	var diff := _squad_target - _squad_pos
	if diff.length() < 2.0:
		if _squad_node and _squad_node.has_method("set_dir"):
			_squad_node.call("set_dir", Vector2.ZERO)
		return
	var dir  := diff.normalized()
	var step := SQUAD_SPEED * delta
	_squad_pos = _squad_pos + dir * minf(step, diff.length())
	if _squad_node:
		_squad_node.position = _squad_pos
		if _squad_node.has_method("set_dir"):
			_squad_node.call("set_dir", dir)

# ── Interactions ───────────────────────────────────────────────────────────────

func _check_fragment_collection() -> void:
	for i in range(_fragment_nodes.size() - 1, -1, -1):
		var node := _fragment_nodes[i] as Node2D
		if (_squad_pos - node.position).length() < COLLECT_RADIUS:
			var id: String = node.get_meta("fragment_id", "")
			_collect_item(i, id)

func _collect_item(idx: int, id: String) -> void:
	var node := _fragment_nodes[idx] as Node2D
	_fragment_nodes.remove_at(idx)
	RunState.collect_fragment(id)
	# Pop-and-fade effect
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(node, "scale",       Vector2(2.2, 2.2),  0.18)
	tw.tween_property(node, "modulate:a",  0.0,                 0.30)
	tw.set_parallel(false)
	tw.tween_callback(node.queue_free)
	_show_notify("COLLECTED: %s" % FragmentEffects.get_display_name(id))

func _check_exit() -> void:
	if _squad_pos.y < EXIT_Y:
		_start_exit()

func _start_exit() -> void:
	_exiting = true
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", 1.0, 0.75)
	tw.tween_callback(func() -> void: garden_exited.emit())

func _show_notify(text: String) -> void:
	if _notify_label == null:
		return
	_notify_label.text = text
	_notify_label.visible = true
	_hint_timer = 2.8

# ── Inner class: squad visual ──────────────────────────────────────────────────

class _SquadDot extends Node2D:
	var _slots:  Array[int]   = []
	var _colors: Array[Color] = []
	var _dir:    Vector2      = Vector2.DOWN

	const _OFFSETS: Array[Vector2] = [
		Vector2( 0,   0), Vector2(-13,  8), Vector2( 13,  8),
		Vector2(-8, -12), Vector2(  8, -12), Vector2(  0, -22),
	]

	func init_kids(slots: Array[int], colors: Array[Color]) -> void:
		_slots  = slots
		_colors = colors
		queue_redraw()

	func set_dir(dir: Vector2) -> void:
		if dir != _dir:
			_dir = dir
			queue_redraw()

	func _draw() -> void:
		# Soft glow
		draw_circle(Vector2.ZERO, 23.0, Color(0.45, 0.75, 1.0, 0.20))
		# Shadow
		draw_circle(Vector2(0, 5), 16.0, Color(0.0, 0.0, 0.0, 0.22))
		# Kid dots
		for i in mini(_slots.size(), _OFFSETS.size()):
			var slot := _slots[i]
			var col  := _colors[slot % _colors.size()] if slot < _colors.size() else Color.WHITE
			var off  := _OFFSETS[i]
			draw_circle(off, 6.5, col)
			draw_arc(off, 7.5, 0.0, TAU, 14, col.lightened(0.3), 1.3)
		# Direction indicator (small triangle pointing the way)
		if _dir.length() > 0.1:
			var tip := _dir * 18.0
			var perp := Vector2(-_dir.y, _dir.x) * 4.0
			draw_colored_polygon(PackedVector2Array([tip, -perp * 0.5, perp * 0.5]),
					Color(1, 1, 1, 0.35))
