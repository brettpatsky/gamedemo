# =============================================================================
# GameManager.gd
# Autoload singleton — lives for the entire session.
# Tracks global state: current squad, score, mission status, audio bus.
# Attach as an AutoLoad in Project > Project Settings > AutoLoad.
# =============================================================================
extends Node

const Balance = preload("res://scripts/BalanceConfig.gd")

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
# Feature-gate signals — the tutorial locks Sacrifice and Revive until the
# final trial. Missions 2-7 leave them enabled. HUD listens for these to
# enable/disable the corresponding buttons in real time.
signal sacrifice_enabled_changed(enabled: bool)
signal revive_enabled_changed(enabled: bool)


# ---------------------------------------------------------------------------
# Game state
# ---------------------------------------------------------------------------
var score: int = 0
var soldiers_alive: int = 0           # decremented by Soldier.die()
var enemies_alive: int = 0            # decremented by Enemy.die()
var current_level: int = 1            # persists across scene reloads (1–3)
# Map source for procedural missions (2 / 4 / 5). When false, MapGenerator
# builds a fresh random map each load (the original behaviour). When true,
# the matching scenes/handcrafted/mission_X.tscn is loaded instead so the
# player gets a hand-edited layout. Toggled by the title screen button;
# session-local (resets to false on quit). Other levels are unaffected —
# tutorial / mazes / boss always use their own hand-authored scenes.
var use_handcrafted_maps: bool = false
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
# Pool sizes live in BalanceConfig.SOLDIER_RIFLE_AMMO_MAX and
# SOLDIER_GRENADE_AMMO_MAX. Both pools are squad-wide so every soldier
# draws from the same counter — fixes the HUD-vs-throws drift the old
# per-soldier grenade ammo had.
var rifle_ammo_pool:   int = Balance.SOLDIER_RIFLE_AMMO_MAX
var grenade_ammo_pool: int = Balance.SOLDIER_GRENADE_AMMO_MAX

# Feature gates. Reset to true at the start of every mission; the tutorial
# disables both during Main._ready and re-enables them when Puzzle 5 (the
# Identity Gate) completes — see TutorialLevel1._build_room_identity.
var sacrifice_enabled: bool = true
var revive_enabled:    bool = true

# Per-mission cap on how many times Sacrifice can be triggered. -1 = unlimited
# (default for normal missions). Tutorial sets this to 1 for the Final Trial
# room so the player can't accidentally drain the squad by spamming clicks.
# Reset to -1 in reset_squad_stats so it doesn't bleed between missions.
var sacrifice_charges: int = -1

# Friendship Bracelet (fragment) — revives still need at least one potion
# to "exist" but don't consume it. Reset per mission in reset_squad_stats.
var free_revives: bool = false

func set_sacrifice_enabled(value: bool) -> void:
	if sacrifice_enabled == value:
		return
	sacrifice_enabled = value
	emit_signal("sacrifice_enabled_changed", value)

func set_revive_enabled(value: bool) -> void:
	if revive_enabled == value:
		return
	revive_enabled = value
	emit_signal("revive_enabled_changed", value)

# Decrement a sacrifice charge (called by Soldier.arm_as_bomb once the bomb
# has actually committed). When the count hits zero the weapon disables so
# the HUD button greys out and a follow-up click can't arm another kid.
func consume_sacrifice_charge() -> void:
	if sacrifice_charges < 0:
		return  # unlimited mode — no bookkeeping
	sacrifice_charges -= 1
	if sacrifice_charges <= 0:
		set_sacrifice_enabled(false)

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
	revive_potions   = REVIVES_PER_MISSION
	rifle_ammo_pool   = Balance.SOLDIER_RIFLE_AMMO_MAX
	grenade_ammo_pool = Balance.SOLDIER_GRENADE_AMMO_MAX
	emit_signal("revives_changed", revive_potions)
	# Default both feature gates open at the start of every mission. Tutorial
	# locks them again in Main.gd right after this call.
	set_sacrifice_enabled(true)
	set_revive_enabled(true)
	# Reset sacrifice-charge cap so non-tutorial missions get unlimited use.
	sacrifice_charges = -1
	# Friendship Bracelet (fragment) re-enables free_revives in FragmentEffects.
	free_revives = false

func record_shot(slot: int) -> void:
	if slot >= 0 and slot < soldier_shots.size():
		soldier_shots[slot] += 1

func record_hit(slot: int) -> void:
	if slot >= 0 and slot < soldier_hits.size():
		soldier_hits[slot] += 1

func advance_level() -> void:
	current_level = min(current_level + 1, 7)

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

# Returns true if a revive could be spent. Normally consumes one potion;
# with the Friendship Bracelet fragment active the count is preserved
# (free_revives = true) — the visible counter stays the same.
func use_revive() -> bool:
	if revive_potions <= 0:
		return false
	if not free_revives:
		revive_potions -= 1
		emit_signal("revives_changed", revive_potions)
	return true

# ---------------------------------------------------------------------------
# Call when an enemy dies; checks win condition for Level 2 (Eliminate Enemies).
# Level 1 is the tutorial (wins on parent rescue), 3 / 6 are maze escapes,
# 4 / 5 have separate objectives (structures / escort), 7 is the boss.
# ---------------------------------------------------------------------------
func on_enemy_died() -> void:
	enemies_alive -= 1
	emit_signal("enemies_changed", enemies_alive) #broardcast remaining enemies to HUD
	if enemies_alive <= 0 and current_level == 2:
		emit_signal("mission_complete")
