// Circular soft-edge fade for the fairy garden background sprite.
// The centre of the sprite is fully opaque; the edges fade to transparent
// so the sprite blends into whatever terrain sits underneath it.
shader_type canvas_item;

// Fraction of the sprite half-width at which the fade begins (0 = centre, 1 = edge).
uniform float fade_start : hint_range(0.0, 1.0) = 0.55;
// Width of the fade band expressed as the same fraction.
uniform float fade_width : hint_range(0.01, 0.5) = 0.35;

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	// Distance from centre in UV space (0 = centre, ~0.7 at corners).
	vec2 off = UV - vec2(0.5);
	float dist = length(off) * 2.0;   // normalise so 1.0 = edge of inscribed circle
	float alpha = 1.0 - smoothstep(fade_start, fade_start + fade_width, dist);
	COLOR = vec4(col.rgb, col.a * alpha);
}
