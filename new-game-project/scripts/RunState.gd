# =============================================================================
# RunState.gd
# Autoload singleton — owns the roguelike-run state that persists across
# missions within a single run. Reset via start_new_run(), the RESET RUN
# button on the title screen, or F12 anywhere in-game.
#
# Scope: things that must outlive a single mission scene reload.
#   - which kids are still alive for the rest of the run
#   - each kid's HP carried into the next mission
#   - which parents have been freed
#   - which missions have been completed this run
#   - collected memory-fragment IDs (effects applied by gameplay code)
#
# Per-mission state (current ammo, revives, score) still lives in GameManager.
# =============================================================================
extends Node

const SQUAD_SIZE := 6

signal run_reset
signal kid_lost(slot: int)
signal parent_freed(slot: int)
signal fragment_collected(id: String)

# Per-slot run state (indexed 0..SQUAD_SIZE-1).
var kids_alive:     Array[bool] = []
# Carried HP at start of the NEXT mission. -1 means "use the kid's max_health".
var kid_hp:         Array[int]  = []
var parents_freed:  Array[bool] = []

var missions_completed: Array[int]    = []
var fragments:          Array[String] = []

func _ready() -> void:
	start_new_run()

func _unhandled_input(event: InputEvent) -> void:
	# F12 anywhere = wipe the run and return to the title screen.
	# Convenience for design iteration; remove (or gate behind a debug flag)
	# before shipping.
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_F12:
		start_new_run()
		get_tree().change_scene_to_file("res://scenes/title_screen.tscn")

func start_new_run() -> void:
	kids_alive    = []
	kid_hp        = []
	parents_freed = []
	for i in SQUAD_SIZE:
		kids_alive.append(true)
		kid_hp.append(-1)
		parents_freed.append(false)
	missions_completed.clear()
	fragments.clear()
	emit_signal("run_reset")

# Snapshots the squad's state at mission end and rolls it forward into the run.
#   `survivors` — Array of { "slot": int, "hp": int }, one entry per kid that
#                 finished the mission alive (NOT a downed/unrevived corpse).
#   `deployed`  — Array[int] of every slot that was actually sent on this
#                 mission. Kids NOT in this list (e.g. the five kids who
#                 stayed home during a single-soldier maze run) are left
#                 untouched: their kids_alive flag and carried HP keep
#                 whatever values they had going in.
# A deployed kid who isn't in survivors is the only case that triggers death.
func record_mission_end(mission_id: int, survivors: Array, deployed: Array[int] = []) -> void:
	var still_alive := {}
	for entry in survivors:
		var slot: int = entry.get("slot", -1)
		var hp:   int = entry.get("hp", -1)
		if slot < 0 or slot >= SQUAD_SIZE:
			continue
		still_alive[slot] = true
		kid_hp[slot] = hp
	# Empty deployed list means "the whole living squad was sent" — the legacy
	# behaviour for callers that haven't been updated yet. New callers should
	# pass the actual deployed slots so untouched kids stay safe at home.
	var effective_deployed: Array[int] = deployed
	if effective_deployed.is_empty():
		for i in SQUAD_SIZE:
			if kids_alive[i]:
				effective_deployed.append(i)
	for slot in effective_deployed:
		if slot < 0 or slot >= SQUAD_SIZE:
			continue
		if kids_alive[slot] and not still_alive.has(slot):
			kids_alive[slot] = false
			emit_signal("kid_lost", slot)
	if not missions_completed.has(mission_id):
		missions_completed.append(mission_id)

func free_parent(slot: int) -> void:
	if slot < 0 or slot >= SQUAD_SIZE:
		return
	if parents_freed[slot]:
		return
	parents_freed[slot] = true
	emit_signal("parent_freed", slot)

func collect_fragment(id: String) -> void:
	if id == "":
		return
	fragments.append(id)
	emit_signal("fragment_collected", id)

# Returns the HP the kid in `slot` should spawn with next mission.
# -1 means "use the kid's max_health" — let Soldier._ready handle the default.
func get_carry_hp(slot: int) -> int:
	if slot < 0 or slot >= SQUAD_SIZE:
		return -1
	return kid_hp[slot]

func kids_alive_count() -> int:
	var n := 0
	for a in kids_alive:
		if a:
			n += 1
	return n

func parents_freed_count() -> int:
	var n := 0
	for p in parents_freed:
		if p:
			n += 1
	return n

# Returns the slots (0..SQUAD_SIZE-1) of every kid still alive, in order.
func living_slots() -> Array[int]:
	var out: Array[int] = []
	for i in SQUAD_SIZE:
		if kids_alive[i]:
			out.append(i)
	return out
