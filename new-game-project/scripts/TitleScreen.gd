extends Control

# Each entry corresponds to a slot in the squad. Order must match Main.soldier_scenes.
const SOLDIER_SCENES := [
	"res://scenes/soldier_1.tscn",
	"res://scenes/soldier_2.tscn",
	"res://scenes/soldier_3.tscn",
	"res://scenes/soldier_4.tscn",
	"res://scenes/soldier_5.tscn",
	"res://scenes/soldier_6.tscn",
]

const SOLDIER_SHEET := preload("res://resources/tdstilepack/Spritesheet/luatilesheet.png")

# First frame of the "idle" animation in soldier.tscn — placeholder until each
# soldier gets its own distinct sprite.
const IDLE_REGION := Rect2(0, 778, 153, 153)

# Stat bar normalisation maxima. Tuned to give the strongest soldier in each
# stat a near-full bar.
const HP_MAX:  float = 8.0
const DMG_MAX: float = 4.0
const SPD_MAX: float = 1200.0
const RNG_MAX: float = 1500.0

func _ready() -> void:
	GameManager.score = 0
	_populate_bios()

# ---------------------------------------------------------------------------
# Bio cards
# ---------------------------------------------------------------------------
func _populate_bios() -> void:
	var grid := get_node_or_null("MarginContainer/VBoxContainer/HBoxContainer/BiosPanel/BiosMargin/BiosVBox/BiosGrid")
	if grid == null:
		push_warning("[TitleScreen] BiosGrid not found")
		return
	for child in grid.get_children():
		child.queue_free()

	for i in SOLDIER_SCENES.size():
		var stats := _read_soldier_stats(SOLDIER_SCENES[i])
		grid.add_child(_build_bio_card(i + 1, stats))

# Instantiate the soldier scene WITHOUT adding it to the tree (so _ready never
# fires) just to read its exported stats, then free it.
func _read_soldier_stats(path: String) -> Dictionary:
	var scene: PackedScene = load(path)
	var stats := {
		"max_health":      3,
		"pistol_damage":   1, "rifle_damage":   1,
		"pistol_speed":    600.0, "rifle_speed":   700.0,
		"pistol_distance": 1500.0, "rifle_distance": 1200.0,
		"bullet_color":    Color.YELLOW,
	}
	if scene == null:
		return stats
	var inst := scene.instantiate()
	for key in stats.keys():
		if key in inst:
			stats[key] = inst.get(key)
	inst.free()
	return stats

func _build_bio_card(index: int, stats: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(220, 180)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	card.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	# Header: idle sprite + soldier name (tinted with their bullet colour).
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)

	var pic := TextureRect.new()
	pic.custom_minimum_size = Vector2(56, 56)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var atlas := AtlasTexture.new()
	atlas.atlas = SOLDIER_SHEET
	atlas.region = IDLE_REGION
	pic.texture = atlas
	header.add_child(pic)

	var name_label := Label.new()
	name_label.text = "Soldier %d" % index
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", stats["bullet_color"])
	header.add_child(name_label)

	# 4 stat bars: HP, DMG, SPD, RNG. DMG/SPD/RNG use the average of pistol+rifle.
	var avg_dmg: float = (float(stats["pistol_damage"]) + float(stats["rifle_damage"])) * 0.5
	var avg_spd: float = (stats["pistol_speed"]    + stats["rifle_speed"])    * 0.5
	var avg_rng: float = (stats["pistol_distance"] + stats["rifle_distance"]) * 0.5

	vbox.add_child(_build_stat_row("HP",  float(stats["max_health"]), HP_MAX))
	vbox.add_child(_build_stat_row("DMG", avg_dmg, DMG_MAX))
	vbox.add_child(_build_stat_row("SPD", avg_spd, SPD_MAX))
	vbox.add_child(_build_stat_row("RNG", avg_rng, RNG_MAX))

	return card

func _build_stat_row(label_text: String, value: float, max_value: float) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(38, 0)
	row.add_child(lbl)

	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = max_value
	bar.value     = clamp(value, 0.0, max_value)
	bar.show_percentage = false
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.custom_minimum_size = Vector2(0, 16)
	row.add_child(bar)

	return row

# ---------------------------------------------------------------------------
# Mission buttons (wired via scene-level signal connections)
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
	get_tree().change_scene_to_file("res://scenes/platformer.tscn")
