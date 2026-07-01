# =============================================================================
# SquadConfig.gd
# Autoload singleton — owns the PLAYER-AUTHORED squad loadout set on the title
# screen. The player spends a fixed pool of points raising four stats per kid:
# HP, DMG (weapon damage), SPD (projectile speed) and RNG (projectile range).
# A floor of LEVEL_MIN on every stat is the safeguard the design asks for — no
# soldier can ever be left at zero in any of the four.
#
# Up to PROFILE_COUNT named profiles are saved to disk (SAVE_PATH) so a loadout
# survives between sessions and the player can flip between builds. Preset
# buttons (Balanced / Ranged / Damage) load hand-tuned spreads; Random scatters
# the whole pool.
#
# The squad defaults to the Balanced preset (a full, even spend of the pool),
# and `overrides_active` is true from the start — so Soldier._ready reads this
# config for every spawn. The title screen forbids deploying until the entire
# pool is spent (see is_fully_allocated), so the squad is never underpowered.
# =============================================================================
extends Node

const SQUAD_SIZE := 6
const STAT_COUNT := 4
# Stat order is fixed; the UI and the value mappings below rely on it.
enum Stat { HP, DMG, SPD, RNG }
const STAT_NAMES := ["HP", "DMG", "SPD", "RNG"]

# Every stat is an integer LEVEL in [LEVEL_MIN, LEVEL_MAX]. LEVEL_MIN = 1 is the
# zero-safeguard: the −/+ controls and every loader clamp to this floor.
const LEVEL_MIN := 1
const LEVEL_MAX := 8

# Total points the player may commit across the whole squad (the sum of every
# soldier's four stat levels). The floor (all 24 stats at LEVEL_MIN) costs 24,
# and the theoretical max is 24 * LEVEL_MAX = 192, so a cap of 120 makes the
# allocation a genuine trade-off rather than "max everything".
const POOL_TOTAL := 120

const PROFILE_COUNT := 3
const SAVE_PATH := "user://squad_profiles.cfg"

# Level → in-game value. HP maps 1:1 to the pre-scale max-health number; the
# other three lerp across a designer range so a single point feels meaningful.
# LEVEL_MIN always maps to a strictly-positive value, preserving the safeguard
# all the way through to the numbers Soldier actually uses.
const DMG_VALUE_MIN := 1.0
const DMG_VALUE_MAX := 6.0
const SPD_VALUE_MIN := 600.0
const SPD_VALUE_MAX := 1200.0
const RNG_VALUE_MIN := 700.0
const RNG_VALUE_MAX := 1600.0

# Hand-tuned presets — one row of four levels, applied to EVERY kid. Each spends
# exactly POOL_TOTAL (20 per kid × 6 = 120) so the preset's name reads true.
const PRESET_BALANCED: Array = [5, 5, 5, 5]
const PRESET_DAMAGE:   Array = [7, 7, 3, 3]   # fat HP + DMG, lean SPD/RNG
const PRESET_RANGED:   Array = [3, 3, 7, 7]   # fast, long-reaching glass cannons

signal config_changed   # active levels / pool / profile state changed → UI repaints

# Active editable config: levels[slot][stat], slot 0..5, stat 0..3.
var levels: Array = []
# Purely-cosmetic per-slot character choice (a CharacterRoster id). Swapping a
# slot's character changes only its sprite + displayed name; all stats stay tied
# to the slot. Defaults to the slot's native kid. Persisted alongside the levels.
var slot_character: Array[String] = []
# Saved profiles: PROFILE_COUNT entries, each {"name": String, "levels": Array}.
# An unused slot is an empty Dictionary.
var profiles: Array = []
# Which saved profile (0..PROFILE_COUNT-1) the active config came from, or -1
# for a custom / unsaved spread.
var active_profile: int = -1
# When true, Soldier._ready reads this config instead of the BalanceConfig
# per-slot tables. _init_state turns it on (Balanced default), so it is
# effectively always active; kept as a flag for standalone test scenes that
# spawn a Soldier before this autoload has run.
var overrides_active: bool = false

# Local RNG so Random doesn't perturb GameManager's deterministic gameplay seed.
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_init_state()
	_load_from_disk()

func _init_state() -> void:
	levels = []
	for _s in SQUAD_SIZE:
		var row: Array = []
		for _t in STAT_COUNT:
			row.append(LEVEL_MIN)
		levels.append(row)
	profiles = []
	for _p in PROFILE_COUNT:
		profiles.append({})
	slot_character = []
	for s in SQUAD_SIZE:
		slot_character.append(CharacterRoster.default_id_for_slot(s))
	# Default loadout is the Balanced preset. It spends the entire pool, so a
	# player who never opens the editor still deploys a fully-allocated squad —
	# which is exactly what the "all points must be used" safeguard requires.
	for s in SQUAD_SIZE:
		for t in STAT_COUNT:
			levels[s][t] = clampi(int(PRESET_BALANCED[t]), LEVEL_MIN, LEVEL_MAX)
	overrides_active = true

# ---------------------------------------------------------------------------
# Pool accounting
# ---------------------------------------------------------------------------
func points_used() -> int:
	var n := 0
	for s in SQUAD_SIZE:
		for t in STAT_COUNT:
			n += int(levels[s][t])
	return n

func points_remaining() -> int:
	return POOL_TOTAL - points_used()

# ---------------------------------------------------------------------------
# Editing — the only mutator the −/+ buttons call. Enforces the [MIN, MAX]
# floor/ceiling AND the shared pool, so it can never overspend or zero a stat.
# Returns true if anything actually changed.
# ---------------------------------------------------------------------------
func adjust(slot: int, stat: int, delta: int) -> bool:
	if slot < 0 or slot >= SQUAD_SIZE or stat < 0 or stat >= STAT_COUNT:
		return false
	var cur: int = int(levels[slot][stat])
	var want: int = clampi(cur + delta, LEVEL_MIN, LEVEL_MAX)
	if want == cur:
		return false
	# A raise must fit inside the remaining pool. Lowering always succeeds.
	if want > cur and points_remaining() < (want - cur):
		return false
	levels[slot][stat] = want
	overrides_active = true
	active_profile = -1
	_save_to_disk()
	emit_signal("config_changed")
	return true

func level_of(slot: int, stat: int) -> int:
	if slot < 0 or slot >= SQUAD_SIZE or stat < 0 or stat >= STAT_COUNT:
		return LEVEL_MIN
	return clampi(int(levels[slot][stat]), LEVEL_MIN, LEVEL_MAX)

# ---------------------------------------------------------------------------
# Cosmetic character selection (title-screen roster swap). Read by the title
# screen for portrait/name and by Main._spawn_squad for the in-game sprite.
# ---------------------------------------------------------------------------
func character_of(slot: int) -> String:
	if slot < 0 or slot >= slot_character.size():
		return CharacterRoster.default_id_for_slot(maxi(slot, 0))
	return slot_character[slot]

func set_character(slot: int, id: String) -> void:
	if slot < 0 or slot >= SQUAD_SIZE or not CharacterRoster.has_id(id):
		return
	if slot_character[slot] == id:
		return
	slot_character[slot] = id
	_save_to_disk()
	emit_signal("config_changed")

# ---------------------------------------------------------------------------
# Presets + Random
# ---------------------------------------------------------------------------
func apply_preset_balanced() -> void: _apply_uniform(PRESET_BALANCED)
func apply_preset_damage()   -> void: _apply_uniform(PRESET_DAMAGE)
func apply_preset_ranged()   -> void: _apply_uniform(PRESET_RANGED)

func _apply_uniform(row: Array) -> void:
	for s in SQUAD_SIZE:
		for t in STAT_COUNT:
			levels[s][t] = clampi(int(row[t]), LEVEL_MIN, LEVEL_MAX)
	overrides_active = true
	active_profile = -1
	_save_to_disk()
	emit_signal("config_changed")

# Reset every stat to the floor, then scatter the rest of the pool one point at
# a time into random cells that still have headroom. Guarantees the floor and
# that exactly POOL_TOTAL is spent (or as much as the ceilings allow).
func apply_random() -> void:
	for s in SQUAD_SIZE:
		for t in STAT_COUNT:
			levels[s][t] = LEVEL_MIN
	var budget := POOL_TOTAL - SQUAD_SIZE * STAT_COUNT * LEVEL_MIN
	while budget > 0:
		var open: Array = []
		for s in SQUAD_SIZE:
			for t in STAT_COUNT:
				if int(levels[s][t]) < LEVEL_MAX:
					open.append([s, t])
		if open.is_empty():
			break
		var pick: Array = open[_rng.randi() % open.size()]
		levels[pick[0]][pick[1]] += 1
		budget -= 1
	overrides_active = true
	active_profile = -1
	_save_to_disk()
	emit_signal("config_changed")

# True only when the whole pool is committed. The title screen blocks deploying
# a mission until this holds, so a player can't accidentally launch with unspent
# (i.e. underpowered) points.
func is_fully_allocated() -> bool:
	return points_remaining() == 0

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------
func profile_exists(idx: int) -> bool:
	return idx >= 0 and idx < PROFILE_COUNT and not profiles[idx].is_empty()

func profile_name(idx: int) -> String:
	if not profile_exists(idx):
		return ""
	return str(profiles[idx].get("name", "Profile %d" % (idx + 1)))

func save_profile(idx: int, pname: String = "") -> void:
	if idx < 0 or idx >= PROFILE_COUNT:
		return
	var stored: Array = []
	for s in SQUAD_SIZE:
		stored.append((levels[s] as Array).duplicate())
	var nm := pname
	if nm == "":
		nm = profile_name(idx)
	if nm == "":
		nm = "Profile %d" % (idx + 1)
	profiles[idx] = {"name": nm, "levels": stored}
	active_profile = idx
	overrides_active = true
	_save_to_disk()
	emit_signal("config_changed")

func load_profile(idx: int) -> bool:
	if not profile_exists(idx):
		return false
	var stored: Array = profiles[idx].get("levels", [])
	for s in SQUAD_SIZE:
		for t in STAT_COUNT:
			levels[s][t] = clampi(int(stored[s][t]), LEVEL_MIN, LEVEL_MAX)
	active_profile = idx
	overrides_active = true
	_save_to_disk()
	emit_signal("config_changed")
	return true

# ---------------------------------------------------------------------------
# Level → in-game value (read by Soldier._ready). Every output is > 0 for any
# level ≥ LEVEL_MIN, so the safeguard reaches all the way to gameplay.
# ---------------------------------------------------------------------------
func hp_value(slot: int) -> int:
	return level_of(slot, Stat.HP)   # pre-scale; Soldier multiplies by COMBAT_NUMBER_SCALE

func dmg_value(slot: int) -> int:
	return int(round(_lerp_stat(DMG_VALUE_MIN, DMG_VALUE_MAX, level_of(slot, Stat.DMG))))

func spd_value(slot: int) -> float:
	return _lerp_stat(SPD_VALUE_MIN, SPD_VALUE_MAX, level_of(slot, Stat.SPD))

func rng_value(slot: int) -> float:
	return _lerp_stat(RNG_VALUE_MIN, RNG_VALUE_MAX, level_of(slot, Stat.RNG))

func _lerp_stat(lo: float, hi: float, level: int) -> float:
	var t := float(level - LEVEL_MIN) / float(LEVEL_MAX - LEVEL_MIN)
	return lerpf(lo, hi, t)

# ---------------------------------------------------------------------------
# Disk persistence (ConfigFile). Levels are stored flat (24 ints) so the format
# is unambiguous and robust to clamping if the level range ever changes.
# ---------------------------------------------------------------------------
func _flatten(lv: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for s in SQUAD_SIZE:
		for t in STAT_COUNT:
			out.append(int(lv[s][t]))
	return out

func _unflatten(flat: PackedInt32Array) -> Array:
	var out: Array = []
	for s in SQUAD_SIZE:
		var row: Array = []
		for t in STAT_COUNT:
			var idx := s * STAT_COUNT + t
			var v := LEVEL_MIN
			if idx < flat.size():
				v = clampi(int(flat[idx]), LEVEL_MIN, LEVEL_MAX)
			row.append(v)
		out.append(row)
	return out

func _save_to_disk() -> void:
	var cf := ConfigFile.new()
	cf.set_value("active", "overrides_active", overrides_active)
	cf.set_value("active", "active_profile", active_profile)
	cf.set_value("active", "levels", _flatten(levels))
	cf.set_value("active", "characters", PackedStringArray(slot_character))
	for i in PROFILE_COUNT:
		var sec := "profile_%d" % i
		if profile_exists(i):
			cf.set_value(sec, "name", profiles[i]["name"])
			cf.set_value(sec, "levels", _flatten(profiles[i]["levels"]))
	cf.save(SAVE_PATH)

func _load_from_disk() -> void:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return
	for i in PROFILE_COUNT:
		var sec := "profile_%d" % i
		if cf.has_section(sec):
			profiles[i] = {
				"name": str(cf.get_value(sec, "name", "Profile %d" % (i + 1))),
				"levels": _unflatten(cf.get_value(sec, "levels", PackedInt32Array())),
			}
	if cf.has_section("active"):
		var flat: PackedInt32Array = cf.get_value("active", "levels", PackedInt32Array())
		if flat.size() == SQUAD_SIZE * STAT_COUNT:
			levels = _unflatten(flat)
		overrides_active = bool(cf.get_value("active", "overrides_active", false))
		active_profile = int(cf.get_value("active", "active_profile", -1))
		# Restore cosmetic character choices, falling back to the slot's native
		# kid for any missing/unknown id (e.g. a roster entry removed since save).
		var chars: PackedStringArray = cf.get_value("active", "characters", PackedStringArray())
		for s in SQUAD_SIZE:
			var cid := String(chars[s]) if s < chars.size() else ""
			slot_character[s] = cid if CharacterRoster.has_id(cid) \
					else CharacterRoster.default_id_for_slot(s)
