# =============================================================================
# FragmentEffects.gd
# Memory-fragment metadata + effect logic. RunState.fragments holds the list of
# collected ids; apply_all() walks that list at the start of every mission and
# re-applies each effect on top of the per-mission base values that
# GameManager.reset_squad_stats just set. Effects therefore compound across the
# run (collect Coach's Whistle once → every mission has +50 rifle ammo).
#
# To add a fragment:
#   1. Add a metadata row to FRAGMENT_METADATA.
#   2. Add a `match` arm in _apply_one() that mutates the relevant state.
#   3. (Optional) If you also want it spawnable in a mission, set
#      memory_fragment.tscn's fragment_id / display_name and place it.
# =============================================================================
class_name FragmentEffects

const FRAGMENT_METADATA := {
	"school_photo": {
		"name":        "School Photo",
		"description": "+1 revive potion each mission",
	},
	"coach_whistle": {
		"name":        "Coach's Whistle",
		"description": "+50 staff ammo at the start of each mission",
	},
	"locker_key": {
		"name":        "Locker Key",
		"description": "+2 throwables per kid each mission",
	},
	"lucky_pencil": {
		"name":        "Lucky Pencil",
		"description": "All kids gain +1 max HP",
	},
	"birthday_candle": {
		"name":        "Birthday Candle",
		"description": "All kids start each mission at full HP",
	},
}

static func get_display_name(id: String) -> String:
	var entry: Variant = FRAGMENT_METADATA.get(id, null)
	if entry == null:
		return id
	return entry.get("name", id)

static func get_description(id: String) -> String:
	var entry: Variant = FRAGMENT_METADATA.get(id, null)
	if entry == null:
		return ""
	return entry.get("description", "")

# Returns up to `count` fragment ids that the player does NOT yet have, drawn
# at random from the pool. If the pool is exhausted, returns whatever is left
# (which may be fewer than `count` or even empty — caller should handle that
# by skipping the reward screen).
static func roll_rewards(count: int) -> Array[String]:
	var available: Array[String] = []
	for id in FRAGMENT_METADATA.keys():
		if not RunState.fragments.has(id):
			available.append(id)
	available.shuffle()
	if available.size() > count:
		available.resize(count)
	return available

# Walks RunState.fragments and applies every effect on top of the just-reset
# per-mission base values. Returns a list of human-readable names for the HUD
# to surface; empty means "no fragments collected yet".
static func apply_all() -> Array[String]:
	var applied: Array[String] = []
	for id in RunState.fragments:
		if _apply_one(id):
			applied.append(get_display_name(id))
	return applied

static func _apply_one(id: String) -> bool:
	match id:
		"school_photo":
			GameManager.revive_potions += 1
			GameManager.emit_signal("revives_changed", GameManager.revive_potions)
			return true
		"coach_whistle":
			GameManager.rifle_ammo_pool += 50
			return true
		"locker_key":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_grenade_ammo"):
					s.add_grenade_ammo(2)
			return true
		"lucky_pencil":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_max_health"):
					s.add_max_health(1)
			return true
		"birthday_candle":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("heal_to_full"):
					s.heal_to_full()
			return true
		_:
			push_warning("[FragmentEffects] Unknown fragment id: %s" % id)
			return false
