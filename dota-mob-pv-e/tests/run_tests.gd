extends SceneTree
## Headless checks. Run from the project folder:
##   godot --headless --path . --script res://tests/run_tests.gd
## Add `-- --sim=afk` or `-- --sim=push` (with --fixed-fps 30) to simulate a whole match.

const GameDataScript := preload("res://src/core/game_data.gd")

var checks := 0
var failures := 0
var _sim: Match = null
var _sim_mode := ""
var _sim_limit := 2400.0
var _gd: Node = null
var _casts := {"q": 0, "w": 0, "r": 0}


class FakeSettings:
	extends Node
	var attack_mode := "auto"
	var target_priority := "nearest"


func _initialize() -> void:
	_gd = GameDataScript.new()
	var loaded: bool = _gd.load_all()
	check(loaded, "data loads and validates: %s" % ", ".join(_gd.errors))
	_test_scripts_compile("res://src")
	_test_scenes()
	if loaded:
		_test_rules(_gd.balance)
		_test_skills(_gd.skills)
		_test_strings(_gd.strings)
		_test_items(_gd.items, _gd.strings)
		_test_shop_rules(_gd.items, _gd.balance)
		_test_match_shop()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sim="):
			_sim_mode = arg.get_slice("=", 1)
	if _sim_mode != "" and loaded:
		_start_sim()
		return
	_finish()


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL: ", what)


## Every script must parse; scenes are only loaded in the game, so check them all here.
func _test_scripts_compile(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		check(false, "cannot open %s" % dir_path)
		return
	for sub in dir.get_directories():
		_test_scripts_compile(dir_path.path_join(sub))
	for file in dir.get_files():
		if file.ends_with(".gd"):
			var path := dir_path.path_join(file)
			var script := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
			check(script != null and script.can_instantiate(), "script compiles: %s" % path)


## Game objects are scenes: each must load and carry the nodes the scripts look up.
func _test_scenes() -> void:
	var required := {
		"res://scenes/units/hero.tscn": ["%Body", "%SwordPivot"],
		"res://scenes/units/creep_melee.tscn": ["%Body"],
		"res://scenes/units/creep_ranged.tscn": ["%Body"],
		"res://scenes/units/creep_siege.tscn": ["%Body"],
		"res://scenes/units/tower.tscn": ["%Body"],
		"res://scenes/units/core.tscn": ["%Body"],
		"res://scenes/units/projectile.tscn": ["%Mesh"],
		"res://scenes/world/camera_rig.tscn": [],
		"res://scenes/ui/hud.tscn": ["%Root", "%Overlay", "%Minimap", "%Joystick", "%AttackPad", "%QPad",
			"%WPad", "%RPad", "%PPad", "%CancelZone", "%UpgradeQ", "%HpBar", "%PausePanel", "%EndPanel",
			"%UpgradePanel", "%DeathPanel", "%Toast", "%FatalLabel", "%ShopButton", "%ShopPanel",
			"%ItemPad1", "%ItemPad2", "%ItemPad3", "%ItemPad4", "%ItemPad5", "%ItemPad6", "%PotionPad"],
		"res://scenes/ui/shop_panel.tscn": ["%Gold", "%Status", "%Close", "%Catalog", "%Name", "%Recipe",
			"%Price", "%Stats", "%Active", "%Buy", "%Slots", "%Sell"],
		"res://scenes/ui/item_card.tscn": [],
		"res://scenes/ui/inventory_slot.tscn": [],
		"res://scenes/main.tscn": ["%Map", "%Match", "%CameraRig", "%Hud"],
	}
	for path in required:
		var ps := load(path) as PackedScene
		check(ps != null, "scene loads: %s" % path)
		if ps == null:
			continue
		var node := ps.instantiate()
		for n in required[path]:
			check(node.get_node_or_null(n) != null, "%s has %s" % [path, n])
		node.free()
	_test_hud_layout()
	var map := (load("res://scenes/world/map.tscn") as PackedScene).instantiate() as GameMap
	check(map != null and map.missing_markers().is_empty(), "map.tscn has every gameplay marker: %s" % (
		", ".join(map.missing_markers()) if map != null else "no map"))
	if map != null:
		map.free()


## An instanced UI scene must keep the anchors of its own root: an instance override such as
## `layout_mode = 0` silently resets them and the panel jumps to the top-left corner.
func _test_hud_layout() -> void:
	var hud := (load("res://scenes/ui/hud.tscn") as PackedScene).instantiate()
	for node in hud.get_node("%Root").get_children():
		if not (node is Control) or node.scene_file_path == "":
			continue
		var own := (load(node.scene_file_path) as PackedScene).instantiate() as Control
		if node.scene_file_path.ends_with("touch_pad.tscn"):
			own.free()
			continue
		var same: bool = is_equal_approx(node.anchor_left, own.anchor_left) \
			and is_equal_approx(node.anchor_top, own.anchor_top) \
			and is_equal_approx(node.anchor_right, own.anchor_right) \
			and is_equal_approx(node.anchor_bottom, own.anchor_bottom)
		check(same, "hud.tscn keeps the anchors of %s (%s)" % [node.name, node.scene_file_path])
		own.free()
	hud.free()


func _test_rules(bal: Dictionary) -> void:
	check(is_equal_approx(Rules.mitigate(100.0, 0.0), 100.0), "armor 0 keeps damage")
	check(is_equal_approx(Rules.mitigate(100.0, 100.0), 50.0), "armor 100 halves damage")
	# Last hit and participation (D08, AC07)
	check(Rules.reward_share(true, true, 0.3) == 1.0, "last hit gives full reward, not added to participation")
	check(is_equal_approx(Rules.reward_share(false, true, 0.3), 0.3), "participation gives 30%")
	check(Rules.reward_share(false, false, 0.3) == 0.0, "no participation gives nothing")
	# Barrier (D11, D13, AC03, AC04, AC24)
	var A := Rules.Barrier.ACTIVE
	var S := Rules.Barrier.SUPPRESSED
	var R := Rules.Barrier.RESTORING
	check(Rules.barrier_state(true, 10.0, 0.0, 5.0) == S, "attacking creep suppresses barrier")
	check(Rules.barrier_state(false, 12.0, 10.0, 5.0) == R, "barrier restores with delay")
	check(Rules.barrier_state(false, 15.1, 10.0, 5.0) == A, "barrier active after delay")
	check(is_equal_approx(Rules.structure_hp_after_hit(1000.0, 100.0, true, A, 0.1), 990.0), "hero deals 10% under active barrier")
	check(is_equal_approx(Rules.structure_hp_after_hit(1000.0, 100.0, true, S, 0.1), 900.0), "hero deals full damage with wave")
	check(is_equal_approx(Rules.structure_hp_after_hit(1000.0, 100.0, true, R, 0.1), 900.0), "full damage during restore delay")
	check(Rules.structure_hp_after_hit(50.0, 100.0, true, A, 1.0) >= 1.0, "no finishing blow without wave")
	check(Rules.structure_hp_after_hit(50.0, 100.0, true, R, 0.1) >= 1.0, "no finishing blow during restore delay")
	check(Rules.structure_hp_after_hit(50.0, 100.0, true, S, 0.1) <= 0.0, "finishing blow while creep attacks")
	check(Rules.structure_hp_after_hit(1.0, 100.0, true, A, 0.1) >= 1.0, "tower at 1 HP stays at 1 HP without wave")
	# Tower order (strict T1 -> T2 -> T3 -> core)
	check(Rules.structure_vulnerable(1, []), "T1 vulnerable at start")
	check(not Rules.structure_vulnerable(2, []), "T2 protected while T1 stands")
	check(Rules.structure_vulnerable(3, [1, 2]), "T3 vulnerable after T1 and T2")
	check(not Rules.structure_vulnerable(4, [1, 2]), "core protected while T3 stands")
	check(Rules.structure_vulnerable(4, [1, 2, 3]), "core vulnerable after all towers")
	# Levels (D03, AC08)
	var skills := 0
	var ults := 0
	var stats := 0
	for lvl in range(1, int(bal["hero_max_level"]) + 1):
		match Rules.level_reward(lvl, bal):
			"skill":
				skills += 1
			"ult":
				ults += 1
			"stats":
				stats += 1
	check(skills == 9 and ults == 3, "12 skill points over 20 levels (9 + 3 ult)")
	check(stats == 8, "8 stat packages over 20 levels")
	check(skills + ults + stats == 20, "every level 1-20 grants exactly one reward")
	# Death (D05, AC11)
	check(Rules.death_gold_loss(1000, 0.25) == 250, "death costs 25% unreliable gold")
	check(Rules.death_gold_loss(3, 0.25) == 0, "gold loss rounds down")
	check(is_equal_approx(Rules.respawn_time(10, 8.0, 1.0), 18.0), "respawn 8 s + 1 s per level")
	check(is_equal_approx(Rules.creep_multiplier(370.0, 180.0, 0.1), 1.2), "creeps grow every period")
	# Diagonal camera (yaw -45): screen up points toward the enemy base (+x) and -z.
	var yaw := deg_to_rad(-45.0)
	var up := Rules.screen_to_world(Vector2(0, -1), yaw)
	check(up.x > 0.6 and up.y < -0.6, "screen up maps to world toward the enemy base")
	var right := Rules.screen_to_world(Vector2(1, 0), yaw)
	check(right.x > 0.6 and right.y > 0.6, "screen right maps to world (+x, +z)")
	check(Rules.world_to_screen(Rules.screen_to_world(Vector2(0.3, 0.8), yaw), yaw).is_equal_approx(Vector2(0.3, 0.8)), "screen/world mapping round-trips")


func _test_skills(skills: Dictionary) -> void:
	var q_levels: Array = skills["q"]["min_levels"]
	var r_levels: Array = skills["r"]["min_levels"]
	check(Rules.upgrade_block_reason("q", 0, 1, 1, 0, q_levels) == "", "level 1 point learns Q")
	check(Rules.upgrade_block_reason("q", 1, 4, 1, 0, q_levels) == "upgrade.level", "Q rank 2 waits for level 5")
	check(Rules.upgrade_block_reason("q", 1, 5, 1, 0, q_levels) == "", "Q rank 2 at level 5")
	check(Rules.upgrade_block_reason("q", 3, 20, 5, 0, q_levels) == "upgrade.max", "no rank 4")
	check(Rules.upgrade_block_reason("q", 0, 3, 0, 1, q_levels) == "upgrade.no_points", "Q needs a skill point, not an ult point")
	check(Rules.upgrade_block_reason("r", 0, 5, 3, 1, r_levels) == "upgrade.level", "R waits for level 6")
	check(Rules.upgrade_block_reason("r", 0, 6, 3, 0, r_levels) == "upgrade.no_points", "R needs an ult point")
	check(Rules.upgrade_block_reason("r", 0, 6, 0, 1, r_levels) == "", "R rank 1 at level 6 with ult point")
	# Activation checks (AC09): nothing is spent when a check fails.
	check(Rules.cast_block_reason(true, false, 0, 0.0, 100.0, 40.0) == "cast.not_learned", "unlearned skill blocked")
	check(Rules.cast_block_reason(true, false, 1, 2.0, 100.0, 40.0) == "cast.cooldown", "cooldown blocks")
	check(Rules.cast_block_reason(true, false, 1, 0.0, 30.0, 40.0) == "cast.no_mana", "low mana blocks")
	check(Rules.cast_block_reason(true, true, 1, 0.0, 100.0, 40.0) == "cast.stunned", "stun blocks")
	check(Rules.cast_block_reason(false, false, 1, 0.0, 100.0, 40.0) == "cast.dead", "dead hero cannot cast")
	check(Rules.cast_block_reason(true, false, 1, 0.0, 40.0, 40.0) == "", "exact mana is enough")
	check(is_equal_approx(Rules.skill_value(skills["q"], "damage", 2), float(skills["q"]["damage"][1])), "rank value lookup")
	check(Rules.in_cone(Vector2.ZERO, Vector2.RIGHT, Vector2(2, 0.5), 3.0, 110.0), "target in front is in the cone")
	check(not Rules.in_cone(Vector2.ZERO, Vector2.RIGHT, Vector2(-2, 0), 3.0, 110.0), "target behind is not in the cone")
	check(not Rules.in_cone(Vector2.ZERO, Vector2.RIGHT, Vector2(4, 0), 3.0, 110.0), "target out of reach is not in the cone")


## Item catalog: the real one is valid, broken ones are rejected with the item id.
func _test_items(items: Dictionary, strings: Dictionary) -> void:
	var actives := 0
	for id in items:
		if items[id]["kind"] == "item" and items[id].get("active") != null:
			actives += 1
		check(strings.has("item.%s.short" % id), "item '%s' has a short name for its button" % id)
	check(actives >= 6, "catalog has at least six items with active effects (AC13)")
	var bad := items.duplicate(true)
	bad["blade"]["components"] = ["onslaught_blade"]
	check(_has_error(GameDataScript.validate_items(bad), "blade"), "a component with a recipe is rejected")
	bad = items.duplicate(true)
	bad["onslaught_blade"]["components"] = ["onslaught_blade"]
	check(_has_error(GameDataScript.validate_items(bad), "not a component"), "a recipe that loops into an item is rejected")
	bad = items.duplicate(true)
	bad["bastion"]["components"] = ["plate", "missing_part"]
	check(_has_error(GameDataScript.validate_items(bad), "missing_part"), "an unknown component is rejected")
	bad = items.duplicate(true)
	bad["hilt"]["price"] = 0
	check(_has_error(GameDataScript.validate_items(bad), "hilt"), "a zero price is rejected")
	bad = items.duplicate(true)
	bad["bastion"]["price"] = 100
	check(_has_error(GameDataScript.validate_items(bad), "bastion"), "an item cheaper than its parts is rejected")
	bad = items.duplicate(true)
	bad["potion_hp"]["active"]["kind"] = "teleport"
	check(_has_error(GameDataScript.validate_items(bad), "potion_hp"), "an unknown active effect is rejected")


func _has_error(errors: PackedStringArray, needle: String) -> bool:
	for e in errors:
		if e.contains(needle):
			return true
	return false


func _inv(ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		out.append({} if id == "" else {"id": id, "count": 1})
	return out


## Purchase, assembly, stacking, wallets and selling as pure rules (AC12, AC14).
func _test_shop_rules(items: Dictionary, bal: Dictionary) -> void:
	var p := Rules.purchase_plan("blade", items, _inv(["", "", "", "", "", ""]), 1000, 0)
	check(p["reason"] == "" and p["slot"] == 0 and p["cost"] == int(items["blade"]["price"]), "component goes to the first empty slot at full price")
	var inv := _inv(["potion_hp", "blade", "", "hilt", "", ""])
	p = Rules.purchase_plan("onslaught_blade", items, inv, 1000, 0)
	var left := int(items["onslaught_blade"]["price"]) - int(items["blade"]["price"]) - int(items["hilt"]["price"])
	check(p["reason"] == "" and p["cost"] == left, "assembly charges only the price left after owned components")
	check(p["consume"] == [1, 3] and p["slot"] == 1, "assembly absorbs both components and takes the first freed slot")
	# AC14: a full inventory can still assemble, because components free their slots.
	inv = _inv(["blade", "hilt", "plate", "plate", "focus", "potion_hp"])
	p = Rules.purchase_plan("onslaught_blade", items, inv, 1000, 0)
	check(p["reason"] == "" and p["slot"] == 0, "full inventory assembles from owned components (AC14)")
	p = Rules.purchase_plan("crystal", items, inv, 5000, 0)
	check(p["reason"] == "shop.no_space", "full inventory refuses a new component with 'No space' (AC14)")
	p = Rules.purchase_plan("bastion", items, _inv(["blade", "hilt", "boots", "focus", "crystal", "potion_mana"]), 5000, 0)
	check(p["reason"] == "shop.no_space", "full inventory without the parts refuses a whole item (AC14)")
	p = Rules.purchase_plan("bastion", items, _inv(["", "", "", "", "", ""]), 100, 50)
	check(p["reason"] == "shop.no_gold", "not enough gold is refused")
	p = Rules.purchase_plan("blade", items, _inv(["", "", "", "", "", ""]), 200, 500)
	check(p["pay_unreliable"] == 200 and p["pay_reliable"] == int(items["blade"]["price"]) - 200, "unreliable gold is spent before reliable")
	# Potions stack up to max_stack in one slot, then need a new slot.
	inv = _inv(["potion_hp", "", "", "", "", ""])
	p = Rules.purchase_plan("potion_hp", items, inv, 500, 0)
	check(p["stack"] and p["slot"] == 0, "potion joins its stack")
	inv[0]["count"] = int(items["potion_hp"]["max_stack"])
	p = Rules.purchase_plan("potion_hp", items, inv, 500, 0)
	check(not p["stack"] and p["slot"] == 1, "a full stack starts a new slot")
	check(Rules.sell_refund(items["bastion"], 1, float(bal["sell_refund_share"])) == int(items["bastion"]["price"]) / 2, "selling returns half the price")
	check(Rules.shop_block_reason(true, true, true) == "shop.in_combat", "buying in combat is refused (AC12)")
	check(Rules.shop_block_reason(true, false, false) == "shop.not_in_shop", "buying outside a shop is refused")
	check(Rules.shop_block_reason(false, true, false) == "cast.dead", "a dead hero cannot buy")
	check(Rules.shop_block_reason(true, true, false) == "", "alive, in the shop, out of combat can buy")
	var st := Rules.inventory_stats(_inv(["blade", "blade", "", "", "", ""]), items)
	check(is_equal_approx(float(st["damage"]), 2.0 * float(items["blade"]["stats"]["damage"])), "item stats add up")


## Shop on a real match: wallets, inventory and hero stats change together or not at all.
func _test_match_shop() -> void:
	var map := (load("res://scenes/world/map.tscn") as PackedScene).instantiate() as GameMap
	root.add_child(map)
	var m := Match.new()
	root.add_child(m)
	var fake := FakeSettings.new()
	m.add_child(fake)
	m.start(_gd, fake, map)
	var h := m.hero
	m.unreliable_gold = 2000
	m.reliable_gold = 300
	var base_damage := h.damage
	check(m.buy("blade") == "" and m.inventory[0]["id"] == "blade", "match buys a component at the base")
	check(is_equal_approx(h.damage, base_damage + float(_gd.items["blade"]["stats"]["damage"])), "component stats reach the hero")
	check(m.buy("hilt") == "" and m.buy("onslaught_blade") == "", "match assembles an item")
	var filled := m.inventory.filter(func(s): return not s.is_empty())
	check(filled.size() == 1 and filled[0]["id"] == "onslaught_blade", "components are absorbed into the item")
	check(m.unreliable_gold == 2000 - int(_gd.items["onslaught_blade"]["price"]) and m.reliable_gold == 300, "the whole item price is paid once")
	# AC12: in combat nothing changes.
	var before := [m.unreliable_gold, m.reliable_gold, m.inventory.duplicate(true)]
	h.last_combat_at = m.time
	check(m.buy("bastion") == "shop.in_combat", "match refuses to buy in combat (AC12)")
	check(m.sell(0) == "shop.in_combat", "match refuses to sell in combat")
	check([m.unreliable_gold, m.reliable_gold, m.inventory] == before, "a refused purchase changes nothing (AC12)")
	h.last_combat_at = -1000.0
	h.position = m.fountain_position(Unit.Faction.PLAYER) + Vector3(30, 0, 0)
	check(m.buy("bastion") == "shop.not_in_shop", "match refuses to buy outside the shop")
	h.position = m.fountain_position(Unit.Faction.PLAYER)
	var gold := m.unreliable_gold
	check(m.sell(0) == "" and m.inventory[0].is_empty(), "match sells an item")
	check(m.unreliable_gold == gold + int(_gd.items["onslaught_blade"]["price"]) / 2, "selling refunds half to unreliable gold")
	check(is_equal_approx(h.damage, base_damage), "selling removes the item's stats")
	# Active items: cooldown spent once, potion stack shrinks.
	check(m.buy("potion_hp") == "" and m.buy("potion_hp") == "", "potions stack")
	h.hp = h.max_hp * 0.5
	check(m.use_item(0) == "" and m.inventory[0]["count"] == 1, "using a potion spends one from the stack")
	check(m.use_item(0) == "cast.cooldown", "potions share a cooldown")
	h.take_damage(1.0, null)
	check(h.regen_hp_left <= 0.0, "damage interrupts the potion")
	m.free()
	map.free()


func _test_strings(strings: Dictionary) -> void:
	# ru and en must take the same placeholders, or formatting fails in one language.
	for key in strings:
		var ru: String = strings[key]["ru"]
		var en: String = strings[key]["en"]
		check(ru.count("%") == en.count("%"), "string '%s' has the same placeholders in ru and en" % key)
	var used := ["skill.q.name", "skill.q.desc", "skill.w.desc", "skill.r.desc", "skill.p.desc",
		"upgrade.title", "upgrade.level", "cast.no_mana", "cast.cancel","hud.attack", "hud.last_hit", "hud.tower", "hud.recall", "pause.resume", "pause.restart",
		"end.victory", "end.defeat", "death.respawn", "toast.barrier", "toast.finish_blocked",
		"toast.invulnerable", "toast.recall_interrupted", "error.data"]
	for key in used:
		check(strings.has(key), "string '%s' exists in ru and en" % key)


func _start_sim() -> void:
	var map := (load("res://scenes/world/map.tscn") as PackedScene).instantiate() as GameMap
	root.add_child(map)
	_sim = Match.new()
	root.add_child(_sim)
	var fake := FakeSettings.new()
	root.add_child(fake)
	_sim.start(_gd, fake, map)
	_sim.hero.cast_done.connect(func(slot): _casts[slot] += 1)
	print("sim '%s' started" % _sim_mode)


func _process(_delta: float) -> bool:
	if _sim == null:
		return false
	if _sim_mode == "push":
		_bot(_sim)
		if _sim.time < 1200.0:
			_items_at_20 = _sim.items_built
	if int(_sim.time / 60.0) != int((_sim.time - _delta) / 60.0):
		var alive_p := _sim.structures.filter(func(s): return s.alive and s.faction == Unit.Faction.PLAYER).size()
		var alive_e := _sim.structures.filter(func(s): return s.alive and s.faction == Unit.Faction.ENEMY).size()
		print("  t=%d min creeps=%d structures player=%d enemy=%d fps_real=%d" % [int(_sim.time / 60.0),
			_sim.creeps.size(), alive_p, alive_e, Engine.get_frames_per_second()])
	if not _sim.running or _sim.time >= _sim_limit:
		var t := int(_sim.time)
		print("sim '%s': outcome=%s time=%02d:%02d level=%d last_hits=%d towers_destroyed=%d towers_lost=%d gold=%d" % [
			_sim_mode, ["RUNNING", "WON", "LOST"][_sim.outcome], t / 60, t % 60, _sim.level, _sim.last_hits,
			_sim.towers_destroyed, _sim.towers_lost, _sim.unreliable_gold + _sim.reliable_gold])
		if _sim_mode == "afk":
			check(_sim.outcome == Match.Outcome.LOST, "AFK hero loses the match (AC02)")
		elif _sim_mode == "push":
			print("  casts q=%d w=%d r=%d ranks=%s" % [_casts["q"], _casts["w"], _casts["r"], _sim.hero.ranks])
			var first := int(_sim.first_item_at)
			print("  items built=%d first at %02d:%02d, item uses=%d, at 20:00 built=%d, inventory=%s" % [
				_sim.items_built, first / 60, first % 60, _item_uses, _items_at_20, _sim.inventory])
			check(_sim.first_item_at > 0.0, "bot buys a finished item")
			check(_item_uses > 0, "bot fires item actives")
			check(_sim.towers_destroyed >= 1, "pushing bot destroys at least one enemy tower")
			check(_casts["q"] > 0 and _casts["r"] > 0, "bot casts Q and R during the match")
			check(_sim.hero.ranks["r"] == 3 or _sim.level < 19, "R reaches rank 3 by level 19")
		_finish()
		return true
	return false


## Bot build order: components first, the finished item assembles from them.
const BOT_BUILD := ["blade", "hilt", "onslaught_blade", "plate", "heart", "bastion", "boots", "hilt",
	"march_boots", "focus", "crystal", "aether_focus", "blade", "focus", "binding_blade", "plate", "focus",
	"signal_banner"]
var _bot_build_index := 0
var _item_uses := 0
var _items_at_20 := 0


## Simple pushing bot: follows the front of its own wave, attacks, recalls when low, shops at
## the base and fires its items in fights.
func _bot(m: Match) -> void:
	var h := m.hero
	for slot in ["r", "q", "w", "p"]:
		while m.upgrade_skill(slot) == "":
			pass
	while _bot_build_index < BOT_BUILD.size() and m.buy(BOT_BUILD[_bot_build_index]) == "":
		_bot_build_index += 1
	if h.alive and not h.is_recalling():
		var near := 0
		for u: Unit in m.enemies_of(h.faction):
			if h.is_valid_target(u) and not (u is Structure) and h.flat_distance(u) < 3.5:
				near += 1
		if near >= 3 and h.cast_block_reason("r") == "":
			h.try_cast("r")
		elif near >= 2 and h.mana > h.max_mana * 0.4 and h.cast_block_reason("q") == "":
			h.try_cast("q")
		if near >= 2:
			for i in Match.INVENTORY_SLOTS:
				if m.use_item(i) == "":
					_item_uses += 1
		if h.hp < h.max_hp * 0.45 and h.cast_block_reason("w") == "":
			h.try_cast("w", m.world_to_screen(Vector2.LEFT))
	if not h.alive or h.is_recalling():
		h.move_input = Vector2.ZERO
		return
	if h.hp < h.max_hp * 0.3:
		h.move_input = Vector2.ZERO
		m.start_recall()
		return
	if h.hp < h.max_hp * 0.95 and h.global_position.distance_to(m.fountain_position(Unit.Faction.PLAYER)) < 6.0:
		h.move_input = Vector2.ZERO
		return
	var front := -INF
	for c in m.creeps:
		if is_instance_valid(c) and c.alive and c.faction == Unit.Faction.PLAYER:
			front = maxf(front, c.global_position.x)
	var goal_x := front - 1.5 if front > -INF else m.fountain_position(Unit.Faction.PLAYER).x + 8.0
	var dx := goal_x - h.global_position.x
	if absf(dx) > 3.0 and not h.is_valid_target(h.order_target):
		# move_input is a screen direction, like the joystick.
		h.move_input = m.world_to_screen(Vector2(signf(dx), -h.global_position.z * 0.2).normalized())
		h.attack_held = false
	else:
		h.move_input = Vector2.ZERO
		h.attack_held = true


func _finish() -> void:
	print("%d checks, %d failed" % [checks, failures])
	if _gd != null and _gd.get_parent() == null:
		_gd.free()
	quit(1 if failures > 0 else 0)
