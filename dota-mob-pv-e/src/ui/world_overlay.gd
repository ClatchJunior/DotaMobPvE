class_name WorldOverlay
extends Control
## 2D layer over the 3D view: health bars, barrier state of enemy structures,
## the hero's attack target and aim highlight, recall progress.

const BARRIER_COLORS := {
	Rules.Barrier.ACTIVE: Color(1.0, 0.82, 0.2),
	Rules.Barrier.RESTORING: Color(1.0, 0.55, 0.15),
	Rules.Barrier.SUPPRESSED: Color(0.55, 0.6, 0.65),
}

var match_ref: Match = null
var camera: Camera3D = null


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if match_ref == null or camera == null:
		return
	var hero := match_ref.hero
	for e in match_ref.fx:
		var a: float = 1.0 - e["t"] / 0.35
		var col: Color = e["color"]
		_shape(e["kind"], e["pos"], e.get("dir", Vector2.RIGHT), e["range"], e.get("angle", 0.0),
			Color(col, 0.55 * a), true)
	if hero.alive and hero.aiming_slot != "":
		_draw_aim(hero)
	if hero.alive:
		if hero.is_valid_target(hero.order_target):
			_ring(hero.order_target, Color(1.0, 0.3, 0.25))
		if hero.is_valid_target(hero.aim_target):
			_ring(hero.aim_target, Color(1.0, 0.95, 0.3))
	for s in match_ref.structures:
		if s.alive:
			_structure_bar(s)
	for c in match_ref.creeps:
		if is_instance_valid(c) and c.alive:
			_bar(c, 28.0, 4.0, Color(0.35, 0.75, 1.0) if c.faction == Unit.Faction.PLAYER else Color(0.95, 0.35, 0.25))
	if hero.alive:
		_bar(hero, 70.0, 8.0, Color(0.3, 0.95, 0.45))
		if hero.is_recalling():
			var p := _screen(hero, hero.bar_height + 0.9)
			var k := 1.0 - hero.recall_left / float(match_ref.bal["recall_seconds"])
			draw_rect(Rect2(p - Vector2(40, 3), Vector2(80, 6)), Color(0, 0, 0, 0.6))
			draw_rect(Rect2(p - Vector2(40, 3), Vector2(80.0 * k, 6)), Color(0.5, 0.8, 1.0))


func _screen(u: Unit, height: float) -> Vector2:
	return camera.unproject_position(u.global_position + Vector3(0, height, 0))


func _visible(u: Unit) -> bool:
	return not camera.is_position_behind(u.global_position)


func _bar(u: Unit, w: float, h: float, color: Color) -> void:
	if not _visible(u):
		return
	var p := _screen(u, u.bar_height)
	var rect := Rect2(p - Vector2(w * 0.5, h * 0.5), Vector2(w, h))
	draw_rect(rect.grow(1.0), Color(0, 0, 0, 0.7))
	draw_rect(Rect2(rect.position, Vector2(w * clampf(u.hp / u.max_hp, 0.0, 1.0), h)), color)


func _structure_bar(s: Structure) -> void:
	if not _visible(s):
		return
	var color := Color(0.35, 0.75, 1.0) if s.faction == Unit.Faction.PLAYER else Color(0.95, 0.35, 0.25)
	var vulnerable := s.is_targetable()
	if not vulnerable:
		color = color.darkened(0.55)
	_bar(s, 90.0, 9.0, color)
	if s.barrier_enabled and vulnerable:
		var p := _screen(s, s.bar_height) + Vector2(-58.0, 0.0)
		var bc: Color = BARRIER_COLORS[s.barrier]
		var pts := PackedVector2Array([p + Vector2(0, -9), p + Vector2(8, -5), p + Vector2(6, 6),
			p + Vector2(0, 10), p + Vector2(-6, 6), p + Vector2(-8, -5)])
		draw_colored_polygon(pts, bc)
		if s.barrier == Rules.Barrier.SUPPRESSED:
			draw_line(p + Vector2(-9, -9), p + Vector2(9, 9), Color(0.1, 0.1, 0.1), 3.0)


## Skill preview while the button is held: Q sector, W dash line, R circle.
func _draw_aim(hero: Hero) -> void:
	var slot := hero.aiming_slot
	var dir := hero.cast_direction(slot, hero.aiming_dir)
	var col := Color(0.55, 0.95, 0.85, 0.35) if slot != "r" else Color(1.0, 0.55, 0.3, 0.35)
	match slot:
		"q":
			_shape("cone", hero.global_position, dir, hero.skill("q", "range"), hero.skill("q", "angle_deg"), col, true)
		"w":
			_shape("line", hero.global_position, dir, hero.skill("w", "distance"), 0.0, col, true)
		"r":
			_shape("circle", hero.global_position, dir, hero.skill("r", "radius"), 0.0, col, true)


## Ground shape in world space projected to the screen.
func _shape(kind: String, pos: Vector3, dir: Vector2, reach: float, angle_deg: float, color: Color,
		filled: bool) -> void:
	var pts := PackedVector2Array()
	var base := pos + Vector3(0, 0.05, 0)
	match kind:
		"cone":
			var half := deg_to_rad(angle_deg) * 0.5
			var a0 := dir.angle()
			pts.append(camera.unproject_position(base))
			for i in 17:
				var a := a0 - half + half * 2.0 * float(i) / 16.0
				pts.append(camera.unproject_position(base + Vector3(cos(a), 0, sin(a)) * reach))
		"circle":
			for i in 33:
				var a := TAU * float(i) / 32.0
				pts.append(camera.unproject_position(base + Vector3(cos(a), 0, sin(a)) * reach))
		"line":
			var side := Vector2(-dir.y, dir.x) * 0.6
			var d3 := Vector3(dir.x, 0, dir.y)
			var s3 := Vector3(side.x, 0, side.y)
			pts.append(camera.unproject_position(base + s3))
			pts.append(camera.unproject_position(base + d3 * reach + s3))
			pts.append(camera.unproject_position(base + d3 * reach - s3))
			pts.append(camera.unproject_position(base - s3))
	if pts.size() < 3:
		return
	if filled:
		draw_colored_polygon(pts, color)
	var outline := pts.duplicate()
	outline.append(pts[0])
	draw_polyline(outline, Color(color, minf(1.0, color.a * 2.5)), 2.0, true)


func _ring(u: Unit, color: Color) -> void:
	if not _visible(u):
		return
	var pts := PackedVector2Array()
	var r := u.radius + 0.35
	for i in 25:
		var a := TAU * float(i) / 24.0
		pts.append(camera.unproject_position(u.global_position + Vector3(cos(a) * r, 0.05, sin(a) * r)))
	draw_polyline(pts, color, 3.0, true)
