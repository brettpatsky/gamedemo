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
signal all_soldiers_dead              # mission-fail condition
signal mission_complete               # all enemies cleared
signal score_changed(new_score)       # UI listens here
signal enemies_changed(count)         # count enemies remaining


# ---------------------------------------------------------------------------
# Game state
# ---------------------------------------------------------------------------
var score: int = 0
var soldiers_alive: int = 0           # decremented by Soldier.die()
var enemies_alive: int = 0            # decremented by Enemy.die()
var current_level: int = 1            # persists across scene reloads (1–3)

func advance_level() -> void:
	current_level = min(current_level + 1, 3)

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
	emit_signal("soldier_died", soldier)
	if soldiers_alive <= 0:
		emit_signal("all_soldiers_dead")

# ---------------------------------------------------------------------------
# Call when an enemy dies; checks win condition for Level 1 only.
# Levels 2 and 3 have separate objectives (structure / escort).
# ---------------------------------------------------------------------------
func on_enemy_died() -> void:
	enemies_alive -= 1
	emit_signal("enemies_changed", enemies_alive) #broardcast remaining enemies to HUD
	if enemies_alive <= 0 and current_level == 1:
		emit_signal("mission_complete")
