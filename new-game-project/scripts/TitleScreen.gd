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

func _ready() -> void:
	GameManager.score = 0
	_build_debug_panel()
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
		var stats := _read_soldier_stats(SOLDIER_SCENES[i])
		var avg_dmg := (float(stats["pistol_damage"]) + float(stats["rifle_damage"])) * 0.5
		var avg_spd := (float(stats["pistol_speed"])    + float(stats["rifle_speed"]))    * 0.5
		var avg_rng := (float(stats["pistol_distance"]) + float(stats["rifle_distance"])) * 0.5

		var name_lbl := card.get_node_or_null("Margin/VBox/Header/Name") as Label
		if name_lbl:
			name_lbl.add_theme_color_override("font_color", stats["bullet_color"])

		_set_bar(card, "Margin/VBox/HPRow/HPBar",  float(stats["max_health"]), HP_MAX)
		_set_bar(card, "Margin/VBox/DMGRow/DMGBar", avg_dmg, DMG_MAX)
		_set_bar(card, "Margin/VBox/SPDRow/SPDBar", avg_spd, SPD_MAX)
		_set_bar(card, "Margin/VBox/RNGRow/RNGBar", avg_rng, RNG_MAX)

func _set_bar(card: Control, rel_path: String, value: float, max_val: float) -> void:
	var bar := card.get_node_or_null(rel_path) as ProgressBar
	if bar:
		bar.max_value = max_val
		bar.value     = clamp(value, 0.0, max_val)

# Instantiate off-tree to read @export values without triggering _ready.
#
# Soldier.gd's _ready falls back to Balance defaults whenever an @export stat
# is left at its zero default (the maths in Soldier.gd is `if X <= 0: X = BalanceX`).
# We mirror that fallback here so the bio cards reflect what each kid actually
# plays as in-game — without it, soldier_2 / soldier_5 (which only override the
# speed/range/HP exports, not damage) showed empty DMG bars.
func _read_soldier_stats(path: String) -> Dictionary:
	var defaults := {
		"max_health":      Balance.SOLDIER_MAX_HEALTH,
		"pistol_damage":   Balance.SOLDIER_PISTOL_DAMAGE,
		"rifle_damage":    Balance.SOLDIER_RIFLE_DAMAGE,
		"pistol_speed":    Balance.SOLDIER_PISTOL_SPEED,
		"rifle_speed":     Balance.SOLDIER_RIFLE_SPEED,
		"pistol_distance": Balance.SOLDIER_PISTOL_DISTANCE,
		"rifle_distance":  Balance.SOLDIER_RIFLE_DISTANCE,
		"bullet_color":    Color.YELLOW,
	}
	var scene: PackedScene = load(path)
	if scene == null:
		return defaults
	var inst := scene.instantiate()
	for key in defaults.keys():
		if key in inst:
			defaults[key] = inst.get(key)
	inst.free()
	return defaults

# ---------------------------------------------------------------------------
# Each mission button delegates to a single helper so they all behave
# identically apart from which level number they kick off.
func _start_mission(level: int) -> void:
	GameManager.current_level = level
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _on_mission_1_pressed() -> void: _start_mission(1)   # Tutorial — The Trials
func _on_mission_2_pressed() -> void: _start_mission(2)   # Eliminate Enemies
func _on_mission_3_pressed() -> void: _start_mission(3)   # Destroy Structures
func _on_mission_4_pressed() -> void: _start_mission(4)   # Escort VIP
func _on_mission_5_pressed() -> void: _start_mission(5)   # Escape (maze 1)
func _on_mission_6_pressed() -> void: _start_mission(6)   # Ruined Catacombs (maze 2)
func _on_mission_7_pressed() -> void: _start_mission(7)   # The Weeping Heart (boss)

func _on_help_pressed() -> void:
	_help_popup.visible = true

func _on_help_close_pressed() -> void:
	_help_popup.visible = false

func _on_exit_pressed() -> void:
	get_tree().quit()

# =============================================================================
# Debug / run-status panel — pinned to the bottom-left of the title screen so
# it stays clear of the title text and the mission buttons. Slightly
# transparent so it doesn't fully hide the bio cards underneath. Built in
# code so the .tscn stays untouched while the design is still in flux.
# Remove (or gate behind a debug flag) before shipping.
# =============================================================================
func _build_debug_panel() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.position = Vector2(20, -270)
	panel.custom_minimum_size = Vector2(320, 250)
	panel.modulate.a = 0.92
	add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	_run_status_label = Label.new()
	_run_status_label.add_theme_font_size_override("font_size", 14)
	vb.add_child(_run_status_label)

	var reset_btn := Button.new()
	reset_btn.text = "RESET RUN  (F12)"
	reset_btn.pressed.connect(_on_reset_run_pressed)
	vb.add_child(reset_btn)

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
