extends Node
## End-to-end input check on the real main scene: injects mouse/keyboard events the way a
## player would and verifies they reach the hero. Run headless:
##   godot --headless --fixed-fps 60 --path . -- --input-test
## Prints PASS/FAIL lines and quits with exit code 1 on any failure.

var main: Node3D = null
var _failures := 0
var _started := false


func _process(_delta: float) -> void:
	if _started or main.match_node == null or main.match_node.time < 22.0:
		return
	_started = true
	_run()


func _run() -> void:
	var m: Match = main.match_node
	var hud: Hud = main.hud
	var hero := m.hero
	# The player's saved settings must not change the result; nothing is saved here.
	var saved_mode: String = Settings.attack_mode
	var saved_priority: String = Settings.target_priority
	Settings.attack_mode = "auto"
	Settings.target_priority = "nearest"

	# 1. Attack button pressed with the mouse (emulated touch), as on PC.
	await _attack_check("attack button (mouse as touch) damages the nearest enemy", func(on: bool):
		_press_mouse(_center(hud.attack_pad), on))

	# 2. Space after clicking a HUD button: buttons must not keep focus and eat Space.
	if hud.upgrade_buttons["q"].visible:
		_press_mouse(_center(hud.upgrade_buttons["q"]), true)
		_press_mouse(_center(hud.upgrade_buttons["q"]), false)
		await _frames(2)
	await _attack_check("Space attacks after a HUD button was clicked", func(on: bool):
		_key(KEY_SPACE, on))

	# 3. Attack while still holding a movement key.
	_key(KEY_W, true)
	await _attack_check("attack lands while a movement key is held", func(on: bool):
		_key(KEY_SPACE, on))
	_key(KEY_W, false)

	# 3b. Semi-auto: hold the attack button, drag toward the enemy, release - the hero attacks it.
	Settings.attack_mode = "semi"
	await _attack_check("semi-auto: drag the attack button at the enemy and release", _semi_hold, true)
	Settings.attack_mode = "auto"

	# 4. Joystick drag moves the hero.
	await _frames(5)
	var start_x := hero.global_position.x
	var c := _center(hud.joystick)
	_press_mouse(c, true)
	_move_mouse(c + _to_window(Vector2(80, 0)))
	await _frames(30)
	_press_mouse(c + _to_window(Vector2(80, 0)), false)
	_report(hero.global_position.x > start_x + 1.0, "joystick drag moves the hero")

	# 4b. Camera follows the hero, and W ("up" on screen) walks toward the enemy base.
	var from := hero.global_position
	_key(KEY_W, true)
	await _frames(40)
	_key(KEY_W, false)
	await _frames(30)
	var walked := Vector2(hero.global_position.x - from.x, hero.global_position.z - from.z)
	_report(walked.x > 1.0 and walked.y < -1.0, "W walks up the screen, toward the enemy base")
	var on_screen: Vector2 = main.camera.unproject_position(hero.global_position)
	var view := get_viewport().get_visible_rect()
	_report(on_screen.distance_to(view.get_center()) < view.size.y * 0.15, "camera keeps the hero near the screen center")

	# 5. Test tool: level 20 with every skill maxed, then cast Q with key 1.
	hud._debug_max_all()
	_report(m.level == 20 and hero.ranks.values().all(func(r): return r == 3),
		"test tool sets level 20 and rank 3 on Q, W, R, P")
	var mana_before := hero.mana
	_key(KEY_1, true)
	_key(KEY_1, false)
	await _frames(2)
	_report(hero.cooldowns["q"] > 0.0 and hero.mana < mana_before, "key 1 casts Q and spends mana once")

	await _shop_checks()
	await _item_checks()

	Settings.attack_mode = saved_mode
	Settings.target_priority = saved_priority
	print("input probe: %d failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


## Shop through the window's own buttons: buy two components, assemble, sell; a purchase right
## after hitting an enemy is refused and changes nothing (AC12).
func _shop_checks() -> void:
	var m: Match = main.match_node
	var hud: Hud = main.hud
	var hero := m.hero
	_go_home(m)
	m.unreliable_gold = 4000
	await _frames(2)
	await _click(hud.shop_button)
	_report(hud.shop_panel.visible, "shop button opens the shop window")
	await _click_card("blade")
	await _click(hud.shop_panel.get_node("%Buy"))
	await _click_card("hilt")
	await _click(hud.shop_panel.get_node("%Buy"))
	_report(_count(m, "blade") == 1 and _count(m, "hilt") == 1, "shop window buys two components")
	var gold_before := m.unreliable_gold
	await _click_card("onslaught_blade")
	await _click(hud.shop_panel.get_node("%Buy"))
	var built := _count(m, "onslaught_blade") == 1 and _count(m, "blade") == 0 and _count(m, "hilt") == 0
	_report(built and gold_before - m.unreliable_gold == m.data.item("onslaught_blade")["price"] - 650,
		"shop window assembles the item from owned components and charges only the rest")
	var slot := _slot_of(m, "onslaught_blade")
	gold_before = m.unreliable_gold
	await _click(hud.shop_panel.get_node("%Slots").get_child(slot))
	await _click(hud.shop_panel.get_node("%Sell"))
	_report(_count(m, "onslaught_blade") == 0 and m.unreliable_gold > gold_before, "shop window sells the selected slot")
	# Hit an enemy creep, walk straight back into the shop zone: still in combat.
	var victim := _victim(m)
	if victim != null:
		hero.order_target = null
		hero.attack_timer = 0.0
		var started := m.time
		_key(KEY_SPACE, true)
		for i in 30:
			_stick(hero, victim)
			await get_tree().process_frame
			if not is_instance_valid(victim) or victim.last_hit_by_hero_at >= started:
				break
		_key(KEY_SPACE, false)
		hero.position = m.fountain_position(Unit.Faction.PLAYER)
		await _frames(2)
		var before := [m.unreliable_gold, m.reliable_gold, m.inventory.duplicate(true)]
		await _click_card("blade")
		await _click(hud.shop_panel.get_node("%Buy"))
		_report(m.shop_block_reason() == "shop.in_combat" and [m.unreliable_gold, m.reliable_gold, m.inventory] == before,
			"buying right after hitting an enemy is refused and changes nothing (AC12)")
	else:
		_report(false, "combat purchase check (no enemy creep found)")
	await _click(hud.shop_panel.get_node("%Close"))
	_report(not hud.shop_panel.visible, "close button hides the shop window")


## AC13: six active items in six slots, each one fired from its own HUD button; H drinks a potion.
func _item_checks() -> void:
	var m: Match = main.match_node
	var hud: Hud = main.hud
	var hero := m.hero
	var ids := ["onslaught_blade", "bastion", "aether_focus", "signal_banner", "binding_blade", "march_boots"]
	for i in 6:
		m.inventory[i] = {"id": ids[i], "count": 1}
	hero.recalc_stats()
	hero.item_cooldowns.clear()
	var fired := 0
	for i in 6:
		var victim := _victim(m)
		if victim != null:
			hero.position = victim.position + Vector3(-2.0, 0, 0)
		hero.stun_left = 0.0
		_press_mouse(_center(hud.item_pads[i]), true)
		_press_mouse(_center(hud.item_pads[i]), false)
		await _frames(2)
		if m.item_cooldown_left(i) > 0.0:
			fired += 1
		else:
			print("  item button %d (%s) did not fire" % [i + 1, ids[i]])
	_report(fired == 6, "all six active items fire from their HUD buttons (AC13)")
	# Potion shortcut: a potion in slot 6 is drunk with H, the stack shrinks.
	m.inventory[5] = {"id": "potion_hp", "count": 2}
	hero.item_cooldowns.clear()
	_go_home(m)
	hero.hp = hero.max_hp * 0.4
	_key(KEY_H, true)
	_key(KEY_H, false)
	await _frames(2)
	_report(m.inventory[5]["count"] == 1 and hero.regen_hp_left > 0.0, "H drinks a potion from the inventory")


func _go_home(m: Match) -> void:
	m.hero.position = m.fountain_position(Unit.Faction.PLAYER)
	m.hero.last_combat_at = -1000.0
	m.hero.order_target = null


func _click_card(id: String) -> void:
	for card in main.hud.shop_panel.get_node("%Catalog").get_children():
		if card.item_id == id:
			await _click(card)
			return
	_report(false, "shop card '%s' exists" % id)


func _click(c: Control) -> void:
	_press_mouse(_center(c), true)
	_press_mouse(_center(c), false)
	await _frames(2)


func _count(m: Match, id: String) -> int:
	var n := 0
	for s: Dictionary in m.inventory:
		if not s.is_empty() and s["id"] == id:
			n += 1
	return n


func _slot_of(m: Match, id: String) -> int:
	for i in m.inventory.size():
		if not m.inventory[i].is_empty() and m.inventory[i]["id"] == id:
			return i
	return 0


## Puts the hero next to the frontmost enemy creep, holds the given input, then releases it,
## and checks that the hero itself hit that creep. release_acts: the hit comes on release
## (semi-auto), so keep watching after it.
func _attack_check(what: String, hold: Callable, release_acts := false) -> void:
	var m: Match = main.match_node
	var hero := m.hero
	var victim := _victim(m)
	if victim == null:
		_report(false, what + " (no enemy creep found)")
		return
	hero.order_target = null
	hero.attack_timer = 0.0
	var started := m.time
	var last_hero_hit := -1000.0
	hold.call(true)
	for i in 30:
		_stick(hero, victim)
		await get_tree().process_frame
		if is_instance_valid(victim):
			last_hero_hit = victim.last_hit_by_hero_at
	hold.call(false)
	for i in (45 if release_acts else 2):
		_stick(hero, victim)
		await get_tree().process_frame
		if is_instance_valid(victim):
			last_hero_hit = victim.last_hit_by_hero_at
	# Only damage dealt by the hero counts: allied creeps may hit or kill the victim too.
	_report(last_hero_hit >= started, what)


func _semi_hold(on: bool) -> void:
	var c0 := _center(main.hud.attack_pad)
	var aim: Vector2 = c0 + _to_window(main.match_node.world_to_screen(Vector2.RIGHT) * 60.0)
	if on:
		_press_mouse(c0, true)
		_move_mouse(aim)
	else:
		_press_mouse(aim, false)


func _stick(hero: Hero, victim: Unit) -> void:
	if hero.is_valid_target(victim):
		hero.global_position = victim.global_position + Vector3(-1.6, 0, 0)


func _victim(m: Match) -> Unit:
	var best: Unit = null
	for u: Unit in m.enemies_of(Unit.Faction.PLAYER):
		if u is Creep and u.alive and (best == null or u.global_position.x < best.global_position.x):
			best = u
	return best


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Center of a control in window coordinates: injected events are window-space and Godot
## maps them back through the stretch transform, like real touches.
func _center(c: Control) -> Vector2:
	return get_viewport().get_final_transform() * c.get_global_rect().get_center()


func _to_window(v: Vector2) -> Vector2:
	return get_viewport().get_final_transform().basis_xform(v)


func _press_mouse(pos: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	if pressed:
		e.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(e)


func _move_mouse(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(e)


func _key(code: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)


func _report(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_failures += 1
