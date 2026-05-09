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
#   └── HUD (CanvasLayer)          ← HUD.gd attached
#       ├── ScoreLabel (Label)
#       ├── SoldierCountLabel (Label)
#       └── MissionLabel (Label)   ← hidden until win/lose
# =============================================================================
extends Node2D

@export var squad_size:    int  = 6
@export var map_seed:      int  = 0
@export var soldier_scene: PackedScene

@onready var map_gen:    Node2D      = $MapGenerator
@onready var squad_ctrl: Node2D      = $SquadController
@onready var hud:        CanvasLayer = $HUD

var _mission_ended: bool = false

# ---------------------------------------------------------------------------
func _ready() -> void:
	add_to_group("main_scene")

	var seed_to_use: int = map_seed if map_seed != 0 else randi()
	map_gen.generate(seed_to_use)

	GameManager.soldiers_alive = 0
	_mission_ended = false

	_spawn_squad()
	squad_ctrl.snap_to_formation()

	GameManager.score_changed.connect(hud.update_score)
	GameManager.soldier_died.connect(_on_soldier_died)
	GameManager.all_soldiers_dead.connect(_on_mission_fail)

	_setup_objective()

	hud.update_score(GameManager.score)
	hud.update_soldier_count(squad_size)
	hud.show_objective(GameManager.current_level)

# ---------------------------------------------------------------------------
func _spawn_squad() -> void:
	if soldier_scene == null:
		push_error("[Main] soldier_scene not assigned in Inspector!")
		return
	var positions: Array[Vector2] = map_gen.get_spawn_positions(squad_size)
	for i in squad_size:
		var soldier: Node2D = soldier_scene.instantiate()
		soldier.is_female = (i % 2 == 1)
		soldier.add_to_group("soldiers")
		add_child(soldier)
		soldier.global_position = positions[i] if i < positions.size() \
				else Vector2(200 + i * 40, 400)
		squad_ctrl.add_soldier(soldier)

# ---------------------------------------------------------------------------
func _setup_objective() -> void:
	match GameManager.current_level:
		1:
			GameManager.mission_complete.connect(_on_mission_win)
		2:
			var structure: Node = map_gen.get_objective_node("fortified_structure")
			if structure:
				structure.structure_destroyed.connect(_on_mission_win)
		3:
			var zone: Node = map_gen.get_objective_node("extraction_zone")
			var npc:  Node = map_gen.get_objective_node("escort_npc")
			if zone:
				zone.npc_extracted.connect(_on_mission_win)
			if npc:
				npc.escort_killed.connect(_on_mission_fail)
				npc.health_changed.connect(hud.update_escort_health)
				hud.update_escort_health(npc.get_health(), npc.MAX_HEALTH)

# ---------------------------------------------------------------------------
func _on_soldier_died(_soldier) -> void:
	hud.update_soldier_count(GameManager.soldiers_alive)

func _on_mission_win() -> void:
	if _mission_ended:
		return
	_mission_ended = true
	if GameManager.current_level >= 3:
		hud.show_mission_result("YOU WIN! ALL LEVELS COMPLETE!", Color.YELLOW, false)
	else:
		hud.show_mission_result("MISSION COMPLETE!", Color.GREEN, true)

func _on_mission_fail() -> void:
	if _mission_ended:
		return
	_mission_ended = true
	hud.show_mission_result("MISSION FAILED", Color.RED, false)

# ---------------------------------------------------------------------------
func advance_level() -> void:
	GameManager.advance_level()
	get_tree().reload_current_scene()

func restart() -> void:
	get_tree().reload_current_scene()
