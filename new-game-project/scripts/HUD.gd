extends CanvasLayer

@onready var score_label:   Label  = $ScoreLabel
@onready var soldier_label: Label  = $SoldierCountLabel
@onready var mission_label: Label  = $MissionLabel
@onready var retry_button:  Button = $RetryButton

var _weapon_label: Label
var _formation_label: Label
var _ammo_label: Label
var _group_label: Label
var _objective_label: Label
var _escort_label: Label
var _next_level_button: Button

func _ready() -> void:
	add_to_group("hud")

	score_label.position   = Vector2(10, 10)
	soldier_label.position = Vector2(10, 40)

	_weapon_label          = Label.new()
	_weapon_label.position = Vector2(10, 70)
	_weapon_label.text     = "WEAPON: Pistol  (Q to cycle)"
	add_child(_weapon_label)

	_formation_label          = Label.new()
	_formation_label.position = Vector2(10, 100)
	_formation_label.text     = "FORMATION: 3×2  (F to cycle)"
	add_child(_formation_label)

	_ammo_label          = Label.new()
	_ammo_label.position = Vector2(10, 130)
	_ammo_label.text     = "AMMO: Rifle 90  Grenades 5"
	add_child(_ammo_label)

	_group_label          = Label.new()
	_group_label.position = Vector2(10, 160)
	_group_label.text     = "GROUP: 1/1  (G to split | 1-3 select)"
	add_child(_group_label)

	_objective_label          = Label.new()
	_objective_label.position = Vector2(10, 190)
	add_child(_objective_label)

	_escort_label          = Label.new()
	_escort_label.position = Vector2(10, 220)
	_escort_label.hide()
	add_child(_escort_label)

	var center := get_viewport().get_visible_rect().size / 2.0
	mission_label.position = center + Vector2(-120.0, -30.0)
	retry_button.position  = center + Vector2(-60.0,  20.0)

	_next_level_button = Button.new()
	_next_level_button.text = "NEXT LEVEL"
	_next_level_button.position = center + Vector2(-60.0, 60.0)
	_next_level_button.hide()
	add_child(_next_level_button)
	_next_level_button.pressed.connect(_on_next_level_pressed)

	mission_label.hide()
	retry_button.hide()
	retry_button.pressed.connect(_on_retry_pressed)

func update_score(new_score: int) -> void:
	score_label.text = "SCORE: %d" % new_score

func update_soldier_count(alive: int) -> void:
	soldier_label.text = "SOLDIERS: %d" % alive

func update_weapon(weapon_name: String) -> void:
	_weapon_label.text = "WEAPON: %s  (Q to cycle)" % weapon_name

func update_formation(formation_name: String) -> void:
	_formation_label.text = "FORMATION: %s  (F to cycle)" % formation_name

func update_ammo(rifle: int, grenades: int) -> void:
	_ammo_label.text = "AMMO: Rifle %d  Grenades %d" % [rifle, grenades]

func update_group_info(active: int, total: int) -> void:
	if total == 1:
		_group_label.text = "GROUP: 1/1  (G to split)"
	else:
		_group_label.text = "GROUP: %d/%d  (G to cycle | 1-%d to select)" % [active, total, total]

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

func _on_retry_pressed() -> void:
	var main: Node = get_tree().get_first_node_in_group("main_scene")
	if main and main.has_method("restart"):
		main.restart()

func _on_next_level_pressed() -> void:
	var main: Node = get_tree().get_first_node_in_group("main_scene")
	if main and main.has_method("advance_level"):
		main.advance_level()
