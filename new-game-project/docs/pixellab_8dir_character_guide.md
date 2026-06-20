# Creating an 8‑Direction Animated Character (PixelLab → Godot)

A complete, repeatable recipe for building a hero character like **Lua** — 8‑way
**idle / walk / fire / die**, crisp at every zoom, dropped into the game with no
new code. Written to use the **fewest PixelLab prompts** possible.

The game already has the runtime plumbing — **both `Soldier.gd` (the kids) and
`Enemy.gd` (the corrupted mushroom) build SpriteFrames from a folder of strips**.
So for a new character you mostly **generate art + composite strips + point a
scene at the folder**.

Two integrations exist; they differ only in the death animation:
- **`Soldier.gd`** (kids): builds 8-way `idle/walk/shoot`, **carries over a single
  shared `die`** pose from the embedded frames.
- **`Enemy.gd`** (mushroom): builds 8-way `idle/walk/shoot` **and a full 8-way
  directional `die`** (`die_<facing>`, one-shot). Falls back to the embedded
  single `die` if no `die_*` strips are present.

Reference implementations: Lua = `scenes/soldier_1.tscn` + `resources/lua8/`;
Corrupted Mushroom enemy = `scenes/enemy.tscn` + `resources/mushroom8/`.

---

## 0. TL;DR — minimum-prompt workflow

PixelLab only runs **8 generation jobs at once**, and a v3 animation = 1 job per
direction (8 jobs for a full ring). So the whole character is **~6 PixelLab calls**
plus local compositing:

1. `create_character` (v3, 8‑dir) — **1 call**. Wait ~10 min. Show user, get approval.
2. `animate_character` v3 **idle**, all 8 dirs — **1 call** (8 jobs).
3. `animate_character` v3 **walk**, all 8 dirs — **1 call** (wait for idle's jobs to free).
4. `animate_character` v3 **fire/cast**, all 8 dirs — **1 call** (wait for walk).
5. `animate_character` v3 **die**, all 8 dirs — **1 call** (enemies only; kids reuse
   their embedded single `die`).
6. (Only if needed) re‑gen specific bad/missing directions — **0–1 calls**. v3
   occasionally drops one direction of an animation silently (we hit `die/west`);
   re-queue just that `directions: ["west"]`, or simply mirror it (§4a).

Everything else (download, composite, mirror, integrate) is local PowerShell +
one scene edit. Poll with `get_character` between steps; don't burn prompts.

---

## 1. The base character

Tool: `mcp__pixellab__create_character`

```
description: "A cheerful brave 7-year-old girl named Lua with long flowing brown
  hair, wearing a colorful paladin's outfit: a shining silver breastplate with
  pink, gold and teal accents and a flowing magenta cape. She holds a magical
  staff topped with a glowing crystal that she uses to cast spells. Cute child
  proportions, big friendly eyes, heroic. High quality fantasy RPG pixel art."
body_type: humanoid          # use "quadruped" + template (horse/cat/dog/bear/lion) for animals
mode: v3                     # HIGHEST quality. Always 8 directions. ~2 gens, ~10 min.
view: low top-down           # matches the existing kids (classic 3/4 RPG). Don't change.
size: 64                     # character px; v3 canvas comes out ~124px square
detail: high detail
outline: single color black outline
name: "<Character> Paladin"
```

Notes / gotchas:
- **v3 ignores** `n_directions` (always 8), `shading`, `proportions`. Put body
  shape ("cute child proportions, big friendly eyes") in the **description**.
- **Keep the palette MUTED / low-saturation on large flat surfaces** (a big cap,
  cloak, shell). v3's per-frame animation re-colours these unevenly, so a vivid /
  rainbow surface comes out a **different brightness each frame = flicker in
  motion** (worst on walk). We hit this hard on the mushroom: a bright multi-colour
  cap flickered across most directions; recreating it with a **dark, desaturated
  cap** (few dull spots, NOT rainbow) fixed it at the source. Save saturated accents
  for *small* areas (eyes, a gem). Spell it out in the description: "dark, muted,
  low-saturation, NOT colorful, NOT rainbow".
- v3 canvas is **~124×124** with lots of transparent padding around the figure.
  That padding is expected and is handled later (scale by opaque bounds).
- If the weapon/look is wrong, **delete and recreate** — it's only ~2 gens:
  `delete_character(confirm=true)` then `create_character` again. (We did this to
  swap a sword for a staff.)

### Approve before animating (saves a lot of wasted generations)
Download the 8 rotation PNGs to a temp/preview folder and show the user the
south (front) view at minimum. `get_character` returns rotation URLs:
`.../<char_id>/rotations/<dir>.png` for `south,east,north,west,south-east,
north-east,north-west,south-west`. Only proceed once they're happy.

---

## 2. Directions: what's generated vs. mirrored

`create_character` (v3) generates **all 8 rotations** itself:
`south, north, east, west, south-east, north-east, north-west, south-west`.

But the **animations** (next section) are not equally reliable per direction.
Empirically with v3:
- **East / south-east / south / south-west** animate cleanly (figure faces the
  movement direction).
- **West & north-west** frequently come out **back-facing / wrong** → **don't use
  them; mirror the east / north-east animations instead** (§5).
- **North (straight up)** tends to **lean** into a ¾ back view no matter how you
  prompt it. Options in §4.

### PixelLab direction → in‑game facing → filename
| PixelLab dir | facing (game) | idle file | walk file | shoot file |
|---|---|---|---|---|
| south       | down       | idle_down.png       | walk_down.png       | shoot_down.png |
| north       | up         | idle_up.png         | walk_up.png         | shoot_up.png |
| east        | right      | idle_right.png      | walk_right.png      | shoot_right.png |
| west        | left       | idle_left.png       | walk_left.png       | shoot_left.png |
| south-east  | down_right | idle_down_right.png | walk_down_right.png | shoot_down_right.png |
| south-west  | down_left  | idle_down_left.png  | walk_down_left.png  | shoot_down_left.png |
| north-east  | up_right   | idle_up_right.png   | walk_up_right.png   | shoot_up_right.png |
| north-west  | up_left    | idle_up_left.png    | walk_up_left.png    | shoot_up_left.png |

Plus a **`die_<facing>.png`** per direction (same naming) when the character
uses the 8-way death (enemies), for **32 strips total**. Save them all to
`res://resources/<char>8/` (Lua = `lua8`, mushroom = `mushroom8`).

For an **enemy** the death is **directional**: `Enemy._die()` plays `die_<facing>`
(non-looping) and the builder treats `die` like the others (loop = false). For the
**kids**, `Soldier.gd` carries over a single embedded `die` instead — supply the
24 `idle/walk/shoot` strips and skip `die_*`. Either way, west / north-west usually
need the mirror treatment and north the lean handling (§4) — including the `die`
set for enemies.

---

## 3. Animations (idle / walk / fire) — use v3, NOT templates

Tool: `mcp__pixellab__animate_character`, **`mode: v3`**.

**Why v3, not template animations:** template animations (`breathing-idle`,
`fireball`, `walking`) are generic skeletons that **don't know about held props**
— the staff flickers / disappears and some directions face the wrong way. v3
interpolates from the character's actual directional base frame (staff already in
hand, correct facing), so the prop stays and motion is smooth.

v3 **defaults to south only** → always pass all 8 directions explicitly:

```
animate_character(
  character_id: "<id>",
  mode: "v3",
  action_description: "<see below>",
  directions: ["south","north","east","west","south-east","south-west","north-east","north-west"],
  frame_count: 6        # v3 stores frame_count+1 (a reference frame) → 7 frames per dir
)
```

**Describe MOTION, not EFFECTS — never bake projectiles / muzzle flashes / spray
into the animation.** v3 renders any "spell / spore / spit / fireball / burst"
differently every frame and every direction, so the effect ends up wildly
inconsistent (we got yellow blobs in one dir, white sprays in another, nothing in
a third). The game spawns projectiles and VFX in-engine anyway, so the sprite only
needs the **body's attack pose**. Word the fire/attack action as a pure body move:
a head/weapon **thrust or lunge**, arm extension, recoil — no emitted matter.

Action descriptions that worked well:
- **idle:**  `"standing still, breathing gently, holding her glowing crystal staff steady in one hand"`
- **walk:**  `"walking forward, holding her glowing crystal staff in one hand"`
- **fire/cast (kid, prop thrust):** `"thrusting her glowing crystal staff forward, arm extended toward the front"` (NO "cast a spell" / glow burst)
- **fire/attack (enemy, body lunge):** `"rearing its head and hunched body back then thrusting sharply forward in an attacking lunge, fanged mouth opening wide"` (NO "spew spores / spit" — that bakes in the muzzle FX)
- **die:** `"staggering and collapsing to the ground, defeated and dying, falling down"` (a dissolve/spore-cloud death also varies per frame — keep it to the body crumpling)

Sequencing (8-slot limit): queue idle (8 jobs) → poll `get_character` until done
→ queue walk → poll → queue fire → poll → queue die. Composite each as it
finishes (don't wait for all four).

If an animation already baked in effects, **`delete_animation(type, confirm=true)`
then re-queue** with an effect-free description (changing the wording also dodges
the dedupe that returns the old frames).

Cost: ~16 generations per animation (2/dir × 8) = ~64 for the full set
(idle + walk + fire + die).

---

## 4. Fixing bad directions

### 4a. West & north-west came out back-facing → MIRROR (no new generation)
Mirror the matching east / north-east strip **per-frame** (flip each frame in
place, keep frame order). See the mirror script in §6. Apply to **every**
animation (include `die` for enemies):
- `walk_right.png`  → `walk_left.png`
- `idle_right.png`  → `idle_left.png`
- `shoot_right.png` → `shoot_left.png`
- `die_right.png`   → `die_left.png`        (enemy 8-way death)
- `walk_up_right.png`  → `walk_up_left.png`
- `idle_up_right.png`  → `idle_up_left.png`
- `shoot_up_right.png` → `shoot_up_left.png`
- `die_up_right.png`   → `die_up_left.png`   (enemy 8-way death)

(A held prop ends up in the opposite hand — normal for a mirrored sprite,
unnoticed in motion. The mushroom has no prop, so mirroring is lossless.)
Mirroring also **fills in any direction v3 silently dropped** — we mirrored
`die_left` from `die_right` rather than wait on a re-gen.

### 4b. North (straight up) leans
Two acceptable choices — pick per taste:
- **Keep the animated v3 north** even though it leans slightly (Lua's final pick —
  it animates and reads fine alongside the mirrored up_left/up_right).
- **Static true-north:** copy the **base north rotation** (`.../rotations/north.png`,
  a clean straight back) into `idle_up/walk_up/shoot_up` as a 1‑frame strip.
  Correct facing but no animation on the up direction.

If you re-generate north to try for straight ("back fully to camera, not turning"),
it usually still leans — don't waste many gens on it.

---

## 5. Compositing strips (PowerShell + System.Drawing)

Each strip is a **horizontal row of square frames at native 124px** (no
downscale — keep the resolution for zoom-in crispness; see §7).

### 5a. Easiest source: the bulk download zip (PREFERRED)
`get_character` returns a `download` URL
(`https://api.pixellab.ai/mcp/characters/<id>/download`). It's a **zip** of the
whole character, already organized as
`<Name>/animations/<action_description_prefix>/<dir>/frame_000.png …`. Grab it
once and composite locally — no per-frame URL juggling, no animId bookkeeping:

```bash
curl -sL -o char.zip "https://api.pixellab.ai/mcp/characters/<id>/download"
unzip -o -q char.zip            # -> <Name>/animations/<prefix>/<dir>/frame_NNN.png
```

Then map each `animations/<prefix>/` folder (the prefix is the slugified
action_description) to your output name (`idle/walk/shoot/die`) and each `<dir>`
to its facing, and build a strip per folder. **Re-download the zip after the LAST
direction finishes** — if a job is still pending the zip omits that direction
silently (this is exactly how we noticed `die/west` was missing).

A ready-made compositor that walks the extracted tree (anim-prefix × dir →
`<out>_<facing>.png`) is what built `resources/mushroom8/`; the per-folder loop is
the same `Build` shape as below but reads local `frame_*.png` instead of URLs.

### 5b. Alternative: per-frame URLs
If you'd rather pull frames directly, the URLs come from `get_character`:
`.../animations/<animId>/<dir>/{i}.png`, `i = 0..frames-1` (one animId per
direction per animation).

```powershell
Add-Type -AssemblyName System.Drawing
$envDir = "c:\projects\gamedemo\new-game-project\resources\<char>8"
New-Item -ItemType Directory -Force -Path $envDir | Out-Null
$ar = "https://backblaze.pixellab.ai/file/pixellab-characters/<account>/<char_id>/animations"
$tmp = Join-Path $env:TEMP "char_fx"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Build($animId,$dir,$outFile,$count){
  $imgs=@()
  for($i=0;$i -lt $count;$i++){
    $f=Join-Path $tmp ("{0}_{1}.png" -f ($dir -replace '-','_'),$i)
    Invoke-WebRequest -Uri "$ar/$animId/$dir/$i.png" -OutFile $f -UseBasicParsing
    $imgs+=[System.Drawing.Image]::FromFile($f)
  }
  $fw=$imgs[0].Width; $fh=$imgs[0].Height
  $strip=New-Object System.Drawing.Bitmap (($fw*$count),$fh,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g=[System.Drawing.Graphics]::FromImage($strip)
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.CompositingMode=[System.Drawing.Drawing2D.CompositingMode]::SourceCopy   # preserve alpha exactly
  for($i=0;$i -lt $count;$i++){ $g.DrawImage($imgs[$i],($i*$fw),0,$fw,$fh) }
  $g.Dispose(); $strip.Save((Join-Path $envDir $outFile),[System.Drawing.Imaging.ImageFormat]::Png)
  $strip.Dispose(); foreach($im in $imgs){$im.Dispose()}
}
# Build "<animId>" "<pixellab-dir>" "<facing-file>.png" <frameCount>   for all 24 (kid) / 32 (enemy)
```

Tips:
- `SourceCopy` (not the default blend) keeps transparency clean between frames.
- Keep frames **square** (`fh × fh`); the loader derives frame count = width/height.
- The whole set (24 kid / 32 enemy strips) composites in one PowerShell run. From
  the bulk zip (§5a) it's all local; via per-frame URLs (§5b) bump the tool timeout
  to ~300000 ms for the ~168–224 small downloads.

---

## 6. Mirror script (east → west, per frame)

```powershell
Add-Type -AssemblyName System.Drawing
$envDir = "c:\projects\gamedemo\new-game-project\resources\<char>8"
function MirrorFrames($srcFile,$dstFile){
  $src=[System.Drawing.Image]::FromFile((Join-Path $envDir $srcFile))
  $fh=$src.Height; $count=[int]($src.Width/$fh)
  $out=New-Object System.Drawing.Bitmap ($src.Width,$fh,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g=[System.Drawing.Graphics]::FromImage($out)
  $g.Clear([System.Drawing.Color]::Transparent); $g.CompositingMode=[System.Drawing.Drawing2D.CompositingMode]::SourceCopy
  for($i=0;$i -lt $count;$i++){
    $frame=New-Object System.Drawing.Bitmap ($fh,$fh,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $fg=[System.Drawing.Graphics]::FromImage($frame); $fg.Clear([System.Drawing.Color]::Transparent); $fg.CompositingMode=[System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $fg.DrawImage($src,(New-Object System.Drawing.Rectangle 0,0,$fh,$fh),(New-Object System.Drawing.Rectangle ($i*$fh),0,$fh,$fh),[System.Drawing.GraphicsUnit]::Pixel)
    $fg.Dispose()
    $frame.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX)   # mirror this frame only
    $g.DrawImage($frame,($i*$fh),0,$fh,$fh)                                # keep frame order
    $frame.Dispose()
  }
  $g.Dispose(); $src.Dispose(); $out.Save((Join-Path $envDir $dstFile),[System.Drawing.Imaging.ImageFormat]::Png); $out.Dispose()
}
MirrorFrames "walk_right.png"     "walk_left.png"
MirrorFrames "idle_right.png"     "idle_left.png"
MirrorFrames "shoot_right.png"    "shoot_left.png"
MirrorFrames "die_right.png"      "die_left.png"      # enemy 8-way death
MirrorFrames "walk_up_right.png"  "walk_up_left.png"
MirrorFrames "idle_up_right.png"  "idle_up_left.png"
MirrorFrames "shoot_up_right.png" "shoot_up_left.png"
MirrorFrames "die_up_right.png"   "die_up_left.png"   # enemy 8-way death
```

**Always Read each mirrored/composited PNG to eyeball it** (the Read tool renders
images). Catching a back-facing or leaning frame here saves a play-test round trip.

---

## 7. Looking good at every zoom level (crispness)

The character is a **detailed** sprite among simpler pixel-art kids, so:
- **Keep frames at full native 124px** (don't pre-downscale). High source res =
  detail to show when the camera zooms in.
- Render with **linear + mipmaps**, NOT nearest. Nearest = blocky when zoomed in,
  shimmery when zoomed out. Linear+mipmaps = smooth at all zooms.
- Give **each frame its own mipmapped texture** (crop from the strip, then
  `Image.generate_mipmaps()`), so mipmaps don't bleed neighboring frames.
- Normalize size by the figure's **opaque bounds**, not the padded canvas
  (otherwise she renders tiny). Target ≈ 77px tall (= other kids' 64px × 1.2).

All of this already lives in `Soldier.gd._build_frames_from_dir()` — you don't
re-implement it; you just supply 124px strips and set `frames_dir`. (The other
kids keep their own nearest-filter pixel-art frames; only the `frames_dir`
character uses linear+mipmaps.)

---

## 8. Godot integration

1. Save the strips to `res://resources/<char>8/` (24 for a kid, **32 for an enemy**
   with the 8-way death).
2. On the character's scene set the `frames_dir` export and leave the embedded
   fallback SpriteFrames in place (used until the strips exist):
   - **Kid:** `scenes/soldier_N.tscn` → `frames_dir = "res://resources/<char>8/"`
   - **Enemy:** `scenes/enemy.tscn` → `frames_dir = "res://resources/<char>8/"`

That's it. At runtime the actor's `_build_frames_from_dir()`:
- Builds a SpriteFrames from `<idle|walk|shoot>_<facing>.png`. `shoot` is one-shot
  for both actors; idle/walk loop. **Gotcha for a persistent ATTACK state** (the
  enemy): don't just call `_play_anim("shoot_*")` every frame — `_play_anim` won't
  restart an already-playing anim, so a one-shot freezes on its last frame (enemy
  slides mid-spit) and a *looping* shoot leaves the muzzle splatter on screen the
  whole time. Instead, on each actual shot restart it from frame 0
  (`sprite.play(...)` + `sprite.set_frame_and_progress(0, 0.0)`), and between shots
  (once `is_playing()` is false) show `idle_<facing>` so the spit plays once per
  shot. Kids avoid this naturally — their SHOOTING state is brief and re-entered
  per shot.
- **Death:** `Soldier.gd` carries over the embedded single `die`; **`Enemy.gd`
  additionally builds `die_<facing>.png` as a one-shot 8-way set** and `Enemy._die()`
  plays `die_<facing>` (falling back to single `die` if no `die_*` strips exist).
- Sets `_use_8way = true` because diagonal anims exist → `_dir_to_facing()`
  returns 8 octants (`down,up,left,right,down_right,down_left,up_right,up_left`).
  Actors without diagonals stay 4-way automatically.
- Applies linear+mipmaps and opaque-bounds scaling (kids target ≈77px tall;
  the mushroom enemy targets ≈96px so it reads heavier than the kids).

Animation names the loader expects: `idle_<facing>`, `walk_<facing>`,
`shoot_<facing>` (and `die_<facing>` for enemies) for all 8 facings. fps in the
builders: idle 6, walk 8–10, shoot 12, die 10.

### Verifying headlessly (no display needed)
The build path is fully checkable without the editor:
```
& "<godot.exe>" --headless --path <project> --import          # import strips, scan for errors
& "<godot.exe>" --headless --path <project> --script test.gd  # instantiate scene, assert frames
```
In a `SceneTree`-extending test script, `_ready` is **deferred** until the loop
runs — `add_child(e)` then `await process_frame` (twice) before inspecting
`sprite.sprite_frames`, or you'll read the embedded frames and think the build
failed. Assert `has_animation("walk_up_right")` (8-way flag), `has_animation("die_left")`,
and `get_animation_loop("die_down") == false`.

---

## 9. Cheat sheet (do this, in order)

1. `create_character` v3 humanoid, low top-down, size 64 — wait, **show user, approve**.
2. `animate_character` v3 idle (all 8 dirs) → poll → composite 8 idle strips @124px.
3. `animate_character` v3 walk (all 8 dirs) → poll → composite 8 walk strips.
4. `animate_character` v3 fire (all 8 dirs) → poll → composite 8 shoot strips.
5. **Enemy only:** `animate_character` v3 die (all 8 dirs) → poll → composite 8 die strips.
6. Grab the bulk `download` zip (re-download after the last dir finishes), composite
   all folders. Read the strips. Mirror right→left for `left` & `up_left` (and `die`
   versions for enemies) — this also fills any direction v3 dropped. Decide north.
7. Save all strips (24 kid / 32 enemy) to `resources/<char>8/`, set `frames_dir` on
   the scene (`soldier_N.tscn` or `enemy.tscn`).
8. Verify headlessly (§8) — `--import` then a `--script` instantiate-and-assert.
9. Delete the temporary base character only when fully done
   (`delete_character` of any throwaway attempts to keep the account tidy).

Reference implementation: Lua = `scenes/soldier_1.tscn` + `resources/lua8/`,
built by `scripts/Soldier.gd` (`_build_frames_from_dir`, `_dir_to_facing`).
