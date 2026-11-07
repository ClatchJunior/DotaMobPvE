class_name Hero
extends Unit
## Vanguard, the player's hero. Basic attack works like in Mobile Legends (D19):
## auto mode picks the target itself; semi-auto mode lets the player aim the attack button
## at a target. Moving with the joystick cancels the current attack order.
## Skills (data/skills.json): Q Cleave Strike (cone), W Guard Dash (dash + damage reduction),
## R Warbreaker (area stun + armor break), P Battle Instinct (attack speed stacks).

signal recall_interrupted
signal cast_failed(reason: String)
signal cast_done(slot: String)

const ACTIVE_SLOTS := ["q", "w", "r"]

var max_mana := 100.0
var mana := 100.0
var hp_regen := 0.0
var mana_regen := 0.0
var acquire_radius := 7.0
var move_input := Vector2.ZERO
var attack_held := false
var order_target: Unit = null
var aim_target: Unit = null
var respawn_left := 0.0
var recall_left := -1.0
var settings: Node = null
var skill_defs: Dictionary = {}
var ranks := {"q": 0, "w": 0, "r": 0, "p": 0}
var cooldowns := {"q": 0.0, "w": 0.0, "r": 0.0}
## Skill being aimed on the HUD ("" when none) and its direction in screen space (-1..1).
var aiming_slot := ""
var aiming_dir := Vector2.ZERO
var damage_reduction := 0.0
var damage_reduction_left := 0.0
var instinct_stacks := 0
var instinct_left := 0.0
var _dash_left := 0.0
var _dash_velocity := Vector3.ZERO
## Stats are rebuilt by recalc_stats(): units.json base + level stat packages + item passives.
var stat_packages := 0
var _base_def: Dictionary = {}
var item_attack_speed := 0.0
var cleave_share := 0.0
## Last time the hero dealt or took damage (combat blocks the shop, AC12).
var last_combat_at := -1000.0
## Item cooldowns by key (item id, or a shared group such as "potion").
var item_cooldowns := {}
## Active item effects.
var shield_hp := 0.0
var shield_left := 0.0
var attack_speed_buff := 0.0
var attack_speed_buff_left := 0.0
var haste := 0.0
var haste_left := 0.0
var regen_hp_rate := 0.0
var regen_hp_left := 0.0
var regen_mana_rate := 0.0
var regen_mana_left := 0.0
const _SWORD_REST := -1.1
var _sword_pivot: Node3D = null
var _swing: Tween = null


func setup(p_match: Node, id: String, def: Dictionary, p_faction: int, mult := 1.0) -> void:
	super(p_match, id, def, p_faction, mult)
	_base_def = def
	is_hero = true
	max_mana = float(def.get("max_mana", 100.0))
	mana = max_mana
	hp_regen = float(def.get("hp_regen", 0.0))
	mana_regen = float(def.get("mana_regen", 0.0))
	acquire_radius = float(def.get("acquire_radius", 7.0))
	# hero.tscn: %Body with Shield and %SwordPivot/Sword; play_swing() sweeps the pivot.
	_sword_pivot = get_node_or_null("%SwordPivot") as Node3D
	if _sword_pivot != null:
		_sword_pivot.rotation.y = _SWORD_REST


func _process(delta: float) -> void:
	if not match_ref.running:
		return
	# Cooldowns keep running while the hero is dead (GDD: they are never reset for free).
	for slot in ACTIVE_SLOTS:
		cooldowns[slot] = maxf(cooldowns[slot] - delta, 0.0)
	for key in item_cooldowns:
		item_cooldowns[key] = maxf(item_cooldowns[key] - delta, 0.0)
	if not alive:
		respawn_left -= delta
		if respawn_left <= 0.0:
			match_ref.respawn_hero()
		return
	tick_flash(delta)
	var stunned := tick_status(delta)
	attack_timer = maxf(attack_timer - delta, 0.0)
	hp = minf(max_hp, hp + hp_regen * delta)
	mana = minf(max_mana, mana + mana_regen * delta)
	if damage_reduction_left > 0.0:
		damage_reduction_left -= delta
		if damage_reduction_left <= 0.0:
			damage_reduction = 0.0
	if instinct_left > 0.0:
		instinct_left -= delta
		if instinct_left <= 0.0:
			instinct_stacks = 0
	_tick_item_effects(delta)
	if _dash_left > 0.0:
		_dash_left -= delta
		global_position = match_ref.clamp_to_map(global_position + _dash_velocity * delta)
		return
	if stunned:
		return
	var mv := move_input
	if mv.length() < 0.1:
		mv = _keyboard_vector()
	if mv.length() >= 0.1 and _attack_in_place():
		_cancel_recall()
		_run_attack_order(delta)
	elif mv.length() >= 0.1:
		# Moving cancels a single attack order, but not a held attack button.
		if not attack_held:
			order_target = null
		_cancel_recall()
		# Joystick and WASD are screen directions: up is "away from the camera".
		var w: Vector2 = match_ref.screen_to_world(mv)
		var dir := Vector3(w.x, 0.0, w.y).limit_length(1.0)
		global_position += dir * move_speed * delta
		face(dir)
	elif recall_left >= 0.0:
		recall_left -= delta
		if recall_left < 0.0:
			match_ref.finish_recall()
	else:
		_run_attack_order(delta)
	global_position = match_ref.clamp_to_map(global_position)


## While the attack button is held, a target already in reach is hit even if the player is
## still pushing the joystick or WASD; otherwise movement wins.
func _attack_in_place() -> bool:
	if not attack_held:
		return false
	if not _order_valid():
		order_target = pick_target("auto")
	return order_target != null and in_attack_range(order_target)


func _run_attack_order(delta: float) -> void:
	if not _order_valid():
		order_target = null
		if attack_held and settings.attack_mode == "auto":
			order_target = pick_target("auto")
	if order_target == null:
		return
	if in_attack_range(order_target):
		face(order_target.global_position - global_position)
		if attack_timer <= 0.0:
			attack_timer = current_attack_cooldown()
			play_swing(false)
			var to := _flat_to(order_target.global_position)
			match_ref.add_fx({"kind": "cone", "pos": global_position, "dir": to.normalized(),
				"range": radius + attack_range + 0.4, "angle": 80.0, "color": Color(1, 1, 1)})
			var hit_at := order_target.global_position
			order_target.take_damage(damage, self)
			if cleave_share > 0.0:
				_cleave(hit_at, order_target)
			_gain_instinct()
	else:
		move_towards(order_target.global_position, delta)


func _order_valid() -> bool:
	return is_valid_target(order_target) and order_target.is_targetable() \
		and flat_distance(order_target) <= acquire_radius * 1.6


## kind: "auto" (settings priority), "creep" (lowest HP creep), "tower" (nearest structure).
func pick_target(kind: String) -> Unit:
	var best: Unit = null
	var best_score := INF
	for u: Unit in match_ref.enemies_of(faction):
		if not is_valid_target(u) or not u.is_targetable():
			continue
		if edge_distance(u) > acquire_radius:
			continue
		var is_structure := u is Structure
		if kind == "creep" and is_structure:
			continue
		if kind == "tower" and not is_structure:
			continue
		var score := flat_distance(u)
		if kind == "creep" or (kind == "auto" and settings.target_priority == "lowest_hp"):
			score = u.hp
		if score < best_score:
			best_score = score
			best = u
	return best


## Target closest to the aimed direction (semi-auto mode). dir is in screen space.
func pick_aimed(dir: Vector2) -> Unit:
	if dir.length() < 0.01:
		return pick_target("auto")
	var world_dir: Vector2 = match_ref.screen_to_world(dir).normalized()
	var best: Unit = null
	var best_score := INF
	for u: Unit in match_ref.enemies_of(faction):
		if not is_valid_target(u) or not u.is_targetable():
			continue
		if edge_distance(u) > acquire_radius:
			continue
		var to := _flat_to(u.global_position)
		var angle := absf(world_dir.angle_to(to.normalized()))
		var score := angle * 10.0 + to.length() * 0.1
		if score < best_score:
			best_score = score
			best = u
	return best


func command_attack(kind: String) -> void:
	if not alive:
		return
	_cancel_recall()
	var t := pick_target(kind)
	if t != null:
		order_target = t
	elif not is_valid_target(order_target):
		cast_failed.emit("attack.no_target")


func command_attack_unit(t: Unit) -> void:
	if alive and t != null:
		_cancel_recall()
		order_target = t


# --- Skills -----------------------------------------------------------------

func skill(slot: String, field: String, rank := -1) -> float:
	return Rules.skill_value(skill_defs[slot], field, maxi(ranks[slot] if rank < 0 else rank, 1))


func cast_block_reason(slot: String) -> String:
	return Rules.cast_block_reason(alive, stun_left > 0.0, ranks[slot], cooldowns[slot], mana,
		skill(slot, "mana_cost"))


## World direction a skill would go: the aimed screen direction, or a sensible default for a
## quick tap. aim is in screen space (x right, y down).
func cast_direction(slot: String, aim: Vector2) -> Vector2:
	if aim.length() > 0.15:
		return match_ref.screen_to_world(aim).normalized()
	if slot == "w" and move_input.length() > 0.1:
		return match_ref.screen_to_world(move_input).normalized()
	if slot == "q":
		var t := pick_target("auto")
		if t != null:
			return _flat_to(t.global_position).normalized()
	return facing()


## Casts a skill. Mana and cooldown are spent exactly once, only when the cast starts.
func try_cast(slot: String, aim := Vector2.ZERO) -> bool:
	var reason := cast_block_reason(slot)
	if reason != "":
		cast_failed.emit(reason)
		return false
	var dir := cast_direction(slot, aim)
	mana -= skill(slot, "mana_cost")
	cooldowns[slot] = skill(slot, "cooldown")
	_cancel_recall()
	match slot:
		"q":
			_cast_cleave(dir)
		"w":
			_cast_dash(dir)
		"r":
			_cast_warbreaker()
	cast_done.emit(slot)
	return true


func _cast_cleave(dir: Vector2) -> void:
	face(Vector3(dir.x, 0.0, dir.y))
	play_swing(true)
	var reach := skill("q", "range")
	var angle := skill("q", "angle_deg")
	var origin := _flat(global_position)
	for u: Unit in match_ref.enemies_of(faction):
		if not is_valid_target(u) or not u.is_targetable():
			continue
		if Rules.in_cone(origin, dir, _flat(u.global_position), reach + u.radius, angle):
			_skill_hit(u, skill("q", "damage"))
	match_ref.add_fx({"kind": "cone", "pos": global_position, "dir": dir, "range": reach,
		"angle": angle, "color": Color(1.0, 0.85, 0.4)})


func _cast_dash(dir: Vector2) -> void:
	order_target = null
	var seconds := skill("w", "dash_seconds")
	_dash_left = seconds
	_dash_velocity = Vector3(dir.x, 0.0, dir.y) * skill("w", "distance") / seconds
	face(_dash_velocity)
	damage_reduction = skill("w", "damage_reduction")
	damage_reduction_left = skill("w", "buff_seconds")
	match_ref.add_fx({"kind": "line", "pos": global_position, "dir": dir,
		"range": skill("w", "distance"), "color": Color(0.5, 0.9, 1.0)})


func _cast_warbreaker() -> void:
	var radius_r := skill("r", "radius")
	for u: Unit in match_ref.enemies_of(faction):
		if not is_valid_target(u) or not u.is_targetable():
			continue
		if flat_distance(u) - u.radius > radius_r:
			continue
		u.apply_stun(skill("r", "stun_seconds"))
		u.apply_armor_debuff(skill("r", "armor_reduction"), skill("r", "debuff_seconds"))
		_skill_hit(u, skill("r", "damage"))
	match_ref.add_fx({"kind": "circle", "pos": global_position, "range": radius_r,
		"color": Color(1.0, 0.45, 0.2)})


## Skills deal reduced damage to towers and cores (balance: skill_structure_damage_mult);
## the barrier rules still apply on top.
func _skill_hit(u: Unit, amount: float) -> void:
	if u is Structure:
		amount *= float(match_ref.bal["skill_structure_damage_mult"])
	u.take_damage(amount, self)


## Sword slash from the right side across the front; wide for Q Cleave Strike.
func play_swing(wide: bool) -> void:
	if _sword_pivot == null or not is_inside_tree():
		return
	if _swing != null and _swing.is_valid():
		_swing.kill()
	var arc := 1.6 if wide else 1.1
	var t := minf(0.22, current_attack_cooldown() * 0.4)
	_swing = create_tween()
	_sword_pivot.rotation.y = arc
	_swing.tween_property(_sword_pivot, "rotation:y", -arc, t).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_swing.tween_property(_sword_pivot, "rotation:y", _SWORD_REST, t * 1.2)


func current_attack_cooldown() -> float:
	var bonus := item_attack_speed
	if attack_speed_buff_left > 0.0:
		bonus += attack_speed_buff
	if ranks["p"] > 0:
		bonus += skill("p", "attack_speed_per_stack") * instinct_stacks
	return attack_cooldown / (1.0 + bonus)


## Onslaught Blade passive: a basic attack also hits enemy creeps next to its target.
func _cleave(center: Vector3, main_target: Unit) -> void:
	var reach := float(match_ref.bal["cleave_radius"])
	for c in match_ref.creeps:
		if c == main_target or not is_valid_target(c) or c.faction == faction:
			continue
		var d: Vector3 = c.global_position - center
		if Vector2(d.x, d.z).length() <= reach:
			c.take_damage(damage * cleave_share, self)


# --- Items --------------------------------------------------------------------

## Rebuilds stats from units.json, level stat packages and item passives. HP and mana keep
## their share of the maximum, so buying or selling never heals or kills.
func recalc_stats() -> void:
	var hp_share := hp / max_hp if max_hp > 0.0 else 1.0
	var mana_share := mana / max_mana if max_mana > 0.0 else 1.0
	var pkg: Dictionary = match_ref.bal["stat_package"]
	var it: Dictionary = Rules.inventory_stats(match_ref.inventory, match_ref.data.items)
	var n := float(stat_packages)
	max_hp = _stat("max_hp", it) + n * float(pkg.get("max_hp", 0.0))
	max_mana = _stat("max_mana", it) + n * float(pkg.get("max_mana", 0.0))
	damage = _stat("damage", it) + n * float(pkg.get("damage", 0.0))
	armor = _stat("armor", it) + n * float(pkg.get("armor", 0.0))
	hp_regen = _stat("hp_regen", it)
	mana_regen = _stat("mana_regen", it)
	move_speed = _stat("move_speed", it) * (1.0 + haste)
	item_attack_speed = float(it.get("attack_speed", 0.0))
	cleave_share = float(it.get("cleave_share", 0.0))
	if alive:
		hp = max_hp * hp_share
		mana = max_mana * mana_share


func _stat(key: String, items_sum: Dictionary) -> float:
	return float(_base_def.get(key, 0.0)) + float(items_sum.get(key, 0.0))


## Starts an item's active effect (items.json "active"). Returns "" or the reason it cannot
## start; the caller spends the cooldown only on "".
func apply_item_active(a: Dictionary) -> String:
	var value := float(a.get("value", 0.0))
	var seconds := float(a.get("seconds", 0.0))
	match str(a["kind"]):
		"attack_speed_buff":
			attack_speed_buff = value
			attack_speed_buff_left = seconds
		"shield":
			shield_hp = maxf(shield_hp, value)
			shield_left = seconds
		"restore_mana":
			mana = minf(max_mana, mana + value)
		"creep_ward":
			var reach := float(a["radius"])
			for c in match_ref.creeps:
				if is_valid_target(c) and c.faction == faction and flat_distance(c) <= reach:
					c.apply_damage_ward(value, seconds)
			match_ref.add_fx({"kind": "circle", "pos": global_position, "range": reach,
				"color": Color(0.4, 0.9, 1.0)})
		"stun_nearest":
			var t := _nearest_enemy(float(a["radius"]))
			if t == null:
				return "attack.no_target"
			t.apply_stun(seconds)
			last_combat_at = match_ref.time
			match_ref.add_fx({"kind": "circle", "pos": t.global_position, "range": t.radius + 0.6,
				"color": Color(0.8, 0.6, 1.0)})
		"haste":
			haste = value
			haste_left = seconds
			recalc_stats()
		"regen_hp":
			regen_hp_rate = value / seconds
			regen_hp_left = seconds
		"regen_mana":
			regen_mana_rate = value / seconds
			regen_mana_left = seconds
	return ""


## Nearest enemy unit that can be stunned (structures ignore stuns).
func _nearest_enemy(reach: float) -> Unit:
	var best: Unit = null
	var best_d := INF
	for u: Unit in match_ref.enemies_of(faction):
		if u is Structure or not is_valid_target(u) or not u.is_targetable():
			continue
		var d := flat_distance(u) - u.radius
		if d <= reach and d < best_d:
			best_d = d
			best = u
	return best


func _tick_item_effects(delta: float) -> void:
	if shield_left > 0.0:
		shield_left -= delta
		if shield_left <= 0.0:
			shield_hp = 0.0
	if attack_speed_buff_left > 0.0:
		attack_speed_buff_left -= delta
	if haste_left > 0.0:
		haste_left -= delta
		if haste_left <= 0.0:
			haste = 0.0
			recalc_stats()
	if regen_hp_left > 0.0:
		hp = minf(max_hp, hp + regen_hp_rate * minf(delta, regen_hp_left))
		regen_hp_left -= delta
	if regen_mana_left > 0.0:
		mana = minf(max_mana, mana + regen_mana_rate * minf(delta, regen_mana_left))
		regen_mana_left -= delta


func _clear_item_effects() -> void:
	shield_hp = 0.0
	shield_left = 0.0
	attack_speed_buff_left = 0.0
	regen_hp_left = 0.0
	regen_mana_left = 0.0
	if haste > 0.0:
		haste = 0.0
		haste_left = 0.0
		recalc_stats()


## P Battle Instinct: each landed basic attack adds a stack; stacks vanish out of combat.
func _gain_instinct() -> void:
	if ranks["p"] <= 0:
		return
	instinct_stacks = mini(instinct_stacks + 1, int(skill("p", "max_stacks")))
	instinct_left = skill("p", "stack_seconds")


# --- Recall, damage, life ---------------------------------------------------

func start_recall(seconds: float) -> void:
	if alive and recall_left < 0.0:
		order_target = null
		recall_left = seconds


func is_recalling() -> bool:
	return recall_left >= 0.0


func _cancel_recall() -> void:
	if recall_left >= 0.0:
		recall_left = -1.0
		recall_interrupted.emit()


## Incoming damage cancels recall, interrupts potions and puts the hero in combat; the
## Bastion shield absorbs it after armor.
func take_damage(amount: float, source: Unit) -> void:
	if not alive:
		return
	if amount > 0.0:
		_cancel_recall()
		last_combat_at = match_ref.time
		regen_hp_left = 0.0
		regen_mana_left = 0.0
	amount *= 1.0 - damage_reduction
	if shield_hp > 0.0 and amount > 0.0:
		var real := Rules.mitigate(amount, effective_armor())
		var absorbed := minf(shield_hp, real)
		shield_hp -= absorbed
		amount *= (real - absorbed) / real
	super(amount, source)


func revive_at(pos: Vector3) -> void:
	alive = true
	hp = max_hp
	mana = max_mana
	order_target = null
	recall_left = -1.0
	stun_left = 0.0
	_dash_left = 0.0
	global_position = pos
	visible = true


func _on_died() -> void:
	visible = false
	order_target = null
	recall_left = -1.0
	instinct_stacks = 0
	aiming_slot = ""
	_clear_item_effects()


func facing() -> Vector2:
	if body == null:
		return Vector2.RIGHT
	return Vector2(sin(body.rotation.y), cos(body.rotation.y))


func _flat(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


func _flat_to(p: Vector3) -> Vector2:
	return Vector2(p.x - global_position.x, p.z - global_position.z)


func _keyboard_vector() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A):
		v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W):
		v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		v.y += 1.0
	return v.normalized()
