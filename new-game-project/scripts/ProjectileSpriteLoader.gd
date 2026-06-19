# =============================================================================
# ProjectileSpriteLoader.gd
# Loads grid-based PNG spritesheets and builds SpriteFrames resources.
# Results are cached so repeated calls don't reload from disk.
#
# Current files in res://resources/fx/projectiles/:
#   fireball.png    320×336  — 5 cols × 7 rows, 64×48 px per frame  (FIRE)
#   iceball.png     320×336  — 5 cols × 7 rows, 64×48 px per frame  (ICE)
#   lightning.png   160×192  — 5 cols × 6 rows, 32×32 px per frame  (LIGHTNING)
#   enemygreen.png  320×336  — 5 cols × 7 rows, 64×48 px per frame  (enemies/NONE)
#
# All sheets face RIGHT at 0 degrees — the Bullet node's rotation already
# aligns to the fire direction so no extra rotation is needed here.
# =============================================================================
class_name ProjectileSpriteLoader

const _PATH := "res://resources/fx/projectiles/"
const _FLY  := &"fly"

# Per-file grid config: { cols, rows, fw (frame width), fh (frame height), fps }
const _CONFIGS: Dictionary = {
	"fireball":   { "cols": 5, "rows": 7, "fw": 64, "fh": 48, "fps": 14.0 },
	"iceball":    { "cols": 5, "rows": 7, "fw": 64, "fh": 48, "fps": 14.0 },
	"lightning":  { "cols": 5, "rows": 6, "fw": 32, "fh": 32, "fps": 18.0 },
	"enemygreen": { "cols": 5, "rows": 7, "fw": 64, "fh": 48, "fps": 14.0 },
	# Potion / grenade in-flight (64×64, single frame, loops while airborne)
	"grenade":           { "cols": 1, "rows": 1, "fw": 64,  "fh": 64,  "fps": 12.0 },
	# Potion explosion (1728×192 = 9 frames of 192×192, plays once over ~0.6 s)
	"explosion_grenade": { "cols": 9, "rows": 1, "fw": 192, "fh": 192, "fps": 15.0 },
	# Sacrifice explosion (2304×256 = 9 frames of 256×256, plays once over ~0.7 s)
	"explosion_bomb":    { "cols": 9, "rows": 1, "fw": 256, "fh": 256, "fps": 13.0 },
}

# Element index → sprite key (matches Elements.E enum order: NONE=0, FIRE=1, ICE=2, LIGHTNING=3)
const _ELEM_KEYS: Array[String] = ["enemygreen", "fireball", "iceball", "lightning"]

static var _cache: Dictionary = {}

# Returns SpriteFrames for a bullet by element index.
# NONE (enemy/default) uses enemygreen.
static func get_bullet_frames(element: int) -> SpriteFrames:
	var idx: int = clampi(element, 0, _ELEM_KEYS.size() - 1)
	return _load(_ELEM_KEYS[idx])

static func get_grenade_frames() -> SpriteFrames:
	return _load("grenade")

static func get_explosion_frames(size: String) -> SpriteFrames:
	return _load("explosion_" + size)

static func _load(key: String) -> SpriteFrames:
	if _cache.has(key):
		return _cache[key]
	var path: String = _PATH + key + ".png"
	if not ResourceLoader.exists(path):
		_cache[key] = null
		return null
	var tex: Texture2D = load(path)
	if tex == null:
		_cache[key] = null
		return null

	var cfg: Dictionary = _CONFIGS.get(key, {})
	var cols: int
	var rows: int
	var fw: int
	var fh: int
	var fps: float

	if cfg.is_empty():
		# Fallback: assume a horizontal strip of square frames.
		fh   = tex.get_height()
		fw   = fh
		cols = tex.get_width() / fw
		rows = 1
		fps  = 12.0
	else:
		cols = cfg["cols"]
		rows = cfg["rows"]
		fw   = cfg["fw"]
		fh   = cfg["fh"]
		fps  = cfg["fps"]

	var frames := SpriteFrames.new()
	frames.add_animation(_FLY)
	frames.set_animation_loop(_FLY, true)
	frames.set_animation_speed(_FLY, fps)

	for row in rows:
		for col in cols:
			var atlas := AtlasTexture.new()
			atlas.atlas  = tex
			atlas.region = Rect2(col * fw, row * fh, fw, fh)
			frames.add_frame(_FLY, atlas)

	_cache[key] = frames
	return frames
