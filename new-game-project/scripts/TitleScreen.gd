extends Control

const Balance = preload("res://scripts/BalanceConfig.gd")

const SOLDIER_SCENES := [
	"res://scenes/soldier_1.tscn",
	"res://scenes/soldier_2.tscn",
	"res://scenes/soldier_3.tscn",
	"res://scenes/soldier_4.tscn",
	"res://scenes/soldier_5.tscn",
	"res://scenes/soldier_6.tscn",
]

const HP_MAX:  float = 8.0
const DMG_MAX: float = 4.0
const SPD_MAX: float = 1200.0
const RNG_MAX: float = 1500.0

@onready var _bios_grid: GridContainer = $MarginContainer/VBoxContainer/HBoxContainer/BiosPanel/BiosMargin/BiosVBox/BiosGrid
@onready var _help_popup: ColorRect = $HelpPopup

var _run_status_label: Label = null
var _run_state_overlay: ColorRect = null
var _run_state_visible: bool = false

func _ready() -> void:
	GameManager.score = 0
	_build_run_state_modal()
	RunState.run_reset.connect(_on_run_reset)
	RunState.kid_lost.connect(func(_slot: int) -> void: _refresh_run_view())
	RunState.parent_freed.connect(func(_slot: int) -> void: _refresh_run_view())
	_refresh_run_view()

func _update_bio_cards() -> void:
	for i in SOLDIER_SCENES.size():
		var card := _bios_grid.get_child(i) as Control
		if card == null:
			continue
		# Dim cards for kids who died earlier in the run so the title screen
		# reads the current squad at a glance.
		card.modulate = Color(1, 1, 1, 1) if RunState.kids_alive[i] \
				else Color(0.4, 0.4, 0.4, 0.55)
		var avg_dmg := (float(Balance.SOLDIER_PISTOL_DAMAGE_PER_SLOT[i]) \
				+ float(Balance.SOLDIER_RIFLE_DAMAGE_PER_SLOT[i])) * 0.5
		var avg_spd := (Balance.SOLDIER_PISTOL_SPEED_PER_SLOT[i] \
				+ Balance.SOLDIER_RIFLE_SPEED_PER_SLOT[i]) * 0.5
		var avg_rng := (Balance.SOLDIER_PISTOL_DISTANCE_PER_SLOT[i] \
				+ Balance.SOLDIER_RIFLE_DISTANCE_PER_SLOT[i]) * 0.5

		var name_lbl := card.get_node_or_null("Margin/VBox/Header/Name") as Label
		if name_lbl:
			name_lbl.add_theme_color_override("font_color",
					Balance.SOLDIER_BULLET_COLOR_PER_SLOT[i])

		_set_bar(card, "Margin/VBox/HPRow/HPBar",
				float(Balance.SOLDIER_MAX_HEALTH_PER_SLOT[i]), HP_MAX)
		_set_bar(card, "Margin/VBox/DMGRow/DMGBar", avg_dmg, DMG_MAX)
		_set_bar(card, "Margin/VBox/SPDRow/SPDBar", avg_spd, SPD_MAX)
		_set_bar(card, "Margin/VBox/RNGRow/RNGBar", avg_rng, RNG_MAX)

func _set_bar(card: Control, rel_path: String, value: float, max_val: float) -> void:
	var bar := card.get_node_or_null(rel_path) as ProgressBar
	if bar:
		bar.max_value = max_val
		bar.value     = clamp(value, 0.0, max_val)

# ---------------------------------------------------------------------------
# Each mission button delegates to a single helper so they all behave
# identically apart from which level number they kick off.
func _start_mission(level: int) -> void:
	GameManager.current_level = level
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _on_mission_1_pressed() -> void: _start_mission(1)   # Tutorial — The Trials
func _on_mission_2_pressed() -> void: _start_mission(2)   # Eliminate Enemies
func _on_mission_3_pressed() -> void: _start_mission(3)   # Escape (Maze 1)
func _on_mission_4_pressed() -> void: _start_mission(4)   # Destroy Structures
func _on_mission_5_pressed() -> void: _start_mission(5)   # Escort VIP
func _on_mission_6_pressed() -> void: _start_mission(6)   # The Ruined Catacombs (Maze 2)
func _on_mission_7_pressed() -> void: _start_mission(7)   # The Weeping Heart (boss)

func _on_help_pressed() -> void:
	_help_popup.visible = true

func _on_help_close_pressed() -> void:
	_help_popup.visible = false

func _on_exit_pressed() -> void:
	get_tree().quit()

# =============================================================================
# Run-state modal — hidden by default; surfaced by the RUN STATE button in
# the top-right (built here to match the Help / Exit row). Click outside the
# card or hit Close to dismiss. Built in code so the .tscn stays untouched.
# =============================================================================
func _build_run_state_modal() -> void:
	# Toggle button — slotted left of the existing Help / Exit pair (HelpButton
	# sits at offset_left = -230, offset_right = -140 in the scene).
	var toggle_btn := Button.new()
	toggle_btn.text = "Run State"
	toggle_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	toggle_btn.offset_left   = -370.0
	toggle_btn.offset_top    =   30.0
	toggle_btn.offset_right  = -240.0
	toggle_btn.offset_bottom =   74.0
	toggle_btn.add_theme_font_size_override("font_size", 22)
	toggle_btn.pressed.connect(_toggle_run_state_modal)
	add_child(toggle_btn)

	# Dim overlay — full screen, click outside the card dismisses.
	_run_state_overlay = ColorRect.new()
	_run_state_overlay.color = Color(0, 0, 0, 0.7)
	_run_state_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_run_state_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_run_state_overlay.gui_input.connect(_on_run_state_overlay_input)
	_run_state_overlay.hide()
	add_child(_run_state_overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_run_state_overlay.add_child(center)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(420, 0)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(card)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	card.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "Run State"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.116, 0.571, 0.855))
	vb.add_child(title)

	_run_status_label = Label.new()
	_run_status_label.add_theme_font_size_override("font_size", 14)
	vb.add_child(_run_status_label)

	var reset_btn := Button.new()
	reset_btn.text = "RESET RUN  (F12)"
	reset_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	reset_btn.pressed.connect(_on_reset_run_pressed)
	vb.add_child(reset_btn)

	var close_btn := Button.new()
	close_btn.text = "  Close  "
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close_btn.add_theme_font_size_override("font_size", 18)
	close_btn.pressed.connect(_toggle_run_state_modal)
	vb.add_child(close_btn)

func _toggle_run_state_modal() -> void:
	_run_state_visible = not _run_state_visible
	if _run_state_overlay:
		_run_state_overlay.visible = _run_state_visible

func _on_run_state_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_toggle_run_state_modal()

func _refresh_run_view() -> void:
	_refresh_run_status_label()
	_update_bio_cards()

func _refresh_run_status_label() -> void:
	if _run_status_label == null:
		return
	var lines := PackedStringArray()
	lines.append("RUN STATE")
	lines.append("Kids alive:    %d / %d" % [RunState.kids_alive_count(), RunState.SQUAD_SIZE])
	lines.append("Parents freed: %d / %d" % [RunState.parents_freed_count(), RunState.SQUAD_SIZE])
	lines.append("Missions done: %s" % str(RunState.missions_completed))
	lines.append("Fragments:     %d" % RunState.fragments.size())
	for i in RunState.SQUAD_SIZE:
		var status: String = "alive" if RunState.kids_alive[i] else "DEAD "
		var hp_raw: int    = RunState.get_carry_hp(i)
		var hp_str: String = "max" if hp_raw < 0 else str(hp_raw)
		var parent: String = "✓" if RunState.parents_freed[i] else "·"
		lines.append("  Kid %d  %s  HP %-3s  parent %s" % [i + 1, status, hp_str, parent])
	_run_status_label.text = "\n".join(lines)

func _on_reset_run_pressed() -> void:
	RunState.start_new_run()

func _on_run_reset() -> void:
	_refresh_run_view()
