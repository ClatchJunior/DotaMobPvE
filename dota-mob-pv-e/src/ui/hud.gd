class_name Hud
extends CanvasLayer
## Root of scenes/ui/hud.tscn. Mobile HUD: joystick, attack buttons, recall, stats, minimap, toasts,
## death / pause / end screens. All texts are translation keys (ru + en).
## Reads Match state and sends commands to the hero; never changes gold or HP itself.

var match_ref: Match = null
var root: Control
var overlay: WorldOverlay
var minimap: Minimap
var joystick: TouchPad
var attack_pad: TouchPad
var last_hit_pad: TouchPad
var tower_pad: TouchPad
var recall_pad: TouchPad
var skill_pads := {}
var upgrade_buttons := {}
var p_pad: TouchPad
var cancel_zone: TouchPad
var upgrade_panel: PanelContainer
var upgrade_title: Label
var upgrade_desc: Label
var _upgrade_slot := ""
var stats_label: Label
var xp_bar: ProgressBar
var hp_bar: ProgressBar
var mana_bar: ProgressBar
var hp_label: Label
var toast_label: Label
var death_panel: PanelContainer
var death_label: Label
var pause_panel: PanelContainer
var end_panel: PanelContainer
var end_title: Label
var end_stats: Label
var mode_button: Button
var priority_button: Button
var language_button: Button
## Six item buttons (slots 1-6), the potion shortcut, the shop button and window.
var item_pads: Array = []
var potion_pad: TouchPad
var shop_button: Button
var shop_panel: ShopPanel
var _toast_left := 0.0


func bind(p_match: Match, camera: Camera3D) -> void:
	match_ref = p_match
	process_mode = Node.PROCESS_MODE_ALWAYS
	_bind_nodes()
	overlay.match_ref = match_ref
	overlay.camera = camera
	minimap.match_ref = match_ref
	match_ref.toast.connect(_on_toast)
	match_ref.outcome_changed.connect(_on_outcome)
	match_ref.hero.recall_interrupted.connect(func(): _on_toast("toast.recall_interrupted", 0))
	match_ref.hero.cast_failed.connect(func(reason): _on_toast(reason, 0))
	Settings.changed.connect(_refresh_texts)
	_refresh_texts()


## Shown instead of the match when game data failed to load.
func show_fatal(text: String) -> void:
	var l := get_node("%FatalLabel") as Label
	l.text = text
	l.visible = true


## Takes the nodes laid out in hud.tscn and its panel scenes and wires their signals.
## Layout, sizes, colors and texts live in the scenes; edit them in the Godot editor.
func _bind_nodes() -> void:
	root = %Root
	overlay = %Overlay
	minimap = %Minimap
	stats_label = %StatsLabel
	xp_bar = %XpBar
	joystick = %Joystick
	attack_pad = %AttackPad
	last_hit_pad = %LastHitPad
	tower_pad = %TowerPad
	recall_pad = %RecallPad
	skill_pads = {"q": %QPad, "w": %WPad, "r": %RPad, "p": %PPad}
	p_pad = %PPad
	cancel_zone = %CancelZone
	upgrade_buttons = {"q": %UpgradeQ, "w": %UpgradeW, "r": %UpgradeR, "p": %UpgradeP}
	hp_label = %HpLabel
	hp_bar = %HpBar
	mana_bar = %ManaBar
	toast_label = %Toast
	death_panel = %DeathPanel
	death_label = death_panel.get_node("%Label")
	pause_panel = %PausePanel
	mode_button = pause_panel.get_node("%Mode")
	priority_button = pause_panel.get_node("%Priority")
	language_button = pause_panel.get_node("%Language")
	upgrade_panel = %UpgradePanel
	upgrade_title = upgrade_panel.get_node("%Title")
	upgrade_desc = upgrade_panel.get_node("%Desc")
	end_panel = %EndPanel
	end_title = end_panel.get_node("%Title")
	end_stats = end_panel.get_node("%Stats")
	item_pads = [%ItemPad1, %ItemPad2, %ItemPad3, %ItemPad4, %ItemPad5, %ItemPad6]
	potion_pad = %PotionPad
	shop_button = %ShopButton
	shop_panel = %ShopPanel
	for i in item_pads.size():
		(item_pads[i] as TouchPad).pressed.connect(use_item.bind(i))
	potion_pad.pressed.connect(use_potion)
	shop_button.pressed.connect(toggle_shop)
	shop_panel.bind(match_ref)
	shop_panel.message.connect(_show_text)

	(%PauseButton as Button).pressed.connect(_toggle_pause)
	attack_pad.pressed.connect(_on_attack_pressed)
	attack_pad.dragged.connect(_on_attack_dragged)
	attack_pad.released.connect(_on_attack_released)
	last_hit_pad.pressed.connect(func(): match_ref.hero.command_attack("creep"))
	tower_pad.pressed.connect(func(): match_ref.hero.command_attack("tower"))
	recall_pad.pressed.connect(func(): match_ref.start_recall())
	for slot in ["q", "w", "r"]:
		var pad: TouchPad = skill_pads[slot]
		pad.pressed.connect(_on_skill_pressed.bind(slot))
		pad.dragged.connect(_on_skill_dragged.bind(slot))
		pad.released.connect(_on_skill_released.bind(slot))
	for slot in upgrade_buttons:
		(upgrade_buttons[slot] as Button).pressed.connect(_open_upgrade.bind(slot))

	(pause_panel.get_node("%Resume") as Button).pressed.connect(_toggle_pause)
	mode_button.pressed.connect(func(): Settings.cycle("attack_mode"))
	priority_button.pressed.connect(func(): Settings.cycle("target_priority"))
	language_button.pressed.connect(func(): Settings.cycle("locale"))
	(pause_panel.get_node("%Restart") as Button).pressed.connect(_restart)
	# Test tools: only in editor and debug builds, never in a release export.
	(pause_panel.get_node("%DebugRow") as Control).visible = OS.is_debug_build()
	(pause_panel.get_node("%DebugLevelUp") as Button).pressed.connect(func(): match_ref.debug_add_levels(1))
	(pause_panel.get_node("%DebugMaxAll") as Button).pressed.connect(_debug_max_all)
	(pause_panel.get_node("%DebugRefill") as Button).pressed.connect(func(): match_ref.debug_refill())
	(upgrade_panel.get_node("%Confirm") as Button).pressed.connect(_confirm_upgrade)
	(upgrade_panel.get_node("%Close") as Button).pressed.connect(func(): upgrade_panel.visible = false)
	(end_panel.get_node("%Again") as Button).pressed.connect(_restart)


func _process(delta: float) -> void:
	if match_ref == null:
		return
	var hero := match_ref.hero
	hero.move_input = joystick.vector()
	_update_stats()
	_update_skills()
	_update_items()
	_toast_left -= delta
	toast_label.modulate.a = clampf(_toast_left, 0.0, 1.0)
	death_panel.visible = not hero.alive and match_ref.running
	if death_panel.visible:
		death_label.text = "%s\n%s\n%s\n%s" % [tr("death.title"),
			tr("death.respawn") % ceili(hero.respawn_left),
			tr("death.gold_lost") % match_ref.last_death_loss, tr("death.front")]


func _update_stats() -> void:
	var t := int(match_ref.time)
	var lvl_text: String
	if match_ref.level >= int(match_ref.bal["hero_max_level"]):
		lvl_text = tr("hud.level_max") % match_ref.level
	else:
		lvl_text = tr("hud.level") % match_ref.level
	stats_label.text = "%02d:%02d\n%s\n%s\n%s" % [t / 60, t % 60,
		tr("hud.gold") % [match_ref.unreliable_gold + match_ref.reliable_gold, match_ref.reliable_gold],
		lvl_text + "    " + tr("hud.last_hits") % match_ref.last_hits,
		tr("hud.skill_points") % [match_ref.skill_points, match_ref.ult_points]]
	xp_bar.max_value = match_ref.xp_needed()
	xp_bar.value = match_ref.xp
	var hero := match_ref.hero
	hp_bar.max_value = hero.max_hp
	hp_bar.value = hero.hp
	mana_bar.max_value = hero.max_mana
	mana_bar.value = hero.mana
	hp_label.text = "%d / %d" % [int(hero.hp), int(hero.max_hp)]


func _update_skills() -> void:
	var hero := match_ref.hero
	for slot in ["q", "w", "r", "p"]:
		var pad: TouchPad = skill_pads[slot]
		pad.rank = hero.ranks[slot]
		upgrade_buttons[slot].visible = match_ref.running and match_ref.upgrade_block_reason(slot) == ""
		if slot == "p":
			pad.dim = hero.ranks["p"] <= 0
			pad.sub_text = "x%d" % hero.instinct_stacks if hero.instinct_stacks > 0 else ""
			pad.queue_redraw()
			continue
		var cd: float = hero.cooldowns[slot]
		var total := hero.skill(slot, "cooldown")
		pad.cooldown_frac = clampf(cd / total, 0.0, 1.0) if cd > 0.0 else 0.0
		pad.cooldown_text = str(ceili(cd)) if cd > 0.0 else ""
		var reason := hero.cast_block_reason(slot)
		pad.dim = reason == "cast.not_learned" or reason == "cast.no_mana" or reason == "cast.dead"
		pad.sub_text = "%d" % int(hero.skill(slot, "mana_cost")) if hero.ranks[slot] > 0 else ""
		pad.queue_redraw()
	cancel_zone.visible = hero.aiming_slot != ""


## Item buttons show the item's short name, its cooldown, the stack of a consumable and
## are dimmed when the slot is empty or the item has no active effect.
func _update_items() -> void:
	var m := match_ref
	shop_button.text = tr("hud.shop") % (m.unreliable_gold + m.reliable_gold)
	for i in item_pads.size():
		var pad: TouchPad = item_pads[i]
		var s: Dictionary = m.inventory[i]
		var def := m.item_in_slot(i)
		pad.label_key = "" if s.is_empty() else "item.%s.short" % s["id"]
		pad.sub_text = "x%d" % int(s["count"]) if not s.is_empty() and def["kind"] == "consumable" else ""
		pad.dim = s.is_empty() or def.get("active") == null
		_show_cooldown(pad, m.item_cooldown_left(i), def)
		pad.queue_redraw()
	var ps := m.potion_slot()
	var potions := 0
	for s: Dictionary in m.inventory:
		if not s.is_empty() and m.data.item(s["id"])["kind"] == "consumable":
			potions += int(s["count"])
	potion_pad.dim = ps < 0
	potion_pad.sub_text = "x%d" % potions if potions > 0 else ""
	_show_cooldown(potion_pad, m.item_cooldown_left(ps) if ps >= 0 else 0.0, m.item_in_slot(ps) if ps >= 0 else {})
	potion_pad.queue_redraw()


func _show_cooldown(pad: TouchPad, left: float, def: Dictionary) -> void:
	var active = def.get("active")
	if left <= 0.0 or active == null:
		pad.cooldown_frac = 0.0
		pad.cooldown_text = ""
		return
	pad.cooldown_frac = clampf(left / float(active["cooldown"]), 0.0, 1.0)
	pad.cooldown_text = str(ceili(left))


## Uses the active effect in slot 0-5; the reason of a refusal is shown as a toast.
func use_item(slot: int) -> void:
	var reason := match_ref.use_item(slot)
	if reason != "":
		_on_toast(reason, 0)


func use_potion() -> void:
	var slot := match_ref.potion_slot()
	if slot < 0:
		_on_toast("item.no_potion", 0)
		return
	use_item(slot)


## The catalog opens anywhere and does not pause the match; buying checks the shop rules.
func toggle_shop() -> void:
	if shop_panel.visible:
		shop_panel.visible = false
	else:
		shop_panel.open()


func _show_text(text: String) -> void:
	toast_label.text = text
	_toast_left = 3.0


func _on_skill_pressed(slot: String) -> void:
	var hero := match_ref.hero
	hero.aiming_slot = slot
	hero.aiming_dir = Vector2.ZERO


func _on_skill_dragged(d: Vector2, slot: String) -> void:
	var pad: TouchPad = skill_pads[slot]
	match_ref.hero.aiming_dir = d / pad.pad_radius()


func _on_skill_released(d: Vector2, slot: String) -> void:
	var hero := match_ref.hero
	var pad: TouchPad = skill_pads[slot]
	var finger := pad.global_position + pad.last_local_pos
	hero.aiming_slot = ""
	if cancel_zone.get_global_rect().has_point(finger):
		return
	hero.try_cast(slot, d / pad.pad_radius())


func _open_upgrade(slot: String) -> void:
	_upgrade_slot = slot
	var hero := match_ref.hero
	var rank: int = hero.ranks[slot]
	upgrade_title.text = tr("upgrade.title") % [tr("skill.%s.name" % slot), rank, rank + 1]
	upgrade_desc.text = skill_description(slot, rank + 1)
	upgrade_panel.visible = true


func _confirm_upgrade() -> void:
	var reason := match_ref.upgrade_skill(_upgrade_slot)
	upgrade_panel.visible = false
	if reason != "":
		_on_toast(reason, match_ref.next_rank_level(_upgrade_slot))


## Effect text of a skill at a rank, with numbers from data/skills.json.
func skill_description(slot: String, rank: int) -> String:
	var h := match_ref.hero
	var fmt := tr("skill.%s.desc" % slot)
	match slot:
		"q":
			return fmt % [int(h.skill("q", "damage", rank)), int(h.skill("q", "mana_cost", rank)),
				_num(h.skill("q", "cooldown", rank))]
		"w":
			return fmt % [_num(h.skill("w", "distance", rank)), int(h.skill("w", "damage_reduction", rank) * 100.0),
				_num(h.skill("w", "buff_seconds", rank)), int(h.skill("w", "mana_cost", rank)),
				_num(h.skill("w", "cooldown", rank))]
		"r":
			return fmt % [_num(h.skill("r", "radius", rank)), int(h.skill("r", "damage", rank)),
				_num(h.skill("r", "stun_seconds", rank)), int(h.skill("r", "armor_reduction", rank)),
				_num(h.skill("r", "debuff_seconds", rank)), int(h.skill("r", "mana_cost", rank)),
				_num(h.skill("r", "cooldown", rank))]
		"p":
			return fmt % [int(h.skill("p", "attack_speed_per_stack", rank) * 100.0),
				int(h.skill("p", "max_stacks", rank)), _num(h.skill("p", "stack_seconds", rank))]
	return ""


func _num(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v


## Multi-touch router: screen touches never reach Control._gui_input, so the HUD hit-tests
## the pads itself and tracks every finger by its index. Buttons ("+", pause, panels) keep
## using regular mouse/touch-emulated clicks, so touches over them are left alone.
func _input(event: InputEvent) -> void:
	if match_ref == null:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			if get_tree().paused or not match_ref.running or _over_button(t.position):
				return
			for pad in _touch_pads():
				if pad.accepts_touch(t.position):
					pad.touch_begin(t.index, t.position)
					get_viewport().set_input_as_handled()
					return
		else:
			for pad in _touch_pads():
				if pad.touch_index == t.index:
					pad.touch_end(t.position)
					get_viewport().set_input_as_handled()
					return
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		for pad in _touch_pads():
			if pad.touch_index == d.index:
				pad.touch_move(d.position)
				get_viewport().set_input_as_handled()
				return


func _touch_pads() -> Array:
	var pads: Array = [attack_pad, last_hit_pad, tower_pad, recall_pad, joystick]
	for slot in ["q", "w", "r"]:
		pads.append(skill_pads[slot])
	pads.append_array(item_pads)
	pads.append(potion_pad)
	return pads


func _over_button(pos: Vector2) -> bool:
	for b in upgrade_buttons.values() + [shop_button]:
		if b.visible and b.get_global_rect().has_point(pos):
			return true
	for p in [upgrade_panel, pause_panel, end_panel, shop_panel]:
		if p.visible and p.get_global_rect().has_point(pos):
			return true
	return false


func _cancel_touches() -> void:
	for pad in _touch_pads():
		pad.touch_cancel()
	var hero := match_ref.hero
	hero.attack_held = false
	hero.aiming_slot = ""
	hero.aim_target = null


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or event.is_echo():
		return
	var k := event as InputEventKey
	var hero := match_ref.hero
	match k.physical_keycode:
		KEY_SPACE:
			hero.attack_held = k.pressed
			attack_pad.keyboard_held = k.pressed
			attack_pad.queue_redraw()
			if k.pressed:
				hero.command_attack("auto")
		KEY_F:
			if k.pressed:
				hero.command_attack("creep")
		KEY_G:
			if k.pressed:
				hero.command_attack("tower")
		KEY_B:
			if k.pressed:
				match_ref.start_recall()
		KEY_1, KEY_2, KEY_3:
			if k.pressed:
				hero.try_cast(["q", "w", "r"][k.physical_keycode - KEY_1])
		KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
			if k.pressed:
				use_item(k.physical_keycode - KEY_4)
		KEY_H:
			if k.pressed:
				use_potion()
		KEY_P:
			if k.pressed:
				toggle_shop()
		KEY_ESCAPE:
			if k.pressed and match_ref.running:
				_toggle_pause()


func _on_attack_pressed() -> void:
	var hero := match_ref.hero
	if Settings.attack_mode == "auto":
		hero.attack_held = true
		hero.command_attack("auto")
	else:
		hero.aim_target = hero.pick_aimed(Vector2.ZERO)


func _on_attack_dragged(d: Vector2) -> void:
	if Settings.attack_mode == "semi":
		match_ref.hero.aim_target = match_ref.hero.pick_aimed(d)


func _on_attack_released(_d: Vector2) -> void:
	var hero := match_ref.hero
	hero.attack_held = false
	if Settings.attack_mode == "semi":
		if hero.is_valid_target(hero.aim_target):
			hero.command_attack_unit(hero.aim_target)
		hero.aim_target = null


func _on_toast(key: String, value: int) -> void:
	var text := tr(key)
	if text.contains("%d"):
		text = text % value
	toast_label.text = text
	_toast_left = 3.0


func _on_outcome(outcome: int) -> void:
	var won := outcome == Match.Outcome.WON
	end_title.text = tr("end.victory") if won else tr("end.defeat")
	var t := int(match_ref.time)
	end_stats.text = (tr("end.victory_reason") if won else tr("end.defeat_reason")) + "\n" + \
		tr("end.stats") % ["%02d:%02d" % [t / 60, t % 60], match_ref.level, match_ref.last_hits,
		match_ref.towers_destroyed, match_ref.towers_lost]
	end_panel.visible = true
	death_panel.visible = false


func _debug_max_all() -> void:
	match_ref.debug_add_levels(20)
	match_ref.debug_max_skills()
	match_ref.debug_refill()


func _toggle_pause() -> void:
	var paused := not get_tree().paused
	if paused:
		_cancel_touches()
	get_tree().paused = paused
	pause_panel.visible = paused


func _restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


func _refresh_texts() -> void:
	mode_button.text = tr("pause.attack_mode_auto") if Settings.attack_mode == "auto" else tr("pause.attack_mode_semi")
	priority_button.text = tr("pause.priority_nearest") if Settings.target_priority == "nearest" \
		else tr("pause.priority_lowest_hp")
	language_button.text = tr("pause.language")
	for pad in [joystick, attack_pad, last_hit_pad, tower_pad, recall_pad, cancel_zone, potion_pad]:
		pad.queue_redraw()
	if shop_panel.visible:
		shop_panel.refresh()
	if upgrade_panel.visible:
		_open_upgrade(_upgrade_slot)
