# =============================================================================
# SoldierMazeMover.gd
# Stripped-down soldier movement used only on the maze level.
#
# Why: the default Soldier._do_move layers stuck-detection, catch-up sprints,
# and unstick sidesteps on top of the navmesh. Those heuristics shove soldiers
# diagonally through 64 px maze corridors and pop them outside walls. In the
# maze we just want "follow the nav path at base speed" — this file owns that
# path so Soldier.gd can stay untouched for every other level.
# =============================================================================
class_name SoldierMazeMover
extends RefCounted

# One physics-frame tick of movement. Returns true once the soldier reaches
# the path's end so the caller can switch to IDLE.
static func tick(soldier: CharacterBody2D) -> bool:
	var nav: NavigationAgent2D = soldier.nav_agent
	if nav.is_navigation_finished():
		soldier.velocity = Vector2.ZERO
		soldier.move_and_slide()
		soldier.footstep.stop()
		return true

	var next_pos: Vector2 = nav.get_next_path_position()
	var direction: Vector2 = (next_pos - soldier.global_position).normalized()
	soldier.velocity = direction * soldier.move_speed
	soldier.move_and_slide()

	if soldier._shoot_flash_timer <= 0.0:
		soldier._play_walk_anim(direction)
	soldier._play_footstep()
	return false
