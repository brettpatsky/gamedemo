# =============================================================================
# BalanceConfig.gd  —  single source of truth for tuning numbers.
# Preloaded as `Balance`:
#   const Balance = preload("res://scripts/BalanceConfig.gd")
#   Balance.SOLDIER_MOVE_SPEED
#
# Anything a designer might want to tweak without reading the surrounding
# code lives here. Per-soldier stats are split into *_PER_SLOT tables so each
# kid is tuned independently in one place.
#
# Scope: balance + tunable visual/atmosphere knobs.
# Out of scope (kept on their owning scripts): scene geometry (arena
# dimensions baked into tscn), formation tables (data shape, not a number),
# tile coords, asset paths, and per-instance editor exports that one map or
# scene needs but the rest of the game doesn't.
# =============================================================================
extends Node

# -----------------------------------------------------------------------------
# COMBAT NUMBER SCALE
# -----------------------------------------------------------------------------
# Single multiplier applied to every HP value and damage value at runtime.
# Lets the per-slot / per-weapon tables below stay readable (1..8 range) while
# the on-screen floating damage numbers and HP bars feel punchier. Balance is
# preserved because both sides scale by the same amount. Tweak this one knob
# to make hits feel chunkier or flatter — gameplay tuning never has to change.
const COMBAT_NUMBER_SCALE: int = 7

# -----------------------------------------------------------------------------
# SOLDIER — squad-wide defaults
# -----------------------------------------------------------------------------
# Every value here is the FALLBACK used when slot_index < 0. Normal mission
# spawns go through the per-slot tables below, so editing these only affects
# standalone test scenes that drop a Soldier without assigning a slot.
const SOLDIER_MOVE_SPEED:       float = 215.0   # px / s while not catching up
const SOLDIER_MAX_HEALTH:       int   = 3       # HP at full
const SOLDIER_WATER_SPEED_MULT: float = 0.4     # multiplier while wading; 1.0 = no slowdown

# Pistol — unlimited ammo, slow rate.
const SOLDIER_PISTOL_DAMAGE:   int   = 1        # damage per bullet
const SOLDIER_PISTOL_SPEED:    float = 700.0    # bullet travel speed (px/s)
const SOLDIER_PISTOL_DISTANCE: float = 2000.0   # bullet max travel (px)
const SOLDIER_PISTOL_COOLDOWN: float = 0.5      # seconds between shots

# Rifle (AUTO) — drains shared rifle_ammo_pool in GameManager, fast burst.
const SOLDIER_RIFLE_DAMAGE:   int   = 1
const SOLDIER_RIFLE_SPEED:    float = 900.0
const SOLDIER_RIFLE_DISTANCE: float = 2000.0
const SOLDIER_RIFLE_COOLDOWN: float = 0.12      # very fast — pool burns quickly
const SOLDIER_RIFLE_AMMO_MAX: int   = 300       # squad-wide pool per mission

# Grenade — squad-wide shared pool, heavy throw.
const SOLDIER_GRENADE_AMMO_MAX: int   = 10      # squad-wide pool per mission
const SOLDIER_GRENADE_COOLDOWN: float = 0.5     # quick lobs so the player can react in a firefight

# -----------------------------------------------------------------------------
# SOLDIER — per-slot stat tables
# -----------------------------------------------------------------------------
# Indexed by slot_index (0 = soldier_1.tscn through 5 = soldier_6.tscn).
# Soldier.gd reads from these in _ready() whenever slot_index >= 0, which is
# every normal mission spawn. The .tscn files no longer carry stat overrides;
# tweak per-kid balance HERE. Each kid's "feel" is the sum of these rows.
const SOLDIER_MAX_HEALTH_PER_SLOT:      Array[int]   = [8,     6,     2,     5,     2,     3]
const SOLDIER_MOVE_SPEED_PER_SLOT:      Array[float] = [215.0, 215.0, 215.0, 215.0, 215.0, 215.0]
const SOLDIER_PISTOL_DAMAGE_PER_SLOT:   Array[int]   = [4,     1,     2,     2,     1,     1]
const SOLDIER_PISTOL_SPEED_PER_SLOT:    Array[float] = [900.0, 650.0, 800.0, 650.0, 900.0, 700.0]
const SOLDIER_PISTOL_DISTANCE_PER_SLOT: Array[float] = [1800.0, 700.0, 1400.0, 800.0, 800.0, 1000.0]
const SOLDIER_RIFLE_DAMAGE_PER_SLOT:    Array[int]   = [5,     1,     2,     2,     1,     3]
const SOLDIER_RIFLE_SPEED_PER_SLOT:     Array[float] = [1100.0, 850.0, 950.0, 850.0, 1000.0, 1100.0]
const SOLDIER_RIFLE_DISTANCE_PER_SLOT:  Array[float] = [2500.0, 900.0, 1600.0, 1000.0, 1000.0, 2000.0]
# Shown on the kid's bio-card name (title screen) and on the autodefend
# tracer. Player-directed fire colours its bullet by ELEMENT instead — see
# Elements.color_of() — so this is mostly cosmetic identity.
const SOLDIER_BULLET_COLOR_PER_SLOT: Array[Color] = [
	Color(1.0,  0.95, 0.2),   # slot 0 — soldier_1 — yellow
	Color(1.0,  1.0,  1.0),   # slot 1 — soldier_2 — white
	Color(0.3,  0.9,  1.0),   # slot 2 — soldier_3 — cyan
	Color(1.0,  0.55, 0.1),   # slot 3 — soldier_4 — orange
	Color(0.3,  1.0,  0.4),   # slot 4 — soldier_5 — green
	Color(1.0,  0.3,  0.9),   # slot 5 — soldier_6 — magenta
]

# -----------------------------------------------------------------------------
# SACRIFICE (walking bomb weapon)
# -----------------------------------------------------------------------------
# When SACRIFICE is selected, the closest soldier sprints to the click point
# and detonates on arrival (or on death, or after the timeout). Drains a kid.
const SACRIFICE_SPEED_MULT:   float = 1.6   # sprint multiplier vs base move speed
const SACRIFICE_RADIUS:       float = 200.0 # damage / FX radius (px)
const SACRIFICE_DAMAGE:       int   = 15    # to every target in radius
const SACRIFICE_ARRIVAL_DIST: float = 24.0  # detonate once within this distance
const SACRIFICE_FX_TIME:      float = 0.65  # explosion flash duration
# Safety net for unreachable target (path blocked, click inside geometry):
# detonate where the bomber is after this long instead of running forever.
const SACRIFICE_TIMEOUT:      float = 2.0

# -----------------------------------------------------------------------------
# SOLDIER — stuck detection / unstick
# -----------------------------------------------------------------------------
# Soldiers can wedge against rocks or each other in tight corridors. The
# sidestep handles most short hangs; HARD_STRIKES escalates to a path-teleport.
const SOLDIER_STUCK_CHECK_INTERVAL: float = 0.5   # how often we sample position
const SOLDIER_STUCK_THRESHOLD:      float = 12.0   # px moved < this in interval = stuck
const SOLDIER_UNSTICK_DURATION:     float = 0.35  # how long the sidestep nudge lasts
const SOLDIER_STUCK_HARD_STRIKES:   int   = 4     # consecutive strikes → teleport

# -----------------------------------------------------------------------------
# SOLDIER — catch-up rubberbanding
# -----------------------------------------------------------------------------
# Stragglers smoothly ramp from base speed (near the squad centroid) up to
# CATCHUP_SPEED_MULT at CATCHUP_FAR away. Stops slow kids being left behind
# without making the whole squad sprint constantly.
const SOLDIER_CATCHUP_SPEED_MULT: float = 1.5
const SOLDIER_CATCHUP_NEAR:       float = 110.0  # below this distance, no bonus
const SOLDIER_CATCHUP_FAR:        float = 320.0  # at this distance, full bonus

# -----------------------------------------------------------------------------
# SOLDIER — autodefend (idle-group return fire)
# -----------------------------------------------------------------------------
# Soldiers not in the actively-commanded group fire their pistol at any enemy
# inside RANGE. Tuned much slower than player fire so unattended groups feel
# unattended, while still being able to defend themselves.
const SOLDIER_AUTODEFEND_RANGE:    float = 280.0
const SOLDIER_AUTODEFEND_COOLDOWN: float = 1.5
const SOLDIER_AUTODEFEND_JITTER:   float = 0.35  # radians of aim wobble

# Visual flash after firing (sprite stays on the "shoot" frame this long).
const SOLDIER_SHOOT_FLASH_DURATION: float = 0.18

# -----------------------------------------------------------------------------
# ENEMY
# -----------------------------------------------------------------------------
const ENEMY_MOVE_SPEED:         float = 105.0
const ENEMY_MAX_HEALTH:         int   = 2
const ENEMY_SIGHT_RANGE:        float = 480.0   # detect squad past this → ALERT
const ENEMY_ATTACK_RANGE:       float = 280.0   # close to within this → ATTACK
const ENEMY_SCORE_VALUE:        int   = 10
const ENEMY_AIM_JITTER:         float = 0.22    # radians; higher = worse shots
const ENEMY_BULLET_SPEED:       float = 500.0
const ENEMY_BULLET_DISTANCE:    float = 300.0
const ENEMY_BULLET_DAMAGE:      int   = 1
const ENEMY_PATROL_INTERVAL:    float = 3.0     # seconds between patrol waypoints
const ENEMY_SHOOT_COOLDOWN:     float = 0.45
const ENEMY_TARGET_SCAN_PERIOD: float = 0.4     # how often ATTACK re-picks target
const ENEMY_WATER_SPEED_MULT:   float = 0.4

# Strafing while in ATTACK — slides sideways for a bit then re-picks.
const ENEMY_STRAFE_MIN_TIME:    float = 0.7
const ENEMY_STRAFE_MAX_TIME:    float = 1.8
const ENEMY_STRAFE_SPEED_MULT:  float = 0.55

# When an enemy spots the squad, every patrolling enemy inside this radius
# also snaps to ALERT. Avoids the slow trickle of one-at-a-time engagements.
const ENEMY_ALERT_PULSE_RADIUS: float = 380.0

# Stuck detection mirrors the soldier shape (just retuned for enemy threshold).
const ENEMY_STUCK_CHECK_INTERVAL: float = 0.5
const ENEMY_STUCK_THRESHOLD:      float = 6.0
const ENEMY_STUCK_HARD_STRIKES:   int   = 6

# -----------------------------------------------------------------------------
# ESCORT NPC
# -----------------------------------------------------------------------------
# Same stuck-detection shape as soldiers so the VIP doesn't snag on a tree.
const NPC_STUCK_CHECK_INTERVAL: float = 0.5
const NPC_STUCK_THRESHOLD:      float = 6.0
const NPC_STUCK_HARD_STRIKES:   int   = 6

# -----------------------------------------------------------------------------
# BULLET — defaults
# -----------------------------------------------------------------------------
# Used by enemy bullets and as a fallback before a soldier calls set_stats
# with their per-weapon values.
const BULLET_SPEED:        float = 600.0
const BULLET_DAMAGE:       int   = 1
const BULLET_MAX_DISTANCE: float = 1500.0

# -----------------------------------------------------------------------------
# BOSS — The Weeping Heart (Level 7)
# -----------------------------------------------------------------------------
const BOSS_MAX_HEALTH:        int = 360
const BOSS_PHASE_2_THRESHOLD: int = 240   # HP at which Phase 2 starts
const BOSS_PHASE_3_THRESHOLD: int = 120   # HP at which Phase 3 starts

# Phase 1 — telegraphed AOE pattern.
const BOSS_PHASE1_WARN:   float = 1.8   # warning circle lead time
const BOSS_PHASE1_DAMAGE: float = 2.0   # damage hit lasts this long
const BOSS_PHASE1_PAUSE:  float = 0.6   # cooldown between AOE bursts

# Phase 2 — orbiting totems + sludge pools.
const BOSS_TOTEM_COUNT:        int   = 3
const BOSS_TOTEM_RADIUS:       float = 280.0   # mean orbit radius
const BOSS_TOTEM_ORBIT_SPEED:  float = 0.30    # rad/s — mean angular speed
# Per-totem chaos so the squad can't lead shots on a metronome. Each totem
# picks its own angular velocity in [SPEED - SPREAD, SPEED + SPREAD * 2] and
# re-rolls every REROLL_TIME seconds; its radius wobbles by ± WOBBLE px.
const BOSS_TOTEM_SPEED_SPREAD: float = 0.45    # rad/s deviation per re-roll
const BOSS_TOTEM_REROLL_TIME:  float = 2.2     # seconds between velocity re-rolls
const BOSS_TOTEM_RADIUS_WOBBLE: float = 60.0   # peak in/out drift from BOSS_TOTEM_RADIUS
const BOSS_TOTEM_WOBBLE_SPEED:  float = 1.5    # rad/s of the radius sine
const BOSS_SLUDGE_COUNT:       int   = 4
const BOSS_SLUDGE_RADIUS_RING: float = 240.0   # ring radius where pools spawn
# Wandering sludge — free-roams the entire boss room so nowhere is safe.
const BOSS_SLUDGE_DRIFT_SPEED: float = 130.0   # px/s while seeking next target

# Phase 3 — projectile spiral + Void Embrace channel.
const BOSS_PROJECTILE_INTERVAL:     float = 0.16  # seconds between spiral shots
const BOSS_VOID_PRE_DELAY:          float = 5.0   # warning window before channel
const BOSS_VOID_CHANNEL_TIME:       float = 15.0  # players have this long to interrupt
const BOSS_VOID_COOLDOWN_AFTER_INT: float = 4.0   # rest period after interrupt
const BOSS_VOID_INTERRUPT_DMG:      int   = 8     # cumulative damage required to interrupt
const BOSS_VOID_WIPE_DAMAGE:        int   = 9999  # uninterrupted channel = squad wipe

# -----------------------------------------------------------------------------
# MEMORY TOTEM  (Boss Phase 2 objective)
# -----------------------------------------------------------------------------
const TOTEM_MAX_HEALTH: int   = 80
const TOTEM_REGEN_RATE:          float = 6.0   # HP/s regenerated if not actively damaged
const TOTEM_CONTACT_DAMAGE:      int   = 35    # damage per tick when a soldier touches an orb
const TOTEM_CONTACT_INTERVAL:    float = 0.6   # seconds between contact damage ticks

# -----------------------------------------------------------------------------
# SLUDGE POOL  (Boss Phase 2 hazard)
# -----------------------------------------------------------------------------
const SLUDGE_RADIUS:          float = 90.0
const SLUDGE_DRAIN_RATE:      float = 14.0   # rifle ammo siphoned/s per soldier inside
const SLUDGE_DAMAGE_TICK:     float = 0.8    # seconds between damage ticks
const SLUDGE_DAMAGE_PER_TICK: int   = 1

# -----------------------------------------------------------------------------
# PHASE DANGER ZONE  (Boss Phase 1 AOE)
# -----------------------------------------------------------------------------
const ZONE_RADIUS:          float = 150.0
const ZONE_DAMAGE_TICK:     float = 0.4
const ZONE_DAMAGE_PER_TICK: int   = 1

# -----------------------------------------------------------------------------
# GRENADE  (squad weapon)
# -----------------------------------------------------------------------------
const GRENADE_SPEED:            float = 600.0   # px/s during arc — fast enough to feel like a lob, not a balloon
const GRENADE_ARC_HEIGHT:       float = 80.0    # peak visual height
const GRENADE_EXPLOSION_RADIUS: float = 140.0
const GRENADE_MAX_RANGE:        float = 500.0   # clicks past this clamp to the rim — no full-screen lobs
const GRENADE_DAMAGE:           int   = 12
# Memory totems regen too fast for pistols. Grenades get a heavy bonus so a
# single throw cracks a totem shield (80 → 20 HP).
const GRENADE_TOTEM_DAMAGE:     int   = 60
const GRENADE_SHOW_TIME:        float = 0.3     # FX persistence after detonation

# -----------------------------------------------------------------------------
# ELDRITCH PROJECTILE  (Boss Phase 3 spiral attack)
# -----------------------------------------------------------------------------
const PROJECTILE_SPEED:        float = 280.0
const PROJECTILE_DAMAGE:       int   = 1
const PROJECTILE_MAX_LIFETIME: float = 6.0
const PROJECTILE_RADIUS:       float = 12.0

# -----------------------------------------------------------------------------
# PER-MISSION LOADOUT OVERRIDES  (applied in Main.gd)
# -----------------------------------------------------------------------------
# Used by the boss mission to hand the squad enough rifle ammo / grenades to
# actually clear the encounter — defaults would starve them.
const LOADOUT_BOSS_RIFLE_POOL:   int = 600
const LOADOUT_BOSS_GRENADE_AMMO: int = 90    # squad-wide pool override for the boss mission (was 15 per soldier × 6)

# =============================================================================
# MAP DIMENSIONS
# =============================================================================

# Auto-generated (procedural) maps — tile size matches the world tileset
# (spritesheet_tiles.png) which uses 64×64 atlas cells.
const MAP_AUTO_WIDTH:     int = 55
const MAP_AUTO_HEIGHT:    int = 50
const MAP_AUTO_TILE_SIZE: int = 64

# Handcrafted maps use the 16×16 Caraka tileset displayed at 2× scale.
# TileMapLayers are scaled Vector2(2,2) so each 16 px art cell renders at 32 px.
# tile_size = 32 (the effective visual size) so camera/nav calculations match.
# World footprint stays identical to auto-gen: 110×32×2 = 3520 px wide.
const MAP_HANDCRAFTED_WIDTH:     int = 110
const MAP_HANDCRAFTED_HEIGHT:    int = 100
const MAP_HANDCRAFTED_TILE_SIZE: int = 32

# =============================================================================
# TERRAIN — gameplay (range / slope) and visual hill-shade
# =============================================================================

# -----------------------------------------------------------------------------
# TERRAIN — elevation gameplay
# -----------------------------------------------------------------------------
# Raw elevation noise sits in [-1, 1]. Tiles past HILL_THRESHOLD give the
# shooter a bullet-range bonus; below VALLEY_THRESHOLD they pay a penalty.
# Move the thresholds toward 0 to make hill/valley terrain more common.
const HILL_THRESHOLD:    float = 0.18
const VALLEY_THRESHOLD:  float = -0.18
const HILL_RANGE_MULT:   float = 1.35   # > 1 = bullets travel further from a hill
const VALLEY_RANGE_MULT: float = 0.70   # < 1 = bullets cut short in a valley

# Slope-based movement modulation. Soldier/enemy speed gets multiplied by
# (1 - slope * SCALE), clamped to [MIN, MAX]. Wider clamp = sharper hills.
const SLOPE_SPEED_SCALE: float = 1.25
const SLOPE_SPEED_MIN:   float = 0.75   # steepest uphill multiplier
const SLOPE_SPEED_MAX:   float = 1.25   # steepest downhill multiplier

# -----------------------------------------------------------------------------
# TERRAIN — elevation heightmap (Perlin noise, backend data layer)
# -----------------------------------------------------------------------------
# Elevation is a continuous Perlin heightmap sampled in tile-space, generated
# independently of the 2D tile rendering (see MapGenerator._init_elevation).
# One noise unit ≈ one map tile, so FREQUENCY is in cycles-per-tile: lower =
# broader, gentler swells. 0.045 ≈ a 22-tile wavelength, giving ~4-5 distinct
# hills across a 110-tile handcrafted map.
const ELEV_NOISE_FREQUENCY:  float = 0.024   # broad swells → plateaus big enough to fight on / fit stairs
const ELEV_NOISE_OCTAVES:    int   = 2      # fractal detail layered on the base swell — low for smooth rolling hills
const ELEV_NOISE_LACUNARITY: float = 2.0    # frequency multiplier per octave
const ELEV_NOISE_GAIN:       float = 0.5    # amplitude falloff per octave (lower = smoother)

# Slope is the directional derivative of the heightmap, taken by central
# finite-difference this many tiles to either side of the sample point. Larger
# = smoother / more averaged slope response.
const ELEV_SLOPE_SAMPLE_TILES: float = 1.5

# -----------------------------------------------------------------------------
# TERRAIN — discrete elevation tiers (Zelda-style cliffs + stairs)
# -----------------------------------------------------------------------------
# The continuous heightmap (above) is quantised into flat height TIERS. Tier
# boundaries are rendered as vertical cliff faces with a drop shadow; stairs are
# carved through cliffs so every plateau stays reachable. A cell's tier = the
# number of thresholds its elevation exceeds, so TIER_COUNT = thresholds + 1.
# Designed to scale to 3 tiers later (e.g. hide parents/totems up top) — just
# bump the count and add a threshold.
const ELEV_TIER_COUNT:      int = 2
const ELEV_TIER_THRESHOLDS: Array = [0.32]   # size == TIER_COUNT - 1, ascending; 3 tiers e.g. [0.10, 0.45]

# Plateaus smaller than this (per side, in tiles) get dissolved back into the
# surrounding lower tier, so cliffs autotile cleanly and stairs have room.
const ELEV_TIER_MIN_BLOCK:  int = 6

# Height of a cliff face in tiles (cap + faces + base occupy this many low cells
# south of a plateau edge). 2 = cap+base; 3 adds a face row for taller drops.
# 3 matches the 3-tall Steps nine-slice so staircases fill the face cleanly.
const ELEV_CLIFF_FACE_TILES: int = 3

# Width (in tiles) of a carved staircase. The Steps art is a 3-wide nine-slice,
# so 3 stamps cleanly; wider repeats the middle column.
const ELEV_STAIR_WIDTH: int = 6

# Drop-shadow cast on the low ground at the foot of a cliff (alpha-blended).
const ELEV_CLIFF_SHADOW_COLOR: Color = Color(0.04, 0.05, 0.10, 0.45)

# =============================================================================
# AMBIENT — birds, critters, weather. Purely cosmetic atmosphere layer.
# =============================================================================

# -----------------------------------------------------------------------------
# AMBIENT — bird flock cadence and flight feel
# -----------------------------------------------------------------------------
# Birds spawn off-screen, cross the camera in a loose flock, and despawn.
# Cadence is random in [MIN, MAX]; lower = busier sky.
const AMBIENT_BIRD_FLOCK_MIN_SEC: float = 8.0
const AMBIENT_BIRD_FLOCK_MAX_SEC: float = 18.0
# Per-bird flight speed; randomised per bird at spawn.
const AMBIENT_BIRD_SPEED_MIN: float = 130.0
const AMBIENT_BIRD_SPEED_MAX: float = 220.0
const AMBIENT_BIRD_FLAP_RATE: float = 7.0     # wing-flap cycles/s
# Where birds sit on screen as a fraction of the view half-height. -0.85 =
# near the top of the screen; 0 = on the horizon; positive = below camera.
const AMBIENT_BIRD_SKY_BAND_RATIO: float = -0.85
# Drop-shadow proportions (ellipse offset+radii below the bird).
const AMBIENT_BIRD_SHADOW_OFFSET_Y: float = 150.0
const AMBIENT_BIRD_SHADOW_RADIUS_X: float = 7.5
const AMBIENT_BIRD_SHADOW_RADIUS_Y: float = 2.5
# Silhouette colour. Tweak alpha for "sunny day" vs "stormy" reads.
const AMBIENT_BIRD_BODY_COLOR: Color = Color(0.08, 0.08, 0.10, 0.75)

# -----------------------------------------------------------------------------
# AMBIENT — wandering critters (rabbit-ish)
# -----------------------------------------------------------------------------
# Target population on each map. AmbientLayer tops up any that despawn.
const AMBIENT_CRITTER_TARGET: int = 4
# Walk / sprint pacing. Sprint kicks in when a bullet whizzes past.
const AMBIENT_CRITTER_MOVE_SPEED:   float = 55.0
const AMBIENT_CRITTER_SPRINT_SPEED: float = 160.0
# How long they pause between wander hops (random in [MIN, MAX]).
const AMBIENT_CRITTER_PAUSE_MIN: float = 1.5
const AMBIENT_CRITTER_PAUSE_MAX: float = 4.0
# Wander distance per hop (random in [MIN, MAX]).
const AMBIENT_CRITTER_WANDER_MIN: float = 60.0
const AMBIENT_CRITTER_WANDER_MAX: float = 180.0
# Bullets within SPOOK_RADIUS make the critter sprint FLEE_DIST away for
# SCARED_TIME seconds. Bigger SPOOK_RADIUS = jumpier critters.
const AMBIENT_CRITTER_SPOOK_RADIUS: float = 80.0
const AMBIENT_CRITTER_SCARED_TIME:  float = 1.5
const AMBIENT_CRITTER_FLEE_DIST:    float = 130.0
# Attempts to re-roll wander targets that landed on water before giving up.
const AMBIENT_CRITTER_WATER_RETRIES: int = 5

# -----------------------------------------------------------------------------
# WEATHER — emission window
# -----------------------------------------------------------------------------
# Extra px past the visible viewport that weather emits into and fog covers,
# so neither shows a hard seam at the screen edge during a camera pan.
const WEATHER_VIEW_PADDING: float = 220.0

# -----------------------------------------------------------------------------
# WEATHER — RAIN (CPUParticles2D)
# -----------------------------------------------------------------------------
# Particle count; higher = denser rainfall. Cheap on modern hardware.
const WEATHER_RAIN_AMOUNT:   int   = 500
const WEATHER_RAIN_LIFETIME: float = 0.9
# Spawn direction — tiny rightward bias for wind-driven rain. spread is the
# cone (degrees) particles deviate from `direction`.
const WEATHER_RAIN_DIRECTION: Vector2 = Vector2(0.18, 1.0)
const WEATHER_RAIN_SPREAD:    float   = 4.0
# Vertical fall — initial velocity range + persistent gravity. Together
# these set how fast the rain feels and how much depth-streak it shows.
const WEATHER_RAIN_VELOCITY_MIN: float = 320.0
const WEATHER_RAIN_VELOCITY_MAX: float = 460.0
const WEATHER_RAIN_GRAVITY:      Vector2 = Vector2(0.0, 700.0)
# Per-particle sprite scale; randomised in [MIN, MAX] at spawn.
const WEATHER_RAIN_SCALE_MIN: float = 1.0
const WEATHER_RAIN_SCALE_MAX: float = 1.5

# -----------------------------------------------------------------------------
# WEATHER — SNOW (CPUParticles2D)
# -----------------------------------------------------------------------------
const WEATHER_SNOW_AMOUNT:   int   = 320
const WEATHER_SNOW_LIFETIME: float = 2.8
const WEATHER_SNOW_DIRECTION: Vector2 = Vector2(0.25, 1.0)
const WEATHER_SNOW_SPREAD:    float   = 35.0   # wider cone = "tumbling" flakes
# Lighter velocity + gravity than rain so flakes drift rather than plummet.
const WEATHER_SNOW_VELOCITY_MIN: float = 15.0
const WEATHER_SNOW_VELOCITY_MAX: float = 45.0
const WEATHER_SNOW_GRAVITY:      Vector2 = Vector2(0.0, 40.0)
# Sideways drift — gives each flake a little randomised lateral wobble.
const WEATHER_SNOW_TANGENTIAL_MIN: float = -25.0
const WEATHER_SNOW_TANGENTIAL_MAX: float = 25.0
const WEATHER_SNOW_SCALE_MIN: float = 1.8
const WEATHER_SNOW_SCALE_MAX: float = 3.6

# -----------------------------------------------------------------------------
# WEATHER — FOG (full-screen tint drawn by AmbientLayer)
# -----------------------------------------------------------------------------
# Alpha in the color sets the haze opacity. The colour itself sets the
# mood — cooler blues read as morning mist, warmer greys as smoke.
const WEATHER_FOG_COLOR: Color = Color(0.85, 0.88, 0.92, 0.42)

# -----------------------------------------------------------------------------
# AMBIENT — render order (z_index)
# -----------------------------------------------------------------------------
# Tweak with care — z_index controls who draws on top of whom.
const AMBIENT_CRITTER_Z: int = 1     # just above terrain, below squad
const AMBIENT_BIRD_Z:    int = 10    # above squad/terrain, below weather
const WEATHER_FOG_Z:     int = 45    # over everything ambient, under HUD
const WEATHER_PARTICLE_Z: int = 50   # rain/snow on top of the whole world

# =============================================================================
# PARTICLE / FX — bullet trails, sacrifice bomb visuals
# =============================================================================

# -----------------------------------------------------------------------------
# BULLET TRAIL — element-coloured streak behind squad bullets
# -----------------------------------------------------------------------------
# Built once per bullet when the shooter sets a non-NONE element. Enemy
# bullets never set an element so they get no trail (perf + visual clarity).
# Higher AMOUNT or LIFETIME = denser / longer comet streak.
const BULLET_TRAIL_AMOUNT:       int   = 18
const BULLET_TRAIL_LIFETIME:     float = 0.35
const BULLET_TRAIL_SPREAD:       float = 28.0    # cone (deg) the particles fan into
const BULLET_TRAIL_VELOCITY_MIN: float = 40.0
const BULLET_TRAIL_VELOCITY_MAX: float = 80.0
const BULLET_TRAIL_SCALE_MIN:    float = 1.4
const BULLET_TRAIL_SCALE_MAX:    float = 2.6
# Quadratic falloff via a Curve in code (start at 1.0, end at 0.15) — kept
# inline rather than exposed; only the start/end values would be designer-
# relevant and they're already implied by SCALE_MIN/MAX.
const BULLET_TRAIL_START_ALPHA:  float = 0.95    # alpha at spawn (fades to 0)

# -----------------------------------------------------------------------------
# SACRIFICE EXPLOSION FX — visual for the walking-bomb detonation
# -----------------------------------------------------------------------------
# Radius / duration come in from the caller (Soldier._explode passes
# SACRIFICE_RADIUS + SACRIFICE_FX_TIME). The values below are the visual
# breakdown of that animation. Higher FLASH_PORTION lengthens the bright
# kick; OUTER_RING_GROWTH_MULT controls how far the shockwave overshoots
# the damage radius.
const BOMB_FX_FLASH_PORTION:        float = 0.2   # fraction of duration the white flash takes
const BOMB_FX_FLASH_ALPHA_START:    float = 0.9
const BOMB_FX_FLASH_COLOR:          Color = Color(1.0, 0.95, 0.8)

# Fireball: scales from FIREBALL_START_R_MULT * radius up to full radius.
const BOMB_FX_FIREBALL_START_R_MULT: float = 0.4
const BOMB_FX_FIREBALL_ALPHA_START:  float = 0.75
const BOMB_FX_FIREBALL_COLOR:        Color = Color(1.0, 0.4, 0.05)

# Outer shockwave ring — expands past the damage radius then fades.
const BOMB_FX_OUTER_RING_START_R_MULT: float = 0.5
const BOMB_FX_OUTER_RING_END_R_MULT:   float = 1.35
const BOMB_FX_OUTER_RING_COLOR:        Color = Color(1.0, 0.85, 0.2)
const BOMB_FX_OUTER_RING_WIDTH:        float = 5.0

# Inner shockwave ring — trails the outer ring at a lower alpha.
const BOMB_FX_INNER_RING_START_R_MULT: float = 0.3
const BOMB_FX_INNER_RING_END_R_MULT:   float = 1.1
const BOMB_FX_INNER_RING_COLOR:        Color = Color(1.0, 0.55, 0.1)
const BOMB_FX_INNER_RING_WIDTH:        float = 3.0
const BOMB_FX_INNER_RING_ALPHA_MULT:   float = 0.7   # vs outer ring alpha

# Damage-radius marker — stays at exact damage radius so the player can
# read what got hit. Pure yellow ring, fades out over the FX lifetime.
const BOMB_FX_EDGE_RING_COLOR:    Color = Color(1.0, 1.0, 0.3)
const BOMB_FX_EDGE_RING_WIDTH:    float = 2.5
const BOMB_FX_EDGE_ALPHA_START:   float = 0.8
