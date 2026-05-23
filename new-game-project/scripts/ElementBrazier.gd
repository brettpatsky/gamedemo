# =============================================================================
# ElementBrazier.gd
# Puzzle prop for the tutorial's Elements room. Plugs into the existing
# bullet → take_damage → element pipeline: when a Bullet stamped with the
# matching element hits the brazier, it lights and stays lit. Wrong-element
# shots are silently consumed (teaches "wrong element wastes a shot").
#
# Set `required_element` to one of the Elements.E.* values when spawning.
# Listen for the `lit(element)` signal to chain into puzzle completion.
# =============================================================================
class_name ElementBrazier
extends StaticBody2D

signal lit(element: int)

@export var required_element: int   = 0     # Elements.E.NONE — set before adding
@export var radius:           float = 28.0

var _lit:   bool = false
var _shape: CollisionShape2D = null

func _ready() -> void:
	add_to_group("element_braziers")
	var shape := CircleShape2D.new()
	shape.radius = radius
	_shape = CollisionShape2D.new()
	_shape.shape = shape
	add_child(_shape)
	# Sits on the environment layer so bullets (mask 1+2) collide and route
	# through Bullet._try_hit → take_damage(amount, element). Soldiers walk
	# past freely because they're on layer 2 with mask 1 only.
	collision_layer = 1
	collision_mask  = 0
	queue_redraw()

# Bullet.gd calls take_damage(amount, element). The amount is irrelevant
# here — only the element decides whether the brazier lights.
func take_damage(_amount: int, element: int = 0) -> void:
	if _lit:
		return
	if element != required_element:
		return
	_lit = true
	emit_signal("lit", required_element)
	queue_redraw()

func is_lit() -> bool:
	return _lit

# Placeholder visuals — a dim crystal of the required colour when unlit,
# a bright flame disc once lit. Easy swap for real art later.
func _draw() -> void:
	var col: Color = Elements.color_of(required_element)
	# Stone plinth base.
	draw_circle(Vector2.ZERO, radius, Color(0.22, 0.18, 0.14))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32, Color(0.50, 0.40, 0.30), 2.0)
	if _lit:
		draw_circle(Vector2.ZERO, radius * 0.66, col)
		draw_arc(Vector2.ZERO, radius * 0.85, 0.0, TAU, 32, col.lightened(0.45), 2.5)
		# Inner spark for a bit more pop.
		draw_circle(Vector2.ZERO, radius * 0.28, Color(1, 1, 1, 0.85))
	else:
		var muted: Color = Color(col.r, col.g, col.b, 0.38)
		draw_circle(Vector2.ZERO, radius * 0.42, muted)
		draw_arc(Vector2.ZERO, radius * 0.58, 0.0, TAU, 24, col.darkened(0.35), 1.5)
