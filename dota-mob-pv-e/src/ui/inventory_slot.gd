class_name InventorySlot
extends Button
## Root of scenes/ui/inventory_slot.tscn: one of the six main slots in the shop window.
## shop_panel.tscn places six instances with index 0-5.

signal chosen(index: int)

@export var index := 0


func _ready() -> void:
	pressed.connect(func(): chosen.emit(index))


## slot: {} when empty or {"id": String, "count": int}.
func show_slot(slot: Dictionary, selected: bool) -> void:
	if slot.is_empty():
		text = "-"
	elif int(slot["count"]) > 1:
		text = "%s\nx%d" % [tr("item.%s.short" % slot["id"]), int(slot["count"])]
	else:
		text = tr("item.%s.short" % slot["id"])
	set_pressed_no_signal(selected)
