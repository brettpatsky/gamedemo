# =============================================================================
# SquadControllerExtension.gd
# This is a PATCH file — copy the get_centroid() method into SquadController.gd
# (added here separately to keep the main file clean and focused).
#
# Add this method inside SquadController.gd:
# =============================================================================

# Returns the average world position of all living soldiers.
# CameraController calls this to softly follow the group.
func get_centroid() -> Vector2:
	if soldiers.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for s in soldiers:
		sum += s.global_position
	return sum / float(soldiers.size())
