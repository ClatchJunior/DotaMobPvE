extends Node
## Loads and validates authored data from res://data and installs UI translations.
## Fails early with the file, id and field that are wrong.

const DATA_DIR := "res://data/"
const LOCALES := ["ru", "en"]
const REQUIRED_UNITS := [
	"hero_vanguard", "creep_melee", "creep_ranged", "creep_siege",
	"tower_t1", "tower_t2", "tower_t3", "core",
]
const UNIT_FIELDS := {
	"hero": ["max_hp", "max_mana", "hp_regen", "mana_regen", "damage", "armor", "attack_range",
		"attack_cooldown", "move_speed", "acquire_radius", "radius"],
	"creep": ["max_hp", "damage", "armor", "attack_range", "attack_cooldown", "move_speed",
		"aggro_radius", "gold", "xp", "radius"],
	"tower": ["max_hp", "damage", "armor", "attack_range", "attack_cooldown", "projectile_speed",
		"reliable_gold", "xp", "radius"],
	"core": ["max_hp", "armor", "radius"],
}
const BALANCE_NUMBERS := [
	"first_wave_delay", "wave_period", "wave_melee", "wave_ranged", "siege_every",
	"creep_upgrade_period", "creep_upgrade_player", "creep_upgrade_enemy",
	"participation_share", "participation_window", "participation_radius",
	"barrier_damage_multiplier", "barrier_restore_delay", "respawn_base", "respawn_per_level",
	"death_gold_loss", "fountain_radius", "fountain_regen_share", "fountain_damage_per_second",
	"recall_seconds", "starting_gold", "hero_max_level", "xp_base", "xp_step", "creep_hero_aggro_seconds",
	"skill_structure_damage_mult", "out_of_combat_seconds", "sell_refund_share", "cleave_radius",
]
const BALANCE_LEVEL_LISTS := ["skill_point_levels", "ult_point_levels", "stat_package_levels"]

const SKILL_SLOTS := ["q", "w", "r", "p"]
const SKILL_FIELDS := {
	"cone": ["range", "angle_deg", "mana_cost", "cooldown", "damage"],
	"dash": ["distance", "dash_seconds", "mana_cost", "cooldown", "damage_reduction", "buff_seconds"],
	"area": ["radius", "mana_cost", "cooldown", "damage", "stun_seconds", "armor_reduction", "debuff_seconds"],
	"passive": ["max_stacks", "attack_speed_per_stack", "stack_seconds"],
}

## items.json: components only add stats; items are built from components (one level deep, so
## a recipe can never loop); consumables stack in one slot and always have an active effect.
const ITEM_KINDS := ["component", "item", "consumable"]
const ITEM_STATS := ["max_hp", "max_mana", "hp_regen", "mana_regen", "damage", "armor",
	"attack_speed", "move_speed", "cleave_share"]
const ITEM_ACTIVES := {
	"attack_speed_buff": ["value", "seconds", "cooldown"],
	"shield": ["value", "seconds", "cooldown"],
	"restore_mana": ["value", "cooldown"],
	"creep_ward": ["value", "radius", "seconds", "cooldown"],
	"stun_nearest": ["radius", "seconds", "cooldown"],
	"haste": ["value", "seconds", "cooldown"],
	"regen_hp": ["value", "seconds", "cooldown"],
	"regen_mana": ["value", "seconds", "cooldown"],
}

var units := {}
var skills := {}
var items := {}
var balance := {}
var strings := {}
var errors := PackedStringArray()
var _translations_installed := false


func _ready() -> void:
	if not load_all():
		for e in errors:
			push_error("GameData: " + e)
	install_translations()


func load_all() -> bool:
	errors.clear()
	units = _read("units.json")
	skills = _read("skills.json")
	balance = _read("balance.json")
	strings = _read("i18n.json")
	items = _read("items.json")
	_validate_units()
	_validate_skills()
	_validate_balance()
	_validate_strings()
	errors.append_array(validate_items(items, strings))
	return errors.is_empty()


func unit(id: String) -> Dictionary:
	return units.get(id, {})


func item(id: String) -> Dictionary:
	return items.get(id, {})


## Errors in an item catalog (empty when it is valid). Every item needs a name string
## "item.<id>.name" when strings are given. Static, so tests can feed broken catalogs.
static func validate_items(catalog: Dictionary, texts := {}) -> PackedStringArray:
	var out := PackedStringArray()
	if catalog.is_empty():
		out.append("items.json: no items")
	for id in catalog:
		var it = catalog[id]
		if typeof(it) != TYPE_DICTIONARY:
			out.append("items.json: '%s' is not an object" % id)
			continue
		var kind := str(it.get("kind", ""))
		if not kind in ITEM_KINDS:
			out.append("items.json: '%s' has unknown kind '%s'" % [id, kind])
			continue
		var price = it.get("price")
		if not (typeof(price) in [TYPE_INT, TYPE_FLOAT]) or float(price) <= 0.0:
			out.append("items.json: '%s' needs a positive 'price'" % id)
			price = 0
		var stats = it.get("stats", {})
		if typeof(stats) != TYPE_DICTIONARY:
			out.append("items.json: '%s.stats' must be an object" % id)
		else:
			for s in stats:
				if not s in ITEM_STATS:
					out.append("items.json: '%s.stats' has unknown stat '%s'" % [id, s])
				elif not (typeof(stats[s]) in [TYPE_INT, TYPE_FLOAT]):
					out.append("items.json: '%s.stats.%s' must be a number" % [id, s])
		var comps = it.get("components", [])
		if kind == "item":
			if typeof(comps) != TYPE_ARRAY or comps.is_empty():
				out.append("items.json: '%s' needs a 'components' list" % id)
			else:
				var parts := 0.0
				for c in comps:
					var cdef = catalog.get(str(c))
					if typeof(cdef) != TYPE_DICTIONARY:
						out.append("items.json: '%s' uses unknown component '%s'" % [id, c])
					elif str(cdef.get("kind", "")) != "component":
						out.append("items.json: '%s' uses '%s', which is not a component (recipes are one level deep)" % [id, c])
					else:
						parts += float(cdef.get("price", 0))
				if float(price) <= parts:
					out.append("items.json: '%s' price %d must be above its components' %d" % [id, int(price), int(parts)])
		elif typeof(comps) != TYPE_ARRAY or not comps.is_empty():
			out.append("items.json: '%s' is a %s and cannot have components" % [id, kind])
		var active = it.get("active")
		if kind == "consumable":
			if not (typeof(it.get("max_stack")) in [TYPE_INT, TYPE_FLOAT]) or int(it["max_stack"]) < 1:
				out.append("items.json: '%s' needs 'max_stack' of at least 1" % id)
			if active == null:
				out.append("items.json: consumable '%s' needs an 'active'" % id)
		if active != null:
			if kind == "component":
				out.append("items.json: component '%s' cannot have an 'active'" % id)
			elif typeof(active) != TYPE_DICTIONARY or not ITEM_ACTIVES.has(str(active.get("kind", ""))):
				out.append("items.json: '%s.active' has unknown kind" % id)
			else:
				for field in ITEM_ACTIVES[str(active["kind"])]:
					var v = active.get(field)
					if not (typeof(v) in [TYPE_INT, TYPE_FLOAT]) or float(v) <= 0.0:
						out.append("items.json: '%s.active' needs positive '%s'" % [id, field])
		if not texts.is_empty() and not texts.has("item.%s.name" % id):
			out.append("i18n.json: missing 'item.%s.name'" % id)
	return out


func install_translations() -> void:
	if _translations_installed:
		return
	for loc in LOCALES:
		var t := Translation.new()
		t.locale = loc
		for key in strings:
			var entry = strings[key]
			if typeof(entry) == TYPE_DICTIONARY:
				t.add_message(key, str(entry.get(loc, key)))
		TranslationServer.add_translation(t)
	_translations_installed = true


func _read(file_name: String) -> Dictionary:
	var path := DATA_DIR + file_name
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		errors.append("%s: cannot open" % path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s: not a JSON object" % path)
		return {}
	return parsed


func _is_number(v) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT


func _validate_units() -> void:
	for id in REQUIRED_UNITS:
		if not units.has(id):
			errors.append("units.json: missing unit '%s'" % id)
	for id in units:
		var u = units[id]
		if typeof(u) != TYPE_DICTIONARY:
			errors.append("units.json: '%s' is not an object" % id)
			continue
		var kind: String = str(u.get("kind", ""))
		if not UNIT_FIELDS.has(kind):
			errors.append("units.json: '%s' has unknown kind '%s'" % [id, kind])
			continue
		for field in UNIT_FIELDS[kind]:
			if not _is_number(u.get(field)):
				errors.append("units.json: '%s' needs number '%s'" % [id, field])
		var scene := str(u.get("scene", ""))
		if not scene.ends_with(".tscn") or not ResourceLoader.exists(scene):
			errors.append("units.json: '%s' needs 'scene' with an existing .tscn, got '%s'" % [id, scene])


## Each per-rank field is a number or an array of exactly 3 numbers (ranks 1-3).
func _validate_skills() -> void:
	for slot in SKILL_SLOTS:
		var s = skills.get(slot)
		if typeof(s) != TYPE_DICTIONARY:
			errors.append("skills.json: missing skill '%s'" % slot)
			continue
		var kind: String = str(s.get("kind", ""))
		if not SKILL_FIELDS.has(kind):
			errors.append("skills.json: '%s' has unknown kind '%s'" % [slot, kind])
			continue
		var levels = s.get("min_levels")
		if typeof(levels) != TYPE_ARRAY or levels.size() != 3:
			errors.append("skills.json: '%s' needs 'min_levels' with 3 levels" % slot)
		for field in SKILL_FIELDS[kind]:
			var v = s.get(field)
			if typeof(v) == TYPE_ARRAY:
				if v.size() != 3 or v.any(func(x): return not _is_number(x)):
					errors.append("skills.json: '%s.%s' must list 3 numbers" % [slot, field])
			elif not _is_number(v):
				errors.append("skills.json: '%s' needs number '%s'" % [slot, field])


func _validate_balance() -> void:
	for field in BALANCE_NUMBERS:
		if not _is_number(balance.get(field)):
			errors.append("balance.json: needs number '%s'" % field)
	for field in BALANCE_LEVEL_LISTS:
		var list = balance.get(field)
		if typeof(list) != TYPE_ARRAY:
			errors.append("balance.json: needs array '%s'" % field)
			continue
		var ints: Array[int] = []
		for v in list:
			ints.append(int(v))
		balance[field] = ints
	var pkg = balance.get("stat_package")
	if typeof(pkg) != TYPE_DICTIONARY:
		errors.append("balance.json: needs object 'stat_package'")


func _validate_strings() -> void:
	for key in strings:
		var entry = strings[key]
		if typeof(entry) != TYPE_DICTIONARY:
			errors.append("i18n.json: '%s' is not an object" % key)
			continue
		for loc in LOCALES:
			if str(entry.get(loc, "")).is_empty():
				errors.append("i18n.json: '%s' has no '%s' text" % [key, loc])
