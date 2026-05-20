# =============================================================================
# FragmentEffects.gd
# Maps each memory-fragment id (collected and stored in RunState.fragments)
# to the gameplay tweak it applies at the start of every mission.
#
# Effects compound across the run — every mission, apply_all() walks the
# collected list and re-applies each one on top of the per-mission base
# values that GameManager.reset_squad_stats just set.
#
# To add a new fragment:
#   1. Place it in a mission (MapGenerator) with a unique fragment_id and
#      display_name.
#   2. Add a metadata entry to FRAGMENT_METADATA below.
#   3. Add a `match` arm in _apply_one() that mutates the relevant state.
# =============================================================================
class_name FragmentEffects

const FRAGMENT_METADATA := {
	"mission_1_school_photo": {
		"name":        "School Photo",
		"description": "+1 revive potion each mission",
	},
}

static func get_name(id: String) -> String:
	var entry: Variant = FRAGMENT_METADATA.get(id, null)
	if entry == null:
		return id
	return entry.get("name", id)

static func get_description(id: String) -> String:
	var entry: Variant = FRAGMENT_METADATA.get(id, null)
	if entry == null:
		return ""
	return entry.get("description", "")

# Walks RunState.fragments and applies every effect on top of the just-reset
# per-mission base values. Returns a list of human-readable names for the
# HUD to surface; an empty list means "no fragments collected yet".
static func apply_all() -> Array[String]:
	var applied: Array[String] = []
	for id in RunState.fragments:
		if _apply_one(id):
			applied.append(get_name(id))
	return applied

static func _apply_one(id: String) -> bool:
	match id:
		"mission_1_school_photo":
			GameManager.revive_potions += 1
			GameManager.emit_signal("revives_changed", GameManager.revive_potions)
			return true
		_:
			push_warning("[FragmentEffects] Unknown fragment id: %s" % id)
			return false
