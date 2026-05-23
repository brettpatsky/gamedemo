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
@onready var _god_button:        Button  = $GodButton
@onready var _objective_label:   Label   = $ObjectiveLabel
@onready var _escort_label:      Label   = $EscortLabel
@onready var _enemy_label:       Label   = $EnemyLabel
@onready var _arrow_node:        Control = $ArrowNode

var _soldier_stat_labels: Array[Label] = []
var _group_buttons: Array[Button] = []

# Pause UI — toggle button (mouse / touch) + overlay + input listener.
# The overlay is purely visual (MOUSE_FILTER_IGNORE) so other HUD buttons
# stay clickable while paused. Game-world processing halts via
# get_tree().paused; the HUD itself runs PROCESS_MODE_ALWAYS so the toggle
# button and the pause_game action keep working.
var _paused:         bool      = false
var _pause_button:   Button    = null
var _pause_overlay:  ColorRect = null

# Status modal — STATUS button (mouse) + dim overlay + centred card listing
# the per-soldier hit/shots/accuracy figures that used to live in the bottom
# panel. Toggled by the STATUS button or by hud_activate while the focus is
# on the STATUS button. Modal labels are wired into _soldier_stat_labels so
# _refresh_soldier_stats keeps populating them.
var _status_button:  Button    = null
var _status_overlay: ColorRect = null
var _status_visible: bool      = false

# "Group X is under attack" notification — shown at top-centre, auto-hides after a few seconds.
var _under_attack_label: Label = null
var _under_attack_timer: float = 0.0

# Between-mission reward picker — populated by show_reward_picker(), hidden
# until then. The picker disables the Next Level button until the player
# selects one of the three cards.
var _reward_panel: PanelContainer = null
var _reward_card_buttons: Array[Button] = []
var _reward_card_ids: Array[String] = []

# Revive UI — references resolved during _wire_formation_buttons().
var _revive_button:        Button = null
var _revive_counter_label: Label  = null

# Level-3 arrow targets. Arrow points to the NPC until it joins the squad,
# then redirects to the extraction zone.
var _escort_npc: Node2D = null
var _extraction_zone: Node2D = null
var _escort_joined: bool = false

# Level-4 arrow target — points at the maze exit zone.
var _maze_exit: Node2D = null

# Level-5 boss reference. Drives the boss-health bar, phase banner, and the
# Void Embrace channel bar at the top of the screen.
var _boss: Node2D = null
var _boss_health_bar: ProgressBar = null
var _boss_phase_label: Label = null
var _void_embrace_bar: ProgressBar = null
var _void_embrace_label: Label = null

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
	# Stay processing while the tree is paused so the pause button stays
	# clickable and _unhandled_input can still hear the pause_game action.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_wire_weapon_buttons()
	_wire_formation_buttons()
	_wire_group_section()
	_hide_bottom_stats_grid()
	_build_pause_ui()
	_build_status_ui()

	retry_button.pressed.connect(_on_retry_pressed)
	_next_level_button.pressed.connect(_on_next_level_pressed)
	_menu_button.pressed.connect(_on_menu_pressed)
	_god_button.button_pressed = GameManager.god_mode
	_god_button.toggled.connect(_on_god_toggled)
	_refresh_god_button_visual()
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
	# Feature-gate signals — the tutorial locks Sacrifice and Revive until
	# Puzzle 5 completes. Listen so the buttons grey out / come back in real time.
	GameManager.sacrifice_enabled_changed.connect(func(_e: bool) -> void: _refresh_weapon_locked_state())
	GameManager.revive_enabled_changed.connect(func(_e: bool) -> void: _refresh_revive_button())
	_refresh_weapon_locked_state()

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

func _hide_bottom_stats_grid() -> void:
	if _soldier_stats_grid:
		_soldier_stats_grid.hide()

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
		1: "OBJECTIVE: Solve the six trials and free Kid 1's parent",
		2: "OBJECTIVE: Eliminate all enemies",
		3: "OBJECTIVE: Escape the maze",
		4: "OBJECTIVE: Destroy the fortified structure",
		5: "OBJECTIVE: Escort the NPC to extraction",
		6: "OBJECTIVE: Escape the ruined catacombs",
		7: "OBJECTIVE: Shatter the Weeping Heart",
	}
	var text: String = texts.get(level, "")
	# Tutorial soft-lock guard: if Kid 1 has somehow already died this run
	# (e.g. retrying after a wipe in a later mission), the parent can never be
	# freed and the run is stuck. Surface that explicitly so the player resets.
	if level == 1 and not RunState.kids_alive[0]:
		text = "OBJECTIVE: Kid 1 lost — RESET RUN (F12) to retry the tutorial"
	_objective_label.text = text
	# Escort label only on the Escort mission (now level 5).
	if level == 5:
		_escort_label.show()
	else:
		_escort_label.hide()
	# Tutorial (3 dummies), mazes (no enemies), and the boss (own health bar)
	# all hide the generic ENEMIES counter — only the procedural missions
	# (Eliminate / Structures / Escort = 2 / 4 / 5) show it.
	if _enemy_label:
		_enemy_label.visible = level == 2 or level == 4 or level == 5

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

# Main.gd calls this on level 4 so the red arrow points at the exit Area2D
# spawned by MazeLevel.
func set_maze_exit(exit_zone: Node2D) -> void:
	_maze_exit = exit_zone

# Main.gd calls this on level 5 with the BossHeartstone instance so the HUD
# can render the boss-health bar / phase banner / Void Embrace channel bar.
# Created in code (rather than in the scene) so HUD.tscn stays untouched.
func set_boss(boss: Node2D) -> void:
	_boss = boss
	if _boss_health_bar == null:
		_build_boss_overlay()
	if boss and boss.has_signal("phase_changed"):
		boss.phase_changed.connect(_on_boss_phase_changed)
	if boss and boss.has_signal("void_embrace_started"):
		boss.void_embrace_started.connect(_on_void_embrace_started)
	if boss and boss.has_signal("void_embrace_cleared"):
		boss.void_embrace_cleared.connect(_on_void_embrace_cleared)

func _build_boss_overlay() -> void:
	# Boss-health bar — centred near the top of the screen, beneath the phase label.
	_boss_health_bar = ProgressBar.new()
	_boss_health_bar.anchor_left   = 0.5
	_boss_health_bar.anchor_right  = 0.5
	_boss_health_bar.anchor_top    = 0.0
	_boss_health_bar.anchor_bottom = 0.0
	_boss_health_bar.offset_left   = -260.0
	_boss_health_bar.offset_right  =  260.0
	_boss_health_bar.offset_top    =  68.0
	_boss_health_bar.offset_bottom =  86.0
	_boss_health_bar.max_value     = 360.0
	_boss_health_bar.value         = 360.0
	_boss_health_bar.show_percentage = false
	add_child(_boss_health_bar)

	_boss_phase_label = Label.new()
	_boss_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_phase_label.anchor_left   = 0.5
	_boss_phase_label.anchor_right  = 0.5
	_boss_phase_label.anchor_top    = 0.0
	_boss_phase_label.anchor_bottom = 0.0
	_boss_phase_label.offset_left   = -260.0
	_boss_phase_label.offset_right  =  260.0
	_boss_phase_label.offset_top    =  44.0
	_boss_phase_label.offset_bottom =  68.0
	_boss_phase_label.add_theme_font_size_override("font_size", 18)
	_boss_phase_label.add_theme_color_override("font_color", Color(1.0, 0.85, 1.0))
	_boss_phase_label.text = "THE WEEPING HEART  —  PHASE 1"
	add_child(_boss_phase_label)

	# Void Embrace channel bar — hidden until the boss starts channelling. Big,
	# threatening, and centred high on the screen so the player can't miss it.
	_void_embrace_bar = ProgressBar.new()
	_void_embrace_bar.anchor_left   = 0.5
	_void_embrace_bar.anchor_right  = 0.5
	_void_embrace_bar.anchor_top    = 0.0
	_void_embrace_bar.anchor_bottom = 0.0
	_void_embrace_bar.offset_left   = -300.0
	_void_embrace_bar.offset_right  =  300.0
	_void_embrace_bar.offset_top    = 110.0
	_void_embrace_bar.offset_bottom = 140.0
	_void_embrace_bar.max_value     = 1.0
	_void_embrace_bar.value         = 0.0
	_void_embrace_bar.show_percentage = false
	_void_embrace_bar.modulate = Color(1.0, 0.3, 1.0)
	_void_embrace_bar.hide()
	add_child(_void_embrace_bar)

	_void_embrace_label = Label.new()
	_void_embrace_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_void_embrace_label.anchor_left   = 0.5
	_void_embrace_label.anchor_right  = 0.5
	_void_embrace_label.anchor_top    = 0.0
	_void_embrace_label.anchor_bottom = 0.0
	_void_embrace_label.offset_left   = -300.0
	_void_embrace_label.offset_right  =  300.0
	_void_embrace_label.offset_top    =  88.0
	_void_embrace_label.offset_bottom = 110.0
	_void_embrace_label.add_theme_font_size_override("font_size", 16)
	_void_embrace_label.add_theme_color_override("font_color", Color(1.0, 0.4, 1.0))
	_void_embrace_label.text = "VOID EMBRACE — SACRIFICE OR DIE!"
	_void_embrace_label.hide()
	add_child(_void_embrace_label)

func _on_boss_phase_changed(phase: int) -> void:
	if _boss_phase_label == null:
		return
	var phase_names := {
		1: "PHASE 1 — LEYLINE GRID",
		2: "PHASE 2 — THE MIRAGE  (BREAK THE TOTEMS)",
		3: "PHASE 3 — MELTDOWN",
	}
	_boss_phase_label.text = "THE WEEPING HEART  —  %s" % phase_names.get(phase, "")

func _on_void_embrace_started() -> void:
	if _void_embrace_bar:
		_void_embrace_bar.value = 0.0
		_void_embrace_bar.show()
	if _void_embrace_label:
		_void_embrace_label.show()

func _on_void_embrace_cleared() -> void:
	if _void_embrace_bar:
		_void_embrace_bar.hide()
	if _void_embrace_label:
		_void_embrace_label.hide()

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
	show_toast("GROUP %d IS UNDER ATTACK!" % group_num, Color(1.0, 0.2, 0.2), 3.0)

# =============================================================================
# REWARD PICKER  (shown after a non-boss mission win)
# =============================================================================
func show_reward_picker(ids: Array[String]) -> void:
	if ids.is_empty():
		return
	if _reward_panel == null:
		_build_reward_picker()
	if _next_level_button:
		_next_level_button.disabled = true
	for i in _reward_card_buttons.size():
		var btn := _reward_card_buttons[i]
		if i < ids.size():
			var id: String = ids[i]
			btn.text = "%s\n\n%s" % [FragmentEffects.get_display_name(id), FragmentEffects.get_description(id)]
			btn.show()
		else:
			btn.hide()
	_reward_card_ids = ids
	_reward_panel.show()

func _build_reward_picker() -> void:
	_reward_panel = PanelContainer.new()
	_reward_panel.set_anchors_preset(Control.PRESET_CENTER)
	_reward_panel.position = Vector2(-330, -130)
	_reward_panel.custom_minimum_size = Vector2(660, 220)
	_reward_panel.hide()
	add_child(_reward_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	_reward_panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "CHOOSE A MEMORY TO CARRY FORWARD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.7))
	vb.add_child(title)

	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 12)
	vb.add_child(hb)

	for i in 3:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(190, 140)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.clip_text = false
		var idx: int = i
		btn.pressed.connect(func() -> void: _on_reward_card_pressed(idx))
		hb.add_child(btn)
		_reward_card_buttons.append(btn)

func _on_reward_card_pressed(card_index: int) -> void:
	if card_index < 0 or card_index >= _reward_card_ids.size():
		return
	var id: String = _reward_card_ids[card_index]
	RunState.collect_fragment(id)
	if _reward_panel:
		_reward_panel.hide()
	if _next_level_button:
		_next_level_button.disabled = false
	show_toast("MEMORY TAKEN — %s" % FragmentEffects.get_display_name(id),
			Color(0.85, 1.0, 0.95), 3.0)

# Generic transient top-centre notification — reuses the under-attack label
# slot so we don't carry a second long-lived child. Latest message wins.
func show_toast(message: String, colour: Color = Color.WHITE, duration: float = 2.5) -> void:
	if _under_attack_label == null:
		return
	_under_attack_label.text = message
	_under_attack_label.add_theme_color_override("font_color", colour)
	_under_attack_label.show()
	_under_attack_timer = duration

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
	_refresh_boss_overlay()
	_poll_rifle_ammo()

# SludgePool decrements GameManager.rifle_ammo_pool directly without notifying
# the HUD, which left the cached `_rifle_ammo` stale — the player would only
# see the real number after firing or switching weapons (sometimes a sudden
# 40+ jump). Polling here keeps the readout honest every frame.
func _poll_rifle_ammo() -> void:
	var current: int = GameManager.rifle_ammo_pool
	if current == _rifle_ammo:
		return
	_rifle_ammo = current
	_refresh_ammo_labels()

func _refresh_boss_overlay() -> void:
	if _boss == null or not is_instance_valid(_boss):
		return
	if _boss_health_bar and _boss.has_method("get_health"):
		_boss_health_bar.value = _boss.get_health()
	if _void_embrace_bar and _void_embrace_bar.visible and _boss.has_method("get_void_progress"):
		_void_embrace_bar.value = _boss.get_void_progress()

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
	if GameManager.current_level == 5:
		# Escort mission — point at the trapped/unfreed NPC, then at the
		# extraction zone once they've linked up with the squad.
		if _escort_joined:
			target = _extraction_zone if is_instance_valid(_extraction_zone) else null
		else:
			target = _escort_npc if is_instance_valid(_escort_npc) else null
	elif GameManager.current_level == 3 or GameManager.current_level == 6:
		# Maze escape (Maze 1 = level 3, Maze 2 = level 6) — always point to the exit.
		target = _maze_exit if is_instance_valid(_maze_exit) else null
	elif GameManager.current_level == 7:
		# Boss fight — entire arena fits on-screen, so no enemy arrow is needed.
		return
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
	# Sit clear of the 90px-tall bottom panel even when the arrow points
	# straight down: tip extends +30, text baseline +50 with ~14px of glyph
	# height below it. -160 keeps everything above the HUD edge.
	var center := Vector2(screen_size.x * 0.5, screen_size.y - 160.0)
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
	# Make sure a paused-state doesn't leak into the new scene.
	if _paused:
		_toggle_pause()
	var main: Node = get_tree().get_first_node_in_group("main_scene")
	if main and main.has_method("restart"):
		main.restart()

func _on_next_level_pressed() -> void:
	if _paused:
		_toggle_pause()
	var main: Node = get_tree().get_first_node_in_group("main_scene")
	if main and main.has_method("advance_level"):
		main.advance_level()

func _on_menu_pressed() -> void:
	if _paused:
		_toggle_pause()
	get_tree().change_scene_to_file("res://scenes/title_screen.tscn")

# =============================================================================
# PAUSE
# =============================================================================
# Builds the bottom-right PAUSE button (sized to match GOD / MAIN MENU) and
# the centred dim-and-text overlay. Overlay uses MOUSE_FILTER_IGNORE so it's
# purely visual — other HUD buttons stay clickable while paused.
func _build_pause_ui() -> void:
	_pause_button = Button.new()
	_pause_button.text = "PAUSE"
	_pause_button.anchor_left   = 1.0
	_pause_button.anchor_top    = 1.0
	_pause_button.anchor_right  = 1.0
	_pause_button.anchor_bottom = 1.0
	# Tucked just to the left of the GOD button (which sits at offset_left
	# = -215). 5 px gap between them.
	_pause_button.offset_left   = -290.0
	_pause_button.offset_top    = -63.0
	_pause_button.offset_right  = -220.0
	_pause_button.offset_bottom = -27.0
	_pause_button.add_theme_font_size_override("font_size", 18)
	_pause_button.pressed.connect(_on_pause_pressed)
	add_child(_pause_button)

	_pause_overlay = ColorRect.new()
	_pause_overlay.color = Color(0, 0, 0, 0.55)
	_pause_overlay.anchor_left   = 0.0
	_pause_overlay.anchor_top    = 0.0
	_pause_overlay.anchor_right  = 1.0
	_pause_overlay.anchor_bottom = 1.0
	_pause_overlay.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_pause_overlay.hide()

	var label := Label.new()
	label.text = "PAUSED\n\nClick PAUSE, press Esc, or press START to resume"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	label.anchor_left   = 0.0
	label.anchor_top    = 0.0
	label.anchor_right  = 1.0
	label.anchor_bottom = 1.0
	label.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 44)
	label.add_theme_color_override("font_color", Color(1, 1, 1))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	label.add_theme_constant_override("outline_size", 6)
	_pause_overlay.add_child(label)
	add_child(_pause_overlay)

func _on_pause_pressed() -> void:
	_toggle_pause()

func _toggle_pause() -> void:
	_paused = not _paused
	get_tree().paused = _paused
	if _pause_overlay:
		_pause_overlay.visible = _paused
	if _pause_button:
		_pause_button.text = "RESUME" if _paused else "PAUSE"

# Listens for the pause_game action (Esc keyboard / Start gamepad) at all
# times — HUD has process_mode = ALWAYS so input flows even when paused.
# Also handles the gamepad-only HUD navigation actions (LB cycles focus
# through visible HUD buttons, LT activates the focused one) and the
# revive shortcut (R / X) which fires the same handler as the heart button.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_game"):
		_toggle_pause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("revive_squad"):
		_on_revive_pressed()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("hud_focus_next"):
		_focus_next_hud_button()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("hud_activate"):
		_activate_focused_hud_button()
		get_viewport().set_input_as_handled()

# =============================================================================
# STATUS MODAL  (per-soldier hit / shots / accuracy panel)
# =============================================================================
# STATUS button sits at the bottom-right, just left of PAUSE. Clicking it
# (or hud_activate while it's focused) toggles a dim-and-card overlay that
# shows the six soldier stat cells in a 3-column grid. Labels are stored in
# _soldier_stat_labels so the existing _refresh_soldier_stats() keeps them
# live every frame.
func _build_status_ui() -> void:
	_status_button = Button.new()
	_status_button.text = "STATUS"
	_status_button.anchor_left   = 1.0
	_status_button.anchor_top    = 1.0
	_status_button.anchor_right  = 1.0
	_status_button.anchor_bottom = 1.0
	# PAUSE sits at offset_left = -290 → -220. STATUS goes immediately to its
	# left with a 5 px gap.
	_status_button.offset_left   = -365.0
	_status_button.offset_top    = -63.0
	_status_button.offset_right  = -295.0
	_status_button.offset_bottom = -27.0
	_status_button.add_theme_font_size_override("font_size", 18)
	_status_button.pressed.connect(_toggle_status_modal)
	add_child(_status_button)

	_status_overlay = ColorRect.new()
	_status_overlay.color = Color(0, 0, 0, 0.55)
	_status_overlay.anchor_left   = 0.0
	_status_overlay.anchor_top    = 0.0
	_status_overlay.anchor_right  = 1.0
	_status_overlay.anchor_bottom = 1.0
	# Catches clicks outside the card so the overlay can dismiss the modal.
	_status_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_status_overlay.gui_input.connect(_on_status_overlay_input)
	_status_overlay.hide()
	add_child(_status_overlay)

	var card := PanelContainer.new()
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.position = Vector2(-230, -160)
	card.custom_minimum_size = Vector2(460, 320)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	_status_overlay.add_child(card)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	card.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "SQUAD STATUS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.7))
	vb.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 12)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(grid)

	_soldier_stat_labels.clear()
	for i in 6:
		var lbl := Label.new()
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 16)
		lbl.custom_minimum_size = Vector2(120, 44)
		lbl.text = "S%d\n0/0  --%%" % (i + 1)
		grid.add_child(lbl)
		_soldier_stat_labels.append(lbl)

	var close_btn := Button.new()
	close_btn.text = "  Close  "
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close_btn.add_theme_font_size_override("font_size", 18)
	close_btn.pressed.connect(_toggle_status_modal)
	vb.add_child(close_btn)

func _toggle_status_modal() -> void:
	_status_visible = not _status_visible
	if _status_overlay:
		_status_overlay.visible = _status_visible

func _on_status_overlay_input(event: InputEvent) -> void:
	# Dismiss when the user clicks the dim area outside the card.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_toggle_status_modal()

# =============================================================================
# CONTROLLER HUD NAVIGATION  (LB = next focus, LT = activate)
# =============================================================================
# Walks the HUD tree and returns every visible, non-disabled Button in
# top-to-bottom order. Used by LB to cycle focus and by LT to activate the
# currently focused button.
func _gather_focusable_hud_buttons() -> Array[Button]:
	var out: Array[Button] = []
	_collect_buttons_recursive(self, out)
	return out

func _collect_buttons_recursive(node: Node, out: Array[Button]) -> void:
	for child in node.get_children():
		if child is CanvasItem and not (child as CanvasItem).visible:
			continue
		if child is Button:
			var btn := child as Button
			if not btn.disabled:
				out.append(btn)
		_collect_buttons_recursive(child, out)

func _focus_next_hud_button() -> void:
	var buttons: Array[Button] = _gather_focusable_hud_buttons()
	if buttons.is_empty():
		return
	var current: Control = get_viewport().gui_get_focus_owner()
	var idx: int = -1
	if current is Button:
		idx = buttons.find(current)
	var next_idx: int = (idx + 1) % buttons.size()
	buttons[next_idx].grab_focus()

func _activate_focused_hud_button() -> void:
	var current: Control = get_viewport().gui_get_focus_owner()
	if not (current is Button):
		return
	var btn := current as Button
	if btn.disabled:
		return
	# Toggle buttons must flip their own state before firing the toggled
	# signal — `pressed` alone won't update button_pressed visually.
	if btn.toggle_mode:
		btn.button_pressed = not btn.button_pressed
		btn.toggled.emit(btn.button_pressed)
	btn.pressed.emit()

# GOD mode — toggles squad-wide invulnerability via GameManager.god_mode.
# Soldier.take_damage() early-returns when the flag is on. The button stays
# pressed-in while active so the player can see the cheat is engaged.
func _on_god_toggled(pressed: bool) -> void:
	GameManager.god_mode = pressed
	_refresh_god_button_visual()

func _refresh_god_button_visual() -> void:
	if _god_button == null:
		return
	if GameManager.god_mode:
		_god_button.add_theme_color_override("font_color", Color(1.0, 0.85, 0.1))
		_god_button.text = "GOD ✓"
	else:
		_god_button.remove_theme_color_override("font_color")
		_god_button.text = "GOD"

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
# the feature is locked (tutorial pre-Puzzle 5), no potions remain, or no
# downed soldier exists to revive.
func _refresh_revive_button() -> void:
	if _revive_button == null:
		return
	if _revive_counter_label:
		_revive_counter_label.text = str(GameManager.revive_potions)
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	var can: bool = GameManager.revive_enabled and GameManager.revive_potions > 0
	if can and squad_ctrl and squad_ctrl.has_method("can_revive"):
		can = squad_ctrl.can_revive()
	_revive_button.disabled = not can

# Disables the Sacrifice weapon button when GameManager.sacrifice_enabled is
# false. Called on _ready and whenever the gate flips.
func _refresh_weapon_locked_state() -> void:
	var sacrifice_btn := _weapon_grid.get_node_or_null("WeaponButton3") as Button
	if sacrifice_btn:
		sacrifice_btn.disabled = not GameManager.sacrifice_enabled
