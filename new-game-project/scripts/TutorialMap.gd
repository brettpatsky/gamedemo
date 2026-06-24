# =============================================================================
# TutorialMap.gd
# Hand-authored Level 1 built on the Caraka HandcraftedMap pipeline (terrain,
# plateaus, painted-tile collision/nav, blocking props) instead of the old
# procedural room corridor. The level is laid out freely in the editor; this
# script:
#   - sizes the map WIDE (≈16:9) so it fills a widescreen monitor (no side bars),
#   - makes water IMPASSABLE (lakes wall the squad in),
#   - skips the combat-mission spawners (no random enemies / structures / cave),
#   - ADOPTS the hand-placed trial nodes and wires their puzzle logic, sealing
#     each trial behind its closed PuzzleGate in the navmesh until solved, then
#     re-baking so the gap opens.
#
# Trials are described entirely by the `trial_index` export shared between a
# trial's sensors (TriggerZone / ElementBrazier / SpecialWall / enemies) and its
# PuzzleGate — no hardcoded room numbers. A trial is solved when EVERY condition
# implied by the sensor types present is satisfied.
# =============================================================================
@tool
extends HandcraftedMap
class_name TutorialMap

# Tutorial squad start — a Marker2D placed in this group; the squad spawns in a
# 2×3 formation around it (fallback: the map centre).
const SPAWN_GROUP := "squad_spawn"

# trial_index -> state dictionary (see _new_trial). Built in _adopt_tutorial_nodes.
var _trials: Dictionary = {}

# ---------------------------------------------------------------------------
# Wide 16:9 map, impassable water, painted-tile ("Custom") terrain.
# ---------------------------------------------------------------------------
func _map_dims() -> Vector3i:
	return Vector3i(Balance.MAP_TUTORIAL_WIDTH, Balance.MAP_TUTORIAL_HEIGHT,
			Balance.MAP_HANDCRAFTED_TILE_SIZE)

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	block_water = true             # lakes block movement (nav + collision)
	regenerate_at_runtime = false  # always use the hand-painted tiles as-is
	super._ready()

# Custom generate(): run only the shared terrain/nav/collision pipeline (all
# inherited from HandcraftedMap), then adopt the hand-placed trial nodes. No
# combat-mission spawners.
func generate(seed_value: int = 0) -> void:
	_objective_nodes.clear()
	_resolve_layers()
	_init_elevation(seed_value)
	_setup_tileset()
	_derive_from_painted_tiles()
	_scan_passable_from_tiles()
	_bake_navigation()
	_build_cliff_collision()
	_adopt_tutorial_nodes()

# ---------------------------------------------------------------------------
# Spawn
# ---------------------------------------------------------------------------
func get_spawn_positions(count: int) -> Array[Vector2]:
	var base: Vector2 = get_map_centre()
	var marker: Node = get_tree().get_first_node_in_group(SPAWN_GROUP)
	if marker and marker is Node2D:
		base = (marker as Node2D).global_position
	var formation := [
		Vector2(-80, 20), Vector2(0, 20), Vector2(80, 20),
		Vector2(-80, 80), Vector2(0, 80), Vector2(80, 80),
	]
	var out: Array[Vector2] = []
	for i in count:
		out.append(base + (formation[i] if i < formation.size() else Vector2.ZERO))
	return out

# ===========================================================================
# Trial adoption + wiring
# ===========================================================================
func _new_trial() -> Dictionary:
	return {
		"gates": [], "zones": [], "braziers": [], "enemies": [], "wall": null,
		"solved": false,
		"zones_needed": 0, "zones_pressed": 0,
		"braziers_needed": 0, "braziers_lit": 0,
		"enemies_total": 0, "enemies_left": 0,
		"has_wall": false, "wall_broken": false,
		"needs_revive": false, "revive_done": false,
	}

func _trial(ti: int) -> Dictionary:
	if not _trials.has(ti):
		_trials[ti] = _new_trial()
	return _trials[ti]

func _adopt_tutorial_nodes() -> void:
	_trials.clear()
	var all: Array[Node] = []
	_gather(self, all)

	var total_enemies := 0
	for node in all:
		# Objective nodes Main wires via get_objective_node — register by scene path.
		var sp := node.scene_file_path
		if sp.ends_with("parent_cage.tscn"):
			_objective_nodes["parent_cage"] = node
		elif sp.ends_with("memory_fragment.tscn"):
			_objective_nodes["memory_fragment"] = node

		if not ("trial_index" in node):
			continue
		var ti: int = node.trial_index
		if ti < 0:
			continue
		var t := _trial(ti)
		if node is PuzzleGate:
			t.gates.append(node)
		elif node is TriggerZone:
			t.zones.append(node)
		elif node is ElementBrazier:
			t.braziers.append(node)
		elif node is SpecialWall:
			t.wall = node
		elif node.is_in_group("enemies"):
			t.enemies.append(node)
			total_enemies += 1

	# Seal each trial in the navmesh (closed gates / intact walls are obstructions
	# until solved) and wire the sensors.
	for ti in _trials:
		_wire_trial(ti)

	# HUD enemy counter — the adopted enemies are the live count for the mission.
	if total_enemies > 0:
		GameManager.enemies_alive = total_enemies
		GameManager.enemies_changed.emit(total_enemies)

func _wire_trial(ti: int) -> void:
	var t: Dictionary = _trials[ti]
	t.zones_needed = (t.zones as Array).size()
	t.braziers_needed = (t.braziers as Array).size()
	t.enemies_total = (t.enemies as Array).size()
	t.enemies_left = t.enemies_total
	t.has_wall = t.wall != null

	for z in t.zones:
		(z as TriggerZone).state_changed.connect(_on_zone_changed.bind(ti))
	for b in t.braziers:
		(b as ElementBrazier).lit.connect(_on_brazier_lit.bind(ti))
	for e in t.enemies:
		(e as Node).tree_exited.connect(_on_enemy_gone.bind(ti))
	if t.wall:
		var w := t.wall as SpecialWall
		t.needs_revive = w.also_requires_revive
		w.destroyed.connect(_on_wall_destroyed.bind(ti))
		if t.needs_revive:
			GameManager.soldier_revived.connect(_on_revive.bind(ti))

func _on_zone_changed(pressed: bool, ti: int) -> void:
	var t: Dictionary = _trials[ti]
	t.zones_pressed += (1 if pressed else -1)
	_check_trial(ti)

func _on_brazier_lit(_element: int, ti: int) -> void:
	_trials[ti].braziers_lit += 1
	_check_trial(ti)

func _on_enemy_gone(ti: int) -> void:
	_trials[ti].enemies_left -= 1
	_check_trial(ti)

func _on_wall_destroyed(ti: int) -> void:
	_trials[ti].wall_broken = true
	_check_trial(ti)

func _on_revive(_soldier: Node, ti: int) -> void:
	_trials[ti].revive_done = true
	_check_trial(ti)

# A trial is solved once EVERY condition its sensors imply is met. A trial with
# no sensors (only a gate) never auto-opens.
func _check_trial(ti: int) -> void:
	var t: Dictionary = _trials[ti]
	if t.solved:
		return
	var has_condition: bool = t.zones_needed > 0 or t.braziers_needed > 0 \
			or t.enemies_total > 0 or t.has_wall
	if not has_condition:
		return
	if t.zones_needed > 0 and t.zones_pressed < t.zones_needed:
		return
	if t.braziers_needed > 0 and t.braziers_lit < t.braziers_needed:
		return
	if t.enemies_total > 0 and t.enemies_left > 0:
		return
	if t.has_wall and not t.wall_broken:
		return
	if t.needs_revive and not t.revive_done:
		return

	t.solved = true
	for g in t.gates:
		var gate := g as PuzzleGate
		gate.open()
		if gate.on_open_unlock_sacrifice_revive:
			_unlock_sacrifice_revive()
	# The gate's collision is gone; re-bake so the navmesh opens the gap too.
	call_deferred("_bake_navigation")

# Ported from TutorialLevel1 — opens Sacrifice + Revive and announces it.
func _unlock_sacrifice_revive() -> void:
	GameManager.set_sacrifice_enabled(true)
	GameManager.set_revive_enabled(true)
	GameManager.sacrifice_charges = 1
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("show_toast"):
		hud.show_toast("SACRIFICE & REVIVE UNLOCKED", Color(1.0, 0.85, 0.5), 3.5)

# ===========================================================================
# Dynamic navmesh sealing — closed gates / intact walls block pathing through
# the barrier gaps until their trial is solved (HandcraftedMap's bake only knows
# cliffs/props/water, not these StaticBody2D nodes).
# ===========================================================================
func _extra_nav_obstruction_outlines() -> Array:
	var out: Array = []
	if nav_region == null:
		return out
	for ti in _trials:
		var t: Dictionary = _trials[ti]
		for g in t.gates:
			var gate := g as PuzzleGate
			if is_instance_valid(gate) and not gate.is_opened():
				out.append(_rect_outline_local(nav_region, _node_rect_world(gate, gate.width, gate.height)))
		if t.wall and is_instance_valid(t.wall) and not t.wall_broken:
			var w := t.wall as SpecialWall
			out.append(_rect_outline_local(nav_region, _node_rect_world(w, w.width, w.height)))
	return out

func _node_rect_world(node: Node2D, w: float, h: float) -> Rect2:
	var size := Vector2(w, h)
	return Rect2(node.global_position - size * 0.5, size)

# ---------------------------------------------------------------------------
func _gather(node: Node, out: Array[Node]) -> void:
	for child in node.get_children():
		out.append(child)
		_gather(child, out)
