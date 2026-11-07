class_name Structure
extends Unit
## Tower (tier 1-3) or core (tier 4). Towers shoot; cores do not.
## Enemy structures carry the barrier: the hero alone deals reduced damage and can never
## finish them; they fall only while an allied lane creep is attacking them (D11, D13, D21).
## Tower defenders are not in this build yet.

signal hero_feedback(key: String)

var tier := 1
## Set in core.tscn; tower.tscn leaves it off.
@export var is_core := false
var barrier_enabled := false
var barrier: int = Rules.Barrier.ACTIVE
var last_suppressed_at := -1000.0
var reliable_gold := 0.0
var xp := 0.0
var projectile_speed := 15.0
var _feedback_cooldown := 0.0


func setup(p_match: Node, id: String, def: Dictionary, p_faction: int, mult := 1.0) -> void:
	super(p_match, id, def, p_faction, mult)
	reliable_gold = float(def.get("reliable_gold", 0.0))
	xp = float(def.get("xp", 0.0))
	projectile_speed = float(def.get("projectile_speed", 15.0))
	barrier_enabled = p_faction == Faction.ENEMY


## Structures cannot be stunned.
func apply_stun(_seconds: float) -> void:
	pass


func is_targetable() -> bool:
	return alive and match_ref.is_structure_vulnerable(self)


func _process(delta: float) -> void:
	if not alive or not match_ref.running:
		return
	tick_flash(delta)
	tick_status(delta)
	_feedback_cooldown -= delta
	update_barrier()
	if damage <= 0.0:
		return
	attack_timer = maxf(attack_timer - delta, 0.0)
	if not is_valid_target(target) or not in_attack_range(target):
		target = _acquire()
	if target != null and attack_timer <= 0.0:
		attack_timer = attack_cooldown
		match_ref.spawn_projectile(self, target, damage, projectile_speed)


func update_barrier() -> void:
	if not barrier_enabled:
		return
	var attacked: bool = match_ref.has_creep_attacking(self)
	var now: float = match_ref.time
	if attacked:
		last_suppressed_at = now
	var delay: float = match_ref.bal["barrier_restore_delay"]
	barrier = Rules.barrier_state(attacked, now, last_suppressed_at, delay)


## Creeps first (nearest), then the hero.
func _acquire() -> Unit:
	var best: Unit = null
	var best_score := INF
	for u: Unit in match_ref.enemies_of(faction):
		if not is_valid_target(u) or u is Structure or not in_attack_range(u):
			continue
		var score := (1000.0 if u.is_hero else 0.0) + flat_distance(u)
		if score < best_score:
			best_score = score
			best = u
	return best


func take_damage(amount: float, source: Unit) -> void:
	if not alive:
		return
	var from_hero := source != null and is_instance_valid(source) and source.is_hero
	if not is_targetable():
		if from_hero:
			_feedback("toast.invulnerable")
		return
	if from_hero:
		last_hit_by_hero_at = match_ref.time
		source.last_combat_at = match_ref.time
	var dealt := Rules.mitigate(amount, effective_armor())
	_flash = 0.1
	if barrier_enabled:
		update_barrier()
		var mult: float = match_ref.bal["barrier_damage_multiplier"]
		var before := hp
		hp = Rules.structure_hp_after_hit(hp, dealt, from_hero, barrier, mult)
		if from_hero:
			if barrier == Rules.Barrier.ACTIVE:
				_feedback("toast.barrier")
			elif hp >= 1.0 and before - dealt < 1.0:
				_feedback("toast.finish_blocked")
	else:
		hp -= dealt
	if hp <= 0.0:
		hp = 0.0
		die(source)


func _feedback(key: String) -> void:
	if _feedback_cooldown > 0.0:
		return
	_feedback_cooldown = 3.0
	hero_feedback.emit(key)


## Destroyed structures stay as rubble; they never come back this match.
func _on_died() -> void:
	target = null
	if body != null:
		body.scale = Vector3(1.0, 0.25, 1.0)
		body.position.y = 0.4
		var mat: StandardMaterial3D = body.material_override
		mat.albedo_color = Color(0.25, 0.25, 0.25)
