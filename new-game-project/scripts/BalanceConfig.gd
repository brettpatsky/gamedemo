# =============================================================================
# BalanceConfig.gd  (combat/balance tuning hub — preloaded as `Balance`)
# All damage, health, speed, range, cooldown, and rate numbers live here so
# tuning the game means editing one file instead of hunting through 12.
# Scripts pull these in via:  const Balance = preload("res://scripts/BalanceConfig.gd")
# then read e.g. Balance.SOLDIER_MOVE_SPEED.
#
# Scope: combat/balance numbers only. Out of scope (kept on their owning
# scripts): arena geometry (ROOM_HEIGHT, CORRIDOR_HALF_W), formation tables,
# tile coords, camera tuning, and per-soldier visual customisation (sprite
# frames, bullet colour) that needs to vary by .tscn instance.
# =============================================================================
extends Node

# -----------------------------------------------------------------------------
# Soldier — movement, health, weapons, sacrifice bomb, catch-up, auto-defend
# -----------------------------------------------------------------------------
# Squad-wide fallbacks. Soldier.gd uses these only when slot_index < 0 (debug
# / standalone scenes). Normal missions go through the *_PER_SLOT tables
# below so every kid's stats are explicit and tunable in one file.
const SOLDIER_MOVE_SPEED:       float = 215.0
const SOLDIER_MAX_HEALTH:       int   = 3
const SOLDIER_WATER_SPEED_MULT: float = 0.4

# Pistol — unlimited ammo, slow rate.
const SOLDIER_PISTOL_DAMAGE:   int   = 1
const SOLDIER_PISTOL_SPEED:    float = 700.0
const SOLDIER_PISTOL_DISTANCE: float = 2000.0
const SOLDIER_PISTOL_COOLDOWN: float = 0.5

# Rifle (AUTO) — drains shared pool, fast burst.
const SOLDIER_RIFLE_DAMAGE:   int   = 1
const SOLDIER_RIFLE_SPEED:    float = 900.0
const SOLDIER_RIFLE_DISTANCE: float = 2000.0
const SOLDIER_RIFLE_COOLDOWN: float = 0.12

# -----------------------------------------------------------------------------
# Per-soldier stat tables. Indexed by slot_index (0 = soldier_1.tscn through
# 5 = soldier_6.tscn — see TitleScreen.SOLDIER_SCENES for the canonical order).
# Soldier.gd reads from these in _ready() whenever slot_index >= 0, which is
# every spawn from Main.gd. The .tscn files no longer carry stat overrides —
# tweak balance for an individual kid here.
# -----------------------------------------------------------------------------
const SOLDIER_MAX_HEALTH_PER_SLOT:      Array[int]   = [8,     6,     2,     5,     2,     3]
const SOLDIER_MOVE_SPEED_PER_SLOT:      Array[float] = [215.0, 215.0, 215.0, 215.0, 215.0, 215.0]
const SOLDIER_PISTOL_DAMAGE_PER_SLOT:   Array[int]   = [4,     1,     2,     2,     1,     1]
const SOLDIER_PISTOL_SPEED_PER_SLOT:    Array[float] = [900.0, 650.0, 800.0, 650.0, 900.0, 700.0]
const SOLDIER_PISTOL_DISTANCE_PER_SLOT: Array[float] = [1800.0, 700.0, 1400.0, 800.0, 800.0, 1000.0]
const SOLDIER_RIFLE_DAMAGE_PER_SLOT:    Array[int]   = [5,     1,     2,     2,     1,     3]
const SOLDIER_RIFLE_SPEED_PER_SLOT:     Array[float] = [1100.0, 850.0, 950.0, 850.0, 1000.0, 1100.0]
const SOLDIER_RIFLE_DISTANCE_PER_SLOT:  Array[float] = [2500.0, 900.0, 1600.0, 1000.0, 1000.0, 2000.0]
# Bullet colour is shown on the kid's bio-card name and on the autodefend
# tracer. Player-controlled fire uses the kid's element colour instead
# (see Elements.color_of).
const SOLDIER_BULLET_COLOR_PER_SLOT: Array[Color] = [
	Color(1.0,  0.95, 0.2),   # slot 0 — soldier_1 — yellow
	Color(1.0,  1.0,  1.0),   # slot 1 — soldier_2 — white
	Color(0.3,  0.9,  1.0),   # slot 2 — soldier_3 — cyan
	Color(1.0,  0.55, 0.1),   # slot 3 — soldier_4 — orange
	Color(0.3,  1.0,  0.4),   # slot 4 — soldier_5 — green
	Color(1.0,  0.3,  0.9),   # slot 5 — soldier_6 — magenta
]

# Grenade — per-soldier ammo, slow throw.
const SOLDIER_GRENADE_AMMO_MAX: int   = 5
const SOLDIER_GRENADE_COOLDOWN: float = 2.0

# Sacrifice (walking bomb) — soldier sprints to target then detonates.
const SACRIFICE_SPEED_MULT:   float = 1.6
const SACRIFICE_RADIUS:       float = 200.0
const SACRIFICE_DAMAGE:       int   = 15
const SACRIFICE_ARRIVAL_DIST: float = 24.0
const SACRIFICE_FX_TIME:      float = 0.65
# Safety net: if the bomber can't reach the click point (path blocked, click
# landed inside geometry, etc.), detonate where they are after this long
# instead of running forever.
const SACRIFICE_TIMEOUT:      float = 6.0

# Stuck detection / sidestep unstick. The sidestep handles most short
# wedges; after STUCK_HARD_STRIKES consecutive failed checks (≈3 s with
# default 0.5 s interval) we hard-unstick by teleporting along the path.
const SOLDIER_STUCK_CHECK_INTERVAL: float = 0.5
const SOLDIER_STUCK_THRESHOLD:      float = 8.0
const SOLDIER_UNSTICK_DURATION:     float = 0.35
const SOLDIER_STUCK_HARD_STRIKES:   int   = 6

# Rubberbanding (catch-up sprint). Stragglers smoothly ramp from base speed at
# CATCHUP_NEAR distance from squad centroid to full bonus at CATCHUP_FAR.
const SOLDIER_CATCHUP_SPEED_MULT: float = 1.5
const SOLDIER_CATCHUP_NEAR:       float = 110.0
const SOLDIER_CATCHUP_FAR:        float = 320.0

# Auto-defend — idle-group soldiers return fire on nearby enemies.
const SOLDIER_AUTODEFEND_RANGE:    float = 280.0
const SOLDIER_AUTODEFEND_COOLDOWN: float = 1.5
const SOLDIER_AUTODEFEND_JITTER:   float = 0.35

# Animation flash duration after firing.
const SOLDIER_SHOOT_FLASH_DURATION: float = 0.18

# -----------------------------------------------------------------------------
# Enemy
# -----------------------------------------------------------------------------
const ENEMY_MOVE_SPEED:         float = 105.0
const ENEMY_MAX_HEALTH:         int   = 2
const ENEMY_SIGHT_RANGE:        float = 480.0
const ENEMY_ATTACK_RANGE:       float = 280.0
const ENEMY_SCORE_VALUE:        int   = 10
const ENEMY_AIM_JITTER:         float = 0.22
const ENEMY_BULLET_SPEED:       float = 500.0
const ENEMY_BULLET_DISTANCE:    float = 300.0
const ENEMY_BULLET_DAMAGE:      int   = 1
const ENEMY_PATROL_INTERVAL:    float = 3.0
const ENEMY_SHOOT_COOLDOWN:     float = 0.45
const ENEMY_TARGET_SCAN_PERIOD: float = 0.4
const ENEMY_WATER_SPEED_MULT:   float = 0.4

# Strafing in ATTACK — sliding sideways while shooting instead of standing
# still. Picks a new direction every STRAFE_MIN..MAX_TIME seconds.
const ENEMY_STRAFE_MIN_TIME:    float = 0.7
const ENEMY_STRAFE_MAX_TIME:    float = 1.8
const ENEMY_STRAFE_SPEED_MULT:  float = 0.55

# Alert pulse — when an enemy first sees the squad, nearby patrolling
# enemies snap into ALERT too. Eliminates the trickle of one-at-a-time
# engagements when the squad crosses into a populated zone.
const ENEMY_ALERT_PULSE_RADIUS: float = 380.0

# Stuck detection (same shape as the soldier version).
const ENEMY_STUCK_CHECK_INTERVAL: float = 0.5
const ENEMY_STUCK_THRESHOLD:      float = 6.0
const ENEMY_STUCK_HARD_STRIKES:   int   = 6

# -----------------------------------------------------------------------------
# Escort NPC — stuck detection so the VIP doesn't snag forever on a tree.
# -----------------------------------------------------------------------------
const NPC_STUCK_CHECK_INTERVAL: float = 0.5
const NPC_STUCK_THRESHOLD:      float = 6.0
const NPC_STUCK_HARD_STRIKES:   int   = 6

# -----------------------------------------------------------------------------
# Bullet — defaults used by enemy bullets and as a fallback before a soldier
# calls set_stats() with their per-weapon values.
# -----------------------------------------------------------------------------
const BULLET_SPEED:        float = 600.0
const BULLET_DAMAGE:       int   = 1
const BULLET_MAX_DISTANCE: float = 1500.0

# -----------------------------------------------------------------------------
# Boss — Heartstone (Level 7)
# -----------------------------------------------------------------------------
const BOSS_MAX_HEALTH:        int = 360
const BOSS_PHASE_2_THRESHOLD: int = 240
const BOSS_PHASE_3_THRESHOLD: int = 120

# Phase 1 — telegraphed AOE pattern timing.
const BOSS_PHASE1_WARN:   float = 1.8
const BOSS_PHASE1_DAMAGE: float = 2.0
const BOSS_PHASE1_PAUSE:  float = 0.6

# Phase 2 — orbiting totems and sludge pools.
const BOSS_TOTEM_COUNT:        int   = 3
const BOSS_TOTEM_RADIUS:       float = 280.0
const BOSS_TOTEM_ORBIT_SPEED:  float = 0.30
const BOSS_SLUDGE_COUNT:       int   = 3
const BOSS_SLUDGE_RADIUS_RING: float = 240.0

# Phase 3 — projectile spiral + Void Embrace channel.
const BOSS_PROJECTILE_INTERVAL:     float = 0.16
const BOSS_VOID_PRE_DELAY:          float = 5.0
const BOSS_VOID_CHANNEL_TIME:       float = 15.0
const BOSS_VOID_COOLDOWN_AFTER_INT: float = 4.0
const BOSS_VOID_INTERRUPT_DMG:      int   = 8
const BOSS_VOID_WIPE_DAMAGE:        int   = 9999

# -----------------------------------------------------------------------------
# Memory Totem (Boss Phase 2 objective)
# -----------------------------------------------------------------------------
const TOTEM_MAX_HEALTH: int   = 80
const TOTEM_REGEN_RATE: float = 6.0

# -----------------------------------------------------------------------------
# Sludge Pool (Boss Phase 2 hazard)
# -----------------------------------------------------------------------------
const SLUDGE_RADIUS:          float = 90.0
const SLUDGE_DRAIN_RATE:      float = 14.0   # rifle ammo siphoned per second per soldier inside
const SLUDGE_DAMAGE_TICK:     float = 0.8
const SLUDGE_DAMAGE_PER_TICK: int   = 1

# -----------------------------------------------------------------------------
# Phase Danger Zone (Boss Phase 1 AOE)
# -----------------------------------------------------------------------------
const ZONE_RADIUS:          float = 150.0
const ZONE_DAMAGE_TICK:     float = 0.4
const ZONE_DAMAGE_PER_TICK: int   = 1

# -----------------------------------------------------------------------------
# Grenade (squad weapon)
# -----------------------------------------------------------------------------
const GRENADE_SPEED:            float = 250.0
const GRENADE_ARC_HEIGHT:       float = 80.0
const GRENADE_EXPLOSION_RADIUS: float = 110.0
const GRENADE_DAMAGE:           int   = 12
# Memory totems regen too fast for pistols. Grenades get a heavy bonus so a
# single throw cracks a totem shield (80 → 20 HP).
const GRENADE_TOTEM_DAMAGE:     int   = 60
const GRENADE_SHOW_TIME:        float = 0.3

# -----------------------------------------------------------------------------
# Eldritch Projectile (Boss Phase 3 spiral attack)
# -----------------------------------------------------------------------------
const PROJECTILE_SPEED:        float = 280.0
const PROJECTILE_DAMAGE:       int   = 1
const PROJECTILE_MAX_LIFETIME: float = 6.0
const PROJECTILE_RADIUS:       float = 12.0

# -----------------------------------------------------------------------------
# Per-mission loadout overrides (applied in Main.gd)
# -----------------------------------------------------------------------------
const LOADOUT_BOSS_RIFLE_POOL:   int = 600
const LOADOUT_BOSS_GRENADE_AMMO: int = 15
