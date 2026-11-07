class_name ShopPanel
extends PanelContainer
## Root of scenes/ui/shop_panel.tscn: catalog, item card (recipe, price, stats, active effect)
## and the six main slots. Browsing works anywhere and does not pause the match; buying and
## selling go through Match.buy / Match.sell, which re-check the shop rules every time and
## change nothing on refusal. Layout lives in the scene; edit it in the Godot editor.

signal message(text: String)

const CARD_SCENE := preload("res://scenes/ui/item_card.tscn")

var match_ref: Match = null
var selected_item := ""
var selected_slot := -1
var _cards: Array = []
var _slots: Array = []


func bind(p_match: Match) -> void:
	match_ref = p_match
	var catalog := %Catalog as GridContainer
	for id in match_ref.data.items:
		var card := CARD_SCENE.instantiate() as ItemCard
		card.item_id = id
		catalog.add_child(card)
		card.chosen.connect(_on_item_chosen)
		_cards.append(card)
	for node in (%Slots as Container).get_children():
		if node is InventorySlot:
			_slots.append(node)
			(node as InventorySlot).chosen.connect(_on_slot_chosen)
	(%Buy as Button).pressed.connect(_on_buy)
	(%Sell as Button).pressed.connect(_on_sell)
	(%Close as Button).pressed.connect(func(): visible = false)


func open() -> void:
	visible = true
	refresh()


func _process(_delta: float) -> void:
	if visible and match_ref != null:
		refresh()


func refresh() -> void:
	var m := match_ref
	(%Gold as Label).text = tr("hud.gold") % [m.unreliable_gold + m.reliable_gold, m.reliable_gold]
	var reason := m.shop_block_reason()
	var status := %Status as Label
	status.text = tr("shop.status_ok") if reason == "" else tr(reason)
	status.modulate = Color(0.55, 1.0, 0.6) if reason == "" else Color(1.0, 0.6, 0.45)
	for card: ItemCard in _cards:
		card.show_item(card.item_id, int(m.purchase_plan(card.item_id)["cost"]), card.item_id == selected_item)
	for slot: InventorySlot in _slots:
		slot.show_slot(m.inventory[slot.index], slot.index == selected_slot)
	_show_details()
	var sell := %Sell as Button
	sell.disabled = selected_slot < 0 or m.inventory[selected_slot].is_empty()
	sell.text = tr("shop.sell") % (m.sell_value(selected_slot) if not sell.disabled else 0)


func _show_details() -> void:
	var name_label := %Name as Label
	var buy := %Buy as Button
	buy.disabled = selected_item == ""
	if selected_item == "":
		name_label.text = tr("shop.pick_item")
		for n in ["%Recipe", "%Price", "%Stats", "%Active"]:
			(get_node(n) as Label).text = ""
		return
	var def: Dictionary = match_ref.data.item(selected_item)
	name_label.text = tr("item.%s.name" % selected_item)
	(%Recipe as Label).text = _recipe_text(def)
	var plan := match_ref.purchase_plan(selected_item)
	var full := int(def["price"])
	var cost := int(plan["cost"])
	(%Price as Label).text = tr("shop.cost") % full if cost >= full else tr("shop.cost_left") % [cost, full]
	(%Stats as Label).text = stats_text(def.get("stats", {}))
	var active = def.get("active")
	(%Active as Label).text = tr("shop.no_active") if active == null else tr("shop.active") % active_text(active)


func _recipe_text(def: Dictionary) -> String:
	match str(def["kind"]):
		"component":
			return tr("shop.component")
		"consumable":
			return tr("shop.consumable") % int(def["max_stack"])
	# Mark the components the player already has (each owned slot counts once).
	var used: Array = []
	var parts: Array = []
	for c in def["components"]:
		var owned := -1
		for i in match_ref.inventory.size():
			var s: Dictionary = match_ref.inventory[i]
			if not i in used and not s.is_empty() and s["id"] == c:
				owned = i
				break
		var part := tr("item.%s.name" % c)
		if owned >= 0:
			used.append(owned)
			part += " (%s)" % tr("shop.owned")
		else:
			part += " %d" % int(match_ref.data.item(c)["price"])
		parts.append(part)
	return tr("shop.recipe") % " + ".join(parts)


## One line per passive stat, with numbers from data/items.json.
func stats_text(stats: Dictionary) -> String:
	var lines: Array = []
	for k in stats:
		var v := float(stats[k])
		match k:
			"attack_speed", "cleave_share":
				lines.append(tr("stat." + k) % int(round(v * 100.0)))
			"move_speed", "mana_regen", "hp_regen":
				lines.append(tr("stat." + k) % _num(v))
			_:
				lines.append(tr("stat." + k) % int(v))
	return "\n".join(lines)


## Effect text of an item's active, with numbers from data/items.json.
func active_text(a: Dictionary) -> String:
	var fmt := tr("active." + str(a["kind"]))
	var v := float(a.get("value", 0.0))
	var s := _num(float(a.get("seconds", 0.0)))
	var cd := _num(float(a["cooldown"]))
	match str(a["kind"]):
		"attack_speed_buff", "haste":
			return fmt % [int(round(v * 100.0)), s, cd]
		"shield", "regen_hp", "regen_mana":
			return fmt % [int(v), s, cd]
		"restore_mana":
			return fmt % [int(v), cd]
		"creep_ward":
			return fmt % [_num(float(a["radius"])), int(round(v * 100.0)), s, cd]
		"stun_nearest":
			return fmt % [_num(float(a["radius"])), s, cd]
	return ""


func _num(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v


func _on_item_chosen(id: String) -> void:
	selected_item = id
	refresh()


func _on_slot_chosen(index: int) -> void:
	selected_slot = -1 if selected_slot == index else index
	refresh()


func _on_buy() -> void:
	if selected_item == "":
		return
	var reason := match_ref.buy(selected_item)
	message.emit(tr(reason) if reason != "" else tr("shop.bought") % tr("item.%s.name" % selected_item))
	refresh()


func _on_sell() -> void:
	if selected_slot < 0:
		return
	var value := match_ref.sell_value(selected_slot)
	var reason := match_ref.sell(selected_slot)
	message.emit(tr(reason) if reason != "" else tr("shop.sold") % value)
	refresh()
