extends CanvasLayer

# =============================================================================
# HUD.gd
# Attached to the root CanvasLayer of scenes/hud.tscn.
#
# Expected scene tree (built in scenes/hud.tscn):
#   HUD (CanvasLayer)
#   ├── BottomPanel (PanelContainer, anchored bottom-full, ~90px tall)
#   │   └── MarginContainer
#   │       └── HBoxContainer
#   │           ├── WeaponGrid (GridContainer, columns=2)
#   │           │   ├── WeaponButton0 (Button + child TextureRect "Icon", Label "Ammo")
#   │           │   ├── WeaponButton1
#   │           │   ├── WeaponButton2
#   │           │   └── WeaponButton3
#   │           ├── VSeparator
#   │           ├── FormationGrid (GridContainer, columns=3)
#   │           │   ├── FormationButton0 (Button + Label child "Name")
#   │           │   ├── FormationButton1
#   │           │   ├── FormationButton2
#   │           │   ├── FormationButton3
#   │           │   ├── FormationButton4
#   │           │   └── FormationButtonReserved (disabled "?" Button)
#   │           ├── VSeparator2
#   │           ├── GroupSection (VBoxContainer)
#   │           │   ├── GroupButton (Button — cycle group count)
#   │           │   └── GroupButtonsContainer (HBoxContainer — per-group select)
#   │           └── StatsSection (VBoxContainer)
#   │               ├── Soldiers (Label)
#   │               └── Score (Label)
#   ├── MissionLabel (Label, hidden)
#   └── RetryButton (Button, hidden)
# =============================================================================

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
const WEAPON_NAMES := ["Pistol", "Auto", "Grenade", "Sacrifice"]
const WEAPON_ICONS := [
	"res://resources/tdstilepack/PNG/weapon_pistol.png",
	"res://resources/tdstilepack/PNG/weapon_machine.png",
	"res://resources/tdstilepack/PNG/weapon_grenade.png",
	"res://resources/tdstilepack/PNG/weapon_gun.png",  # placeholder for Sacrifice
]

const FORMATION_NAMES := ["2×3", "3×2", "1×6", "6×1", "★"]

# ---------------------------------------------------------------------------
# Onready node refs (paths match the scene tree above)
# ---------------------------------------------------------------------------
@onready var mission_label: Label  = $MissionLabel
@onready var retry_button:  Button = $RetryButton

@onready var _weapon_grid:        GridContainer = $BottomPanel/MarginContainer/HBoxContainer/WeaponGrid
@onready var _formation_grid:     GridContainer = $BottomPanel/MarginContainer/HBoxContainer/FormationGrid
@onready var _group_cycle_button: Button        = $BottomPanel/MarginContainer/HBoxContainer/GroupSection/GroupButton
@onready var _group_buttons_container: HBoxContainer = $BottomPanel/MarginContainer/HBoxContainer/GroupSection/GroupButtonsContainer

@onready var _soldier_stats_grid: GridContainer = $BottomPanel/MarginContainer/HBoxContainer/SoldierStatsGrid
var _soldier_stat_labels: Array[Label] = []

# ---------------------------------------------------------------------------
# Programmatic UI (created in _ready)
# ---------------------------------------------------------------------------
var _objective_label: Label
var _escort_label:    Label
var _enemy_label:     Label
var _next_level_button: Button
var _menu_button:     Button
var _arrow_node:      Control

var _group_buttons: Array[Button] = []

# Caches for current state — used to render highlights & ammo
var _current_weapon:    int = 0
var _current_formation: int = 1   # 3×2 on mission start (matches SquadController)
var _rifle_ammo:        int = 0
var _grenade_ammo:      int = 0
var _sacrifice_avail:   int = 0

# =============================================================================
# READY
# =============================================================================
func _ready() -> void:
	add_to_group("hud")

	_wire_weapon_buttons()
	_wire_formation_buttons()
	_wire_group_section()
	_wire_soldier_stats_grid()

	# Mission-end UI (hidden until win/lose)
	var center := get_viewport().get_visible_rect().size / 2.0
	mission_label.position = center + Vector2(-120.0, -30.0)
	retry_button.position  = center + Vector2(-60.0,  20.0)
	retry_button.text                = "Retry Level"
	retry_button.custom_minimum_size = Vector2(120.0, 40.0)
	mission_label.hide()
	retry_button.hide()
	retry_button.pressed.connect(_on_retry_pressed)

	# NEXT LEVEL button (hidden until mission complete)
	_next_level_button = Button.new()
	_next_level_button.text = "NEXT LEVEL"
	_next_level_button.custom_minimum_size = Vector2(120.0, 40.0)
	_next_level_button.position = center + Vector2(-60.0, 60.0)
	_next_level_button.hide()
	add_child(_next_level_button)
	_next_level_button.pressed.connect(_on_next_level_pressed)

	# Top-right main-menu button
	var vp := get_viewport().get_visible_rect().size
	_menu_button = Button.new()
	_menu_button.text = "MAIN MENU"
	_menu_button.position = Vector2(vp.x - 120, 10)
	add_child(_menu_button)
	_menu_button.pressed.connect(_on_menu_pressed)

	# Objective / escort / enemy-count labels (top-left)
	_objective_label = Label.new()
	_objective_label.position = Vector2(10, 10)
	add_child(_objective_label)

	_escort_label = Label.new()
	_escort_label.position = Vector2(10, 40)
	_escort_label.hide()
	add_child(_escort_label)

	_enemy_label = Label.new()
	_enemy_label.position = Vector2(10, 40)
	add_child(_enemy_label)
	GameManager.enemies_changed.connect(update_enemy_count)
	update_enemy_count(GameManager.enemies_alive)

	# Off-screen-enemy arrow
	_arrow_node = Control.new()
	_arrow_node.set_anchors_preset(Control.PRESET_FULL_RECT)
	_arrow_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_arrow_node)
	_arrow_node.draw.connect(_draw_enemy_arrow)

	# Paint initial states.
	_refresh_weapon_highlight()
	_refresh_formation_highlight()

# =============================================================================
# WIRING — connect each grid button to its handler
# =============================================================================
func _wire_weapon_buttons() -> void:
	for i in WEAPON_NAMES.size():
		var btn := _weapon_grid.get_node_or_null("WeaponButton%d" % i) as Button
		if btn == null:
			push_warning("[HUD] Missing WeaponButton%d" % i)
			continue
		# Icon
		var icon := btn.get_node_or_null("Icon") as TextureRect
		if icon and ResourceLoader.exists(WEAPON_ICONS[i]):
			icon.texture = load(WEAPON_ICONS[i])
		# Tooltip
		btn.tooltip_text = WEAPON_NAMES[i]
		# Click handler
		var idx := i
		btn.pressed.connect(func() -> void: _on_weapon_pressed(idx))

func _wire_formation_buttons() -> void:
	for i in FORMATION_NAMES.size():
		var btn := _formation_grid.get_node_or_null("FormationButton%d" % i) as Button
		if btn == null:
			push_warning("[HUD] Missing FormationButton%d" % i)
			continue
		var lbl := btn.get_node_or_null("Name") as Label
		if lbl:
			lbl.text = FORMATION_NAMES[i]
		btn.tooltip_text = "Formation %s" % FORMATION_NAMES[i]
		var idx := i
		btn.pressed.connect(func() -> void: _on_formation_pressed(idx))

	# Reserved (disabled) placeholder — 6th cell of the 3×2 grid.
	var reserved := _formation_grid.get_node_or_null("FormationButtonReserved") as Button
	if reserved:
		reserved.disabled = true
		reserved.tooltip_text = "Reserved for future use"

func _wire_group_section() -> void:
	if _group_cycle_button:
		_group_cycle_button.pressed.connect(_on_group_cycle_pressed)

func _wire_soldier_stats_grid() -> void:
	_soldier_stat_labels.clear()
	if _soldier_stats_grid == null:
		return
	for child in _soldier_stats_grid.get_children():
		if child is Label:
			(child as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_soldier_stat_labels.append(child)

# =============================================================================
# PUBLIC UPDATE API — called by SquadController and GameManager
# =============================================================================
# Kept as a no-op for callers that still invoke it; the per-soldier grid
# implicitly shows who is alive (dead slots dim out).
func update_soldier_count(_alive: int) -> void:
	pass

# Accepts either an int (preferred) or a String (legacy, mapped by name).
func update_weapon(weapon: Variant) -> void:
	if typeof(weapon) == TYPE_INT:
		_current_weapon = int(weapon)
	elif typeof(weapon) == TYPE_STRING:
		var idx := WEAPON_NAMES.find(String(weapon))
		if idx >= 0:
			_current_weapon = idx
	_refresh_weapon_highlight()
	_refresh_ammo_labels()

func update_ammo(rifle: int, grenades: int, sacrifice_avail: int = 0) -> void:
	_rifle_ammo      = rifle
	_grenade_ammo    = grenades
	_sacrifice_avail = sacrifice_avail
	_refresh_ammo_labels()

# Accepts either an int (preferred) or a String (legacy).
func update_formation(formation: Variant) -> void:
	if typeof(formation) == TYPE_INT:
		_current_formation = int(formation)
	elif typeof(formation) == TYPE_STRING:
		var idx := FORMATION_NAMES.find(String(formation))
		if idx >= 0:
			_current_formation = idx
	_refresh_formation_highlight()

func update_group_info(active: int, total: int) -> void:
	if _group_cycle_button:
		_group_cycle_button.text = "GRP %d/%d" % [active, total]
	_rebuild_group_buttons(total, active - 1)

func show_objective(level: int) -> void:
	var texts := {
		1: "OBJECTIVE: Eliminate all enemies",
		2: "OBJECTIVE: Destroy the fortified structure",
		3: "OBJECTIVE: Escort the NPC to extraction",
	}
	_objective_label.text = texts.get(level, "")
	if level == 3:
		_escort_label.show()
		_enemy_label.position = Vector2(10, 70)
	else:
		_escort_label.hide()
		_enemy_label.position = Vector2(10, 40)

func update_escort_health(current: int, max_hp: int) -> void:
	_escort_label.text = "ESCORT HEALTH: %d / %d" % [current, max_hp]

func show_mission_result(message: String, colour: Color, show_next: bool = false) -> void:
	mission_label.text = message
	mission_label.add_theme_color_override("font_color", colour)
	mission_label.show()
	retry_button.show()
	if show_next:
		_next_level_button.show()
	else:
		_next_level_button.hide()

func update_enemy_count(count: int) -> void:
	if _enemy_label:
		_enemy_label.text = "ENEMIES: %d" % count

# =============================================================================
# INTERNAL — refresh visual state
# =============================================================================
func _refresh_weapon_highlight() -> void:
	for i in WEAPON_NAMES.size():
		var btn := _weapon_grid.get_node_or_null("WeaponButton%d" % i) as Button
		if btn == null:
			continue
		btn.button_pressed = (i == _current_weapon)

func _refresh_formation_highlight() -> void:
	for i in FORMATION_NAMES.size():
		var btn := _formation_grid.get_node_or_null("FormationButton%d" % i) as Button
		if btn == null:
			continue
		btn.button_pressed = (i == _current_formation)

func _refresh_ammo_labels() -> void:
	var ammo_per_weapon := ["∞", str(_rifle_ammo), str(_grenade_ammo), str(_sacrifice_avail)]
	for i in WEAPON_NAMES.size():
		var btn := _weapon_grid.get_node_or_null("WeaponButton%d" % i) as Button
		if btn == null:
			continue
		var ammo_lbl := btn.get_node_or_null("Ammo") as Label
		if ammo_lbl:
			ammo_lbl.text = ammo_per_weapon[i]

func _rebuild_group_buttons(num_groups: int, active: int) -> void:
	for b in _group_buttons:
		b.queue_free()
	_group_buttons.clear()
	if num_groups <= 1:
		return
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	for i in num_groups:
		var btn := Button.new()
		btn.text = str(i + 1)
		btn.custom_minimum_size = Vector2(28, 28)
		if i == active:
			btn.add_theme_color_override("font_color", Color.YELLOW)
		var idx := i
		btn.pressed.connect(func() -> void:
			if squad_ctrl and squad_ctrl.has_method("_select_group"):
				squad_ctrl._select_group(idx)
		)
		_group_buttons_container.add_child(btn)
		_group_buttons.append(btn)

# =============================================================================
# BUTTON HANDLERS — send commands to SquadController
# =============================================================================
func _on_weapon_pressed(idx: int) -> void:
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl and squad_ctrl.has_method("set_weapon"):
		squad_ctrl.set_weapon(idx)
	# Keep the highlight in sync immediately (toggle buttons can drop pressed=false).
	_current_weapon = idx
	_refresh_weapon_highlight()

func _on_formation_pressed(idx: int) -> void:
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl and squad_ctrl.has_method("set_formation"):
		squad_ctrl.set_formation(idx)
	_current_formation = idx
	_refresh_formation_highlight()

func _on_group_cycle_pressed() -> void:
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl and squad_ctrl.has_method("_cycle_group_count"):
		squad_ctrl._cycle_group_count()

# =============================================================================
# OFF-SCREEN ENEMY ARROW
# =============================================================================
func _process(_delta: float) -> void:
	if _arrow_node:
		_arrow_node.queue_redraw()
	_refresh_soldier_stats()

func _refresh_soldier_stats() -> void:
	var n: int = _soldier_stat_labels.size()
	for i in n:
		var lbl := _soldier_stat_labels[i]
		var shots: int = GameManager.soldier_shots[i] if i < GameManager.soldier_shots.size() else 0
		var hits:  int = GameManager.soldier_hits[i]  if i < GameManager.soldier_hits.size()  else 0
		var alive: bool = i < GameManager.soldier_alive.size() and GameManager.soldier_alive[i]
		var acc_text := "--%"
		if shots > 0:
			acc_text = "%d%%" % int(round(100.0 * float(hits) / float(shots)))
		var tag := "S%d" % (i + 1)
		if not alive:
			tag += " †"
		lbl.text = "%s\n%d/%d  %s" % [tag, hits, shots, acc_text]
		lbl.modulate = Color(1, 1, 1, 1) if alive else Color(0.6, 0.6, 0.6, 1)

func _draw_enemy_arrow() -> void:
	if GameManager.enemies_alive <= 0 or GameManager.enemies_alive >= 10:
		return
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl == null:
		return
	var origin: Vector2 = squad_ctrl.get_centroid()
	var enemies := get_tree().get_nodes_in_group("enemies")
	if enemies.is_empty():
		return
	var closest: Node2D = null
	var best_dist := INF
	for e in enemies:
		if e is Node2D:
			var d := origin.distance_to(e.global_position)
			if d < best_dist:
				best_dist = d
				closest = e
	if closest == null:
		return
	var dir  := (closest.global_position - origin).normalized()
	var perp := Vector2(-dir.y, dir.x)
	var screen_size := get_viewport().get_visible_rect().size
	var center := Vector2(screen_size.x * 0.5, screen_size.y - 100.0)
	var tip        := center + dir  * 30.0
	var base_left  := center - dir  * 10.0 + perp * 12.0
	var base_right := center - dir  * 10.0 - perp * 12.0
	_arrow_node.draw_colored_polygon(PackedVector2Array([tip, base_left, base_right]), Color.RED)
	_arrow_node.draw_string(
		ThemeDB.fallback_font,
		center + dir * 50.0,
		"%d tiles" % int(best_dist / 64.0),
		HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color.WHITE
	)

# =============================================================================
# MISSION-END BUTTONS
# =============================================================================
func _on_retry_pressed() -> void:
	var main: Node = get_tree().get_first_node_in_group("main_scene")
	if main and main.has_method("restart"):
		main.restart()

func _on_next_level_pressed() -> void:
	var main: Node = get_tree().get_first_node_in_group("main_scene")
	if main and main.has_method("advance_level"):
		main.advance_level()

func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/title_screen.tscn")
