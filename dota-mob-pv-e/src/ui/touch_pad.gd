class_name TouchPad
extends Control
## Round multi-touch control: a virtual joystick or an action button that can be dragged to aim.
## Handles each finger by its touch index, so moving and attacking work at the same time.
## On PC the project emulates touch from the mouse. The HUD routes touches to pads.

signal pressed
signal released(drag: Vector2)
signal dragged(drag: Vector2)

## Root of scenes/ui/touch_pad.tscn; each HUD button is an instance with these set in hud.tscn.
@export var is_joystick := false
@export var label_key := ""
@export var accent := Color(0.85, 0.9, 1.0)
## Rank pips under skill buttons: -1 hides them.
@export var rank := -1
@export var max_rank := 3
var touch_index := -1
var drag := Vector2.ZERO
## Last finger position in local coordinates, not clamped (used for the cancel zone).
var last_local_pos := Vector2.ZERO
var keyboard_held := false
## Skill button state drawn on top of the pad.
var cooldown_frac := 0.0
var cooldown_text := ""
var dim := false
var sub_text := ""


func pad_radius() -> float:
	return minf(size.x, size.y) * 0.5


func is_held() -> bool:
	return touch_index != -1 or keyboard_held


## Joystick direction with length 0..1.
func vector() -> Vector2:
	if touch_index == -1:
		return Vector2.ZERO
	return drag / pad_radius()


## Touches are routed here by the HUD (Hud._input), not by Godot's GUI: screen touches do not
## reach Control._gui_input, so the HUD hit-tests the pads itself. Positions are global.
func accepts_touch(global_pos: Vector2) -> bool:
	if touch_index != -1 or mouse_filter == MOUSE_FILTER_IGNORE or not is_visible_in_tree():
		return false
	return (global_pos - get_global_rect().position).distance_to(size * 0.5) <= pad_radius() * 1.15


func touch_begin(index: int, global_pos: Vector2) -> void:
	touch_index = index
	drag = Vector2.ZERO
	last_local_pos = global_pos - get_global_rect().position
	if is_joystick:
		_update_drag(last_local_pos)
	pressed.emit()
	queue_redraw()


func touch_move(global_pos: Vector2) -> void:
	last_local_pos = global_pos - get_global_rect().position
	_update_drag(last_local_pos)
	dragged.emit(drag)
	queue_redraw()


func touch_end(global_pos: Vector2) -> void:
	last_local_pos = global_pos - get_global_rect().position
	var d := drag
	touch_index = -1
	drag = Vector2.ZERO
	released.emit(d)
	queue_redraw()


## Drops a touch without firing the action (pause, death, panels).
func touch_cancel() -> void:
	if touch_index == -1:
		return
	touch_index = -1
	drag = Vector2.ZERO
	queue_redraw()


func _update_drag(pos: Vector2) -> void:
	drag = (pos - size * 0.5).limit_length(pad_radius())


func _draw() -> void:
	var c := size * 0.5
	var r := pad_radius()
	draw_circle(c, r, Color(0.06, 0.08, 0.12, 0.55))
	draw_arc(c, r - 1.5, 0.0, TAU, 48, Color(accent, 0.9), 3.0, true)
	if is_joystick:
		draw_circle(c + drag, r * 0.42, Color(accent, 0.75 if is_held() else 0.45))
		return
	if is_held():
		draw_circle(c, r * 0.92, Color(accent, 0.3))
	if dim:
		draw_circle(c, r - 3.0, Color(0.0, 0.0, 0.0, 0.55))
	if cooldown_frac > 0.0:
		var pts := PackedVector2Array([c])
		for i in 33:
			var a := -PI * 0.5 + TAU * cooldown_frac * float(i) / 32.0
			pts.append(c + Vector2(cos(a), sin(a)) * (r - 3.0))
		draw_colored_polygon(pts, Color(0.0, 0.0, 0.0, 0.6))
	if drag.length() > 6.0:
		draw_line(c, c + drag, accent, 4.0, true)
	var font := get_theme_default_font()
	var text := cooldown_text if cooldown_text != "" else tr(label_key)
	var fs := clampi(int(r * 0.34), 13, 30)
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, c + Vector2(-w * 0.5, fs * 0.35), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
	if sub_text != "":
		var sfs := clampi(int(r * 0.22), 11, 16)
		var sw := font.get_string_size(sub_text, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x
		draw_string(font, c + Vector2(-sw * 0.5, r * 0.62), sub_text, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs,
			Color(1, 1, 1, 0.85))
	if rank >= 0:
		for i in max_rank:
			var p := c + Vector2((float(i) - float(max_rank - 1) * 0.5) * 12.0, r + 7.0)
			draw_circle(p, 4.0, accent if i < rank else Color(0.2, 0.2, 0.25, 0.9))
