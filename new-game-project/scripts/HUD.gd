# =============================================================================
# HUD.gd — simplified to match Main.tscn node tree
# HUD (CanvasLayer)
# ├── ScoreLabel         (Label)
# ├── SoldierCountLabel  (Label)
# ├── MissionLabel       (Label)   — set Visible = false in Inspector
# └── RetryButton        (Button)  — set Visible = false in Inspector
# =============================================================================
extends CanvasLayer

@onready var score_label:   Label  = $ScoreLabel
@onready var soldier_label: Label  = $SoldierCountLabel
@onready var mission_label: Label  = $MissionLabel
@onready var retry_button:  Button = $RetryButton

func _ready() -> void:
	score_label.position = Vector2(10, 10)
	soldier_label.position = Vector2(10, 40)

	var center := get_viewport().get_visible_rect().size / 2.0
	mission_label.position = center + Vector2(-120.0, -30.0)
	retry_button.position  = center + Vector2(-60.0,  20.0)

	mission_label.hide()
	retry_button.hide()
	retry_button.pressed.connect(_on_retry_pressed)

func update_score(new_score: int) -> void:
	score_label.text = "SCORE: %d" % new_score

func update_soldier_count(alive: int) -> void:
	soldier_label.text = "SOLDIERS: %d" % alive

func show_mission_result(message: String, colour: Color) -> void:
	mission_label.text = message
	mission_label.add_theme_color_override("font_color", colour)
	mission_label.show()
	retry_button.show()

func _on_retry_pressed() -> void:
	get_tree().reload_current_scene()
