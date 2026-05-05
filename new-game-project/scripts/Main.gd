# =============================================================================
# Main.gd
# Attach to the root Node2D of Main.tscn.
#
# SCENE NODE TREE (build in the editor):
#   Main (Node2D)
#   ├── MapGenerator (Node2D)      ← MapGenerator.gd attached
#   │   ├── TileMapLayer           ← TileSet resource assigned
#   │   └── NavigationRegion2D
#   ├── SquadController (Node2D)   ← SquadController.gd attached
#   │                              ← add to group "squad_controller"
#   ├── Camera2D                   ← CameraController.gd attached
#   │                              ← add to group "main_camera"
#   └── HUD (CanvasLayer)          ← HUD.gd attached (separate file below)
#       ├── ScoreLabel (Label)
#       ├── SoldierCountLabel (Label)
#       └── MissionLabel (Label)   ← hidden until win/lose
# =============================================================================
extends Node2D

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
@export var squad_size:    int  = 6     # how many soldiers to spawn (1–8)
@export var map_seed:      int  = 0     # 0 = random each run
@export var soldier_scene: PackedScene  # drag Soldier.tscn into Inspector

# ---------------------------------------------------------------------------
# Node references
# ---------------------------------------------------------------------------
@onready var map_gen:       Node2D  = $MapGenerator
@onready var squad_ctrl:    Node2D  = $SquadController
@onready var hud:           CanvasLayer = $HUD

# ---------------------------------------------------------------------------
func _ready() -> void:
	# Choose a seed: fixed for debugging, random for real runs
	var seed_to_use: int = map_seed if map_seed != 0 else randi()

	# 1. Generate the procedural map (tiles + nav-mesh + enemies)
	map_gen.generate(seed_to_use)

	# 2. Spawn soldiers at valid map positions
	_spawn_squad()

	# 3. Wire up GameManager signals so HUD and endgame respond
	GameManager.score_changed.connect(hud.update_score)
	GameManager.soldier_died.connect(_on_soldier_died)
	GameManager.all_soldiers_dead.connect(_on_mission_fail)
	GameManager.mission_complete.connect(_on_mission_win)

	# 4. Update initial HUD state
	hud.update_score(GameManager.score)
	hud.update_soldier_count(squad_size)

# ---------------------------------------------------------------------------
func _spawn_squad() -> void:
	if soldier_scene == null:
		push_error("[Main] soldier_scene not assigned in Inspector!")
		return

	# Ask the map for valid spawn positions
	var positions: Array[Vector2] = map_gen.get_spawn_positions(squad_size)

	for i in squad_size:
		var soldier: Node2D = soldier_scene.instantiate()

		# Alternate gender for visual variety (0,2,4… male; 1,3,5… female)
		soldier.is_female = (i % 2 == 1)

		# Soldiers must be in the "soldiers" group for enemy detection
		soldier.add_to_group("soldiers")

		add_child(soldier)

		# Position after adding to tree so global_position is valid
		if i < positions.size():
			soldier.global_position = positions[i]
		else:
			# Fallback if map couldn't find enough spawn points
			soldier.global_position = Vector2(200 + i * 40, 400)

		squad_ctrl.add_soldier(soldier)

# ---------------------------------------------------------------------------
# Expose squad centroid so CameraController can follow the group
# (Added here so SquadController stays input-focused)
# ---------------------------------------------------------------------------
func _on_soldier_died(_soldier) -> void:
	hud.update_soldier_count(GameManager.soldiers_alive)

func _on_mission_win() -> void:
	hud.show_mission_result("MISSION COMPLETE!", Color.GREEN)

func _on_mission_fail() -> void:
	hud.show_mission_result("MISSION FAILED", Color.RED)

# ---------------------------------------------------------------------------
# Restart the mission — called by the HUD retry button
# ---------------------------------------------------------------------------
func restart() -> void:
	get_tree().reload_current_scene()
