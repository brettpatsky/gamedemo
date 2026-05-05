# SquadGame — Godot 4 Tactical Shooter
### Cannon Fodder-inspired | Top-Down | Cute Cartoon Style | Steam-Ready

---

## Overview

A top-down tactical squad shooter where you command 1–8 cartoon soldiers across
procedurally generated maps. Left-click to move. Right-click to shoot. Clear all
enemies to win the mission.

Built for **Godot 4.x** (tested on 4.2+). Targets **desktop** (Windows/Mac/Linux)
for Steam distribution via the official Godot Steam export templates.

---

## File Structure

```
SquadGame/
├── scripts/
│   ├── GameManager.gd          ← AutoLoad singleton; global state & signals
│   ├── Main.gd                 ← Root scene orchestrator; spawns map + squad
│   ├── MapGenerator.gd         ← Procedural tile map + nav-mesh baking
│   ├── SquadController.gd      ← Input handler; issues move/fire orders
│   ├── Soldier.gd              ← Player unit; pathfinding + shooting + death
│   ├── Enemy.gd                ← Enemy AI; patrol → alert → attack FSM
│   ├── Bullet.gd               ← Projectile; movement + hit detection
│   ├── CameraController.gd     ← Zoom, pan, soft-follow, map-clamp
│   └── HUD.gd                  ← Score, soldier count, win/lose overlay
├── scenes/                     ← Create these in the Godot editor (see below)
│   ├── Main.tscn
│   ├── Soldier.tscn
│   ├── Enemy.tscn
│   └── Bullet.tscn
└── resources/                  ← Your art assets go here
    ├── tilesets/
    ├── sprites/soldiers/
    ├── sprites/enemies/
    └── audio/
```

---

## Step-by-Step Setup in the Godot Editor

### 1. Project Settings

1. Open Godot 4, create a new project.
2. Go to **Project > Project Settings > AutoLoad**.
3. Add `scripts/GameManager.gd` with the name `GameManager`.
4. Set **Rendering > 2D > Default Canvas Item Texture Filter** to `Nearest`
   (crisp pixel art look for cartoon sprites).

---

### 2. Create `scenes/Main.tscn`

**Node tree:**
```
Main               (Node2D)           ← attach scripts/Main.gd
├── MapGenerator   (Node2D)           ← attach scripts/MapGenerator.gd
│   ├── TileMapLayer                  ← create TileSet with 4 terrain tiles
│   └── NavigationRegion2D
├── SquadController (Node2D)          ← attach scripts/SquadController.gd
│                                       add to group: "squad_controller"
├── Camera2D                          ← attach scripts/CameraController.gd
│                                       add to group: "main_camera"
└── HUD (CanvasLayer)                 ← attach scripts/HUD.gd
    ├── MarginContainer
    │   └── VBoxContainer
    │       ├── ScoreLabel   (Label)
    │       └── SoldierCountLabel (Label)
    ├── MissionLabel (Label)           ← Anchors: centre; hide in editor
    └── RetryButton  (Button)          ← Anchors: centre-bottom; hide in editor
```

**Inspector settings for Main (Node2D):**
- `squad_size` → 6
- `soldier_scene` → drag in `scenes/Soldier.tscn`

---

### 3. Create `scenes/Soldier.tscn`

**Node tree:**
```
Soldier           (CharacterBody2D)   ← attach scripts/Soldier.gd
├── NavigationAgent2D                 ← Path Find Interval: 0.1s (default fine)
├── AnimatedSprite2D                  ← create SpriteFrames with animations below
├── CollisionShape2D                  ← CapsuleShape2D, height 28, radius 10
├── HealthBar      (ProgressBar)      ← position above head e.g. (0, -28)
│                                       size (40, 6), hide background false
└── FootstepAudio  (AudioStreamPlayer2D) ← assign a footstep .wav or .ogg
```

**Required SpriteFrames animations** (name them exactly):
- `idle`  — 2-4 frames, looping
- `walk`  — 4-8 frames, looping
- `shoot` — 2-4 frames, looping
- `die`   — 4-6 frames, NOT looping

Create **two** SpriteFrames resources: one for male, one for female.
Assign them to `male_frames` and `female_frames` in the Inspector.

**Inspector settings:**
- `bullet_scene` → drag in `scenes/Bullet.tscn`
- `move_speed` → 90
- `max_health` → 3

**Soldier must be in group `soldiers`** (added via code in Main.gd, but you can
pre-add it in Node > Groups in the editor too).

---

### 4. Create `scenes/Enemy.tscn`

**Node tree:**
```
Enemy             (CharacterBody2D)   ← attach scripts/Enemy.gd
├── NavigationAgent2D
├── AnimatedSprite2D                  ← animations: "patrol", "shoot", "die"
├── CollisionShape2D                  ← same shape as soldier
├── HealthBar      (ProgressBar)
└── DetectionArea  (Area2D)           ← large circle for line-of-sight
    └── CollisionShape2D              ← CircleShape2D, radius 200
```

**Inspector settings:**
- `bullet_scene` → drag in `scenes/Bullet.tscn`
- `score_value` → 10
- `sight_range` → 200
- `attack_range` → 120

---

### 5. Create `scenes/Bullet.tscn`

**Node tree:**
```
Bullet            (Area2D)            ← attach scripts/Bullet.gd
├── Sprite2D                          ← tiny oval or star sprite
├── CollisionShape2D                  ← CircleShape2D, radius 4
└── VisibleOnScreenNotifier2D
```

**Inspector:** `speed` → 400, `damage` → 1

---

### 6. TileSet Setup

In the `TileMapLayer` node:
1. Create a new **TileSet** resource.
2. Add tiles with IDs matching these constants in MapGenerator.gd:
   - ID 0 → Water (blue, impassable)
   - ID 1 → Grass (green, passable)
   - ID 2 → Dirt  (brown, passable)
   - ID 3 → Rock  (grey, impassable)
3. Set `tile_size` to 64×64 (or 32×32; update the `tile_size` export in MapGenerator.gd).

---

### 7. Navigation Setup

For pathfinding to work, each passable tile needs a **navigation polygon**:
1. In the TileSet editor, select a passable tile source.
2. In the **Navigation** panel, draw a polygon covering the full tile.
3. MapGenerator.gd also bakes a NavigationRegion2D at runtime as a fallback.

---

## Art Style Guide (Cute Cartoon)

The codebase is art-agnostic — bring your own sprites. Recommended approach:

- **Resolution:** 32×32 or 48×48 px per character, scaled up 2× in Godot.
- **Palette:** Bright primary colours, thick black outlines (1-2 px).
- **Female soldiers:** Different hair/beret colour, shorter silhouette.
- **Enemies:** Distinct silhouette (e.g. different helmet shape, red uniform).
- **Terrain:** Pastel greens/browns, chunky pixel art style.

Free asset packs to prototype with:
- **Kenney.nl** — Tiny Top-Down, Tiny Dungeon
- **itch.io** search "top down soldier sprite sheet"

---

## Steam Publishing Checklist

1. **Export Templates:** Download Godot 4 export templates from godotengine.org.
2. **Export Preset:** Project > Export > Add Windows Desktop preset.
   - Enable "Embed PCK" for single-exe distribution.
3. **Steam SDK Integration:** Use the **GodotSteam** plugin:
   - https://godotsteam.com — drop-in Godot 4 compatible Steam API wrapper.
   - Handles achievements, leaderboards, and Steam overlay.
4. **App ID:** Get a Steam App ID at partner.steamgames.com (costs ~$100 USD one-time).
5. **Icon & Capsule Art:** 512×512 icon, 460×215 library capsule (Steam spec).
6. **Steam Deck:** Godot exports are Deck-compatible; test with controller input.

---

## Extending the Game

| Feature | Where to add it |
|---|---|
| Multiple missions / levels | Create additional Map scenes; cycle them in Main.gd |
| Soldier selection (click to select subset) | Add selection rect logic to SquadController.gd |
| Explosives / grenades | New scene + script similar to Bullet.gd with AOE damage |
| Cover system | Add boolean `in_cover` to Soldier.gd; reduce incoming damage |
| Objectives (flags, rescue) | Add Objective.tscn; emit signal when soldiers reach it |
| Sound effects | AudioStreamPlayer2D in each scene; bus setup in AudioServer |
| Music | AudioStreamPlayer in Main.tscn; assign .ogg looping track |
| Save / load | Use `ConfigFile` or `FileAccess` in GameManager.gd |

---

## Controls

| Input | Action |
|---|---|
| **Left Click** | Move squad to cursor |
| **Right Click** | Fire toward cursor |
| **Scroll Wheel** | Zoom in / out |
| **Middle Mouse Drag** | Pan camera |
| **WASD / Arrow Keys** | Pan camera |

---

## License

Your code. Build something great.
