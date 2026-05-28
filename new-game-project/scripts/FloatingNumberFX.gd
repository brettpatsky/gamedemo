# FloatingNumberFX.gd
# Small popup number that drifts up and fades — spawned when a character
# takes damage so the player gets crisp feedback per hit. Added directly to
# the viewport (world space) so it survives if the source node dies on the
# same frame. Tunables (rise distance, lifetime, font size, drift) live at
# the top of this script rather than BalanceConfig — they're purely cosmetic
# and there's no per-mission reason to vary them.
extends Node2D

const RISE_DISTANCE: float = 36.0
const DRIFT_X:       float = 12.0   # max horizontal jitter, randomised per spawn
const LIFETIME:      float = 0.75
const FONT_SIZE:     int   = 18
const OUTLINE_SIZE:  int   = 4

var _label: Label = null

# amount: the damage value to show.
# color:  text colour (red for enemy hits on the squad, yellow for squad hits
#         on enemies, green for heals, etc.).
func start(amount: int, color: Color = Color(1, 0.3, 0.3)) -> void:
	_label = Label.new()
	_label.text = str(amount)
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_label.add_theme_color_override("font_color", color)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-20, -8)  # rough centre on origin
	_label.custom_minimum_size = Vector2(40, 0)
	add_child(_label)

	var drift_x: float = randf_range(-DRIFT_X, DRIFT_X)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "position",
			position + Vector2(drift_x, -RISE_DISTANCE), LIFETIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_label, "modulate:a", 0.0, LIFETIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(queue_free)
