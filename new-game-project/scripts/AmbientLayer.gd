# =============================================================================
# AmbientLayer.gd
# Per-mission atmosphere controller — weather (rain / snow / fog / clear),
# bird flyovers, and a pool of wandering critters. Purely visual.
#
# Set `weather` before adding to the tree. All numeric tunables (particle
# counts, fog colour, bird cadence, critter pop, z-order) live in
# BalanceConfig under the WEATHER_* and AMBIENT_* prefixes.
#
# Architecture: AmbientLayer tracks the camera so its child CPUParticles2D
# always emits over the visible area. Birds and critters are added to
# AmbientLayer's PARENT (the world) so they live in world space — only the
# weather follows the player.
# =============================================================================
class_name AmbientLayer
extends Node2D

const Balance = preload("res://scripts/BalanceConfig.gd")

enum Weather { CLEAR, RAIN, SNOW, FOG }

@export var weather: Weather = Weather.CLEAR

var _camera:       Camera2D       = null
var _weather_emit: CPUParticles2D = null
var _bird_timer:   float          = 4.0    # first flock a few seconds in
var _map_rect:     Rect2          = Rect2()
# View extents derived from the actual viewport + camera zoom each frame.
var _view_half_w:  float          = 800.0
var _view_half_h:  float          = 500.0
# FOG-only — drawn via _draw with a high z_index so it tints squad/critters
# /birds but stays underneath any future overlay.
var _fog_active:   bool           = false
# Per-weather particle textures generated once per AmbientLayer instance.
# Without a texture, CPUParticles2D renders as single white pixels that are
# invisible at the squad's view distance.
var _snow_tex: ImageTexture = null
var _rain_tex: ImageTexture = null

func _ready() -> void:
	_camera = get_tree().get_first_node_in_group("main_camera") as Camera2D
	var map_gen: Node = get_tree().get_first_node_in_group("map_generator")
	if map_gen and map_gen.has_method("get_map_rect"):
		_map_rect = map_gen.get_map_rect()
	else:
		_map_rect = Rect2(Vector2.ZERO, Vector2(3000.0, 3000.0))
	_snow_tex = _make_soft_circle_texture(6)
	_rain_tex = _make_streak_texture(2, 18)
	_refresh_view_extents()
	_setup_weather()
	_spawn_initial_critters()

func _process(delta: float) -> void:
	# Keep AmbientLayer pinned to the camera so the weather emitter (a child)
	# is always in the right spot. Birds + critters live in the PARENT scene
	# and don't move with us.
	if _camera:
		global_position = _camera.global_position
	_refresh_view_extents()
	# Bird flock cadence.
	_bird_timer -= delta
	if _bird_timer <= 0.0:
		_bird_timer = randf_range(Balance.AMBIENT_BIRD_FLOCK_MIN_SEC,
				Balance.AMBIENT_BIRD_FLOCK_MAX_SEC)
		_spawn_bird_flock()
	# Top up each critter type independently if any have despawned.
	if get_tree().get_nodes_in_group("critter_bunny").size() < Balance.AMBIENT_CRITTER_TARGET:
		_spawn_critter(AmbientCritter.Type.BUNNY)
	elif get_tree().get_nodes_in_group("critter_fox").size() < Balance.AMBIENT_FOX_TARGET:
		_spawn_critter(AmbientCritter.Type.FOX)

# Pulls the viewport size and the camera's zoom into our view-extent vars.
# Cheap; running every frame so weather + fog stay in sync if the window
# resizes or the camera zooms during play.
func _refresh_view_extents() -> void:
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var zoom: Vector2 = Vector2.ONE
	if _camera and _camera.zoom != Vector2.ZERO:
		zoom = _camera.zoom
	var new_w: float = (vp_size.x * 0.5) / maxf(zoom.x, 0.01)
	var new_h: float = (vp_size.y * 0.5) / maxf(zoom.y, 0.01)
	# Only push updates downstream if the size actually changed by a real
	# amount — avoids re-emitting redraws on sub-pixel jitter.
	if absf(new_w - _view_half_w) < 1.0 and absf(new_h - _view_half_h) < 1.0:
		return
	_view_half_w = new_w
	_view_half_h = new_h
	if _weather_emit:
		# Match _setup_weather: full-area emission centred on the camera so
		# weather covers wide / zoomed-out viewports.
		_weather_emit.emission_rect_extents = Vector2(
			_view_half_w + Balance.WEATHER_VIEW_PADDING,
			_view_half_h + Balance.WEATHER_VIEW_PADDING,
		)
		_weather_emit.position = Vector2.ZERO
	if _fog_active:
		queue_redraw()

# Tiny soft-circle ImageTexture used as the particle sprite for snow.
# Without a texture, CPUParticles2D renders as single white pixels which
# are invisible at the player's view distance.
static func _make_soft_circle_texture(radius: int) -> ImageTexture:
	var size: int = (radius + 1) * 2
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c: float = float(radius) + 0.5
	for y in size:
		for x in size:
			var dx: float = float(x) - c
			var dy: float = float(y) - c
			var d:  float = sqrt(dx * dx + dy * dy)
			if d <= radius:
				var t: float = 1.0 - (d / float(radius))
				img.set_pixel(x, y, Color(1, 1, 1, t * t))   # quadratic falloff
	return ImageTexture.create_from_image(img)

# Tall vertical streak ImageTexture for rain. Alpha tapers at the top and
# bottom so adjacent raindrops blend smoothly rather than reading as fixed
# rectangles. CPUParticles2D doesn't rotate sprites to match travel
# direction, but rain falls mostly vertical (4° spread + 10° wind) so the
# upright streak orientation looks right.
static func _make_streak_texture(width: int, height: int) -> ImageTexture:
	var img := Image.create(width, height, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cy: float = float(height - 1) * 0.5
	for y in height:
		var t: float = 1.0 - absf(float(y) - cy) / cy
		var alpha: float = t * t   # quadratic taper at both ends
		for x in width:
			img.set_pixel(x, y, Color(1, 1, 1, alpha))
	return ImageTexture.create_from_image(img)

# ---------------------------------------------------------------------------
# Weather
# ---------------------------------------------------------------------------
func _setup_weather() -> void:
	if weather == Weather.CLEAR:
		return
	# Fog is a full-screen tint via _draw — cheap stand-in for wispy fog.
	if weather == Weather.FOG:
		_fog_active = true
		z_index = Balance.WEATHER_FOG_Z
		queue_redraw()
		return
	var p := CPUParticles2D.new()
	p.local_coords = false
	p.emitting     = true
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	# Emit across the full visible area; _refresh_view_extents() keeps the
	# rect in sync with zoom / window size.
	p.emission_rect_extents = Vector2(_view_half_w + Balance.WEATHER_VIEW_PADDING,
			_view_half_h + Balance.WEATHER_VIEW_PADDING)
	p.position = Vector2.ZERO
	p.z_index  = Balance.WEATHER_PARTICLE_Z
	if weather == Weather.RAIN:
		p.texture      = _rain_tex
		p.amount       = Balance.WEATHER_RAIN_AMOUNT
		p.lifetime     = Balance.WEATHER_RAIN_LIFETIME
		p.direction    = Balance.WEATHER_RAIN_DIRECTION.normalized()
		p.spread       = Balance.WEATHER_RAIN_SPREAD
		p.initial_velocity_min = Balance.WEATHER_RAIN_VELOCITY_MIN
		p.initial_velocity_max = Balance.WEATHER_RAIN_VELOCITY_MAX
		p.gravity              = Balance.WEATHER_RAIN_GRAVITY
		p.scale_amount_min     = Balance.WEATHER_RAIN_SCALE_MIN
		p.scale_amount_max     = Balance.WEATHER_RAIN_SCALE_MAX
		# Gentle scale growth + soft fade-in/out gradient — visual finesse,
		# not designer-facing, so kept in-script rather than in Balance.
		var rain_grow := Curve.new()
		rain_grow.add_point(Vector2(0.0, 0.7))
		rain_grow.add_point(Vector2(1.0, 1.0))
		p.scale_amount_curve = rain_grow
		var ramp := Gradient.new()
		ramp.set_color(0, Color(0.72, 0.83, 1.0, 0.0))
		ramp.add_point(0.15, Color(0.72, 0.83, 1.0, 0.90))
		ramp.add_point(0.85, Color(0.72, 0.83, 1.0, 0.85))
		ramp.set_color(1, Color(0.72, 0.83, 1.0, 0.0))
		p.color_ramp = ramp
	else:   # SNOW
		p.texture      = _snow_tex
		p.amount       = Balance.WEATHER_SNOW_AMOUNT
		p.lifetime     = Balance.WEATHER_SNOW_LIFETIME
		p.direction    = Balance.WEATHER_SNOW_DIRECTION.normalized()
		p.spread       = Balance.WEATHER_SNOW_SPREAD
		p.initial_velocity_min = Balance.WEATHER_SNOW_VELOCITY_MIN
		p.initial_velocity_max = Balance.WEATHER_SNOW_VELOCITY_MAX
		p.gravity              = Balance.WEATHER_SNOW_GRAVITY
		p.tangential_accel_min = Balance.WEATHER_SNOW_TANGENTIAL_MIN
		p.tangential_accel_max = Balance.WEATHER_SNOW_TANGENTIAL_MAX
		p.scale_amount_min     = Balance.WEATHER_SNOW_SCALE_MIN
		p.scale_amount_max     = Balance.WEATHER_SNOW_SCALE_MAX
		var snow_grow := Curve.new()
		snow_grow.add_point(Vector2(0.0, 0.7))
		snow_grow.add_point(Vector2(1.0, 1.0))
		p.scale_amount_curve = snow_grow
		var ramp := Gradient.new()
		ramp.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
		ramp.add_point(0.15, Color(1.0, 1.0, 1.0, 0.90))
		ramp.add_point(0.80, Color(1.0, 1.0, 1.0, 0.85))
		ramp.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
		p.color_ramp = ramp
	add_child(p)
	_weather_emit = p

# ---------------------------------------------------------------------------
# Birds — spawn in flocks at the edge of view, fly across in world space.
# ---------------------------------------------------------------------------
func _spawn_bird_flock() -> void:
	if _camera == null:
		return
	var parent: Node = get_parent()
	if parent == null:
		return
	var count: int = randi_range(3, 6)
	var dir:   int = 1 if randf() < 0.5 else -1
	var cam_pos: Vector2 = _camera.global_position
	var y_offset: float = _view_half_h * Balance.AMBIENT_BIRD_SKY_BAND_RATIO + randf_range(-50.0, 60.0)
	# All birds in a flock are the same species; type varies flock-to-flock.
	# DARK is excluded — the silhouette style clashes with the coloured sprites.
	const FLOCK_TYPES := [AmbientBird.BirdType.BLUE_JAY, AmbientBird.BirdType.RED_ROBIN,
			AmbientBird.BirdType.YELLOW_CANARY, AmbientBird.BirdType.GREEN_PARAKEET]
	var btype: AmbientBird.BirdType = FLOCK_TYPES[randi() % FLOCK_TYPES.size()]
	for i in count:
		var bird := AmbientBird.new()
		var start_x: float = cam_pos.x - float(dir) * (_view_half_w + 100.0 + float(i) * 26.0)
		var start_y: float = cam_pos.y + y_offset + randf_range(-15.0, 15.0)
		# add_child first — setup writes global_position which needs a parent.
		parent.add_child(bird)
		bird.setup(Vector2(start_x, start_y), dir, _view_half_w * 4.0, btype)

# ---------------------------------------------------------------------------
# Critters — pool of wanderers in random map cells.
# ---------------------------------------------------------------------------
func _spawn_initial_critters() -> void:
	for i in Balance.AMBIENT_CRITTER_TARGET:
		_spawn_critter(AmbientCritter.Type.BUNNY)
	for i in Balance.AMBIENT_FOX_TARGET:
		_spawn_critter(AmbientCritter.Type.FOX)

func _spawn_critter(critter_type: AmbientCritter.Type) -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var c := AmbientCritter.new()
	# Type must be set BEFORE add_child() — _ready() runs synchronously inside
	# add_child() and reads the type to join the correct group. If we set it
	# after, every critter defaults to BUNNY and the fox group stays empty,
	# causing the top-up check to fire every frame.
	c.type = critter_type
	var x: float = randf_range(_map_rect.position.x + 64.0, _map_rect.end.x - 64.0)
	var y: float = randf_range(_map_rect.position.y + 64.0, _map_rect.end.y - 64.0)
	parent.add_child(c)
	c.setup(Vector2(x, y), _map_rect, critter_type)

# Draws the fog tint when FOG is active. The rect is centred on AmbientLayer
# (which tracks the camera each frame), and sized from the live viewport
# extents so it always covers the visible area regardless of window size
# or camera zoom.
func _draw() -> void:
	if not _fog_active:
		return
	var w: float = _view_half_w + Balance.WEATHER_VIEW_PADDING
	var h: float = _view_half_h + Balance.WEATHER_VIEW_PADDING
	draw_rect(Rect2(-w, -h, w * 2.0, h * 2.0), Balance.WEATHER_FOG_COLOR)
