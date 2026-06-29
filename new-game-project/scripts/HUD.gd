extends CanvasLayer

# =============================================================================
# HUD.gd  —  attached to the root CanvasLayer of scenes/hud.tscn.
#
# Most nodes live in the scene file. The Pause overlay, Status modal, the
# under-attack toast, and the boss-health/Void Embrace bars are all built
# in code so the .tscn stays untouched while their layout iterates.
#
# Scene tree (top-level CanvasLayer children):
#   MissionLabel      Label     (centre, shown on mission end)
#   RetryButton       Button    (centre, shown on mission end)
#   NextLevelButton   Button    (centre, shown on mission win)
#   MainMenuButton    Button    (top-right)
#   GodButton         Button    (bottom-right — debug invincibility toggle)
#   ObjectiveLabel    Label     (top-left)
#   EscortLabel       Label     (top-left, escort mission only)
#   EnemyLabel        Label     (top-left)
#   ArrowNode         Control   (full-rect, draws off-screen-enemy arrow)
#   BottomPanel       PanelContainer (bottom-full)
#     └─ MarginContainer → HBoxContainer
#          ├─ WeaponGrid     GridContainer(2 cols)
#          ├─ FormationGrid  GridContainer(3 cols, last cell = Revive)
#          ├─ GroupSection   VBoxContainer (cycle btn + per-group btns)
#          └─ SoldierStatsGrid  GridContainer (hidden — moved into the Status modal)
# =============================================================================

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
const WEAPON_NAMES := ["Pistol", "Auto", "Grenade", "Sacrifice"]
const WEAPON_ICONS := [
	"res://resources/UI/icons/wand_fire.png",
	"res://resources/UI/icons/wand_rapid.png",
	"res://resources/UI/icons/bomb_magic.png",
	"res://resources/UI/icons/gem_sacrifice.png",
]

const FORMATION_NAMES := ["2×3", "3×2", "1×6", "6×1", "★"]

const FORMATION_ICONS := [
	"res://resources/UI/icons/formation_2x3.png",
	"res://resources/UI/icons/formation_3x2.png",
	"res://resources/UI/icons/formation_1x6.png",
	"res://resources/UI/icons/formation_6x1.png",
	"res://resources/UI/icons/formation_star.png",
]

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
var _pause_button:   Button    = null   # lives inside the options popup
var _pause_overlay:  ColorRect = null

# Options popup — collects STATUS / PAUSE / GOD / MENU into a small panel
# that slides up above the bottom bar when the ⚙ button is pressed.
var _options_button: Button        = null
var _options_popup:  PanelContainer = null
var _options_open:   bool          = false

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
var _reward_card_containers: Array[Control] = []
var _reward_card_buttons: Array[Button] = []
var _reward_card_icons: Array[TextureRect] = []
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

# Boss reference. Drives the Void Embrace channel warning at the top of the
# screen; the boss's health bar lives above the boss itself, not on the HUD.
var _boss: Node2D = null
var _void_embrace_bar: ProgressBar = null
var _void_embrace_label: Label = null

# Caches for current state — used to render highlights & ammo
var _current_weapon:    int = 0
var _current_formation: int = 1   # 3×2 on mission start (matches SquadController)
var _rifle_ammo:        int = 0
var _grenade_ammo:      int = 0
var _sacrifice_avail:   int = 0
# Running max per weapon slot (reset at mission start via show_objective).
# Index 0 = infinite, 1 = rifle, 2 = grenade, 3 = sacrifice.
var _ammo_max: Array[int] = [0, 0, 0, 0]

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
	# Hide the standalone scene buttons before _build_options_popup() reassigns
	# _god_button to the new in-popup version.
	_god_button.hide()
	_menu_button.hide()
	_build_options_popup()  # reassigns _god_button / _status_button / _pause_button

	retry_button.pressed.connect(_on_retry_pressed)
	_next_level_button.pressed.connect(_on_next_level_pressed)
	# _god_button and _menu_button are now the popup versions; no extra wiring needed.
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
	_style_hud()
	_build_touch_controls()

# =============================================================================
# TOUCH CONTROLS (tablet / phone)
# Move = tap the field (Godot emulates a left-click from touch). Every command is
# already an on-screen button. The one missing input is firing (a held right-click
# aiming at the cursor), so we add a big thumb FIRE button that auto-aims the
# nearest enemy. Only shown when a touchscreen is present, so desktop is untouched.
# =============================================================================
var _touch_ui: bool = false
var _touch_fire_button: Button = null

# Safe-area (notch / rounded corners). Black bars live on their own high layer;
# base offsets of the edge controls are captured once so re-applying on rotate
# never stacks.
var _safe_bars: CanvasLayer = null
var _safe_base_offsets: Dictionary = {}   # Control -> Vector4(l, t, r, b)

func _build_touch_controls() -> void:
	if not DisplayServer.is_touchscreen_available():
		return
	_touch_ui = true
	_finger_size_hud()
	var btn := Button.new()
	btn.name = "TouchFireButton"
	btn.text = "FIRE"
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 30)
	btn.modulate = Color(1, 1, 1, 0.85)
	# Big round-ish red button, bottom-right, sitting above the bottom HUD panel.
	const SZ := 156.0
	btn.anchor_left = 1.0; btn.anchor_top = 1.0; btn.anchor_right = 1.0; btn.anchor_bottom = 1.0
	btn.offset_right  = -32.0
	btn.offset_bottom = -118.0
	btn.offset_left   = -32.0 - SZ
	btn.offset_top    = -118.0 - SZ
	for style_name in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.85, 0.18, 0.18) if style_name != "pressed" else Color(1.0, 0.4, 0.3)
		sb.set_corner_radius_all(int(SZ * 0.5))
		sb.border_color = Color(1, 1, 1, 0.6)
		sb.set_border_width_all(3)
		btn.add_theme_stylebox_override(style_name, sb)
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.button_down.connect(func() -> void: _set_squad_touch_firing(true))
	btn.button_up.connect(func() -> void: _set_squad_touch_firing(false))
	add_child(btn)
	_touch_fire_button = btn

	# Notch / rounded-corner handling. Recompute now and on every resize/rotation.
	# Deferred once so Android reports a valid safe area (it can return the full
	# window on the very first frame).
	get_viewport().size_changed.connect(_apply_safe_area)
	_apply_safe_area.call_deferred()

func _set_squad_touch_firing(on: bool) -> void:
	var sc: Node = get_tree().get_first_node_in_group("squad_controller")
	if sc and sc.has_method("set_touch_firing"):
		sc.set_touch_firing(on)

# Computes the display safe area (camera hole-punch + rounded corners), masks the
# unsafe margins with opaque black bars, and pulls the edge-anchored HUD controls
# inward so the cog, FIRE button, labels, and command bar stay fully on-screen.
func _apply_safe_area() -> void:
	if not _touch_ui:
		return
	var win: Vector2 = Vector2(DisplayServer.window_get_size())
	if win.x <= 0.0 or win.y <= 0.0:
		return
	var safe: Rect2i = DisplayServer.get_display_safe_area()
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var sx: float = vp.x / win.x
	var sy: float = vp.y / win.y
	var left:   float = maxf(float(safe.position.x) * sx, 0.0)
	var top:    float = maxf(float(safe.position.y) * sy, 0.0)
	var right:  float = maxf((win.x - float(safe.position.x + safe.size.x)) * sx, 0.0)
	var bottom: float = maxf((win.y - float(safe.position.y + safe.size.y)) * sy, 0.0)

	_rebuild_safe_bars(vp, left, top, right, bottom)

	# Bottom-right corner controls: pull left by `right`, up by `bottom`.
	_inset_control(_options_button, -right, -bottom, -right, -bottom)
	_inset_control(_options_popup,  -right, -bottom, -right, -bottom)
	_inset_control(_touch_fire_button, -right, -bottom, -right, -bottom)
	# Top-left labels: push right by `left`, down by `top`.
	_inset_control(_objective_label, left, top, left, top)
	_inset_control(_enemy_label,     left, top, left, top)
	_inset_control(_escort_label,    left, top, left, top)
	# Keep the command bar's contents clear of the side bars.
	var bar_margin := get_node_or_null("BottomPanel/MarginContainer") as MarginContainer
	if bar_margin:
		bar_margin.add_theme_constant_override("margin_left",  int(maxf(left, 8.0)))
		bar_margin.add_theme_constant_override("margin_right", int(maxf(right, 8.0)))

func _inset_control(c: Control, dl: float, dt: float, dr: float, db: float) -> void:
	if c == null:
		return
	if not _safe_base_offsets.has(c):
		_safe_base_offsets[c] = Vector4(c.offset_left, c.offset_top, c.offset_right, c.offset_bottom)
	var b: Vector4 = _safe_base_offsets[c]
	c.offset_left   = b.x + dl
	c.offset_top    = b.y + dt
	c.offset_right  = b.z + dr
	c.offset_bottom = b.w + db

func _rebuild_safe_bars(vp: Vector2, left: float, top: float, right: float, bottom: float) -> void:
	if _safe_bars == null:
		_safe_bars = CanvasLayer.new()
		_safe_bars.layer = 80   # above the HUD (layer 1) so it frames everything
		add_child(_safe_bars)
	for child in _safe_bars.get_children():
		child.queue_free()
	if left <= 0.0 and top <= 0.0 and right <= 0.0 and bottom <= 0.0:
		return
	var rects := [
		Rect2(0, 0, left, vp.y),                       # left
		Rect2(vp.x - right, 0, right, vp.y),           # right
		Rect2(0, 0, vp.x, top),                        # top
		Rect2(0, vp.y - bottom, vp.x, bottom),         # bottom
	]
	for r: Rect2 in rects:
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		var bar := ColorRect.new()
		bar.color = Color.BLACK
		bar.position = r.position
		bar.size = r.size
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_safe_bars.add_child(bar)

# Enlarges the bottom command panel + its buttons to finger-friendly sizes on
# touch devices (the defaults are mouse-sized). Desktop keeps the compact layout.
func _finger_size_hud() -> void:
	var panel := get_node_or_null("BottomPanel") as Control
	if panel:
		panel.offset_top = -88.0   # taller strip so 64px buttons fit
	for grid in [_weapon_grid, _formation_grid]:
		if grid == null:
			continue
		for c in grid.get_children():
			if c is Button:
				(c as Button).custom_minimum_size = Vector2(60, 64)
	if _group_cycle_button:
		_group_cycle_button.custom_minimum_size = Vector2(80, 64)

# =============================================================================
# WIRING — connect each grid button to its handler
# =============================================================================
func _wire_weapon_buttons() -> void:
	for i in WEAPON_NAMES.size():
		var btn := _weapon_grid.get_node_or_null("WeaponButton%d" % i) as Button
		if btn == null:
			push_warning("[HUD] Missing WeaponButton%d" % i)
			continue
		if ResourceLoader.exists(WEAPON_ICONS[i]):
			btn.icon = load(WEAPON_ICONS[i])
			btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			btn.expand_icon = true
		var icon := btn.get_node_or_null("Icon") as TextureRect
		if icon and ResourceLoader.exists(WEAPON_ICONS[i]):
			icon.texture = load(WEAPON_ICONS[i])
		# Hide the old text label; replace with a colour-coded ammo bar.
		var ammo_lbl := btn.get_node_or_null("Ammo") as Label
		if ammo_lbl:
			ammo_lbl.hide()
		_add_ammo_bar(btn, i == 0)
		btn.tooltip_text = WEAPON_NAMES[i]
		var idx := i
		btn.pressed.connect(func() -> void: _on_weapon_pressed(idx))

func _add_ammo_bar(btn: Button, infinite: bool) -> void:
	var bg := ColorRect.new()
	bg.name = "AmmoBarBg"
	bg.anchor_left   = 0.0
	bg.anchor_right  = 1.0
	bg.anchor_top    = 1.0
	bg.anchor_bottom = 1.0
	bg.offset_top    = -5.0
	bg.color         = Color(0.08, 0.08, 0.08, 0.85)
	bg.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	btn.add_child(bg)
	var fill := ColorRect.new()
	fill.name          = "AmmoBarFill"
	fill.anchor_left   = 0.0
	fill.anchor_right  = 1.0
	fill.anchor_top    = 0.0
	fill.anchor_bottom = 1.0
	fill.color         = Color(0.15, 0.85, 0.15)
	fill.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	bg.add_child(fill)
	if infinite:
		fill.anchor_right = 1.0   # always full green

func _wire_formation_buttons() -> void:
	for i in FORMATION_NAMES.size():
		var btn := _formation_grid.get_node_or_null("FormationButton%d" % i) as Button
		if btn == null:
			push_warning("[HUD] Missing FormationButton%d" % i)
			continue
		var lbl := btn.get_node_or_null("Name") as Label
		if lbl:
			lbl.hide()
		btn.icon = _make_formation_icon(i)
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.expand_icon = true
		btn.tooltip_text = "Formation %s" % FORMATION_NAMES[i]
		var idx := i
		btn.pressed.connect(func() -> void: _on_formation_pressed(idx))

	# Revive button — repurposes the 6th cell of the formation grid.
	_revive_button = _formation_grid.get_node_or_null("FormationButtonReserved") as Button
	if _revive_button:
		_revive_button.disabled = false
		_revive_button.toggle_mode = false
		_revive_button.text = ""
		_revive_button.tooltip_text = "Revive last fallen soldier"
		if ResourceLoader.exists("res://resources/UI/icons/revive_heart.png"):
			_revive_button.icon = load("res://resources/UI/icons/revive_heart.png")
			_revive_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_revive_button.expand_icon = true
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
	_ammo_max = [0, 0, 0, 0]  # let the next update_ammo call set the full-pool baseline
	var texts := {
		1: "OBJECTIVE: (Optional) Solve the six trials",
		2: "OBJECTIVE: Eliminate all enemies",
		3: "OBJECTIVE: Hunt down the elite bruisers",
		4: "OBJECTIVE: Escape the catacombs",
		5: "OBJECTIVE: Destroy the fortified structures",
		6: "OBJECTIVE: Escort the NPC to extraction",
		7: "OBJECTIVE: Find the hidden portal in the blighted marsh",
		8: "OBJECTIVE: Shatter the Weeping Heart",
	}
	var text: String = texts.get(level, "")
	_objective_label.text = text
	# Escort label only on the Escort mission (now level 6).
	if level == 6:
		_escort_label.show()
	else:
		_escort_label.hide()
	# Tutorial, the maze, the marsh (terrain-focused), and the boss (own health
	# bar) hide the generic ENEMIES counter — only the combat-objective missions
	# (Eliminate / Elite Hunt / Structures / Escort = 2 / 3 / 5 / 6) show it.
	if _enemy_label:
		_enemy_label.visible = level == 2 or level == 3 or level == 5 or level == 6

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
	if _void_embrace_bar == null:
		_build_boss_overlay()
	if boss and boss.has_signal("void_embrace_started"):
		boss.void_embrace_started.connect(_on_void_embrace_started)
	if boss and boss.has_signal("void_embrace_cleared"):
		boss.void_embrace_cleared.connect(_on_void_embrace_cleared)

func _build_boss_overlay() -> void:
	# No on-screen boss-health bar or phase banner — the boss carries its own
	# health bar above its head (shown only once the fight starts). Only the Void
	# Embrace channel warning lives on the HUD.

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
		var card: Control = _reward_card_containers[i]
		var btn: Button  = _reward_card_buttons[i]
		var icon: TextureRect = _reward_card_icons[i]
		if i < ids.size():
			var id: String = ids[i]
			btn.text = "%s\n\n%s" % [FragmentEffects.get_display_name(id), FragmentEffects.get_description(id)]
			var img_path := "res://resources/fragments/%s.png" % id
			icon.texture = load(img_path) if ResourceLoader.exists(img_path) else null
			card.show()
		else:
			card.hide()
	_reward_card_ids = ids
	_reward_panel.show()

func _build_reward_picker() -> void:
	_reward_panel = PanelContainer.new()
	_reward_panel.set_anchors_preset(Control.PRESET_CENTER)
	_reward_panel.position = Vector2(-330, -150)
	_reward_panel.custom_minimum_size = Vector2(660, 270)
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
		# Card: icon at top, button with text below.
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 0)
		hb.add_child(card)
		_reward_card_containers.append(card)

		var icon_wrap := CenterContainer.new()
		icon_wrap.custom_minimum_size = Vector2(190, 60)
		card.add_child(icon_wrap)

		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(48, 48)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon_wrap.add_child(icon)
		_reward_card_icons.append(icon)

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(190, 140)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.clip_text = false
		var idx: int = i
		btn.pressed.connect(func() -> void: _on_reward_card_pressed(idx))
		card.add_child(btn)
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
	var ammo_vals := [0, _rifle_ammo, _grenade_ammo, _sacrifice_avail]
	for i in range(1, WEAPON_NAMES.size()):
		_ammo_max[i] = maxi(_ammo_max[i], ammo_vals[i])
	for i in WEAPON_NAMES.size():
		var btn := _weapon_grid.get_node_or_null("WeaponButton%d" % i) as Button
		if btn == null:
			continue
		var bg := btn.get_node_or_null("AmmoBarBg") as ColorRect
		if bg == null:
			continue
		var fill := bg.get_node_or_null("AmmoBarFill") as ColorRect
		if fill == null:
			continue
		if i == 0:
			continue  # infinite — stays full green from setup
		var mx := float(_ammo_max[i])
		var frac := 1.0 if mx <= 0.0 else clampf(float(ammo_vals[i]) / mx, 0.0, 1.0)
		fill.anchor_right = frac
		if frac > 0.5:
			fill.color = Color(0.15, 0.85, 0.15)
		elif frac > 0.25:
			fill.color = Color(0.95, 0.75, 0.0)
		else:
			fill.color = Color(0.9, 0.12, 0.12)

func _rebuild_group_buttons(num_groups: int, active: int, alive_groups: Array = []) -> void:
	for b in _group_buttons:
		b.queue_free()
	_group_buttons.clear()
	if num_groups <= 1:
		return
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	for i in num_groups:
		var btn := Button.new()
		btn.icon = _make_group_icon(i)
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.expand_icon    = true
		btn.custom_minimum_size = Vector2(60, 60) if _touch_ui else Vector2(30, 30)
		btn.toggle_mode    = true
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
	if GameManager.current_level == 6:
		# Escort mission — point at the trapped/unfreed NPC, then at the
		# extraction zone once they've linked up with the squad.
		if _escort_joined:
			target = _extraction_zone if is_instance_valid(_extraction_zone) else null
		else:
			target = _escort_npc if is_instance_valid(_escort_npc) else null
	elif GameManager.current_level == 4:
		# Catacombs maze — always point to the exit.
		target = _maze_exit if is_instance_valid(_maze_exit) else null
	elif GameManager.current_level == 8:
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
	# Button is created inside _build_options_popup(); only the overlay lives here.
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

func _build_options_popup() -> void:
	# ⚙ trigger button — bottom-right corner of the screen, inside the panel strip.
	_options_button = Button.new()
	_options_button.text = "⚙"
	_options_button.anchor_left   = 1.0
	_options_button.anchor_right  = 1.0
	_options_button.anchor_top    = 1.0
	_options_button.anchor_bottom = 1.0
	_options_button.offset_left   = -42.0
	_options_button.offset_top    = -44.0
	_options_button.offset_right  = -4.0
	_options_button.offset_bottom = -2.0
	_options_button.add_theme_font_size_override("font_size", 20)
	_options_button.pressed.connect(_toggle_options_popup)
	add_child(_options_button)

	# Popup panel — appears above the ⚙ button when toggled.
	# Right-aligned to the screen edge; grows LEFTWARD so it never overflows right.
	_options_popup = PanelContainer.new()
	_options_popup.anchor_left   = 1.0
	_options_popup.anchor_right  = 1.0
	_options_popup.anchor_top    = 1.0
	_options_popup.anchor_bottom = 1.0
	_options_popup.offset_left   = -320.0
	_options_popup.offset_right  = -2.0
	_options_popup.offset_top    = -92.0
	_options_popup.offset_bottom = -46.0
	_options_popup.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_options_popup.hide()
	add_child(_options_popup)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   6)
	margin.add_theme_constant_override("margin_right",  6)
	margin.add_theme_constant_override("margin_top",    4)
	margin.add_theme_constant_override("margin_bottom", 4)
	_options_popup.add_child(margin)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	margin.add_child(hb)

	# STATUS button
	_status_button = Button.new()
	_status_button.text = "STATUS"
	_status_button.pressed.connect(_toggle_status_modal)
	hb.add_child(_status_button)

	# PAUSE/RESUME button
	_pause_button = Button.new()
	_pause_button.text = "PAUSE"
	_pause_button.pressed.connect(_on_pause_pressed)
	hb.add_child(_pause_button)

	# GOD toggle — mirrors the hidden scene-side GodButton
	var god_btn := Button.new()
	god_btn.text     = "GOD"
	god_btn.toggle_mode    = true
	god_btn.button_pressed = GameManager.god_mode
	god_btn.toggled.connect(_on_god_toggled)
	# Keep _god_button pointing at this new button so _refresh_god_button_visual works.
	_god_button = god_btn
	_refresh_god_button_visual()
	hb.add_child(god_btn)

	# MENU button
	var menu_btn := Button.new()
	menu_btn.text = "MENU"
	menu_btn.pressed.connect(_on_menu_pressed)
	hb.add_child(menu_btn)

func _toggle_options_popup() -> void:
	_options_open = not _options_open
	if _options_popup:
		_options_popup.visible = _options_open

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
	# Button is created inside _build_options_popup(); only the overlay lives here.
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

# =============================================================================
# FORMATION ICON GENERATION
# Draws 6 pixel-art "magic orb" dots onto a 40×36 Image arranged to represent
# each formation pattern, then wraps it in an ImageTexture for btn.icon.
# =============================================================================
func _make_formation_icon(index: int) -> ImageTexture:
	var img := Image.create(40, 36, false, Image.FORMAT_RGBA8)
	img.fill(Color.TRANSPARENT)
	var positions: Array[Vector2i]
	match index:
		0:  # 2×3 — 2 cols, 3 rows
			positions = [Vector2i(12,6),Vector2i(28,6),
						 Vector2i(12,18),Vector2i(28,18),
						 Vector2i(12,30),Vector2i(28,30)]
		1:  # 3×2 — 3 cols, 2 rows (default)
			positions = [Vector2i(8,10),Vector2i(20,10),Vector2i(32,10),
						 Vector2i(8,26),Vector2i(20,26),Vector2i(32,26)]
		2:  # 1×6 — single column
			positions = [Vector2i(20,3),Vector2i(20,9),Vector2i(20,15),
						 Vector2i(20,21),Vector2i(20,27),Vector2i(20,33)]
		3:  # 6×1 — single row
			positions = [Vector2i(3,18),Vector2i(10,18),Vector2i(17,18),
						 Vector2i(24,18),Vector2i(31,18),Vector2i(37,18)]
		4:  # ★ — hexagonal ring
			positions = []
			for k in 6:
				var angle := k * PI / 3.0 - PI / 2.0
				positions.append(Vector2i(int(20.0 + 12.0 * cos(angle)),
										  int(18.0 + 12.0 * sin(angle))))
		_:
			positions = []
	for p in positions:
		_draw_magic_dot(img, p.x, p.y)
	return ImageTexture.create_from_image(img)

func _draw_magic_dot(img: Image, cx: int, cy: int) -> void:
	var outer := Color(0.9, 0.55, 0.1, 1.0)
	var inner := Color(1.0, 0.92, 0.45, 1.0)
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			if abs(dx) + abs(dy) <= 2:
				_px(img, cx + dx, cy + dy, outer)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if abs(dx) + abs(dy) <= 1:
				_px(img, cx + dx, cy + dy, inner)

func _px(img: Image, x: int, y: int, color: Color) -> void:
	if x >= 0 and x < img.get_width() and y >= 0 and y < img.get_height():
		img.set_pixel(x, y, color)

# GROUP ICON — a coloured shield/crest for each squad group.
# Uses the same GROUP_COLORS as the per-soldier floating labels so the player
# can instantly map HUD icon → soldiers on the field.
func _make_group_icon(group_index: int) -> ImageTexture:
	var img := Image.create(24, 24, false, Image.FORMAT_RGBA8)
	img.fill(Color.TRANSPARENT)
	var base: Color = GROUP_COLORS[group_index % GROUP_COLORS.size()]
	var dark := Color(base.r * 0.40, base.g * 0.40, base.b * 0.40, 1.0)
	var mid  := Color(base.r * 0.75, base.g * 0.75, base.b * 0.75, 1.0)
	var bright := Color(
		minf(base.r * 1.2 + 0.15, 1.0),
		minf(base.g * 1.2 + 0.15, 1.0),
		minf(base.b * 1.2 + 0.15, 1.0), 1.0)
	# Shield outline: wide rectangle that tapers to a point at the bottom.
	# Rows 0-15: full width (x 3..20). Rows 16-20: narrowing. Row 21: single pixel.
	for y in 22:
		var half_w: int
		if y <= 15:
			half_w = 9
		else:
			half_w = 9 - (y - 15) * 2
		if half_w < 0:
			half_w = 0
		for x in range(12 - half_w, 12 + half_w + 1):
			var on_edge := (x == 12 - half_w or x == 12 + half_w or y == 0 or (y == 21 and half_w == 0))
			_px(img, x, y, dark if on_edge else base)
	# Highlight stripe across the upper-left of the shield
	for y in range(2, 6):
		for x in range(5, 10):
			_px(img, x, y, bright)
	# Small inner gem — a 3×3 diamond in mid tone centered at (12, 10)
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			if abs(dx) + abs(dy) <= 2:
				_px(img, 12 + dx, 10 + dy, mid)
	_px(img, 12, 10, bright)  # gem centre sparkle
	return ImageTexture.create_from_image(img)

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

# =============================================================================
# HUD STYLING
# =============================================================================
func _style_hud() -> void:
	# Bottom panel — fantasy stone texture with gold corner ornaments.
	var bottom := get_node_or_null("BottomPanel") as PanelContainer
	if bottom:
		const PANEL_TEX := "res://resources/UI/hud_panel_bg.png"
		if ResourceLoader.exists(PANEL_TEX):
			var style_tex := StyleBoxTexture.new()
			style_tex.texture = load(PANEL_TEX)
			# Leave the corner ornaments (~18px) fixed; stretch the centre.
			style_tex.texture_margin_left   = 18
			style_tex.texture_margin_right  = 18
			style_tex.texture_margin_top    = 8
			style_tex.texture_margin_bottom = 8
			bottom.add_theme_stylebox_override("panel", style_tex)
		else:
			# Fallback if texture hasn't been imported yet.
			var style := StyleBoxFlat.new()
			style.bg_color = Color(0.07, 0.05, 0.10, 0.94)
			style.border_width_top = 2
			style.border_color = Color(0.65, 0.48, 0.18, 0.9)
			bottom.add_theme_stylebox_override("panel", style)

	# Top-left labels — warm gold text with a black outline for readability
	# over any tile background.
	for lbl in [_objective_label, _enemy_label, _escort_label]:
		if lbl == null:
			continue
		lbl.add_theme_color_override("font_color", Color(1.0, 0.93, 0.65))
		lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
		lbl.add_theme_constant_override("outline_size", 3)

	# Under-attack toast — keep red but add black outline so it pops over light tiles.
	if _under_attack_label:
		_under_attack_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
		_under_attack_label.add_theme_constant_override("outline_size", 4)
		_under_attack_label.add_theme_font_size_override("font_size", 18)

	# Group cycle button — match the gold border theme.
	if _group_cycle_button:
		_group_cycle_button.add_theme_color_override("font_color", Color(1.0, 0.88, 0.45))
