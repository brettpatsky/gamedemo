# =============================================================================
# ObjectiveManager.gd
# Autoload singleton — persists across scene reloads.
# Owns the objective event signals. Level state lives in GameManager so that
# on_enemy_died() can check it without a cross-autoload reference.
#
# FortifiedStructure._destroy()    → objective_complete.emit()  (Level 2)
# ExtractionZone._on_npc_arrived() → objective_complete.emit()  (Level 3)
# NPCEscort._die()                 → objective_failed.emit()    (Level 3)
# =============================================================================
extends Node

@warning_ignore("unused_signal") signal objective_complete
@warning_ignore("unused_signal") signal objective_failed

func advance_level() -> void:
	GameManager.current_level = min(GameManager.current_level + 1, 3)
