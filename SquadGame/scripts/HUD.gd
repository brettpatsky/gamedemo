# =============================================================================
# HUD.gd
# Attach to the HUD CanvasLayer node in Main.tscn.
#
# SCENE NODE TREE (create in editor):
#   HUD (CanvasLayer)
#   ├── MarginContainer
#   │   └── VBoxContainer
#   │       ├── ScoreLabel        (Label)   — top-left
#   │       └── SoldierCountLabel (Label)   — top-left, below score
#   ├── MissionLabel (Label)      — centred, hidden by default
#   └── RetryButton (Button)      — centred below MissionLabel, hidden by default
# =============================================================================
extends CanvasLayer

@onready var score_label:    Label  = $MarginContainer/VBoxContainer/ScoreLabel
@onready var soldier_label:  Label  = $MarginContainer/VBoxContainer/SoldierCountLabel
@onready var mission_label:  Label  = $MissionLabel
@onready var retry_button:   Button = $RetryButton

func _ready() -> void:
	mission_label.hide()
	retry_button.hide()
	retry_button.pressed.connect(_on_retry_pressed)

# Called by Main.gd when GameManager emits score_changed
func update_score(new_score: int) -> void:
	score_label.text = "SCORE: %d" % new_score

# Called by Main.gd when a soldier dies
func update_soldier_count(alive: int) -> void:
	soldier_label.text = "SOLDIERS: %d" % alive

# Called on win or lose
func show_mission_result(message: String, colour: Color) -> void:
	mission_label.text              = message
	mission_label.add_theme_color_override("font_color", colour)
	mission_label.show()
	retry_button.show()

func _on_retry_pressed() -> void:
	# Main.gd handles the actual reload
	get_tree().reload_current_scene()
