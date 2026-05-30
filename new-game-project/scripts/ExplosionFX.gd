# =============================================================================
# ExplosionFX.gd
# Reusable explosion effect. Spawned programmatically on bullet impact,
# grenade detonation, and by BombExplosionFX for the sacrifice weapon.
# Plays an AnimatedSprite2D (if the PNG exists) then frees itself, or falls
# back to a quick CPUParticles2D burst so something always shows on impact.
#
# Usage:
#   var fx := Node2D.new()
#   fx.set_script(preload("res://scripts/ExplosionFX.gd"))
#   get_viewport().add_child(fx)
#   fx.global_position = impact_pos
#   fx.start("hit")          # "hit", "grenade", or "bomb"
#   fx.start("hit", tint)    # optional tint for element-colored hits
# =============================================================================
extends Node2D

const _LOADER = preload("res://scripts/ProjectileSpriteLoader.gd")

# Particle counts and radii per size tier — used for the fallback when no
# PNG has been dropped in yet.
const _FALLBACK := {
	"hit":     {"count": 8,  "radius": 18.0,  "speed": 80.0,  "life": 0.25, "color": Color(1.0, 0.8, 0.4)},
	"grenade": {"count": 20, "radius": 50.0,  "speed": 140.0, "life": 0.45, "color": Color(1.0, 0.55, 0.1)},
	"bomb":    {"count": 35, "radius": 100.0, "speed": 200.0, "life": 0.65, "color": Color(1.0, 0.3, 0.1)},
}

func start(size: String, tint: Color = Color.WHITE) -> void:
	var frames: SpriteFrames = ProjectileSpriteLoader.get_explosion_frames(size)
	if frames != null:
		_play_sprite(frames, tint)
	else:
		_play_particles(size, tint)

func _play_sprite(frames: SpriteFrames, tint: Color) -> void:
	var spr := AnimatedSprite2D.new()
	spr.sprite_frames = frames
	spr.modulate = tint
	# Explosions shouldn't inherit parent rotation (the parent Node2D may be
	# rotated to face the fire direction — we want the blast to be upright).
	spr.global_rotation = 0.0
	add_child(spr)
	# Disable looping so the animation plays exactly once.
	if spr.sprite_frames.has_animation(&"fly"):
		spr.sprite_frames.set_animation_loop(&"fly", false)
		spr.play(&"fly")
	spr.animation_finished.connect(queue_free)

func _play_particles(size: String, tint: Color) -> void:
	var cfg: Dictionary = _FALLBACK.get(size, _FALLBACK["hit"])
	var p := CPUParticles2D.new()
	p.emitting          = true
	p.one_shot          = true
	p.explosiveness     = 1.0
	p.amount            = cfg["count"]
	p.lifetime          = cfg["life"]
	p.local_coords      = false
	p.emission_shape    = CPUParticles2D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = cfg["radius"] * 0.3
	p.direction         = Vector2.UP
	p.spread            = 180.0
	p.initial_velocity_min = cfg["speed"] * 0.5
	p.initial_velocity_max = cfg["speed"]
	p.gravity          = Vector2.ZERO
	p.scale_amount_min = 2.0
	p.scale_amount_max = 5.0
	var col: Color = cfg["color"]
	if tint != Color.WHITE:
		col = tint
	var grad := Gradient.new()
	grad.set_color(0, Color(col.r, col.g, col.b, 1.0))
	grad.set_color(1, Color(col.r, col.g, col.b, 0.0))
	p.color_ramp = grad
	add_child(p)
	# Free once all particles have died.
	get_tree().create_timer(cfg["life"] * 1.5).timeout.connect(queue_free)
