extends Node
## Player settings stored on the device: attack mode, auto-target priority, language.

signal changed

const PATH := "user://settings.json"
const ATTACK_MODES := ["auto", "semi"]
const PRIORITIES := ["nearest", "lowest_hp"]
const LOCALES := ["ru", "en"]

var attack_mode := "auto"
var target_priority := "nearest"
var locale := ""


func _ready() -> void:
	load_settings()
	apply_locale()


func load_settings() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("Settings: unreadable settings file, using defaults")
		return
	if data.get("attack_mode") in ATTACK_MODES:
		attack_mode = data["attack_mode"]
	if data.get("target_priority") in PRIORITIES:
		target_priority = data["target_priority"]
	if data.get("locale") in LOCALES:
		locale = data["locale"]


func save_settings() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("Settings: cannot write %s" % PATH)
		return
	f.store_string(JSON.stringify({
		"attack_mode": attack_mode,
		"target_priority": target_priority,
		"locale": locale,
	}))


func apply_locale() -> void:
	if not locale in LOCALES:
		locale = "ru" if OS.get_locale_language() == "ru" else "en"
	TranslationServer.set_locale(locale)


func cycle(key: String) -> void:
	match key:
		"attack_mode":
			attack_mode = _next(ATTACK_MODES, attack_mode)
		"target_priority":
			target_priority = _next(PRIORITIES, target_priority)
		"locale":
			locale = _next(LOCALES, locale)
			apply_locale()
	save_settings()
	changed.emit()


func _next(options: Array, current: String) -> String:
	return options[(options.find(current) + 1) % options.size()]
