# BombExplosionFX.gd
# Short-lived visual for the SACRIFICE weapon detonation. Spawned by Soldier._explode().
# Draws an expanding shockwave + fireball, then queue_frees itself.
extends Node2D

var _radius:   float = 0.0
var _duration: float = 0.65
var _elapsed:  float = 0.0

func start(radius: float, duration: float) -> void:
	_radius   = radius
	_duration = duration
	queue_redraw()

func _process(delta: float) -> void:
	_elapsed += delta
	queue_redraw()
	if _elapsed >= _duration:
		queue_free()

func _draw() -> void:
	var t: float = clampf(_elapsed / _duration, 0.0, 1.0)

	# Bright white flash — covers full radius instantly then vanishes in the first 20% of time.
	var flash_t: float = clampf(t / 0.2, 0.0, 1.0)
	var flash_alpha: float = lerpf(0.9, 0.0, flash_t)
	if flash_alpha > 0.0:
		draw_circle(Vector2.ZERO, _radius, Color(1.0, 0.95, 0.8, flash_alpha))

	# Main fireball: expands from 40% to full radius, fades out.
	var r: float = lerpf(_radius * 0.4, _radius, t)
	var fill_alpha: float = lerpf(0.75, 0.0, t)
	draw_circle(Vector2.ZERO, r, Color(1.0, 0.4, 0.05, fill_alpha))

	# Outer shockwave ring: expands past the damage radius, fades.
	var ring_r: float  = lerpf(_radius * 0.5, _radius * 1.35, t)
	var ring_alpha: float = lerpf(1.0, 0.0, t)
	draw_arc(Vector2.ZERO, ring_r, 0.0, TAU, 64, Color(1.0, 0.85, 0.2, ring_alpha), 5.0)

	# Second inner ring slightly behind the outer one.
	var inner_r: float = lerpf(_radius * 0.3, _radius * 1.1, t)
	draw_arc(Vector2.ZERO, inner_r, 0.0, TAU, 48, Color(1.0, 0.55, 0.1, ring_alpha * 0.7), 3.0)

	# Damage-radius marker ring — stays fixed, fades out, so the player can clearly
	# see the exact area that was damaged.
	var edge_alpha: float = lerpf(0.8, 0.0, t)
	draw_arc(Vector2.ZERO, _radius, 0.0, TAU, 64, Color(1.0, 1.0, 0.3, edge_alpha), 2.5)
