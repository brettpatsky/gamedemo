# =============================================================================
# PortalVisual.gd
# Shared loader for the PixelLab-generated portal idle-swirl animations. Each
# portal's art ships as a single horizontal strip PNG (square frames) under
# resources/portals/. Builds a SpriteFrames with one looping "idle" animation.
# =============================================================================
class_name PortalVisual
extends RefCounted

static func build_sprite_frames(strip_path: String, fps: float = 10.0) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	frames.add_animation(&"idle")
	frames.set_animation_loop(&"idle", true)
	frames.set_animation_speed(&"idle", fps)
	if not ResourceLoader.exists(strip_path):
		return frames
	var tex: Texture2D = load(strip_path)
	if tex == null:
		return frames
	var img: Image = tex.get_image()
	var frame_h: int = img.get_height()
	if frame_h <= 0:
		return frames
	@warning_ignore("integer_division")
	var frame_count: int = img.get_width() / frame_h
	for i in frame_count:
		var sub := Image.create(frame_h, frame_h, false, img.get_format())
		sub.blit_rect(img, Rect2i(i * frame_h, 0, frame_h, frame_h), Vector2i.ZERO)
		frames.add_frame(&"idle", ImageTexture.create_from_image(sub))
	return frames
