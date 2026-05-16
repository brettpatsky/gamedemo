# =============================================================================
# GameManager.gd
# Autoload singleton — lives for the entire session.
# Tracks global state: current squad, score, mission status, audio bus.
# Attach as an AutoLoad in Project > Project Settings > AutoLoad.
# =============================================================================
extends Node

# ---------------------------------------------------------------------------
# Signals — other nodes subscribe to these instead of polling each frame
# ---------------------------------------------------------------------------
signal soldier_died(soldier)          # emitted when any soldier is killed
signal soldier_revived(soldier)       # emitted when a downed soldier is restored
signal all_soldiers_dead              # mission-fail condition
signal mission_complete               # all enemies cleared
signal score_changed(new_score)       # UI listens here
signal enemies_changed(count)         # count enemies remaining
signal revives_changed(remaining)     # HUD updates the revive-potion counter


# ---------------------------------------------------------------------------
# Game state
# ---------------------------------------------------------------------------
var score: int = 0
var soldiers_alive: int = 0           # decremented by Soldier.die()
var enemies_alive: int = 0            # decremented by Enemy.die()
var current_level: int = 1            # persists across scene reloads (1–3)
# Cheat: when true, Soldier.take_damage() is a no-op for the entire squad.
# Toggled by the GOD button next to MAIN MENU on the HUD. Persists across
# retries / next-level transitions so it stays on once enabled.
var god_mode: bool = false
# Each mission starts with this many revive potions. The HUD shows the count
# in the formation grid's "?" slot; clicking it brings the last downed soldier
# back to full health.
const REVIVES_PER_MISSION  := 1
var revive_potions: int = REVIVES_PER_MISSION

# Shared rifle ammo pool — all soldiers draw from this so smaller groups
# aren't penalised with less ammo after a split.
const RIFLE_AMMO_POOL_MAX := 300
var rifle_ammo_pool: int = RIFLE_AMMO_POOL_MAX

# Per-soldier accuracy stats (indexed by spawn slot 0..squad_size-1).
# Persisted in GameManager so dead soldiers' final totals survive after queue_free.
var soldier_shots: Array[int] = []
var soldier_hits:  Array[int] = []
var soldier_alive: Array[bool] = []

func reset_squad_stats(size: int) -> void:
	soldier_shots.resize(size)
	soldier_hits.resize(size)
	soldier_alive.resize(size)
	for i in size:
		soldier_shots[i] = 0
		soldier_hits[i]  = 0
		soldier_alive[i] = true
	revive_potions  = REVIVES_PER_MISSION
	rifle_ammo_pool = RIFLE_AMMO_POOL_MAX
	emit_signal("revives_changed", revive_potions)

func record_shot(slot: int) -> void:
	if slot >= 0 and slot < soldier_shots.size():
		soldier_shots[slot] += 1

func record_hit(slot: int) -> void:
	if slot >= 0 and slot < soldier_hits.size():
		soldier_hits[slot] += 1

func advance_level() -> void:
	current_level = min(current_level + 1, 5)

# ---------------------------------------------------------------------------
# Called once at startup
# ---------------------------------------------------------------------------
func _ready() -> void:
	# Ensure consistent random seed each run (change to randomize() for true RNG)
	seed(42)
	print("[GameManager] Ready.")

# ---------------------------------------------------------------------------
# Add to score and broadcast so the HUD updates automatically
# ---------------------------------------------------------------------------
func add_score(points: int) -> void:
	score += points
	emit_signal("score_changed", score)

# ---------------------------------------------------------------------------
# Call when a soldier dies; checks loss condition
# ---------------------------------------------------------------------------
func on_soldier_died(soldier) -> void:
	soldiers_alive -= 1
	if soldier and "slot_index" in soldier:
		var slot: int = soldier.slot_index
		if slot >= 0 and slot < soldier_alive.size():
			soldier_alive[slot] = false
	emit_signal("soldier_died", soldier)
	# Only fail the mission if there are no revives left — otherwise the
	# player can still bring someone back.
	if soldiers_alive <= 0 and revive_potions <= 0:
		emit_signal("all_soldiers_dead")

# Mirror of on_soldier_died — used when a downed soldier is restored to full
# health via the revive button.
func on_soldier_revived(soldier) -> void:
	soldiers_alive += 1
	if soldier and "slot_index" in soldier:
		var slot: int = soldier.slot_index
		if slot >= 0 and slot < soldier_alive.size():
			soldier_alive[slot] = true
	emit_signal("soldier_revived", soldier)

# Returns true if a potion was available and consumed.
func use_revive() -> bool:
	if revive_potions <= 0:
		return false
	revive_potions -= 1
	emit_signal("revives_changed", revive_potions)
	return true

# ---------------------------------------------------------------------------
# Call when an enemy dies; checks win condition for Level 1 only.
# Levels 2 and 3 have separate objectives (structure / escort).
# ---------------------------------------------------------------------------
func on_enemy_died() -> void:
	enemies_alive -= 1
	emit_signal("enemies_changed", enemies_alive) #broardcast remaining enemies to HUD
	if enemies_alive <= 0 and current_level == 1:
		emit_signal("mission_complete")
