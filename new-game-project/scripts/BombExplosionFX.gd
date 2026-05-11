# BombExplosionFX.gd
# Short-lived visual for the SACRIFICE weapon detonation. Spawned by Soldier._explode().
# Draws an expanding ring + filled disc, then queue_frees itself.
extends Node2D

var _radius:   float = 0.0
var _duration: float = 0.35
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
	var t := clampf(_elapsed / _duration, 0.0, 1.0)
	var r := lerpf(_radius * 0.4, _radius, t)
	var fill_alpha := lerpf(0.55, 0.0, t)
	draw_circle(Vector2.ZERO, r, Color(1.0, 0.45, 0.05, fill_alpha))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 48, Color(1.0, 0.85, 0.2, 1.0 - t), 3.0)
