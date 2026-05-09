extends StaticBody2D

var is_tree: bool = true

func _ready() -> void:
	var col := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 20.0
	col.shape = shape
	add_child(col)

	var nav_obs := NavigationObstacle2D.new()
	nav_obs.radius = 24.0
	add_child(nav_obs)

	queue_redraw()

func _draw() -> void:
	if is_tree:
		draw_circle(Vector2.ZERO, 22.0, Color(0.13, 0.52, 0.13))
		draw_arc(Vector2.ZERO, 22.0, 0.0, TAU, 24, Color(0.06, 0.33, 0.06), 2.5)
		draw_circle(Vector2(0.0, 10.0), 5.0, Color(0.42, 0.27, 0.10))
	else:
		var pts := PackedVector2Array([
			Vector2(-16,  3), Vector2(-9, -17), Vector2(9, -19),
			Vector2(19, -6), Vector2(16,  12), Vector2(2,  18), Vector2(-13, 11)
		])
		draw_colored_polygon(pts, Color(0.56, 0.53, 0.50))
		draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0.33, 0.30, 0.28), 2.0)
		draw_circle(Vector2(-4, -5), 4.0, Color(0.48, 0.45, 0.42))
