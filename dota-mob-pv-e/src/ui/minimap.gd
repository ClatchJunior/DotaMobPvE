class_name Minimap
extends Control
## Square minimap in the top-left corner, turned like the camera (Mobile Legends style):
## own base bottom-left, enemy base top-right. Shows the lane, forest, structures, both
## waves and the hero.

var match_ref: Match = null
var _scale := 1.0
var _center := Vector2.ZERO


func _process(_delta: float) -> void:
	queue_redraw()


func _corners(half_x: float, half_z: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(-half_x, -half_z), Vector2(half_x, -half_z),
		Vector2(half_x, half_z), Vector2(-half_x, half_z)])


## World (x, z) to minimap pixels: rotate like the camera, then fit into the square.
func _to_map(world: Vector2) -> Vector2:
	return size * 0.5 + (match_ref.world_to_screen(world) - _center) * _scale


func _fit() -> void:
	var half_x := match_ref.map_node.half_length
	var half_z := match_ref.map_node.half_depth()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in _corners(half_x, half_z):
		var s := match_ref.world_to_screen(c)
		lo = lo.min(s)
		hi = hi.max(s)
	_center = (lo + hi) * 0.5
	var extent := hi - lo
	_scale = minf((size.x - 8.0) / extent.x, (size.y - 8.0) / extent.y)


func _poly(half_x: float, half_z: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for c in _corners(half_x, half_z):
		pts.append(_to_map(c))
	return pts


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.08, 0.06, 0.85))
	if match_ref == null:
		return
	_fit()
	var m := match_ref.map_node
	draw_colored_polygon(_poly(m.half_length, m.half_depth()), Color(0.16, 0.3, 0.17))
	draw_colored_polygon(_poly(m.half_length, m.lane_half_width), Color(0.45, 0.4, 0.33))
	for s in match_ref.structures:
		var col: Color = Unit.FACTION_COLORS[s.faction] if s.alive else Color(0.3, 0.3, 0.3)
		var half := 6.0 if s.is_core else 4.0
		var p := _to_map(Vector2(s.global_position.x, s.global_position.z))
		draw_rect(Rect2(p - Vector2(half, half), Vector2(half, half) * 2.0), col)
	for c in match_ref.creeps:
		if is_instance_valid(c) and c.alive:
			draw_circle(_to_map(Vector2(c.global_position.x, c.global_position.z)), 2.0,
				Unit.FACTION_COLORS[c.faction])
	var hero := match_ref.hero
	if hero.alive:
		var hp := _to_map(Vector2(hero.global_position.x, hero.global_position.z))
		draw_circle(hp, 5.0, Color.WHITE)
		draw_circle(hp, 3.0, Color(0.1, 0.85, 0.75))
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.4), false, 1.5)
