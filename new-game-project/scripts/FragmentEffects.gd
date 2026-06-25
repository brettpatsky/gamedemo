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
	"bus_pass": {
		"name":        "Bus Pass",
		"description": "+15% squad move speed each mission",
	},
	# --- Picker-only fragments (no in-mission placement) -------------------
	"friendship_bracelet": {
		"name":        "Friendship Bracelet",
		"description": "Revives don't consume potions",
	},
	"swimming_goggles": {
		"name":        "Swimming Goggles",
		"description": "Kids ignore the water slowdown",
	},
	"dads_watch": {
		"name":        "Dad's Watch",
		"description": "Weapons cool down 25% faster",
	},
	"snack_bar": {
		"name":        "Snack Bar",
		"description": "All incoming damage reduced by 1",
	},
	"lost_marble": {
		"name":        "Lost Marble",
		"description": "Wand and staff shots deal +1 damage",
	},
	"brothers_cap": {
		"name":        "Brother's Cap",
		"description": "+25% wand and staff range",
	},
	# --- Second batch: six more so the pool covers 3 finds × 6 missions ------
	"story_book": {
		"name":        "Storybook",
		"description": "All kids gain +2 max HP",
	},
	"magic_compass": {
		"name":        "Enchanted Compass",
		"description": "+30 staff ammo and +6 throwables each mission",
	},
	"night_lantern": {
		"name":        "Night Lantern",
		"description": "+20% wand and staff range and +1 shot damage",
	},
	"toy_shield": {
		"name":        "Wooden Shield",
		"description": "Each kid blocks the first 2 hits every mission",
	},
	"healing_charm": {
		"name":        "Healing Charm",
		"description": "Hitting an enemy heals that kid 1 HP",
	},
	"river_stone": {
		"name":        "River Stone",
		"description": "Kids regenerate 1 HP every 3 seconds",
	},
}

# Mission-N → in-mission fragment mapping. The artifact placed in each
# mission's map is the SAME id every run — picking it up adds that fragment
# to RunState.fragments and the reward picker afterwards offers from the
# remaining pool. Missions 2-6 each free one parent + grant one of these.
const MISSION_FRAGMENTS := {
	1: "school_photo",
	2: "coach_whistle",
	3: "locker_key",
	4: "birthday_candle",
	5: "lucky_pencil",
	6: "bus_pass",
}

static func get_mission_fragment_id(level: int) -> String:
	return MISSION_FRAGMENTS.get(level, "")

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
			# Grenade ammo is now a shared squad pool — add once, not per
			# soldier. Old behaviour added 2 per kid (×6 = +12 total); we
			# preserve that total with a single +12 to the pool.
			GameManager.grenade_ammo_pool += 12
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
		"bus_pass":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_speed_bonus"):
					s.add_speed_bonus(0.15)
			return true
		"friendship_bracelet":
			GameManager.free_revives = true
			return true
		"swimming_goggles":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("enable_water_immunity"):
					s.enable_water_immunity()
			return true
		"dads_watch":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("multiply_cooldown"):
					s.multiply_cooldown(0.75)   # 25% faster fire rate
			return true
		"snack_bar":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_damage_reduction"):
					s.add_damage_reduction(1)
			return true
		"lost_marble":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_damage_bonus"):
					s.add_damage_bonus(1)
			return true
		"brothers_cap":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_range_mult"):
					s.add_range_mult(0.25)
			return true
		"story_book":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_max_health"):
					s.add_max_health(2)
			return true
		"magic_compass":
			GameManager.rifle_ammo_pool += 30
			GameManager.grenade_ammo_pool += 6
			return true
		"night_lantern":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_range_mult"):
					s.add_range_mult(0.20)
				if s.has_method("add_damage_bonus"):
					s.add_damage_bonus(1)
			return true
		"toy_shield":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_hit_shield"):
					s.add_hit_shield(2)
			return true
		"healing_charm":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_lifesteal"):
					s.add_lifesteal(1)
			return true
		"river_stone":
			for s in Engine.get_main_loop().get_nodes_in_group("soldiers"):
				if s.has_method("add_regen"):
					s.add_regen(1, 3.0)
			return true
		_:
			push_warning("[FragmentEffects] Unknown fragment id: %s" % id)
			return false
