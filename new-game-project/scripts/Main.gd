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
# One scene per squad slot so each soldier can have a distinct sprite, stats,
# bullet colour, etc. Falls back to wrapping if fewer scenes than squad_size.
@export var soldier_scenes: Array[PackedScene]

@onready var map_gen:    Node2D      = $GameViewport/SubViewport/MapGenerator
@onready var squad_ctrl: Node2D      = $GameViewport/SubViewport/SquadController
@onready var hud:        CanvasLayer = $HUD
@onready var _subviewport: SubViewport = $GameViewport/SubViewport

const HUD_HEIGHT := 90.0

var _mission_ended: bool = false

# ---------------------------------------------------------------------------
func _ready() -> void:
	add_to_group("main_scene")

	# SubViewportContainer is a Control child of a Node2D, so anchors don't
	# resolve automatically — set its size explicitly from the viewport rect.
	var vp_size := get_viewport().get_visible_rect().size
	$GameViewport.set_position(Vector2.ZERO)
	$GameViewport.set_size(Vector2(vp_size.x, vp_size.y - HUD_HEIGHT))

	var seed_to_use: int = map_seed if map_seed != 0 else randi()
	map_gen.generate(seed_to_use)

	GameManager.soldiers_alive = 0
	GameManager.reset_squad_stats(squad_size)
	_mission_ended = false

	_spawn_squad()
	squad_ctrl.snap_to_formation()

	GameManager.soldier_died.connect(_on_soldier_died)
	GameManager.all_soldiers_dead.connect(_on_mission_fail)

	_setup_objective()

	hud.update_soldier_count(squad_size)
	hud.show_objective(GameManager.current_level)

# ---------------------------------------------------------------------------
func _spawn_squad() -> void:
	if soldier_scenes.is_empty():
		push_error("[Main] soldier_scenes is empty — assign at least one PackedScene in the Inspector!")
		return
	var positions: Array[Vector2] = map_gen.get_spawn_positions(squad_size)
	for i in squad_size:
		var scene: PackedScene = soldier_scenes[i % soldier_scenes.size()]
		var soldier: Node2D = scene.instantiate()
		soldier.slot_index = i
		soldier.add_to_group("soldiers")
		_subviewport.add_child(soldier)
		soldier.global_position = positions[i] if i < positions.size() \
				else Vector2(200 + i * 40, 400)
		squad_ctrl.add_soldier(soldier)

# ---------------------------------------------------------------------------
func _setup_objective() -> void:
	match GameManager.current_level:
		1:
			GameManager.mission_complete.connect(_on_mission_win)
		2:
			var structures = map_gen.get_objective_node("fortified_structure")
			if structures is Array and not structures.is_empty():
				var remaining := [structures.size()]
				for s: Node in structures:
					s.structure_destroyed.connect(func() -> void:
						# Snapshot position while the node is still alive (queue_free
						# runs at end of frame, so global_position is valid here).
						var spawn_pos: Vector2 = (s as Node2D).global_position
						# Defer spawn one frame so the structure's StaticBody2D
						# collision is fully removed before enemies are placed —
						# enemies spawned inside a live collision box get stuck.
						call_deferred("_spawn_enemies_at", spawn_pos, 5)
						remaining[0] -= 1
						if remaining[0] <= 0:
							_on_mission_win()
					)
		3:
			var zone: Node = map_gen.get_objective_node("extraction_zone")
			var npc:  Node = map_gen.get_objective_node("escort_npc")
			if zone:
				zone.npc_extracted.connect(_on_mission_win)
			if npc:
				npc.escort_killed.connect(_on_mission_fail)
				npc.health_changed.connect(hud.update_escort_health)
				hud.update_escort_health(npc.get_health(), npc.MAX_HEALTH)
				hud.set_escort_targets(npc, zone)
				npc.joined_squad.connect(hud.on_escort_joined)
			# Any sheltering wall destroyed frees the NPC and topples the rest.
			var walls: Variant = map_gen.get_objective_node("escort_walls")
			if walls is Array and npc:
				for w: Node in walls:
					w.wall_destroyed.connect(func() -> void:
						if is_instance_valid(npc) and npc.has_method("release"):
							npc.release()
						# Use queue_free() directly to avoid re-emitting wall_destroyed
						# and triggering this lambda again (stack overflow).
						for other: Node in walls:
							if is_instance_valid(other):
								other.queue_free()
					)

# ---------------------------------------------------------------------------
func _spawn_enemies_at(world_pos: Vector2, count: int) -> void:
	var enemy_scene: PackedScene = load("res://scenes/enemy.tscn")
	if enemy_scene == null:
		enemy_scene = load("res://scenes/Enemy.tscn")
	if enemy_scene == null:
		push_warning("[Main] Enemy scene not found — skipping reinforcement spawn.")
		return
	for i in count:
		var enemy: Node2D = enemy_scene.instantiate()
		# Spread evenly in a ring around the destroyed structure.
		# 96px radius keeps every enemy clear of the 80x80 structure collision box.
		var angle := (TAU / count) * i
		var offset := Vector2(cos(angle), sin(angle)) * 96.0
		_subviewport.add_child(enemy)
		enemy.global_position = world_pos + offset
	GameManager.enemies_alive += count
	GameManager.enemies_changed.emit(GameManager.enemies_alive)

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
