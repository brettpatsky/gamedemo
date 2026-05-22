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
signal joined_squad

const MAX_HEALTH: int   = 5
const MOVE_SPEED: float = 130.0
# Stop this far from the nearest squad member rather than diving into the
# centroid — pushing into the middle of the formation knocked soldiers around
# and made the NPC physically jam against squad capsules.
const FOLLOW_DIST: float = 70.0

var _health: int = MAX_HEALTH
var _dead:   bool = false
var _freed:  bool = false   # set true once a sheltering wall is destroyed
var _joined: bool = false   # set true the first time we reach the squad

# Stuck-recovery — same escalation pattern as Soldier/Enemy. The VIP getting
# wedged forever was the most disruptive case because the mission stalls.
const Balance = preload("res://scripts/BalanceConfig.gd")
var _stuck_timer:     float   = 0.0
var _stuck_check_pos: Vector2 = Vector2.ZERO
var _stuck_strikes:   int     = 0

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

func _physics_process(delta: float) -> void:
	if _dead:
		return
	# Stay put inside the shelter until the squad blows open a wall.
	if not _freed:
		velocity = Vector2.ZERO
		move_and_slide()
		return
	# Track the nearest live squad member rather than the centroid so the NPC
	# trails on the edge of the formation instead of jamming into it.
	var nearest: Node2D = _nearest_soldier()
	if nearest != null:
		var dist: float = global_position.distance_to(nearest.global_position)
		if dist > FOLLOW_DIST:
			nav_agent.target_position = nearest.global_position
		elif not _joined:
			_joined = true
			joined_squad.emit()
	_tick_stuck_check(delta)
	if not nav_agent.is_navigation_finished():
		var next: Vector2 = nav_agent.get_next_path_position()
		velocity = (next - global_position).normalized() * MOVE_SPEED
	else:
		velocity = Vector2.ZERO
	move_and_slide()

# Same stuck-recovery escalation as Soldier/Enemy. Important here because a
# wedged VIP halts the mission outright — without the hard-unstick the only
# fix was to retry the level.
func _tick_stuck_check(delta: float) -> void:
	if nav_agent.is_navigation_finished():
		_stuck_strikes = 0
		_stuck_check_pos = global_position
		return
	_stuck_timer -= delta
	if _stuck_timer > 0.0:
		return
	_stuck_timer = Balance.NPC_STUCK_CHECK_INTERVAL
	var moved: bool = global_position.distance_to(_stuck_check_pos) >= Balance.NPC_STUCK_THRESHOLD
	_stuck_check_pos = global_position
	if moved:
		_stuck_strikes = 0
		return
	_stuck_strikes += 1
	if _stuck_strikes >= Balance.NPC_STUCK_HARD_STRIKES:
		_hard_unstick()
		_stuck_strikes = 0

func _hard_unstick() -> void:
	if nav_agent.is_navigation_finished():
		return
	var next: Vector2 = nav_agent.get_next_path_position()
	var diff: Vector2 = next - global_position
	if diff.length() < 1.0:
		return
	global_position += diff.normalized() * minf(diff.length(), 64.0)

func _nearest_soldier() -> Node2D:
	var best: Node2D = null
	var best_d: float = INF
	for s in get_tree().get_nodes_in_group("soldiers"):
		if s == self or not is_instance_valid(s):
			continue
		# Skip downed soldiers — the NPC chasing a corpse looks broken.
		if s.has_method("is_downed") and s.is_downed():
			continue
		var d: float = (s as Node2D).global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best   = s
	return best

func release() -> void:
	_freed = true

func is_freed() -> bool:
	return _freed

func has_joined_squad() -> bool:
	return _joined

func get_health() -> int:
	return _health

func take_damage(amount: int) -> void:
	# Invulnerable inside the shelter — a stray enemy shot before the squad
	# arrives shouldn't be able to kill the NPC before they can be freed.
	if _dead or not _freed:
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
