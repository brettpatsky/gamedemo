extends CanvasLayer

# Original mission UI (from main.tscn structure)
@onready var score_label:   Label  = $ScoreLabel
@onready var soldier_label: Label  = $SoldierCountLabel
@onready var mission_label: Label  = $MissionLabel
@onready var retry_button:  Button = $RetryButton

# New bottom HUD (from hud.tscn structure)
@onready var weapon_button:        Button = $BottomPanel/MarginContainer/HBoxContainer/WeaponButton
@onready var weapon_icon:          TextureRect = $BottomPanel/MarginContainer/HBoxContainer/WeaponButton/VBoxContainer/TextureRect
@onready var weapon_label:         Label  = $BottomPanel/MarginContainer/HBoxContainer/WeaponButton/VBoxContainer/Label

@onready var formation_button:     Button = $BottomPanel/MarginContainer/HBoxContainer/FormationSection
@onready var formation_icon:       TextureRect = $BottomPanel/MarginContainer/HBoxContainer/FormationSection/VBoxContainer/TextureRect
@onready var formation_label:      Label  = $BottomPanel/MarginContainer/HBoxContainer/FormationSection/VBoxContainer/Label

@onready var group_button:         Button = $BottomPanel/MarginContainer/HBoxContainer/GroupSection
@onready var group_icon:           TextureRect = $BottomPanel/MarginContainer/HBoxContainer/GroupSection/VBoxContainer/TextureRect
@onready var group_label:          Label  = $BottomPanel/MarginContainer/HBoxContainer/GroupSection/VBoxContainer/Label

@onready var soldiers_label:       Label  = $BottomPanel/MarginContainer/HBoxContainer/StatsSection/Soldiers
@onready var score_label_bottom:   Label  = $BottomPanel/MarginContainer/HBoxContainer/StatsSection/Score

var _objective_label: Label
var _escort_label: Label
var _next_level_button: Button
var _menu_button: Button
var enemy_label: Label
var _arrow_node: Control
var _group_buttons: Array[Button] = []

# Weapon icons — update these paths if your icons are stored elsewhere
const WEAPON_ICONS := {
	"Pistol": "res://resources/tdstilepack/PNG/weapon_pistol.png",
	"Auto": "res://resources/tdstilepack/PNG/weapon_machine.png",
	"Grenade": "res://resources/tdstilepack/PNG/weapon_grenade.png",
}

func _ready() -> void:
	add_to_group("hud")
	
	enemy_label = Label.new()
	enemy_label.name = "EnemyLabel"
	add_child(enemy_label)
	enemy_label.position = Vector2(10, 70)
	GameManager.enemies_changed.connect(update_enemy_count)
	update_enemy_count(GameManager.enemies_alive)

	_arrow_node = Control.new()
	_arrow_node.name = "ArrowOverlay"
	_arrow_node.set_anchors_preset(Control.PRESET_FULL_RECT)
	_arrow_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_arrow_node)
	_arrow_node.draw.connect(_draw_enemy_arrow)

	# Wire up bottom HUD button clicks to cycle commands (only if nodes exist)
	if weapon_button:
		weapon_button.pressed.connect(_on_weapon_button_pressed)
	else:
		push_warning("[HUD] WeaponButton not found")

	if formation_button:
		formation_button.pressed.connect(_on_formation_button_pressed)
	else:
		push_warning("[HUD] FormationSection not found")

	if group_button:
		group_button.pressed.connect(_on_group_button_pressed)
	else:
		push_warning("[HUD] GroupSection not found")

	# Mission-end UI (center screen)
	var center := get_viewport().get_visible_rect().size / 2.0
	mission_label.position = center + Vector2(-120.0, -30.0)
	retry_button.position  = center + Vector2(-60.0,  20.0)

	_next_level_button                      = Button.new()
	_next_level_button.text                = "NEXT LEVEL"
	_next_level_button.custom_minimum_size = Vector2(120.0, 40.0)
	_next_level_button.position            = center + Vector2(-60.0, 60.0)
	_next_level_button.hide()
	add_child(_next_level_button)
	_next_level_button.pressed.connect(_on_next_level_pressed)

	# Top-right menu button
	var vp := get_viewport().get_visible_rect().size
	_menu_button          = Button.new()
	_menu_button.text     = "MAIN MENU"
	_menu_button.position = Vector2(vp.x - 120, 10)
	add_child(_menu_button)
	_menu_button.pressed.connect(_on_menu_pressed)

	# Objective labels (top-left, above bottom HUD)
	_objective_label          = Label.new()
	_objective_label.position = Vector2(10, 10)
	add_child(_objective_label)

	_escort_label          = Label.new()
	_escort_label.position = Vector2(10, 40)
	_escort_label.hide()
	add_child(_escort_label)

	retry_button.text                = "Retry Level"
	retry_button.custom_minimum_size = Vector2(120.0, 40.0)

	mission_label.hide()
	retry_button.hide()
	retry_button.pressed.connect(_on_retry_pressed)

# =============================================================================
# Update functions — called by GameManager and SquadController
# =============================================================================

func update_score(new_score: int) -> void:
	if score_label:
		score_label.text = "SCORE: %d" % new_score
	if score_label_bottom:
		score_label_bottom.text = "SCORE: %d" % new_score

func update_soldier_count(alive: int) -> void:
	if soldier_label:
		soldier_label.text = "SOLDIERS: %d" % alive
	if soldiers_label:
		soldiers_label.text = "SOLDIERS: %d" % alive

func update_weapon(weapon_name: String) -> void:
	if weapon_label:
		weapon_label.text = weapon_name
	# Swap the icon based on weapon name
	if weapon_icon and weapon_name in WEAPON_ICONS:
		weapon_icon.texture = load(WEAPON_ICONS[weapon_name])

func update_formation(formation_name: String) -> void:
	if formation_label:
		formation_label.text = formation_name

func update_ammo(rifle: int, grenades: int) -> void:
	# Show both rifle and grenade ammo in compact format
	if not weapon_label:
		return
	var current := weapon_label.text
	if current.contains("("):
		current = current.split("(")[0].strip_edges()
	weapon_label.text = "%s (%d|%d)" % [current, rifle, grenades]

func update_group_info(active: int, total: int) -> void:
	if group_label:
		group_label.text = "%d/%d" % [active, total]
	_rebuild_group_buttons(total, active - 1)

func _rebuild_group_buttons(num_groups: int, active: int) -> void:
	for b in _group_buttons:
		b.queue_free()
	_group_buttons.clear()
	if num_groups <= 1:
		return
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	var screen_size := get_viewport().get_visible_rect().size
	var btn_width := 55.0
	var start_x := screen_size.x * 0.5 - (num_groups * btn_width) * 0.5
	for i in num_groups:
		var btn := Button.new()
		btn.text = "GRP %d" % (i + 1)
		btn.position = Vector2(start_x + i * btn_width, screen_size.y - 90.0)
		btn.size = Vector2(50.0, 30.0)
		if i == active:
			btn.add_theme_color_override("font_color", Color.YELLOW)
		var idx := i
		btn.pressed.connect(func():
			if squad_ctrl and squad_ctrl.has_method("_select_group"):
				squad_ctrl._select_group(idx)
		)
		add_child(btn)
		_group_buttons.append(btn)

func show_objective(level: int) -> void:
	var texts = {
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
	if enemy_label:
		enemy_label.text = "ENEMIES: %d" % count


func _process(_delta: float) -> void:
	if _arrow_node:
		_arrow_node.queue_redraw()

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
	var center := Vector2(screen_size.x * 0.5, screen_size.y - 60.0)
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
# Bottom HUD button handlers — send commands to SquadController
# =============================================================================

func _on_weapon_button_pressed() -> void:
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl and squad_ctrl.has_method("_cycle_weapons"):
		squad_ctrl._cycle_weapons()

func _on_formation_button_pressed() -> void:
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl and squad_ctrl.has_method("_cycle_formation"):
		squad_ctrl._cycle_formation()

func _on_group_button_pressed() -> void:
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl and squad_ctrl.has_method("_cycle_group_count"):
		squad_ctrl._cycle_group_count()

# =============================================================================
# Mission-end button handlers
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
