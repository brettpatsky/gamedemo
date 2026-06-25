# =============================================================================
# LightingUtil.gd
# Shared helpers for 2D night lighting. A single soft radial gradient texture is
# built once and reused by every PointLight2D (soldiers, lanterns, totems, the
# portal beacon) so dark levels like the Blighted Marsh stay cheap.
#
# No class_name on purpose — consumers `preload` it as a const so it resolves
# regardless of global-class indexing order.
# =============================================================================

static var _radial: GradientTexture2D = null

# Soft white→transparent radial gradient, cached across all callers.
static func radial_texture() -> GradientTexture2D:
	if _radial != null:
		return _radial
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 256
	gt.height = 256
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	_radial = gt
	return _radial

# Build a configured PointLight2D ready to add to the scene.
static func make_light(color: Color, energy: float, scale: float) -> PointLight2D:
	var light := PointLight2D.new()
	light.texture = radial_texture()
	light.color = color
	light.energy = energy
	light.texture_scale = scale
	return light
