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

# The four editable stat rows, in SquadConfig.Stat order (HP, DMG, SPD, RNG).
# Each entry is the row's node name under "Margin/VBox" inside a bio card.
const _STAT_ROW_NAMES := ["HPRow", "DMGRow", "SPDRow", "RNGRow"]

@onready var _bios_grid: GridContainer = $MarginContainer/VBoxContainer/HBoxContainer/BiosPanel/BiosMargin/BiosVBox/BiosGrid
@onready var _bios_vbox: VBoxContainer = $MarginContainer/VBoxContainer/HBoxContainer/BiosPanel/BiosMargin/BiosVBox
@onready var _help_popup: ColorRect = $HelpPopup

var _run_status_label: Label = null
var _run_state_overlay: ColorRect = null
var _run_state_visible: bool = false
var _map_mode_btn: Button = null

# Squad-editor widgets, built in code so the .tscn stays untouched.
var _points_label: Label = null
var _profile_load_btns: Array[Button] = []

func _ready() -> void:
	GameManager.score = 0
	_build_run_state_modal()
	_build_utility_bar()
	_build_squad_editor()
	RunState.run_reset.connect(_on_run_reset)
	RunState.kid_lost.connect(func(_slot: int) -> void: _refresh_run_view())
	RunState.parent_freed.connect(func(_slot: int) -> void: _refresh_run_view())
	SquadConfig.config_changed.connect(_on_squad_config_changed)
	_refresh_run_view()
	_refresh_editor()

# Repaints every bio card from the player's editable SquadConfig levels. The
# bars now show stat LEVELS (1..LEVEL_MAX) rather than raw numbers, because the
# cards are the squad editor — the −/+ buttons built in _add_stat_buttons drive
# the same SquadConfig the bars read back.
func _update_bio_cards() -> void:
	for i in SOLDIER_SCENES.size():
		var card := _bios_grid.get_child(i) as Control
		if card == null:
			continue
		# Dim cards for kids who died earlier in the run so the title screen
		# reads the current squad at a glance.
		card.modulate = Color(1, 1, 1, 1) if RunState.kids_alive[i] \
				else Color(0.4, 0.4, 0.4, 0.55)

		var name_lbl := card.get_node_or_null("Margin/VBox/Header/Name") as Label
		if name_lbl:
			name_lbl.add_theme_color_override("font_color",
					Balance.SOLDIER_BULLET_COLOR_PER_SLOT[i])

		for stat in _STAT_ROW_NAMES.size():
			_set_stat_row(card, i, stat)

# Updates one stat row's label text ("HP 5") and its progress bar (level / max).
func _set_stat_row(card: Control, slot: int, stat: int) -> void:
	var row := card.get_node_or_null("Margin/VBox/%s" % _STAT_ROW_NAMES[stat]) as Control
	if row == null:
		return
	var level := SquadConfig.level_of(slot, stat)
	var lbl := row.get_child(0) as Label
	if lbl:
		lbl.text = "%s %d" % [SquadConfig.STAT_NAMES[stat], level]
	for child in row.get_children():
		if child is ProgressBar:
			var bar := child as ProgressBar
			bar.max_value = SquadConfig.LEVEL_MAX
			bar.value     = level
			break

# =============================================================================
# Squad editor — turns the bio cards into a point-buy loadout screen. Built in
# code (the .tscn cards already carry the HP/DMG/SPD/RNG rows; we inject −/+
# buttons and append a pool/preset/profile control block under the grid).
# =============================================================================
func _build_squad_editor() -> void:
	_add_stat_buttons()
	_build_editor_controls()

# Inject a −/+ button on either side of every stat row, in every card. Each
# button just calls SquadConfig.adjust, which enforces the pool and the
# can't-go-to-zero floor; config_changed then repaints the whole panel.
func _add_stat_buttons() -> void:
	for slot in SOLDIER_SCENES.size():
		var card := _bios_grid.get_child(slot) as Control
		if card == null:
			continue
		for stat in _STAT_ROW_NAMES.size():
			var row := card.get_node_or_null("Margin/VBox/%s" % _STAT_ROW_NAMES[stat]) as Control
			if row == null:
				continue
			# Give the stat label room for the "DMG 8" readout.
			var lbl := row.get_child(0) as Label
			if lbl:
				lbl.custom_minimum_size.x = 52.0

			var minus := _make_step_button("−", slot, stat, -1)
			row.add_child(minus)
			row.move_child(minus, 1)   # sit between the label and the bar

			var plus := _make_step_button("+", slot, stat, 1)
			row.add_child(plus)        # tail of the row, after the bar

func _make_step_button(label: String, slot: int, stat: int, delta: int) -> Button:
	var btn := Button.new()
	btn.text = label
	# Compact font keeps each stat row tight so all six cards + the editor
	# controls fit the window without overflowing.
	btn.custom_minimum_size = Vector2(26, 0)
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 14)
	btn.pressed.connect(func() -> void: SquadConfig.adjust(slot, stat, delta))
	return btn

# The control block is kept to three single lines (pool readout, presets,
# profiles) so it fits under the 2-row card grid at the default window height —
# stacking the profiles vertically pushed slots 2 & 3 off the bottom.
func _build_editor_controls() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_bios_vbox.add_child(box)

	_points_label = Label.new()
	_points_label.add_theme_font_size_override("font_size", 16)
	box.add_child(_points_label)

	# Preset row — Balanced / Ranged / Damage load tuned spreads; Random scatters
	# the pool. All four spend the entire pool, so the squad stays deployable.
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 8)
	box.add_child(presets)
	presets.add_child(_make_action_button("Balanced", SquadConfig.apply_preset_balanced))
	presets.add_child(_make_action_button("Ranged",   SquadConfig.apply_preset_ranged))
	presets.add_child(_make_action_button("Damage",   SquadConfig.apply_preset_damage))
	presets.add_child(_make_action_button("Random",   SquadConfig.apply_random))

	# Profiles on a single row: per slot a Load button (shows the saved name, or
	# greys out when empty) paired with a Save. bind(i) avoids any ambiguity over
	# capturing the loop variable.
	var prof_row := HBoxContainer.new()
	prof_row.add_theme_constant_override("separation", 8)
	box.add_child(prof_row)

	var prof_lbl := Label.new()
	prof_lbl.text = "Profiles:"
	prof_lbl.add_theme_font_size_override("font_size", 16)
	prof_row.add_child(prof_lbl)

	_profile_load_btns.clear()
	for i in SquadConfig.PROFILE_COUNT:
		var load_btn := _make_action_button("", _on_profile_load.bind(i))
		load_btn.custom_minimum_size.x = 120.0
		prof_row.add_child(load_btn)
		_profile_load_btns.append(load_btn)
		prof_row.add_child(_make_action_button("Save %d" % (i + 1), _on_profile_save.bind(i)))

func _make_action_button(label: String, handler: Callable) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 16)
	btn.pressed.connect(handler)
	return btn

func _on_profile_load(idx: int) -> void:
	SquadConfig.load_profile(idx)

func _on_profile_save(idx: int) -> void:
	SquadConfig.save_profile(idx)

func _on_squad_config_changed() -> void:
	_update_bio_cards()
	_refresh_editor()

# Repaints the pool readout (green only when fully spent) and the per-slot Load
# buttons (saved name + active marker, disabled when the slot is empty).
func _refresh_editor() -> void:
	if _points_label:
		var remaining := SquadConfig.points_remaining()
		_points_label.text = "Squad Points:  %d / %d   (Remaining: %d)" \
				% [SquadConfig.points_used(), SquadConfig.POOL_TOTAL, remaining]
		_points_label.add_theme_color_override("font_color",
				Color(0.5, 0.9, 0.55) if remaining == 0 else Color(1.0, 0.6, 0.35))
	for i in _profile_load_btns.size():
		var exists := SquadConfig.profile_exists(i)
		var marker := "▶ " if SquadConfig.active_profile == i else ""
		var name_str := SquadConfig.profile_name(i) if exists else "P%d (empty)" % (i + 1)
		_profile_load_btns[i].text = "%s%s" % [marker, name_str]
		_profile_load_btns[i].disabled = not exists

# ---------------------------------------------------------------------------
# Each mission button delegates to a single helper so they all behave
# identically apart from which level number they kick off.
func _start_mission(level: int) -> void:
	# Safeguard: every squad point must be spent before deploying, so the player
	# can't accidentally launch an underpowered squad with points left over.
	if not SquadConfig.is_fully_allocated():
		_warn_unspent_points()
		return
	GameManager.current_level = level
	# Cover the screen with the splash before the (blocking) main-scene load, the
	# same way between-level reloads do (Main.advance_level). Main._ready hides it
	# again once the level is built. The extra processed frame lets the loading
	# screen actually paint before change_scene_to_file stalls on the load.
	var ls := get_node_or_null("/root/LoadingScreen")
	if ls and ls.has_method("show_loading"):
		ls.show_loading()
	# Wait for the splash to actually be DRAWN before kicking off the blocking
	# scene load. A single process_frame await resumes within the same frame
	# (before any draw), so change_scene would freeze the UI on the menu with the
	# splash never painted. frame_post_draw fires after the GPU draw, guaranteeing
	# the loading screen is the last thing on-screen during the load stall.
	await RenderingServer.frame_post_draw
	get_tree().change_scene_to_file("res://scenes/main.tscn")

# Surfaces the "spend everything first" rule on the points readout. Cleared on
# the next edit/preset (config_changed → _refresh_editor).
func _warn_unspent_points() -> void:
	if _points_label:
		_points_label.text = "⚠ Spend all %d remaining squad points before deploying!" \
				% SquadConfig.points_remaining()
		_points_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))

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
# Run-state modal — hidden by default; surfaced by the RUN STATE button in the
# Missions card's bottom utility bar (see _build_utility_bar). Click outside the
# card or hit Close to dismiss. Built in code so the .tscn stays untouched.
# =============================================================================
func _build_run_state_modal() -> void:
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

# =============================================================================
# Utility bar — Map / Run State / Help / Exit, parked at the BOTTOM of the
# Missions card (a vertical spacer pushes them down into the empty space below
# the mission list). Help and Exit live in the .tscn; they're reparented here so
# their styling and signal wiring carry over. Map and Run State are code-built.
#
# Map-mode toggle switches the source for missions 2 / 4 / 5 between MapGenerator
# (random each load) and the matching scenes/handcrafted/mission_X.tscn. The
# choice lives on GameManager, so it survives scene reloads but resets on quit.
# =============================================================================
func _build_utility_bar() -> void:
	var missions_vbox := $MarginContainer/VBoxContainer/HBoxContainer/MissionsPanel/MissionsMargin/MissionsVBox

	# Spacer eats the slack so the button row sits flush at the bottom.
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	missions_vbox.add_child(spacer)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	missions_vbox.add_child(row)

	_map_mode_btn = Button.new()
	_map_mode_btn.add_theme_font_size_override("font_size", 18)
	_map_mode_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_mode_btn.pressed.connect(_on_map_mode_pressed)
	row.add_child(_map_mode_btn)
	_refresh_map_mode_label()

	var run_state_btn := Button.new()
	run_state_btn.text = "Run State"
	run_state_btn.add_theme_font_size_override("font_size", 18)
	run_state_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	run_state_btn.pressed.connect(_toggle_run_state_modal)
	row.add_child(run_state_btn)

	# Reparent the .tscn Help / Exit buttons into the row. reparent() keeps their
	# styling and the pressed connections declared in the scene.
	var help_btn := $HelpButton as Button
	var exit_btn := $ExitButton as Button
	help_btn.reparent(row)
	exit_btn.reparent(row)
	for b in [help_btn, exit_btn]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL

func _refresh_map_mode_label() -> void:
	if _map_mode_btn == null:
		return
	_map_mode_btn.text = "Map: Custom" if GameManager.use_handcrafted_maps else "Map: Auto"

func _on_map_mode_pressed() -> void:
	GameManager.use_handcrafted_maps = not GameManager.use_handcrafted_maps
	_refresh_map_mode_label()
