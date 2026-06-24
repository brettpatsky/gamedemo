# =============================================================================
# PhaseDangerZone.gd  (Boss Mission — Phase 1 "Thorn Bramble")
# A tree-themed telegraphed hazard. For WARN_DURATION an animated bramble of
# thorny vines grows up to cover the circle — a soldier standing in it is SLOWED
# (vines grabbing their legs) but takes no damage yet. After the telegraph the
# bramble bristles into thorns: soldiers still inside are slowed AND take periodic
# damage for DAMAGE_DURATION, then it withers away.
#
# Visuals are PixelLab-animated (resources/boss/vine_grow + vine_thorn); a flat
# circle is drawn as a fallback if those frames are missing.
# =============================================================================
extends Area2D

const Balance = preload("res://scripts/BalanceConfig.gd")

var warn_duration:   float = 1.8
var damage_duration: float = 2.0

const VINE_SLOW: float = 0.5   # movement multiplier while standing in the vines

var _elapsed:     float = 0.0
var _tick_timer:  float = 0.0
var _pulse_phase: float = 0.0
var _sprite:      AnimatedSprite2D = null
var _base_scale:  float = 1.0
var _thorns_playing: bool = false

func configure(p_warn: float, p_damage: float) -> void:
	warn_duration   = p_warn
	damage_duration = p_damage

func _ready() -> void:
	add_to_group("danger_zones")
	collision_layer = 0
	collision_mask  = 2   # detect soldiers
	var shape := CircleShape2D.new()
	shape.radius = Balance.ZONE_RADIUS
	var cs := CollisionShape2D.new()
	cs.shape = shape
	add_child(cs)
	_build_sprite()
	queue_redraw()

func _build_sprite() -> void:
	var frames := SpriteFrames.new()
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")
	var any := false
	for pair in [["grow", "res://resources/boss/vine_grow"], ["thorns", "res://resources/boss/vine_thorn"]]:
		var anim: String = pair[0]
		frames.add_animation(anim)
		frames.set_animation_loop(anim, true)
		frames.set_animation_speed(anim, 10.0)
		var idx := 0
		while ResourceLoader.exists("%s/%d.png" % [pair[1], idx]):
			frames.add_frame(anim, load("%s/%d.png" % [pair[1], idx]))
			idx += 1
		if frames.get_frame_count(anim) > 0:
			any = true
	if not any:
		return
	_sprite = AnimatedSprite2D.new()
	_sprite.sprite_frames = frames
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var ref: Texture2D = _first_frame(frames)
	if ref:
		_base_scale = (Balance.ZONE_RADIUS * 2.0) / float(ref.get_width())
	var start_anim := "grow" if frames.get_frame_count("grow") > 0 else "thorns"
	_sprite.play(start_anim)
	_sprite.scale = Vector2.ONE * (_base_scale * 0.35)
	add_child(_sprite)

func _first_frame(frames: SpriteFrames) -> Texture2D:
	for anim in ["grow", "thorns"]:
		if frames.get_frame_count(anim) > 0:
			return frames.get_frame_texture(anim, 0)
	return null

func _process(delta: float) -> void:
	_elapsed     += delta
	_pulse_phase += delta
	queue_redraw()
	var active: bool = _elapsed >= warn_duration
	# Drive the bramble: grow to fill the circle during the telegraph, then bristle
	# red thorns once it's active.
	if _sprite:
		if not active:
			var g: float = clampf(_elapsed / maxf(warn_duration, 0.01), 0.0, 1.0)
			_sprite.scale = Vector2.ONE * (_base_scale * (0.35 + 0.65 * g))
			_sprite.modulate = Color(0.75, 1.0, 0.75, 0.6 + 0.4 * g)   # green, fading in
		else:
			_sprite.scale = Vector2.ONE * _base_scale
			if not _thorns_playing and _sprite.sprite_frames.get_frame_count("thorns") > 0:
				_sprite.play("thorns")
				_thorns_playing = true
			var pulse: float = 0.5 + 0.5 * sin(_pulse_phase * 9.0)
			_sprite.modulate = Color(1.0, 0.45 + 0.15 * pulse, 0.45, 1.0)  # angry red

	if _elapsed >= warn_duration + damage_duration:
		queue_free()
		return

	_tick_timer -= delta
	var do_damage: bool = active and _tick_timer <= 0.0
	if do_damage:
		_tick_timer = Balance.ZONE_DAMAGE_TICK
	for body in get_overlapping_bodies():
		if not body.is_in_group("soldiers"):
			continue
		if body.has_method("is_downed") and body.is_downed():
			continue
		if body.has_method("slow_down"):
			body.slow_down(VINE_SLOW, 0.2)
		if do_damage and body.has_method("take_damage"):
			body.take_damage(Balance.ZONE_DAMAGE_PER_TICK)

# Fallback footprint (only visible if the animated frames are missing).
func _draw() -> void:
	if _sprite:
		return
	var active: bool = _elapsed >= warn_duration
	var pulse: float = 0.5 + 0.5 * sin(_pulse_phase * 9.0)
	var col := Color(0.30, 0.55, 0.20, 0.5) if not active else Color(0.75, 0.12, 0.18, 0.55 + 0.2 * pulse)
	var g: float = 1.0 if active else clampf(_elapsed / maxf(warn_duration, 0.01), 0.0, 1.0)
	draw_circle(Vector2.ZERO, Balance.ZONE_RADIUS * (0.4 + 0.6 * g), col)
