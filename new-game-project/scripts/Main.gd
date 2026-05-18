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

const Balance = preload("res://scripts/BalanceConfig.gd")

@export var squad_size:    int  = 6
@export var map_seed:      int  = 0
# One scene per squad slot so each soldier can have a distinct sprite, stats,
# bullet colour, etc. Falls back to wrapping if fewer scenes than squad_size.
@export var soldier_scenes: Array[PackedScene]

# Level 4 — first hand-authored maze (the original 22×15).
const MAZE_SCENE_PATH := "res://scenes/mazes/maze_1.tscn"
# Level 5 — larger 44×30 maze with multiple paths to the exit.
const MAZE_2_SCENE_PATH := "res://scenes/mazes/maze_2.tscn"
# Level 6 — The Weeping Heart boss arena.
const BOSS_ARENA_SCENE_PATH := "res://scenes/bosses/boss_arena.tscn"

@onready var map_gen:    Node        = $GameViewport/SubViewport/MapGenerator
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

	# Levels 4 and 5 swap the procedural MapGenerator for a hand-authored maze
	# and run with a single soldier (the corridors are 1 tile wide).
	# Level 6 swaps it for the Heart boss arena (full squad of 6).
	var effective_squad_size: int = squad_size
	if GameManager.current_level == 4:
		var old: Node = map_gen
		map_gen = _spawn_alt_level(MAZE_SCENE_PATH)
		old.remove_from_group("map_generator")
		old.queue_free()
		effective_squad_size = 1
		# Camera snapshotted the old map's bounds in its own _ready (which ran
		# before Main._ready) — re-read from the maze now.
		var camera: Node = get_tree().get_first_node_in_group("main_camera")
		if camera and camera.has_method("refresh_map_bounds"):
			camera.refresh_map_bounds()
	elif GameManager.current_level == 5:
		var old: Node = map_gen
		map_gen = _spawn_alt_level(MAZE_2_SCENE_PATH)
		old.remove_from_group("map_generator")
		old.queue_free()
		effective_squad_size = 1
		var camera: Node = get_tree().get_first_node_in_group("main_camera")
		if camera and camera.has_method("refresh_map_bounds"):
			camera.refresh_map_bounds()
	elif GameManager.current_level == 6:
		var old: Node = map_gen
		map_gen = _spawn_alt_level(BOSS_ARENA_SCENE_PATH)
		old.remove_from_group("map_generator")
		old.queue_free()
		var camera: Node = get_tree().get_first_node_in_group("main_camera")
		if camera and camera.has_method("refresh_map_bounds"):
			camera.refresh_map_bounds()

	var seed_to_use: int = map_seed if map_seed != 0 else randi()
	map_gen.generate(seed_to_use)

	GameManager.soldiers_alive = 0
	GameManager.reset_squad_stats(effective_squad_size)
	_mission_ended = false

	_spawn_squad(effective_squad_size)
	# Maze levels start with a single soldier at the entrance — no formation snap.
	if GameManager.current_level != 4 and GameManager.current_level != 5:
		squad_ctrl.snap_to_formation()
	# Boss mission gets a heavier loadout: extra rifle ammo for sustained Phase 1
	# fire and more grenades to crack the orbiting Memory Totems in Phase 2.
	if GameManager.current_level == 6:
		_apply_boss_loadout()

	GameManager.soldier_died.connect(_on_soldier_died)
	GameManager.all_soldiers_dead.connect(_on_mission_fail)

	_setup_objective()

	hud.update_soldier_count(effective_squad_size)
	hud.show_objective(GameManager.current_level)

# ---------------------------------------------------------------------------
# Maze click handler (levels 4 and 5): SubViewportContainer._gui_input consumes
# mouse events before _unhandled_input fires, so we intercept in _input (which
# runs first). Action-based so the gamepad "A" button also triggers a move order.
func _input(event: InputEvent) -> void:
	if GameManager.current_level != 4 and GameManager.current_level != 5:
		return
	if not event.is_action_pressed("squad_move"):
		return
	# Mouse events carry their position; gamepad events don't — fall back to
	# the current cursor position (kept current by Reticle).
	var screen_pos: Vector2 = (event as InputEventMouse).position if event is InputEventMouse \
			else get_viewport().get_mouse_position()
	# Ignore clicks in the bottom HUD panel so formation/weapon buttons still work.
	var vp_size := get_viewport().get_visible_rect().size
	if screen_pos.y > vp_size.y - HUD_HEIGHT:
		return
	var cam := get_tree().get_first_node_in_group("main_camera") as Camera2D
	if cam == null:
		return
	var world_pos: Vector2 = cam.get_canvas_transform().affine_inverse() * screen_pos
	for s in get_tree().get_nodes_in_group("soldiers"):
		if s.has_method("move_to"):
			s.move_to(world_pos)

# ---------------------------------------------------------------------------
# Boss-mission loadout boost. Doubles the shared rifle pool and triples each
# soldier's grenade stockpile so the squad can sustain damage through three
# phases and still have potions to crack the orbiting totems. Values live in
# Balance.LOADOUT_BOSS_*.
func _apply_boss_loadout() -> void:
	GameManager.rifle_ammo_pool = Balance.LOADOUT_BOSS_RIFLE_POOL
	for s in get_tree().get_nodes_in_group("soldiers"):
		if s.has_method("set_grenade_ammo"):
			s.set_grenade_ammo(Balance.LOADOUT_BOSS_GRENADE_AMMO)
	# Re-push the ammo readout so the HUD numbers match the new pool before the
	# player issues their first fire order.
	if squad_ctrl and squad_ctrl.has_method("_update_ammo_hud"):
		squad_ctrl._update_ammo_hud()

# ---------------------------------------------------------------------------
# Generic hand-authored level swap (used by levels 4, 5, and 6). The loaded
# scene's root must implement the MapGenerator interface — see MazeLevel.gd /
# MazeLevel2.gd / BossArenaLevel.gd for the contract.
func _spawn_alt_level(path: String) -> Node:
	var scene: PackedScene = load(path)
	if scene == null:
		push_error("[Main] Failed to load alt-level scene: %s" % path)
		return null
	var node: Node = scene.instantiate()
	_subviewport.add_child(node)
	return node

# ---------------------------------------------------------------------------
func _spawn_squad(count: int) -> void:
	if soldier_scenes.is_empty():
		push_error("[Main] soldier_scenes is empty — assign at least one PackedScene in the Inspector!")
		return
	var positions: Array[Vector2] = map_gen.get_spawn_positions(count)
	for i in count:
		var scene: PackedScene = soldier_scenes[i % soldier_scenes.size()]
		var soldier: Node2D = scene.instantiate()
		soldier.slot_index = i
		if GameManager.current_level == 4 or GameManager.current_level == 5:
			soldier.maze_mode = true
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
		4, 5:
			# Maze escape — reaching the exit Area2D wins the mission. Same
			# wiring works for both maze layouts since they share the API.
			if map_gen and map_gen.has_signal("escaped"):
				map_gen.escaped.connect(_on_mission_win)
			var exit_zone: Node = map_gen.get_objective_node("maze_exit")
			if exit_zone and hud.has_method("set_maze_exit"):
				hud.set_maze_exit(exit_zone)
		6:
			# Boss arena — defeating the Heart wins the mission.
			if map_gen and map_gen.has_signal("boss_defeated"):
				map_gen.boss_defeated.connect(_on_mission_win)
			# When the squad enters the boss room, hide the corridor and zoom in.
			if map_gen and map_gen.has_signal("arena_locked"):
				map_gen.arena_locked.connect(func() -> void:
					var camera: Node = get_tree().get_first_node_in_group("main_camera")
					if camera and camera.has_method("lock_to_rect"):
						camera.lock_to_rect(map_gen.get_map_rect())
				)
			var boss: Node = map_gen.get_objective_node("boss")
			if boss and hud.has_method("set_boss"):
				hud.set_boss(boss)

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
	if GameManager.current_level >= 6:
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
