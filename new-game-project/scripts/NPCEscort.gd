# =============================================================================
# NPCEscort.gd  (Level 3 objective)
# A friendly NPC that must survive and reach the extraction zone.
# - "soldiers" group: enemies detect and target it automatically.
# - "escort_npc" group: ExtractionZone watches for this group.
# - escort_killed signal: Main.gd connects this to mission-fail.
# =============================================================================
extends CharacterBody2D

signal health_changed(current_hp: int, max_hp: int)
signal escort_killed

const MAX_HEALTH: int   = 5
const MOVE_SPEED: float = 80.0
const FOLLOW_DIST: float = 55.0

var _health: int = MAX_HEALTH
var _dead:   bool = false

@onready var nav_agent:  NavigationAgent2D = $NavigationAgent2D
@onready var health_bar: ProgressBar       = $HealthBar

func _ready() -> void:
	add_to_group("soldiers")    # enemies detect + target this
	add_to_group("escort_npc")  # extraction zone watches for this group
	_health              = MAX_HEALTH
	health_bar.max_value = MAX_HEALTH
	health_bar.value     = _health
	queue_redraw()
	await get_tree().physics_frame

func _physics_process(_delta: float) -> void:
	if _dead:
		return
	var squad_ctrl: Node = get_tree().get_first_node_in_group("squad_controller")
	if squad_ctrl and squad_ctrl.has_method("get_centroid"):
		var centroid: Vector2 = squad_ctrl.get_centroid()
		if global_position.distance_to(centroid) > FOLLOW_DIST:
			nav_agent.target_position = centroid
	if not nav_agent.is_navigation_finished():
		var next: Vector2 = nav_agent.get_next_path_position()
		velocity = (next - global_position).normalized() * MOVE_SPEED
	else:
		velocity = Vector2.ZERO
	move_and_slide()

func get_health() -> int:
	return _health

func take_damage(amount: int) -> void:
	if _dead:
		return
	_health -= amount
	health_bar.value = _health
	health_changed.emit(_health, MAX_HEALTH)
	if _health <= 0:
		_die()

func _die() -> void:
	_dead    = true
	velocity = Vector2.ZERO
	$CollisionShape2D.set_deferred("disabled", true)
	escort_killed.emit()
	queue_free()

func _draw() -> void:
	draw_circle(Vector2.ZERO, 14.0, Color(0.1, 0.85, 0.85))
	draw_arc(Vector2.ZERO, 14.0, 0.0, TAU, 24, Color(0.0, 0.5, 0.6), 2.5)
	draw_circle(Vector2.ZERO, 4.0, Color(0.0, 0.4, 0.5))
