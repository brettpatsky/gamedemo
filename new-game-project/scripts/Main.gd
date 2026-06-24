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

const Balance      = preload("res://scripts/BalanceConfig.gd")
# Preload sidesteps Godot's `class_name` re-index lag — without it the LSP
# can't resolve AmbientLayer in _spawn_ambient_effects until you reload the
# whole project. The const intentionally shadows the global class_name (both
# point at the same script), so the warning is silenced explicitly.
@warning_ignore("shadowed_global_identifier")
const AmbientLayer = preload("res://scripts/AmbientLayer.gd")

@export var squad_size:    int  = 6
@export var map_seed:      int  = 0
# One scene per squad slot so each soldier can have a distinct sprite, stats,
# bullet colour, etc. Falls back to wrapping if fewer scenes than squad_size.
@export var soldier_scenes: Array[PackedScene]

# Level 1 — hand-authored tutorial corridor (six puzzles + parent room).
const TUTORIAL_1_SCENE_PATH := "res://scenes/tutorials/tutorial_1.tscn"
# Level 3 — first hand-authored maze (the original 22×15).
const MAZE_SCENE_PATH := "res://scenes/mazes/maze_1.tscn"
# Level 6 — larger 44×30 maze with multiple paths to the exit.
const MAZE_2_SCENE_PATH := "res://scenes/mazes/maze_2.tscn"
# Level 7 — The Weeping Heart boss arena.
const BOSS_ARENA_SCENE_PATH := "res://scenes/bosses/boss_arena.tscn"
# Hand-crafted alternatives to the default per-level scenes. Used when the
# player flips the "Map: Custom" toggle on the title screen. Each scene uses
# HandcraftedMap.gd and is editable in the Godot editor. When toggled on, these
# REPLACE the level's default behaviour entirely — handcrafted versions of the
# tutorial / mazes / boss won't have their scripted puzzles / exits / boss
# fight; they're blank canvases for the level designer to populate themselves.
const HANDCRAFTED_MAP_PATHS := {
	1: "res://scenes/handcrafted/mission_1_tutorial.tscn",
	2: "res://scenes/handcrafted/mission_2_eliminate.tscn",
	3: "res://scenes/handcrafted/mission_3_maze1.tscn",
	4: "res://scenes/handcrafted/mission_4_structures.tscn",
	5: "res://scenes/handcrafted/mission_5_escort.tscn",
	6: "res://scenes/handcrafted/mission_6_maze2.tscn",
	7: "res://scenes/handcrafted/mission_7_boss.tscn",
}

@onready var map_gen:    Node        = $GameViewport/SubViewport/MapGenerator
@onready var squad_ctrl: Node2D      = $GameViewport/SubViewport/SquadController
@onready var hud:        CanvasLayer = $HUD
@onready var _subviewport: SubViewport = $GameViewport/SubViewport
@onready var _music:     AudioStreamPlayer = $AudioStreamPlayer

const HUD_HEIGHT := 46.0

var _mission_ended: bool = false

# ---------------------------------------------------------------------------
func _ready() -> void:
	randomize()   # re-seed global RNG from OS entropy so each run has a different map
	add_to_group("main_scene")

	# SubViewportContainer is a Control child of a Node2D, so anchors don't
	# resolve automatically — set its size explicitly from the viewport rect.
	var vp_size := get_viewport().get_visible_rect().size
	$GameViewport.set_position(Vector2.ZERO)
	$GameViewport.set_size(Vector2(vp_size.x, vp_size.y - HUD_HEIGHT))

	# Level dispatch — new order:
	#   1 Tutorial · 2 Eliminate · 3 Maze 1 · 4 Structures · 5 Escort · 6 Maze 2 · 7 Boss
	# Default behaviour: mazes (3 + 6) swap MapGenerator for hand-authored
	# 1-tile corridors and run with a single soldier. Boss (7) swaps for the
	# Heart arena with the full squad. Tutorial (1) swaps for the puzzle
	# corridor. Levels 2 / 4 / 5 always load the handcrafted scene; the
	# title-screen "Map: Auto/Custom" toggle decides whether they regenerate
	# fresh Caraka terrain at runtime (Auto) or use the saved hand-edited
	# tiles (Custom). For the other levels the toggle still swaps in the
	# handcrafted scene when Custom is on.
	var effective_squad_size: int = squad_size
	var lvl: int = GameManager.current_level
	var is_proc_level: bool = (lvl == 2 or lvl == 4 or lvl == 5)
	var should_use_handcrafted: bool = is_proc_level \
		or (GameManager.use_handcrafted_maps and HANDCRAFTED_MAP_PATHS.has(lvl))
	if should_use_handcrafted and HANDCRAFTED_MAP_PATHS.has(lvl):
		var old: Node = map_gen
		map_gen = _spawn_alt_level(HANDCRAFTED_MAP_PATHS[lvl])
		# Auto mode regenerates fresh Caraka terrain at runtime; Custom uses
		# the saved tiles as-is. Only meaningful for HandcraftedMap-based scenes.
		if "regenerate_at_runtime" in map_gen:
			map_gen.regenerate_at_runtime = not GameManager.use_handcrafted_maps
		# Auto mode also randomises the season per run for variety. Custom
		# leaves whatever the scene was saved with.
		if not GameManager.use_handcrafted_maps and "season" in map_gen:
			map_gen.season = randi() % 4
		old.remove_from_group("map_generator")
		old.queue_free()
		var camera: Node = get_tree().get_first_node_in_group("main_camera")
		if camera and camera.has_method("refresh_map_bounds"):
			camera.refresh_map_bounds()
		# Mazes ship with a single-soldier rule baked into their gameplay —
		# preserve that for handcrafted versions of mazes so squad size matches
		# the rest of the maze pipeline (formation snap skipped, etc.).
		# Tutorial handcrafted uses the same tall-narrow layout — allow free zoom.
		if lvl == 1 and camera and camera.has_method("allow_free_zoom"):
			camera.allow_free_zoom()
		if lvl == 3 or lvl == 6:
			effective_squad_size = 1
	elif GameManager.current_level == 1:
		var old: Node = map_gen
		map_gen = _spawn_alt_level(TUTORIAL_1_SCENE_PATH)
		old.remove_from_group("map_generator")
		old.queue_free()
		var camera: Node = get_tree().get_first_node_in_group("main_camera")
		if camera and camera.has_method("refresh_map_bounds"):
			# The tutorial is now a wide ≈16:9 Caraka map — let the camera fit the
			# whole map (no free-zoom override) so it fills the screen with no bars.
			camera.refresh_map_bounds()
	elif GameManager.current_level == 3:
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
	elif GameManager.current_level == 6:
		var old: Node = map_gen
		map_gen = _spawn_alt_level(MAZE_2_SCENE_PATH)
		old.remove_from_group("map_generator")
		old.queue_free()
		effective_squad_size = 1
		var camera: Node = get_tree().get_first_node_in_group("main_camera")
		if camera and camera.has_method("refresh_map_bounds"):
			camera.refresh_map_bounds()
	elif GameManager.current_level == 7:
		var old: Node = map_gen
		map_gen = _spawn_alt_level(BOSS_ARENA_SCENE_PATH)
		old.remove_from_group("map_generator")
		old.queue_free()
		var camera: Node = get_tree().get_first_node_in_group("main_camera")
		if camera and camera.has_method("refresh_map_bounds"):
			camera.refresh_map_bounds()

	var seed_to_use: int = map_seed if map_seed != 0 else randi()
	map_gen.generate(seed_to_use)

	# Procedural-map missions (2-4) get an ambient atmosphere layer: weather,
	# bird flyovers, and a handful of wandering critters. Tutorial / mazes /
	# boss skip this — they're either too tight (mazes), too narratively
	# loaded (boss), or have their own scripted feel (tutorial).
	_spawn_ambient_effects()

	GameManager.soldiers_alive = 0
	GameManager.reset_squad_stats(effective_squad_size)
	# Tutorial mission locks Sacrifice and Revive until the player solves
	# Puzzle 5 (Identity Gate) — see TutorialLevel1._build_room_identity.
	# Every other mission leaves both available from the start.
	if GameManager.current_level == 1:
		GameManager.set_sacrifice_enabled(false)
		GameManager.set_revive_enabled(false)
	_mission_ended = false

	_spawn_squad(effective_squad_size)
	# Apply persistent fragment effects on top of the freshly-reset per-mission
	# baselines. Done after spawn so per-soldier bonuses (future fragments)
	# can mutate live soldier instances.
	var applied_fragments: Array[String] = FragmentEffects.apply_all()
	if not applied_fragments.is_empty():
		hud.show_toast("MEMORIES ACTIVE — %s" % ", ".join(applied_fragments),
				Color(0.75, 0.95, 1.0), 3.5)
	# Maze levels (3 + 6) start with a single soldier at the entrance — no formation snap.
	if GameManager.current_level != 3 and GameManager.current_level != 6:
		squad_ctrl.snap_to_formation()
	# Boss mission gets a heavier loadout: extra rifle ammo for sustained Phase 1
	# fire and more grenades to crack the orbiting Memory Totems in Phase 2.
	if GameManager.current_level == 7:
		_apply_boss_loadout()

	GameManager.soldier_died.connect(_on_soldier_died)
	GameManager.all_soldiers_dead.connect(_on_mission_fail)

	_setup_objective()

	hud.update_soldier_count(effective_squad_size)
	hud.show_objective(GameManager.current_level)

	var ls := get_node_or_null("/root/LoadingScreen")
	if ls and ls.has_method("hide_loading"):
		ls.hide_loading()

# ---------------------------------------------------------------------------
# Maze click handler (levels 3 and 6): SubViewportContainer._gui_input consumes
# mouse events before _unhandled_input fires, so we intercept in _input (which
# runs first). Action-based so the gamepad "A" button also triggers a move order.
func _input(event: InputEvent) -> void:
	if GameManager.current_level != 3 and GameManager.current_level != 6:
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
# Boss-mission loadout boost. Bumps the shared rifle and grenade pools so the
# squad can sustain damage through three phases and still have potions to
# crack the orbiting totems. Values live in Balance.LOADOUT_BOSS_*.
func _apply_boss_loadout() -> void:
	GameManager.rifle_ammo_pool   = Balance.LOADOUT_BOSS_RIFLE_POOL
	GameManager.grenade_ammo_pool = Balance.LOADOUT_BOSS_GRENADE_AMMO
	# Re-push the ammo readout so the HUD numbers match the new pool before the
	# player issues their first fire order.
	if squad_ctrl and squad_ctrl.has_method("_update_ammo_hud"):
		squad_ctrl._update_ammo_hud()

# ---------------------------------------------------------------------------
# Adds an AmbientLayer to the SubViewport on procedural-map missions so they
# have weather + birds + wandering critters. Purely visual; no gameplay
# effect. Tutorial / mazes / boss skip this entirely.
func _spawn_ambient_effects() -> void:
	# Only fire on the procedural-map missions (Eliminate / Structures /
	# Escort = levels 2, 4, 5 in the new order). Tutorial / mazes / boss
	# have their own hand-authored feel.
	var lv: int = GameManager.current_level
	if lv != 2 and lv != 4 and lv != 5:
		return
	# Weather follows the map's season:
	#   WINTER → snow
	#   SPRING / FALL → 50% rain, 50% clear
	#   SUMMER → clear
	# Fog is intentionally never used (visually noisy, requested removed).
	var weather: AmbientLayer.Weather = AmbientLayer.Weather.CLEAR
	if map_gen and "season" in map_gen:
		match map_gen.season:
			HandcraftedMap.Season.WINTER:
				weather = AmbientLayer.Weather.SNOW
			HandcraftedMap.Season.SPRING, HandcraftedMap.Season.FALL:
				if randi() % 2 == 0:
					weather = AmbientLayer.Weather.RAIN
	var layer := AmbientLayer.new()
	layer.weather = weather
	_subviewport.add_child(layer)

# ---------------------------------------------------------------------------
# Generic hand-authored level swap (used by levels 1, 5, 6, and 7). The loaded
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
	# Filter the slot list against RunState — dead kids stay dead for the run
	# and never spawn. `count` is the cap (1 for maze levels, full squad
	# otherwise); we honour it by truncating the living-slot list.
	var living: Array[int] = RunState.living_slots()
	if living.is_empty():
		# Safety net: a totally-wiped roster reached spawn (restart() should have
		# already refreshed it). Never leave the level with zero soldiers — that's
		# the invisible, can't-move/fire state — so begin a fresh run and respawn.
		push_warning("[Main] No living kids in RunState — starting a fresh run so the squad isn't empty")
		RunState.start_new_run()
		living = RunState.living_slots()
		if living.is_empty():
			return
	var slots_to_spawn: Array[int] = living.slice(0, count)
	# Maze missions (level 3 = Maze 1, level 6 = Maze 2) only spawn one kid,
	# and each maze frees a specific kid's parent. Prefer that kid so the cage
	# opens; fall back to the first living kid if they've died earlier in
	# the run (cage stays shut, mission still winnable via the maze exit).
	# Slot = level - 1: Maze 1 → Kid 3 (slot 2), Maze 2 → Kid 6 (slot 5).
	if count == 1 and (GameManager.current_level == 3 or GameManager.current_level == 6):
		var preferred_slot: int = GameManager.current_level - 1
		if preferred_slot >= 0 and preferred_slot < RunState.SQUAD_SIZE \
				and RunState.kids_alive[preferred_slot]:
			slots_to_spawn = [preferred_slot]
	var positions: Array[Vector2] = map_gen.get_spawn_positions(slots_to_spawn.size())
	for i in slots_to_spawn.size():
		var slot: int = slots_to_spawn[i]
		var scene: PackedScene = soldier_scenes[slot % soldier_scenes.size()]
		var soldier: Node2D = scene.instantiate()
		soldier.slot_index = slot
		var carry_hp: int = RunState.get_carry_hp(slot)
		if carry_hp > 0 and soldier.has_method("set_carried_hp"):
			soldier.set_carried_hp(carry_hp)
		if GameManager.current_level == 3 or GameManager.current_level == 6:
			soldier.maze_mode = true
		soldier.add_to_group("soldiers")
		_subviewport.add_child(soldier)
		soldier.global_position = positions[i] if i < positions.size() \
				else Vector2(200 + i * 40, 400)
		squad_ctrl.add_soldier(soldier)

# ---------------------------------------------------------------------------
func _setup_objective() -> void:
	# Every non-boss mission can have a parent cage + memory fragment placed
	# by its level script. Wire them here uniformly; the tutorial wins the
	# mission on parent rescue, every other mission treats the cage as a
	# side objective that flips a RunState bit and shows a toast.
	if GameManager.current_level != 7:
		_wire_parent_cage(GameManager.current_level == 1)
		_wire_memory_fragment()

	match GameManager.current_level:
		1:
			# Tutorial — _wire_parent_cage above already routes parent_freed
			# to _on_mission_win, and DELIBERATELY mission_complete is not
			# connected: clearing the three Puzzle 1 dummies would otherwise
			# end the mission five rooms early.
			pass
		2:
			# Eliminate Enemies — GameManager.mission_complete fires when the
			# enemies_alive counter reaches zero (see GameManager.on_enemy_died,
			# which is hard-coded to check level == 2).
			GameManager.mission_complete.connect(_on_mission_win)
		3, 6:
			# Maze escape (Maze 1 = level 3, Maze 2 = level 6) — reaching the
			# exit Area2D wins the mission. Same wiring works for both maze
			# layouts since they share the API.
			if map_gen and map_gen.has_signal("escaped"):
				map_gen.escaped.connect(_on_mission_win)
			var exit_zone: Node = map_gen.get_objective_node("maze_exit")
			if exit_zone and hud.has_method("set_maze_exit"):
				hud.set_maze_exit(exit_zone)
		4:
			# Destroy Structures — mission ends when every fortified building
			# has been levelled. Each destruction spawns a reinforcement wave.
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
		5:
			# Escort VIP — walk the NPC from their shelter to the extraction zone.
			var zone: Node = map_gen.get_objective_node("extraction_zone")
			var npc:  Node = map_gen.get_objective_node("escort_npc")
			if zone:
				zone.npc_extracted.connect(_on_mission_win)
			if npc:
				npc.escort_killed.connect(_on_mission_fail)
				npc.health_changed.connect(hud.update_escort_health)
				var npc_max: int = npc.get_max_health() if npc.has_method("get_max_health") else npc.MAX_HEALTH
				hud.update_escort_health(npc.get_health(), npc_max)
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
		7:
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
		# 160px radius clears the 220×220 rubble collision box (half-diagonal ~156px).
		var angle := (TAU / count) * i
		var offset := Vector2(cos(angle), sin(angle)) * 160.0
		# Brief invulnerability so grenades that destroyed the structure don't
		# insta-kill the reinforcements before the player sees them.
		if "spawn_protection" in enemy:
			enemy.spawn_protection = 1.0
		_subviewport.add_child(enemy)
		enemy.global_position = world_pos + offset
		# Fade in from transparent so enemies emerge rather than pop into existence.
		enemy.modulate.a = 0.0
		var tw := enemy.create_tween()
		tw.tween_property(enemy, "modulate:a", 1.0, 0.6)
	GameManager.enemies_alive += count
	GameManager.enemies_changed.emit(GameManager.enemies_alive)

func _on_soldier_died(_soldier) -> void:
	hud.update_soldier_count(GameManager.soldiers_alive)

func _on_mission_win() -> void:
	if _mission_ended:
		return
	_mission_ended = true
	_persist_run_state()
	_freeze_and_fade_world()
	if GameManager.current_level >= 7:
		hud.show_mission_result("YOU WIN! ALL LEVELS COMPLETE!", Color.YELLOW, false)
	else:
		_enter_fairy_garden()

func _enter_fairy_garden() -> void:
	var found := RunState.claim_level_fragments()
	_music.stop()
	# Finish dimming the world to full black, then show the garden.
	var tw := create_tween()
	tw.tween_interval(0.4)
	tw.tween_property($GameViewport, "modulate", Color.BLACK, 0.45) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		var garden := FairyGarden.new()
		garden.setup(found)
		garden.garden_exited.connect(_on_garden_exited)
		add_child(garden)
	)

func _on_garden_exited() -> void:
	advance_level()

func _on_mission_fail() -> void:
	if _mission_ended:
		return
	_mission_ended = true
	_persist_run_state()
	_freeze_and_fade_world()
	hud.show_mission_result("MISSION FAILED", Color.RED, false)

# Stops all gameplay motion and dims the world so the bonus cards / end
# screen read clearly. Disables processing on the SubViewport subtree so
# soldiers, enemies, bullets and the camera all freeze in place — drawing
# continues, only callbacks stop. HUD lives on its own CanvasLayer above
# the viewport, so it keeps animating and stays at full brightness.
func _freeze_and_fade_world() -> void:
	# Deferred: _on_mission_win can fire from a physics callback (ExtractionZone
	# body_entered), and disabling a subtree's CollisionObjects mid-callback is
	# illegal. set_deferred applies it once the physics step finishes.
	_subviewport.set_deferred("process_mode", Node.PROCESS_MODE_DISABLED)
	# Looped audio (footsteps) doesn't stop when process is disabled, so
	# silence anything currently playing on the soldier/enemy/NPC nodes.
	for group in ["soldiers", "enemies"]:
		for n in get_tree().get_nodes_in_group(group):
			for child in (n as Node).get_children():
				if child is AudioStreamPlayer2D and (child as AudioStreamPlayer2D).playing:
					(child as AudioStreamPlayer2D).stop()
	# Quick darken on the viewport — HUD stays bright because it isn't a child.
	var tween := create_tween()
	tween.tween_property($GameViewport, "modulate",
			Color(0.35, 0.35, 0.4, 1.0), 0.4) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

# Connects the level's parent-cage signals if the map_gen has placed one.
# When end_mission_on_freed is true (tutorial), opening the cage also ends
# the mission via _on_mission_win. Otherwise it's purely a side objective —
# the toast fires and RunState.parents_freed flips, but the mission doesn't
# end. wrong_kid_entered toasts a hint either way.
func _wire_parent_cage(end_mission_on_freed: bool) -> void:
	var cage: Node = map_gen.get_objective_node("parent_cage") if map_gen else null
	if cage == null:
		return
	if cage.has_signal("parent_freed"):
		cage.parent_freed.connect(func(slot: int) -> void:
			hud.show_toast("KID %d'S PARENT FREED" % (slot + 1),
					Color(1.0, 0.85, 0.35), 3.0)
			if end_mission_on_freed:
				_on_mission_win()
		)
	if cage.has_signal("wrong_kid_entered"):
		cage.wrong_kid_entered.connect(func(_slot: int) -> void:
			var expected: int = (cage.child_slot if "child_slot" in cage else 0) + 1
			hud.show_toast("Only Kid %d can open this cage" % expected,
					Color(0.95, 0.75, 0.75), 2.0)
		)

# Surfaces fragment pickups as toasts. Handles both the three-fragment main
# missions ("memory_fragments" array) and single-fragment maze levels.
func _wire_memory_fragment() -> void:
	if map_gen == null:
		return
	var frags: Variant = map_gen.get_objective_node("memory_fragments")
	if frags == null:
		frags = map_gen.get_objective_node("memory_fragment")
	if frags == null:
		return
	var frag_array: Array = frags if frags is Array else [frags]
	for frag in frag_array:
		if frag == null or not frag.has_signal("collected"):
			continue
		frag.collected.connect(func(_id: String, name_text: String) -> void:
			hud.show_toast("MEMORY FOUND — %s" % name_text,
					Color(0.7, 0.95, 1.0), 2.5)
		)

# Snapshots the squad at the moment the mission ends and rolls the result into
# RunState. The soldiers group still contains downed kids (they're left on the
# field as revivable corpses), so iterating it gives us the full DEPLOYED list
# for this mission. Anyone in the group who isn't downed counts as a survivor;
# downed kids are deployed-but-not-survivor (RunState marks them lost). Kids
# who weren't deployed at all (e.g. the five who stayed home during a maze
# mission) are left untouched.
func _persist_run_state() -> void:
	var survivors: Array = []
	var deployed: Array[int] = []
	for s in get_tree().get_nodes_in_group("soldiers"):
		if not is_instance_valid(s):
			continue
		var slot: int = s.slot_index if "slot_index" in s else -1
		if slot < 0:
			continue
		deployed.append(slot)
		if s.has_method("is_downed") and s.is_downed():
			continue
		var hp: int = s.get_health() if s.has_method("get_health") else -1
		if hp >= 0:
			survivors.append({"slot": slot, "hp": hp})
	RunState.record_mission_end(GameManager.current_level, survivors, deployed)

# ---------------------------------------------------------------------------
func advance_level() -> void:
	GameManager.advance_level()
	_show_loading_screen()
	await get_tree().process_frame
	get_tree().reload_current_scene()

func restart() -> void:
	# A total squad wipe marks every kid dead in RunState (permadeath), so simply
	# reloading the level would spawn ZERO soldiers — an invisible, uncontrollable
	# squad with no move/fire. A wipe ends the run, so start a fresh roster here so
	# the retry button actually hands the player a squad again. The guard means
	# normal cases (partial losses, a pause-menu restart with living kids) keep
	# their surviving roster untouched — permadeath within a live run still holds.
	if RunState.living_slots().is_empty():
		RunState.start_new_run()
	_show_loading_screen()
	await get_tree().process_frame
	get_tree().reload_current_scene()

func _show_loading_screen() -> void:
	var ls := get_node_or_null("/root/LoadingScreen")
	if ls and ls.has_method("show_loading"):
		ls.show_loading()
