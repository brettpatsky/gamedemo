extends Control

# Wire each Button's "pressed" signal to the matching _on_*_pressed function
# in the Godot editor (or via code in _ready if you prefer).

func _ready() -> void:
	GameManager.score = 0

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


func _on_button_pressed() -> void:
	pass # Replace with function body.


func _on_button_2_pressed() -> void:
	pass # Replace with function body.


func _on_button_3_pressed() -> void:
	pass # Replace with function body.


func _on_button_4_pressed() -> void:
	pass # Replace with function body.
