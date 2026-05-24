# BombExplosionFX.gd
# Short-lived visual for the SACRIFICE weapon detonation. Spawned by
# Soldier._explode() with the damage radius + duration. Draws an expanding
# shockwave + fireball + damage-radius marker, then queue_frees itself.
# All colours / size multipliers / timings are tunable in BalanceConfig under
# the BOMB_FX_* prefix.
extends Node2D

const Balance = preload("res://scripts/BalanceConfig.gd")

var _radius:   float = 0.0
var _duration: float = 0.65
var _elapsed:  float = 0.0

func start(radius: float, duration: float) -> void:
	_radius   = radius
	_duration = duration
	# Explicitly enable _process — required when the script is attached via
	# set_script() before the node enters the scene tree.
	set_process(true)
	queue_redraw()

func _process(delta: float) -> void:
	_elapsed += delta
	queue_redraw()
	if _elapsed >= _duration:
		queue_free()

func _draw() -> void:
	var t: float = clampf(_elapsed / _duration, 0.0, 1.0)

	# Bright white flash — full radius, gone after FLASH_PORTION of the duration.
	var flash_t: float = clampf(t / Balance.BOMB_FX_FLASH_PORTION, 0.0, 1.0)
	var flash_alpha: float = lerpf(Balance.BOMB_FX_FLASH_ALPHA_START, 0.0, flash_t)
	if flash_alpha > 0.0:
		var flash := Balance.BOMB_FX_FLASH_COLOR
		flash.a = flash_alpha
		draw_circle(Vector2.ZERO, _radius, flash)

	# Main fireball: expands from FIREBALL_START_R_MULT * radius to full.
	var r: float = lerpf(_radius * Balance.BOMB_FX_FIREBALL_START_R_MULT, _radius, t)
	var fill_alpha: float = lerpf(Balance.BOMB_FX_FIREBALL_ALPHA_START, 0.0, t)
	var fireball := Balance.BOMB_FX_FIREBALL_COLOR
	fireball.a = fill_alpha
	draw_circle(Vector2.ZERO, r, fireball)

	# Outer shockwave ring — expands past the damage radius, fades.
	var ring_r: float = lerpf(
			_radius * Balance.BOMB_FX_OUTER_RING_START_R_MULT,
			_radius * Balance.BOMB_FX_OUTER_RING_END_R_MULT, t)
	var ring_alpha: float = lerpf(1.0, 0.0, t)
	var outer := Balance.BOMB_FX_OUTER_RING_COLOR
	outer.a = ring_alpha
	draw_arc(Vector2.ZERO, ring_r, 0.0, TAU, 64, outer, Balance.BOMB_FX_OUTER_RING_WIDTH)

	# Inner shockwave ring — trails the outer, lower alpha.
	var inner_r: float = lerpf(
			_radius * Balance.BOMB_FX_INNER_RING_START_R_MULT,
			_radius * Balance.BOMB_FX_INNER_RING_END_R_MULT, t)
	var inner := Balance.BOMB_FX_INNER_RING_COLOR
	inner.a = ring_alpha * Balance.BOMB_FX_INNER_RING_ALPHA_MULT
	draw_arc(Vector2.ZERO, inner_r, 0.0, TAU, 48, inner, Balance.BOMB_FX_INNER_RING_WIDTH)

	# Damage-radius marker — stays at exact damage radius so the player can
	# read what got hit.
	var edge_alpha: float = lerpf(Balance.BOMB_FX_EDGE_ALPHA_START, 0.0, t)
	var edge := Balance.BOMB_FX_EDGE_RING_COLOR
	edge.a = edge_alpha
	draw_arc(Vector2.ZERO, _radius, 0.0, TAU, 64, edge, Balance.BOMB_FX_EDGE_RING_WIDTH)
