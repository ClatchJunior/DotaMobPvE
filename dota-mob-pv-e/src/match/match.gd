class_name Match
extends Node3D
## Authoritative match state: clock, waves, structures, rewards, hero progression, outcome.
## HUD and visuals only read from here and send commands to the hero.

signal outcome_changed(outcome: int)
signal toast(key: String, value: int)
signal hero_died(gold_lost: int)

enum Outcome { RUNNING, WON, LOST }

const PROJECTILE_SCENE_PATH := "res://scenes/units/projectile.tscn"

var data: Node = null
var settings: Node = null
var bal: Dictionary = {}
## map.tscn root: geometry bounds and gameplay markers.
var map_node: GameMap = null
## Camera yaw (radians) for screen-to-world input; main.gd copies it from the CameraRig.
var yaw := deg_to_rad(-45.0)
var time := 0.0
var outcome: int = Outcome.RUNNING
var running: bool:
	get:
		return outcome == Outcome.RUNNING
var hero: Hero = null
var creeps: Array = []
var structures: Array = []
var unreliable_gold := 0
var reliable_gold := 0
var xp := 0.0
var level := 1
var skill_points := 0
var ult_points := 0
var last_hits := 0
var towers_destroyed := 0
var towers_lost := 0
var last_death_loss := 0
var _wave_timer := 0.0
var _wave_index := 0
var _upgrade_steps := 0
var _core_lost := false
var _core_won := false
## Short-lived skill visuals for the overlay: {kind, pos, dir, range, angle, color, t}.
var fx: Array = []
## Six main slots (D06): {} when empty or {"id": String, "count": int}.
var inventory: Array = []
## Finished (non-component, non-consumable) items bought, and when the first one was.
var items_built := 0
var first_item_at := -1.0

const INVENTORY_SLOTS := 6


func start(p_data: Node, p_settings: Node, p_map: GameMap) -> void:
	data = p_data
	settings = p_settings
	map_node = p_map
	bal = data.balance
	unreliable_gold = int(bal["starting_gold"])
	inventory.clear()
	for i in INVENTORY_SLOTS:
		inventory.append({})
	_wave_timer = float(bal["first_wave_delay"])
	if Rules.level_reward(1, bal) == "skill":
		skill_points = 1
	for f in [Unit.Faction.PLAYER, Unit.Faction.ENEMY]:
		for i in 3:
			_spawn_structure("tower_t%d" % (i + 1), f, i + 1, map_node.marker(f, "T%d" % (i + 1)))
		_spawn_structure("core", f, 4, map_node.marker(f, "Core"))
	hero = spawn_unit("hero_vanguard") as Hero
	hero.settings = settings
	hero.skill_defs = data.skills
	add_child(hero)
	hero.setup(self, "hero_vanguard", data.unit("hero_vanguard"), Unit.Faction.PLAYER)
	# Match sits at the origin, so local positions are world positions; this also works
	# before the match is inside the scene tree (headless tests).
	hero.position = fountain_position(Unit.Faction.PLAYER)
	hero.died.connect(_on_hero_died)


func _process(delta: float) -> void:
	if not running:
		return
	# Cores destroyed during the previous frame resolve together: defeat has priority (O09).
	if _core_lost or _core_won:
		_finish(Outcome.LOST if _core_lost else Outcome.WON)
		return
	time += delta
	_wave_timer -= delta
	if _wave_timer <= 0.0:
		_wave_timer += float(bal["wave_period"])
		_spawn_wave()
	var steps := int(floor(time / float(bal["creep_upgrade_period"])))
	if steps > _upgrade_steps:
		_upgrade_steps = steps
		toast.emit("toast.creeps_upgraded", 0)
	_apply_fountains(delta)
	creeps = creeps.filter(func(c): return is_instance_valid(c) and c.alive)
	for e in fx:
		e["t"] += delta
	fx = fx.filter(func(e): return e["t"] < 0.35)


func add_fx(effect: Dictionary) -> void:
	effect["t"] = 0.0
	fx.append(effect)


## Raises a skill rank. Returns "" on success or a translation key with the reason.
func upgrade_skill(slot: String) -> String:
	var reason := upgrade_block_reason(slot)
	if reason != "":
		return reason
	if slot == "r":
		ult_points -= 1
	else:
		skill_points -= 1
	hero.ranks[slot] += 1
	return ""


func upgrade_block_reason(slot: String) -> String:
	return Rules.upgrade_block_reason(slot, hero.ranks[slot], level, skill_points, ult_points,
		data.skills[slot]["min_levels"])


# --- Shop and items -----------------------------------------------------------

## The base shop is the own fountain zone (forest shops and outposts come in later stages).
## Match sits at the origin, so the hero's local position is its world position.
func in_shop() -> bool:
	return hero.alive and hero.position.distance_to(fountain_position(Unit.Faction.PLAYER)) \
		<= float(bal["fountain_radius"])


## Combat: the hero dealt or took damage recently, or an enemy is attacking or shooting at it.
func hero_in_combat() -> bool:
	if time - hero.last_combat_at < float(bal["out_of_combat_seconds"]):
		return true
	for u in creeps + structures:
		if is_instance_valid(u) and u.alive and u.faction != hero.faction and u.target == hero:
			return true
	for p in get_children():
		if p is Projectile and p.target == hero:
			return true
	return false


func shop_block_reason() -> String:
	return Rules.shop_block_reason(hero.alive, in_shop(), hero_in_combat())


## Buys an item in one transaction. Returns "" or a translation key; on refusal nothing changes.
func buy(item_id: String) -> String:
	var reason := shop_block_reason()
	if reason != "":
		return reason
	var plan := purchase_plan(item_id)
	if plan["reason"] != "":
		return plan["reason"]
	unreliable_gold -= int(plan["pay_unreliable"])
	reliable_gold -= int(plan["pay_reliable"])
	for i in plan["consume"]:
		inventory[i] = {}
	var slot: int = plan["slot"]
	if plan["stack"]:
		inventory[slot]["count"] += 1
	else:
		inventory[slot] = {"id": item_id, "count": 1}
	if data.item(item_id)["kind"] == "item":
		items_built += 1
		if first_item_at < 0.0:
			first_item_at = time
	hero.recalc_stats()
	return ""


func purchase_plan(item_id: String) -> Dictionary:
	return Rules.purchase_plan(item_id, data.items, inventory, unreliable_gold, reliable_gold)


## Sells a whole slot for a share of its price, paid as unreliable gold.
func sell(slot: int) -> String:
	var reason := shop_block_reason()
	if reason != "":
		return reason
	var s: Dictionary = inventory[slot]
	if s.is_empty():
		return "shop.empty_slot"
	unreliable_gold += sell_value(slot)
	inventory[slot] = {}
	hero.recalc_stats()
	return ""


func sell_value(slot: int) -> int:
	var s: Dictionary = inventory[slot]
	if s.is_empty():
		return 0
	return Rules.sell_refund(data.item(s["id"]), int(s["count"]), float(bal["sell_refund_share"]))


func item_in_slot(slot: int) -> Dictionary:
	var s: Dictionary = inventory[slot]
	return {} if s.is_empty() else data.item(s["id"])


## Cooldown key of an item: potions share one ("cooldown_group"), other copies share the id.
func item_cooldown_key(slot: int) -> String:
	var s: Dictionary = inventory[slot]
	if s.is_empty():
		return ""
	var active = data.item(s["id"]).get("active")
	if active == null:
		return s["id"]
	return str(active.get("cooldown_group", s["id"]))


func item_cooldown_left(slot: int) -> float:
	return float(hero.item_cooldowns.get(item_cooldown_key(slot), 0.0))


func item_use_block_reason(slot: int) -> String:
	return Rules.item_use_block_reason(hero.alive, hero.stun_left > 0.0, inventory[slot],
		item_in_slot(slot), item_cooldown_left(slot))


## Uses the active effect of a slot. The cooldown is spent once, only when the effect starts;
## a consumable loses one from its stack.
func use_item(slot: int) -> String:
	var reason := item_use_block_reason(slot)
	if reason != "":
		return reason
	var s: Dictionary = inventory[slot]
	var active: Dictionary = data.item(s["id"])["active"]
	reason = hero.apply_item_active(active)
	if reason != "":
		return reason
	hero.item_cooldowns[item_cooldown_key(slot)] = float(active["cooldown"])
	if data.item(s["id"])["kind"] == "consumable":
		s["count"] -= 1
		if s["count"] <= 0:
			inventory[slot] = {}
			hero.recalc_stats()
	return ""


## First slot with a potion for the HUD shortcut: health first when HP is lower than mana.
func potion_slot() -> int:
	var order := ["potion_hp", "potion_mana"]
	if hero.max_mana > 0.0 and hero.mana / hero.max_mana < hero.hp / hero.max_hp:
		order = ["potion_mana", "potion_hp"]
	for id in order:
		for i in INVENTORY_SLOTS:
			if not inventory[i].is_empty() and inventory[i]["id"] == id:
				return i
	return -1


## Test tools, shown in the pause menu of debug builds only.
func debug_add_levels(count: int) -> void:
	var target := mini(level + count, int(bal["hero_max_level"]))
	while level < target:
		add_xp(xp_needed() - xp + 0.01)


func debug_max_skills() -> void:
	for slot in ["r", "q", "w", "p"]:
		while upgrade_skill(slot) == "":
			pass


func debug_refill() -> void:
	hero.hp = hero.max_hp
	hero.mana = hero.max_mana
	for slot in hero.cooldowns:
		hero.cooldowns[slot] = 0.0


## Hero level needed for the next rank of a skill (0 when it is maxed).
func next_rank_level(slot: String) -> int:
	var levels: Array = data.skills[slot]["min_levels"]
	var rank: int = hero.ranks[slot]
	return int(levels[rank]) if rank < levels.size() else 0


func _other(f: int) -> int:
	return Unit.Faction.ENEMY if f == Unit.Faction.PLAYER else Unit.Faction.PLAYER


func screen_to_world(v: Vector2) -> Vector2:
	return Rules.screen_to_world(v, yaw)


func world_to_screen(v: Vector2) -> Vector2:
	return Rules.world_to_screen(v, yaw)


## Creeps walk toward the opposing core.
func lane_goal_x(f: int) -> float:
	return map_node.marker(_other(f), "Core").x


func fountain_position(f: int) -> Vector3:
	return map_node.marker(f, "Fountain")


func clamp_to_map(p: Vector3) -> Vector3:
	var half_x := map_node.half_length
	var half_z := map_node.half_depth()
	return Vector3(clampf(p.x, -half_x, half_x), 0.0, clampf(p.z, -half_z, half_z))


## New instance of a unit's scene (units.json "scene").
func spawn_unit(id: String) -> Unit:
	var scene := load(str(data.unit(id)["scene"])) as PackedScene
	return scene.instantiate() as Unit


func enemies_of(f: int) -> Array:
	var out: Array = []
	for c in creeps:
		if is_instance_valid(c) and c.alive and c.faction != f:
			out.append(c)
	for s in structures:
		if s.alive and s.faction != f:
			out.append(s)
	if f == Unit.Faction.ENEMY and hero != null and hero.alive:
		out.append(hero)
	return out


func is_structure_vulnerable(s: Structure) -> bool:
	var destroyed: Array = []
	for other in structures:
		if other.faction == s.faction and not other.alive:
			destroyed.append(other.tier)
	return Rules.structure_vulnerable(s.tier, destroyed)


func has_creep_attacking(s: Structure) -> bool:
	for c in creeps:
		if is_instance_valid(c) and c.alive and c.faction != s.faction and c.target == s \
				and c.in_attack_range(s):
			return true
	return false


func spawn_projectile(source: Unit, t: Unit, dmg: float, speed: float) -> void:
	var p := (load(PROJECTILE_SCENE_PATH) as PackedScene).instantiate() as Projectile
	add_child(p)
	p.global_position = source.global_position + Vector3(0, source.bar_height * 0.7, 0)
	p.launch(source, t, dmg, speed, Unit.FACTION_COLORS[source.faction].lightened(0.3))


func respawn_hero() -> void:
	hero.revive_at(fountain_position(Unit.Faction.PLAYER))


func finish_recall() -> void:
	hero.global_position = fountain_position(Unit.Faction.PLAYER)


func start_recall() -> void:
	hero.start_recall(float(bal["recall_seconds"]))


func creep_multiplier(f: int) -> float:
	var growth := float(bal["creep_upgrade_player"] if f == Unit.Faction.PLAYER else bal["creep_upgrade_enemy"])
	return Rules.creep_multiplier(time, float(bal["creep_upgrade_period"]), growth)


func xp_needed() -> float:
	return Rules.xp_to_next(level, float(bal["xp_base"]), float(bal["xp_step"]))


func add_xp(amount: float) -> void:
	var max_level := int(bal["hero_max_level"])
	if level >= max_level:
		return
	xp += amount
	while level < max_level and xp >= xp_needed():
		xp -= xp_needed()
		level += 1
		match Rules.level_reward(level, bal):
			"skill":
				skill_points += 1
				toast.emit("toast.level_up", level)
			"ult":
				ult_points += 1
				toast.emit("toast.level_up", level)
			"stats":
				hero.stat_packages += 1
				hero.recalc_stats()
				toast.emit("toast.stat_package", level)
	if level >= max_level:
		xp = 0.0


func _spawn_structure(id: String, f: int, tier: int, pos: Vector3) -> void:
	var s := spawn_unit(id) as Structure
	s.tier = tier
	add_child(s)
	s.setup(self, id, data.unit(id), f)
	s.position = pos
	s.died.connect(_on_structure_died)
	s.hero_feedback.connect(func(key): toast.emit(key, 0))
	structures.append(s)


func _spawn_wave() -> void:
	_wave_index += 1
	for f in [Unit.Faction.PLAYER, Unit.Faction.ENEMY]:
		var list: Array = []
		for i in int(bal["wave_melee"]):
			list.append("creep_melee")
		for i in int(bal["wave_ranged"]):
			list.append("creep_ranged")
		if _wave_index % int(bal["siege_every"]) == 0:
			list.append("creep_siege")
		var mult := creep_multiplier(f)
		var spawn := map_node.marker(f, "Spawn")
		# Later rows stand further back, away from the enemy.
		var back := 1.6 if spawn.x >= 0.0 else -1.6
		for i in list.size():
			var c := spawn_unit(list[i]) as Creep
			add_child(c)
			c.setup(self, list[i], data.unit(list[i]), f, mult)
			var row := floorf(i / 3.0)
			c.lane_z = spawn.z + (float(i % 3) - 1.0) * 1.6
			c.position = Vector3(spawn.x + back * row, 0.0, c.lane_z)
			c.died.connect(_on_creep_died)
			creeps.append(c)


func _apply_fountains(delta: float) -> void:
	var r := float(bal["fountain_radius"])
	var own := fountain_position(Unit.Faction.PLAYER)
	if hero.alive and hero.global_position.distance_to(own) <= r:
		var share := float(bal["fountain_regen_share"])
		hero.hp = minf(hero.max_hp, hero.hp + hero.max_hp * share * delta)
		hero.mana = minf(hero.max_mana, hero.mana + hero.max_mana * share * delta)
	var dps := float(bal["fountain_damage_per_second"])
	for f in [Unit.Faction.PLAYER, Unit.Faction.ENEMY]:
		var center := fountain_position(f)
		for u in enemies_of(f):
			if not (u is Structure) and u.global_position.distance_to(center) <= r:
				u.take_damage(dps * delta, null)


func _on_creep_died(c: Unit, killer: Unit) -> void:
	if c.faction != Unit.Faction.ENEMY:
		return
	var creep := c as Creep
	var hero_last_hit := killer != null and killer.is_hero
	var participated := time - c.last_hit_by_hero_at <= float(bal["participation_window"]) \
		or (hero.alive and hero.flat_distance(c) <= float(bal["participation_radius"]))
	var share := Rules.reward_share(hero_last_hit, participated, float(bal["participation_share"]))
	if share <= 0.0:
		return
	if hero_last_hit:
		last_hits += 1
	unreliable_gold += int(round(creep.gold * share))
	add_xp(creep.xp * share)


func _on_structure_died(u: Unit, _killer: Unit) -> void:
	var s := u as Structure
	if s.faction == Unit.Faction.ENEMY:
		if not s.is_core:
			towers_destroyed += 1
			reliable_gold += int(s.reliable_gold)
			add_xp(s.xp)
			toast.emit("toast.tower_destroyed", int(s.reliable_gold))
		else:
			_core_won = true
	else:
		if not s.is_core:
			towers_lost += 1
			toast.emit("toast.tower_lost", 0)
		else:
			_core_lost = true


func _on_hero_died(_u: Unit, _killer: Unit) -> void:
	last_death_loss = Rules.death_gold_loss(unreliable_gold, float(bal["death_gold_loss"]))
	unreliable_gold -= last_death_loss
	hero.respawn_left = Rules.respawn_time(level, float(bal["respawn_base"]), float(bal["respawn_per_level"]))
	hero_died.emit(last_death_loss)


## The first terminal outcome wins; later events in the same tick cannot change it.
func _finish(result: int) -> void:
	if outcome != Outcome.RUNNING:
		return
	outcome = result
	outcome_changed.emit(outcome)
