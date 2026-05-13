extends CanvasLayer

# =============================================================================
# HUD.gd  —  attached to the root CanvasLayer of scenes/hud.tscn.
#
# All nodes live in the scene file; nothing is created in code.
#
# Direct CanvasLayer children:
#   MissionLabel      Label     (centre-anchored, hidden until mission ends)
#   RetryButton       Button    (centre-anchored, hidden until mission ends)
#   NextLevelButton   Button    (centre-anchored, hidden until mission won)
#   MainMenuButton    Button    (top-right anchor)
#   ObjectiveLabel    Label     (top-left)
#   EscortLabel       Label     (top-left, hidden unless escort mission)
#   EnemyLabel        Label     (top-left)
#   ArrowNode         Control   (full-rect, MOUSE_FILTER_IGNORE — draws enemy arrow)
#   BottomPanel       PanelContainer (bottom-full anchor, ~90 px)
#     └─ MarginContainer
#          └─ HBoxContainer (centred)
#               ├─ WeaponGrid        GridContainer(2 cols)
#               ├─ FormationGrid     GridContainer(3 cols)
#               ├─ GroupSection      VBoxContainer
#               │    ├─ GroupButton
#               │    └─ GroupButtonsContainer
#               └─ SoldierStatsGrid  GridContainer(3 cols)
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

# Colors shared by group buttons and the per-soldier group-number labels so the
# player can instantly match a number on screen to the correct HUD button.
const GROUP_COLORS: Array[Color] = [
	Color(1.0, 0.95, 0.0),   # group 1 — yellow
	Color(0.3,  0.9, 1.0),   # group 2 — cyan
	Color(0.5,  1.0, 0.4),   # group 3 — green
]

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

@onready var _next_level_button: Button  = $NextLevelButton
@onready var _menu_button:       Button  = $MainMenuButton
@onready var _objective_label:   Label   = $ObjectiveLabel
@onready var _escort_label:      Label   = $EscortLabel
@onready var _enemy_label:       Label   = $EnemyLabel
@onready var _arrow_node:        Control = $ArrowNode

var _soldier_stat_labels: Array[Label] = []
var _group_buttons: Array[Button] = []

# "Group X is under attack" notification — shown at top-centre, auto-hides after a few seconds.
var _under_attack_label: Label = null
var _under_attack_timer: float = 0.0

# Revive UI — references resolved during _wire_formation_buttons().
var _revive_button:        Button = null
var _revive_counter_label: Label  = null

# Level-3 arrow targets. Arrow points to the NPC until it joins the squad,
# then redirects to the extraction zone.
var _escort_npc: Node2D = null
var _extraction_zone: Node2D = null
var _escort_joined: bool = false

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

	retry_button.pressed.connect(_on_retry_pressed)
	_next_level_button.pressed.connect(_on_next_level_pressed)
	_menu_button.pressed.connect(_on_menu_pressed)
	_arrow_node.draw.connect(_draw_enemy_arrow)

	# "Group X is under attack" notification — created in code so it doesn't
	# need a scene node. Sits at the top-centre, hidden until triggered.
	_under_attack_label = Label.new()
	_under_attack_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_under_attack_label.anchor_left   = 0.5
	_under_attack_label.anchor_right  = 0.5
	_under_attack_label.anchor_top    = 0.0
	_under_attack_label.anchor_bottom = 0.0
	_under_attack_label.offset_left   = -200.0
	_under_attack_label.offset_right  =  200.0
	_under_attack_label.offset_top    =  12.0
	_under_attack_label.offset_bottom =  40.0
	_under_attack_label.add_theme_font_size_override("font_size", 16)
	_under_attack_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	_under_attack_label.hide()
	add_child(_under_attack_label)

	GameManager.enemies_changed.connect(update_enemy_count)
	update_enemy_count(GameManager.enemies_alive)
	# Toggle the revive button on/off as soldiers fall and come back.
	GameManager.soldier_died.connect(func(_s: Node) -> void: _refresh_revive_button())
	GameManager.soldier_revived.connect(func(_s: Node) -> void: _refresh_revive_button())

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

	# Revive button — repurposes the 6th cell of the formation grid. The "?"
	# label is replaced with a heart icon and a potion counter. Click to bring
	# back the most recently downed soldier (one potion per mission).
	_revive_button = _formation_grid.get_node_or_null("FormationButtonReserved") as Button
	if _revive_button:
		_revive_button.disabled = false
		_revive_button.toggle_mode = false
		_revive_button.text = "♥"
		_revive_button.tooltip_text = "Revive last fallen soldier"
		# Add a small counter label inside the button (same pattern as ammo).
		var counter := Label.new()
		counter.name = "Counter"
		counter.text = str(GameManager.revive_potions)
		counter.add_theme_font_size_override("font_size", 10)
		counter.anchor_left   = 0.5
		counter.anchor_right  = 0.5
		counter.anchor_top    = 1.0
		counter.anchor_bottom = 1.0
		counter.offset_left   = -20.0
		counter.offset_right  =  20.0
		counter.offset_top    = -14.0
		counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_revive_button.add_child(counter)
		_revive_counter_label = counter
		_revive_button.pressed.connect(_on_revive_pressed)
		GameManager.revives_changed.connect(_on_revives_changed)
		_refresh_revive_button()

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

func update_group_info(active: int, total: int, alive_groups: Array = []) -> void:
	if _group_cycle_button:
		_group_cycle_button.text = "GRP %d/%d" % [active, total]
	_rebuild_group_buttons(total, active - 1, alive_groups)

func show_objective(level: int) -> void:
	var texts := {
		1: "OBJECTIVE: Eliminate all enemies",
		2: "OBJECTIVE: Destroy the fortified structure",
		3: "OBJECTIVE: Escort the NPC to extraction",
	}
	_objective_label.text = texts.get(level, "")
	if level == 3:
		_escort_label.show()
	else:
		_escort_label.hide()

func update_escort_health(current: int, max_hp: int) -> void:
	_escort_label.text = "ESCORT HEALTH: %d / %d" % [current, max_hp]

# Main.gd calls these once the level-3 nodes exist so the arrow knows where
# to point. Until the NPC joins the squad the arrow tracks the NPC; after
# that it tracks the extraction zone.
func set_escort_targets(npc: Node2D, zone: Node2D) -> void:
	_escort_npc = npc
	_extraction_zone = zone
	_escort_joined = false

func on_escort_joined() -> void:
	_escort_joined = true

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

func show_under_attack(group_num: int) -> void:
	if _under_attack_label == null:
		return
	_under_attack_label.text = "GROUP %d IS UNDER ATTACK!" % group_num
	_under_attack_label.show()
	_under_attack_timer = 3.0

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

func _rebuild_group_buttons(num_groups: int, active: int, alive_groups: Array = []) -> void:
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
		# Empty groups (whole squad wiped) are not selectable — grey them out so
		# the player can see at a glance which groups still have soldiers.
		# Color matches the per-soldier label so the player can instantly map
		# the HUD number to soldiers on the field.
		btn.add_theme_color_override("font_color", GROUP_COLORS[i % GROUP_COLORS.size()])
		# Toggle-mode lets button_pressed show the currently commanded group.
		btn.toggle_mode   = true
		btn.button_pressed = (i == active)
		var is_alive: bool = alive_groups.is_empty() or alive_groups.has(i)
		if not is_alive:
			btn.disabled = true
			btn.modulate = Color(0.5, 0.5, 0.5, 0.6)
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
func _process(delta: float) -> void:
	if _under_attack_timer > 0.0:
		_under_attack_timer -= delta
		if _under_attack_timer <= 0.0 and _under_attack_label != null:
			_under_attack_label.hide()
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
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl == null:
		return
	var origin: Vector2 = squad_ctrl.get_centroid()

	var target: Node2D = null
	if GameManager.current_level == 3:
		# Point at the trapped/unfreed NPC, then at the extraction zone once
		# they've linked up with the squad.
		if _escort_joined:
			target = _extraction_zone if is_instance_valid(_extraction_zone) else null
		else:
			target = _escort_npc if is_instance_valid(_escort_npc) else null
	else:
		# Original behaviour — surface the arrow once the map is nearly clear
		# so it acts as a closest-enemy finder rather than constant clutter.
		if GameManager.enemies_alive <= 0 or GameManager.enemies_alive >= 10:
			return
		var enemies := get_tree().get_nodes_in_group("enemies")
		var best_dist := INF
		for e in enemies:
			if e is Node2D:
				var d := origin.distance_to(e.global_position)
				if d < best_dist:
					best_dist = d
					target = e

	if target == null:
		return

	var dist: float = origin.distance_to(target.global_position)
	var dir  := (target.global_position - origin).normalized()
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
		"%d tiles" % int(dist / 64.0),
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

# =============================================================================
# REVIVE BUTTON
# =============================================================================
func _on_revive_pressed() -> void:
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl and squad_ctrl.has_method("try_revive"):
		squad_ctrl.try_revive()
	_refresh_revive_button()

func _on_revives_changed(_remaining: int) -> void:
	_refresh_revive_button()

# Updates the counter label and enabled state. The button is disabled when
# either no potions remain OR there is no downed soldier to revive.
func _refresh_revive_button() -> void:
	if _revive_button == null:
		return
	if _revive_counter_label:
		_revive_counter_label.text = str(GameManager.revive_potions)
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	var can: bool = GameManager.revive_potions > 0
	if can and squad_ctrl and squad_ctrl.has_method("can_revive"):
		can = squad_ctrl.can_revive()
	_revive_button.disabled = not can
