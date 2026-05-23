# =============================================================================
# Elements.gd
# Phase-1 elemental damage system. Each kid has a fixed element by slot:
#   slot 0 (Kid 1)  → FIRE
#   slot 1 (Kid 2)  → ICE
#   slot 2 (Kid 3)  → LIGHTNING
#   slot 3 (Kid 4)  → FIRE
#   slot 4 (Kid 5)  → ICE
#   slot 5 (Kid 6)  → LIGHTNING
# Pairs let the player free a "fire kid" without losing access to fire damage,
# while still rewarding squad variety.
#
# Damage modifiers are soft (×2 / ×0.5) — see the design note in
# `apply_damage`. NONE-element attacks (grenade, sacrifice, structure
# spawns) bypass the multiplier entirely.
# =============================================================================
class_name Elements

enum E { NONE, FIRE, ICE, LIGHTNING }

const SLOT_ELEMENTS: Array[int] = [
	E.FIRE,       # slot 0 — Kid 1 (Lua)
	E.ICE,        # slot 1 — Kid 2 (Friend 1)
	E.LIGHTNING,  # slot 2 — Kid 3 (Friend 2)
	E.FIRE,       # slot 3 — Kid 4 (Friend 3)
	E.ICE,        # slot 4 — Kid 5 (Friend 4)
	E.LIGHTNING,  # slot 5 — Kid 6 (Friend 5)
]

# Projectile / pip colour per element. NONE keeps white so non-elemental
# damage sources don't accidentally tint their effects.
const COLORS: Array[Color] = [
	Color(1.00, 1.00, 1.00),   # NONE
	Color(1.00, 0.45, 0.15),   # FIRE      — warm orange
	Color(0.45, 0.85, 1.00),   # ICE       — cool cyan
	Color(0.95, 0.85, 0.30),   # LIGHTNING — bright yellow
]

# Human-readable name, mostly for HUD / debug toasts later.
const NAMES: Array[String] = ["None", "Fire", "Ice", "Lightning"]

static func of_slot(slot: int) -> int:
	if slot < 0 or slot >= SLOT_ELEMENTS.size():
		return E.NONE
	return SLOT_ELEMENTS[slot]

static func color_of(element: int) -> Color:
	if element < 0 or element >= COLORS.size():
		return Color.WHITE
	return COLORS[element]

static func name_of(element: int) -> String:
	if element < 0 or element >= NAMES.size():
		return "Unknown"
	return NAMES[element]

# Soft counter — ×2 vs weakness, ×0.5 vs resistance, ×1 otherwise. Half
# damage floors at 1 so resistant enemies still die to sustained fire
# instead of becoming invulnerable to a 1-damage pistol.
static func apply_damage(amount: int, element: int, weakness: int, resistance: int) -> int:
	if element == E.NONE or amount <= 0:
		return amount
	if weakness != E.NONE and element == weakness:
		return amount * 2
	if resistance != E.NONE and element == resistance:
		return maxi(amount / 2, 1)
	return amount
