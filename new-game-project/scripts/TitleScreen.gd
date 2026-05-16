extends Control

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

func _ready() -> void:
	GameManager.score = 0
	_update_bio_cards()

func _update_bio_cards() -> void:
	for i in SOLDIER_SCENES.size():
		var card := _bios_grid.get_child(i) as Control
		if card == null:
			continue
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
func _read_soldier_stats(path: String) -> Dictionary:
	var defaults := {
		"max_health": 3,
		"pistol_damage": 1, "rifle_damage": 1,
		"pistol_speed": 600.0, "rifle_speed": 700.0,
		"pistol_distance": 1500.0, "rifle_distance": 1200.0,
		"bullet_color": Color.YELLOW,
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
func _on_mission_1_pressed() -> void:
	GameManager.current_level = 1
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _on_mission_2_pressed() -> void:
	GameManager.current_level = 2
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _on_mission_3_pressed() -> void:
	GameManager.current_level = 3
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _on_mission_4_pressed() -> void:
	GameManager.current_level = 4
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _on_mission_5_pressed() -> void:
	GameManager.current_level = 5
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _on_help_pressed() -> void:
	_help_popup.visible = true

func _on_help_close_pressed() -> void:
	_help_popup.visible = false

func _on_exit_pressed() -> void:
	get_tree().quit()
