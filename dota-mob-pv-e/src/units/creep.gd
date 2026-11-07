class_name Creep
extends Unit
## Lane creep: walks to the enemy base and fights the nearest enemy on the way.
## Target priority: enemy creeps, then vulnerable structures, then the hero
## (the hero is chased only after hitting this creep or when nothing else is near).

var aggro_radius := 5.0
var gold := 0.0
var xp := 0.0
var projectile_speed := 0.0
var structure_damage_mult := 1.0
var lane_z := 0.0
var _retarget := 0.0


func setup(p_match: Node, id: String, def: Dictionary, p_faction: int, mult := 1.0) -> void:
	super(p_match, id, def, p_faction, mult)
	aggro_radius = float(def.get("aggro_radius", 5.0))
	gold = float(def.get("gold", 0.0))
	xp = float(def.get("xp", 0.0))
	projectile_speed = float(def.get("projectile_speed", 0.0))
	structure_damage_mult = float(def.get("structure_damage_mult", 1.0))


func _process(delta: float) -> void:
	if not alive or not match_ref.running:
		return
	tick_flash(delta)
	if tick_status(delta):
		return
	attack_timer = maxf(attack_timer - delta, 0.0)
	_retarget -= delta
	if not _target_still_good():
		target = _acquire()
		_retarget = 0.5
	elif _retarget <= 0.0:
		_retarget = 0.5
		var better := _acquire()
		if better != null and _priority(better) < _priority(target):
			target = better
	if target != null:
		if in_attack_range(target):
			face(target.global_position - global_position)
			if attack_timer <= 0.0:
				_attack(target)
		else:
			move_towards(target.global_position, delta)
	else:
		var goal_x: float = match_ref.lane_goal_x(faction)
		move_towards(Vector3(goal_x, 0.0, lane_z), delta)
	_separate(delta)


func _target_still_good() -> bool:
	if not is_valid_target(target):
		return false
	if not target.is_targetable():
		return false
	return flat_distance(target) <= aggro_radius * 1.6 + target.radius


## Lower is more important.
func _priority(u: Unit) -> int:
	if u is Creep:
		return 0
	if u is Structure:
		return 1
	return 2


func _acquire() -> Unit:
	var best: Unit = null
	var best_score := INF
	var now: float = match_ref.time
	var aggro_seconds: float = match_ref.bal["creep_hero_aggro_seconds"]
	var hero_aggro: bool = now - last_hit_by_hero_at <= aggro_seconds
	for u: Unit in match_ref.enemies_of(faction):
		if not is_valid_target(u) or not u.is_targetable():
			continue
		var dist := flat_distance(u) - u.radius
		if dist > aggro_radius:
			continue
		var prio := _priority(u)
		if u.is_hero and hero_aggro:
			prio = -1
		var score := prio * 1000.0 + dist
		if score < best_score:
			best_score = score
			best = u
	return best


func _attack(t: Unit) -> void:
	attack_timer = attack_cooldown
	var dmg := damage * (structure_damage_mult if t is Structure else 1.0)
	if projectile_speed > 0.0:
		match_ref.spawn_projectile(self, t, dmg, projectile_speed)
	else:
		_lunge()
		t.take_damage(dmg, self)


## Short forward bump so melee hits read on screen.
func _lunge() -> void:
	if body == null or not is_inside_tree():
		return
	var rest := Vector3(0.0, body.position.y, 0.0)
	var forward := body.transform.basis.z.normalized() * 0.35
	var tw := create_tween()
	tw.tween_property(body, "position", rest + forward, 0.07)
	tw.tween_property(body, "position", rest, 0.12)


func _separate(delta: float) -> void:
	var push := Vector3.ZERO
	for c in match_ref.creeps:
		if c == self or not is_instance_valid(c) or not c.alive:
			continue
		var d: Vector3 = global_position - c.global_position
		d.y = 0.0
		var min_d: float = radius + c.radius
		var dist := d.length()
		if dist < min_d and dist > 0.0001:
			push += d / dist * (min_d - dist)
	global_position += push * minf(1.0, delta * 8.0)
