class_name ItemCard
extends Button
## Root of scenes/ui/item_card.tscn: one catalog entry of the shop with its name and price.
## The shop panel instances one card per item of data/items.json.

signal chosen(item_id: String)

@export var item_id := ""


func _ready() -> void:
	pressed.connect(func(): chosen.emit(item_id))


## price: what the player would pay now (owned components already subtracted).
func show_item(id: String, price: int, selected: bool) -> void:
	item_id = id
	text = "%s\n%d" % [tr("item.%s.name" % id), price]
	set_pressed_no_signal(selected)
