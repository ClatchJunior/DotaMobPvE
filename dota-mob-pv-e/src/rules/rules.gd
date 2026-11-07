class_name Rules
extends RefCounted
## Pure match rules: damage, rewards, tower barrier, levels, death.
## No scene access, so every rule is covered by tests/run_tests.gd.

enum Barrier { ACTIVE, SUPPRESSED, RESTORING }


## Physical damage after armor: damage * 100 / (100 + armor).
static func mitigate(damage: float, armor: float) -> float:
	return damage * 100.0 / (100.0 + maxf(armor, 0.0))


## Share of a kill reward the hero gets: full for the last hit, a part for participation.
static func reward_share(hero_last_hit: bool, hero_participated: bool, participation_share: float) -> float:
	if hero_last_hit:
		return 1.0
	if hero_participated:
		return participation_share
	return 0.0


## Barrier of an enemy structure. SUPPRESSED while an allied lane creep attacks it,
## RESTORING for restore_delay seconds after the last one stopped, ACTIVE otherwise.
static func barrier_state(has_attacking_creep: bool, now: float, last_suppressed_at: float,
		restore_delay: float) -> Barrier:
	if has_attacking_creep:
		return Barrier.SUPPRESSED
	if now - last_suppressed_at < restore_delay:
		return Barrier.RESTORING
	return Barrier.ACTIVE


## HP left after a hit on a barrier-protected structure.
## Hero damage is reduced while the barrier is ACTIVE; the structure can only reach 0 HP
## while it is SUPPRESSED, i.e. while an allied creep is attacking it.
static func structure_hp_after_hit(hp: float, damage: float, from_hero: bool, state: Barrier,
		barrier_multiplier: float) -> float:
	var dealt := damage
	if from_hero and state == Barrier.ACTIVE:
		dealt *= barrier_multiplier
	var left := hp - dealt
	if state != Barrier.SUPPRESSED:
		left = maxf(left, minf(hp, 1.0))
	return left


## A tower of tier t is vulnerable once every lower tier of its side is destroyed.
## The core (tier 4) is vulnerable once all three towers are destroyed.
static func structure_vulnerable(tier: int, destroyed_tiers: Array) -> bool:
	for t in range(1, tier):
		if not t in destroyed_tiers:
			return false
	return true


static func xp_to_next(level: int, base: float, step: float) -> float:
	return base + step * float(level - 1)


## What reaching a level grants: "skill", "ult", "stats" or "" (see the level table in the GDD).
static func level_reward(level: int, balance: Dictionary) -> String:
	if level in balance["skill_point_levels"]:
		return "skill"
	if level in balance["ult_point_levels"]:
		return "ult"
	if level in balance["stat_package_levels"]:
		return "stats"
	return ""


## "" when the skill rank can be raised, otherwise a translation key with the reason.
## Q, W and P spend skill points; R spends ult points. min_levels are the hero levels
## that unlock ranks 1, 2 and 3.
static func upgrade_block_reason(slot: String, rank: int, level: int, skill_points: int,
		ult_points: int, min_levels: Array) -> String:
	if rank >= min_levels.size():
		return "upgrade.max"
	if level < int(min_levels[rank]):
		return "upgrade.level"
	var points := ult_points if slot == "r" else skill_points
	if points <= 0:
		return "upgrade.no_points"
	return ""


## "" when the skill can be cast now. Mana and cooldown are spent only after this passes.
static func cast_block_reason(alive: bool, stunned: bool, rank: int, cooldown_left: float,
		mana: float, cost: float) -> String:
	if not alive:
		return "cast.dead"
	if stunned:
		return "cast.stunned"
	if rank <= 0:
		return "cast.not_learned"
	if cooldown_left > 0.0:
		return "cast.cooldown"
	if mana < cost:
		return "cast.no_mana"
	return ""


## Value of a skill field at a rank (1-3): fields are either one number or 3 numbers.
static func skill_value(def: Dictionary, field: String, rank: int) -> float:
	var v = def.get(field, 0.0)
	if typeof(v) == TYPE_ARRAY:
		return float(v[clampi(rank, 1, v.size()) - 1])
	return float(v)


## Is a point inside a sector (cone) in front of an origin? dir must be normalized.
static func in_cone(origin: Vector2, dir: Vector2, point: Vector2, reach: float, angle_deg: float) -> bool:
	var to := point - origin
	if to.length() > reach:
		return false
	if to.length() < 0.001:
		return true
	return absf(dir.angle_to(to.normalized())) <= deg_to_rad(angle_deg) * 0.5


## Screen-space direction (x right, y down) to a world (x, z) direction for a camera turned
## by yaw (radians) around the vertical axis, like the diagonal Mobile Legends view.
static func screen_to_world(v: Vector2, yaw: float) -> Vector2:
	return v.rotated(-yaw)


static func world_to_screen(v: Vector2, yaw: float) -> Vector2:
	return v.rotated(yaw)


static func death_gold_loss(unreliable_gold: int, share: float) -> int:
	return int(floor(float(unreliable_gold) * share))


static func respawn_time(level: int, base: float, per_level: float) -> float:
	return base + per_level * float(level)


static func creep_multiplier(time: float, period: float, growth: float) -> float:
	return 1.0 + growth * floor(time / period)


# --- Shop and items (D06, AC12-AC14) -------------------------------------------

## "" when the shop may buy or sell now, otherwise a translation key with the reason.
static func shop_block_reason(alive: bool, in_shop: bool, in_combat: bool) -> String:
	if not alive:
		return "cast.dead"
	if not in_shop:
		return "shop.not_in_shop"
	if in_combat:
		return "shop.in_combat"
	return ""


## One atomic purchase check over gold, components and the final free slot. Nothing is changed
## here; the caller applies the plan only when "reason" is "". inventory: one entry per slot,
## {} when empty or {"id": String, "count": int}. Gold is spent unreliable first, then reliable.
## Returns {reason, cost, consume (slots whose components the recipe absorbs), slot (where the
## item goes), stack (true when it joins an existing consumable stack), pay_unreliable, pay_reliable}.
static func purchase_plan(item_id: String, items: Dictionary, inventory: Array, unreliable: int,
		reliable: int) -> Dictionary:
	var plan := {"reason": "", "cost": 0, "consume": [], "slot": -1, "stack": false,
		"pay_unreliable": 0, "pay_reliable": 0}
	var def: Dictionary = items.get(item_id, {})
	if def.is_empty():
		plan["reason"] = "shop.pick_item"
		return plan
	var cost := int(def["price"])
	var consume: Array = []
	if def["kind"] == "consumable":
		for i in inventory.size():
			var s: Dictionary = inventory[i]
			if not s.is_empty() and s["id"] == item_id and int(s["count"]) < int(def["max_stack"]):
				plan["slot"] = i
				plan["stack"] = true
				break
	elif def["kind"] == "item":
		for c in def["components"]:
			for i in inventory.size():
				var s: Dictionary = inventory[i]
				if not i in consume and not s.is_empty() and s["id"] == c:
					consume.append(i)
					cost -= int(items[c]["price"])
					break
	plan["consume"] = consume
	plan["cost"] = cost
	if plan["slot"] == -1:
		# The finished item takes the first slot its components free, else the first empty one.
		if not consume.is_empty():
			plan["slot"] = consume.min()
		else:
			for i in inventory.size():
				if (inventory[i] as Dictionary).is_empty():
					plan["slot"] = i
					break
	if plan["slot"] == -1:
		plan["reason"] = "shop.no_space"
		return plan
	if unreliable + reliable < cost:
		plan["reason"] = "shop.no_gold"
		return plan
	plan["pay_unreliable"] = mini(cost, unreliable)
	plan["pay_reliable"] = cost - plan["pay_unreliable"]
	return plan


## Gold back for selling a slot: a share of the full price (it goes to unreliable gold).
static func sell_refund(def: Dictionary, count: int, share: float) -> int:
	return int(floor(float(def.get("price", 0)) * float(count) * share))


## Sum of the passive stats of everything in the inventory.
static func inventory_stats(inventory: Array, items: Dictionary) -> Dictionary:
	var out := {}
	for s: Dictionary in inventory:
		if s.is_empty():
			continue
		var stats: Dictionary = items.get(s["id"], {}).get("stats", {})
		for k in stats:
			out[k] = float(out.get(k, 0.0)) + float(stats[k])
	return out


## "" when the item in a slot can be used now, otherwise a translation key with the reason.
## The cooldown is spent only after this passes.
static func item_use_block_reason(alive: bool, stunned: bool, slot: Dictionary, def: Dictionary,
		cooldown_left: float) -> String:
	if not alive:
		return "cast.dead"
	if slot.is_empty():
		return "shop.empty_slot"
	if def.get("active") == null:
		return "item.passive"
	if stunned:
		return "cast.stunned"
	if cooldown_left > 0.0:
		return "cast.cooldown"
	return ""
