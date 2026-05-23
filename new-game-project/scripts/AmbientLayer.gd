# =============================================================================
# AmbientLayer.gd
# Per-mission atmosphere controller — adds weather (rain / snow / clear),
# occasional bird flyovers, and a small pool of wandering critters. Purely
# visual; nothing here interacts with the squad or with gameplay state.
#
# Set `weather` before adding to the tree. Birds + critters are independent
# of weather; both fire on all non-clear AND clear missions.
#
# Architecture note: AmbientLayer itself tracks the camera so its child
# CPUParticles2D (rain / snow) always emits from a band just above the
# visible area. Birds and critters are added to AmbientLayer's PARENT (the
# SubViewport / world) so they live in world space and don't move with the
# camera — only the weather follows the player around.
# =============================================================================
class_name AmbientLayer
extends Node2D

enum Weather { CLEAR, RAIN, SNOW, FOG }

@export var weather: Weather   = Weather.CLEAR
@export var bird_flock_min: float = 8.0    # seconds between flocks (lower bound)
@export var bird_flock_max: float = 18.0
@export var critter_target: int   = 4      # target population on the map

# Birds drift through a band above the camera. Expressed as a ratio of the
# computed view half-height so it scales with the actual viewport instead
# of being hardcoded for one window size.
const SKY_BAND_RATIO: float = -0.85
# Padding outside the visible viewport for the fog rect and the weather
# emission band, so neither leaves visible seams at the screen edge.
const VIEW_PADDING: float = 220.0

var _camera:       Camera2D       = null
var _weather_emit: CPUParticles2D = null
var _bird_timer:   float          = 4.0    # first flock a few seconds in
var _map_rect:     Rect2          = Rect2()
# View extents derived from the actual viewport + camera zoom each frame.
# Stored as members so _draw / _spawn_bird_flock can read them directly.
var _view_half_w:  float          = 800.0
var _view_half_h:  float          = 500.0
# FOG-only — drawn via _draw with a high z_index so it tints squad/critters
# /birds but stays underneath any future overlay (HUD, banner toasts).
var _fog_active:   bool           = false
const _FOG_COLOR  := Color(0.85, 0.88, 0.92, 0.42)
const _FOG_Z      := 45
# Per-weather particle textures, generated once per AmbientLayer instance.
# Without a texture, CPUParticles2D renders as single white pixels that
# are invisible at the squad's view distance. Snow uses a soft round
# flake, rain uses a vertical streak so it actually reads as rain.
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
		_bird_timer = randf_range(bird_flock_min, bird_flock_max)
		_spawn_bird_flock()
	# Top up critters if any have despawned (they currently don't, but this
	# also catches scene-tree edge cases on retry).
	if get_tree().get_nodes_in_group("ambient_critters").size() < critter_target:
		_spawn_critter()

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
		# Keep this in sync with _setup_weather — emission is a full-area
		# rectangle centred on the camera, not a thin top-band any more.
		# Wrong shape here was making weather collapse back into a strip
		# at the top of the screen on every zoom change.
		_weather_emit.emission_rect_extents = Vector2(
			_view_half_w + VIEW_PADDING,
			_view_half_h + VIEW_PADDING,
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
	# Fog gets a simple full-screen tint via _draw instead of particles —
	# realistic wispy fog would need a soft texture; this is a cheap and
	# readable stand-in. z_index 45 puts it over the squad / critters /
	# birds while staying under any future overlay particles at 50.
	if weather == Weather.FOG:
		_fog_active = true
		z_index = _FOG_Z
		queue_redraw()
		return
	var p := CPUParticles2D.new()
	p.local_coords = false   # particles render in world space, not local
	p.emitting     = true
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	# Emit across the FULL visible area (not just a strip at the top) so
	# particles cover wide / zoomed-out viewports. Each particle's short
	# lifetime + alpha fade makes it look like snow / rain falling through
	# the air, not "spawning from a ceiling and dropping to the floor".
	# _refresh_view_extents() keeps the emission rect in sync if zoom or
	# window size changes mid-play.
	p.emission_rect_extents = Vector2(_view_half_w + VIEW_PADDING,
			_view_half_h + VIEW_PADDING)
	p.position = Vector2.ZERO
	p.z_index  = 50  # over terrain AND over the squad — weather is on top
	if weather == Weather.RAIN:
		p.texture      = _rain_tex     # tall vertical streak
		p.amount       = 500
		p.lifetime     = 0.9
		p.direction    = Vector2(0.18, 1.0).normalized()
		p.spread       = 4.0
		p.initial_velocity_min = 320.0
		p.initial_velocity_max = 460.0
		p.gravity              = Vector2(0.0, 700.0)
		p.scale_amount_min     = 1.0
		p.scale_amount_max     = 1.5
		# Gentle growth for a touch of depth without making early particles
		# invisible (the strong 0.35 start was the cause of the "starts at
		# top, ends at a point" look).
		var rain_grow := Curve.new()
		rain_grow.add_point(Vector2(0.0, 0.7))
		rain_grow.add_point(Vector2(1.0, 1.0))
		p.scale_amount_curve = rain_grow
		# Quick fade-in at spawn so streaks appear to materialise in the
		# air (not pop out of nowhere); held alpha through most of the
		# life; clean fade-out at end so nothing pops out of existence.
		var ramp := Gradient.new()
		ramp.set_color(0, Color(0.72, 0.83, 1.0, 0.0))
		ramp.add_point(0.15, Color(0.72, 0.83, 1.0, 0.90))
		ramp.add_point(0.85, Color(0.72, 0.83, 1.0, 0.85))
		ramp.set_color(1, Color(0.72, 0.83, 1.0, 0.0))
		p.color_ramp = ramp
	else:   # SNOW
		p.texture      = _snow_tex     # soft round flake
		p.amount       = 320
		p.lifetime     = 2.8
		p.direction    = Vector2(0.25, 1.0).normalized()
		p.spread       = 35.0
		# Gentle drift with light gravity — flakes hang in the air instead
		# of plummeting through it.
		p.initial_velocity_min = 15.0
		p.initial_velocity_max = 45.0
		p.gravity              = Vector2(0.0, 40.0)
		p.tangential_accel_min = -25.0
		p.tangential_accel_max = 25.0
		p.scale_amount_min     = 1.8
		p.scale_amount_max     = 3.6
		var snow_grow := Curve.new()
		snow_grow.add_point(Vector2(0.0, 0.7))
		snow_grow.add_point(Vector2(1.0, 1.0))
		p.scale_amount_curve = snow_grow
		# Fade in / hold / fade out — flakes appear in mid-air, persist,
		# then melt away. Symmetric ramp covers the full visible area
		# uniformly regardless of where each particle was spawned.
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
	var y_offset: float = _view_half_h * SKY_BAND_RATIO + randf_range(-50.0, 60.0)
	for i in count:
		var bird := AmbientBird.new()
		var start_x: float = cam_pos.x - float(dir) * (_view_half_w + 100.0 + float(i) * 26.0)
		var start_y: float = cam_pos.y + y_offset + randf_range(-15.0, 15.0)
		# Travel a couple of screen widths so they cross the visible area
		# even if the player has scrolled along their direction of travel.
		# add_child first — setup writes global_position which needs a parent.
		parent.add_child(bird)
		bird.setup(Vector2(start_x, start_y), dir, _view_half_w * 4.0)

# ---------------------------------------------------------------------------
# Critters — pool of wanderers in random map cells.
# ---------------------------------------------------------------------------
func _spawn_initial_critters() -> void:
	for i in critter_target:
		_spawn_critter()

func _spawn_critter() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var c := AmbientCritter.new()
	c.add_to_group("ambient_critters")
	var x: float = randf_range(_map_rect.position.x + 64.0, _map_rect.end.x - 64.0)
	var y: float = randf_range(_map_rect.position.y + 64.0, _map_rect.end.y - 64.0)
	# IMPORTANT: add to the tree BEFORE calling setup() — setup() picks a
	# wander target via map_gen lookup through get_tree(), which returns
	# null for orphan nodes.
	parent.add_child(c)
	c.setup(Vector2(x, y), _map_rect)

# Draws the fog tint when FOG is active. The rect is centred on AmbientLayer
# (which tracks the camera each frame), and sized from the live viewport
# extents so it always covers the visible area regardless of window size
# or camera zoom.
func _draw() -> void:
	if not _fog_active:
		return
	var w: float = _view_half_w + VIEW_PADDING
	var h: float = _view_half_h + VIEW_PADDING
	draw_rect(Rect2(-w, -h, w * 2.0, h * 2.0), _FOG_COLOR)
