class_name Unit
extends Node3D
## Base of every combat unit: hero, lane creeps, towers and cores.
## Movement is planar (x, z); there is no physics body in the gray-box build.
## Every unit is a scene in scenes/units/ with this script family on the root and a %Body mesh.

signal died(unit: Unit, killer: Unit)

enum Faction { PLAYER, ENEMY }

const FACTION_COLORS := [Color(0.25, 0.7, 0.85), Color(0.95, 0.55, 0.2)]

var match_ref: Node = null
var unit_id := ""
var faction: int = Faction.PLAYER
var is_hero := false
var max_hp := 100.0
var hp := 100.0
var damage := 0.0
var armor := 0.0
var attack_range := 1.0
var attack_cooldown := 1.0
var move_speed := 0.0
var radius := 0.5
var alive := true
var attack_timer := 0.0
var target: Unit = null
var last_hit_by_hero_at := -1000.0
## Height of the health bar above the ground, set per unit scene.
@export var bar_height := 2.0
## Recolor the Body by faction (creeps, towers, cores) or keep the scene's own color (hero).
@export var tint_by_faction := true
@export var tint_darken := 0.15
var body: MeshInstance3D = null
var stun_left := 0.0
var armor_debuff := 0.0
var armor_debuff_left := 0.0
var ward_reduction := 0.0
var ward_left := 0.0
var _flash := 0.0
var _base_color := Color.WHITE


func setup(p_match: Node, id: String, def: Dictionary, p_faction: int, mult := 1.0) -> void:
	match_ref = p_match
	unit_id = id
	faction = p_faction
	max_hp = float(def.get("max_hp", 100.0)) * mult
	hp = max_hp
	damage = float(def.get("damage", 0.0)) * mult
	armor = float(def.get("armor", 0.0))
	attack_range = float(def.get("attack_range", 1.0))
	attack_cooldown = float(def.get("attack_cooldown", 1.0))
	move_speed = float(def.get("move_speed", 0.0))
	radius = float(def.get("radius", 0.5))
	bind_body()


## Untyped on purpose: a target may already be freed, and a freed object cannot be passed
## into a typed Unit parameter.
func is_valid_target(u) -> bool:
	return u != null and is_instance_valid(u) and u.alive


## Structures override this: a tower behind a living lower tier cannot be attacked.
func is_targetable() -> bool:
	return alive


func flat_distance(u: Unit) -> float:
	var d := global_position - u.global_position
	return Vector2(d.x, d.z).length()


## Distance between edges, so big structures are reachable.
func edge_distance(u: Unit) -> float:
	return flat_distance(u) - radius - u.radius


func in_attack_range(u: Unit) -> bool:
	return edge_distance(u) <= attack_range


func take_damage(amount: float, source: Unit) -> void:
	if not alive:
		return
	if source != null and is_instance_valid(source) and source.is_hero:
		last_hit_by_hero_at = match_ref.time
		source.last_combat_at = match_ref.time
	if ward_left > 0.0:
		amount *= 1.0 - ward_reduction
	hp -= Rules.mitigate(amount, effective_armor())
	_flash = 0.12
	if hp <= 0.0:
		hp = 0.0
		die(source)


func effective_armor() -> float:
	return armor - armor_debuff


func apply_stun(seconds: float) -> void:
	stun_left = maxf(stun_left, seconds)


## The same debuff does not stack: the strongest value stays, the duration refreshes.
func apply_armor_debuff(value: float, seconds: float) -> void:
	armor_debuff = maxf(armor_debuff, value)
	armor_debuff_left = maxf(armor_debuff_left, seconds)


## Signal Banner: less damage taken for a while. Copies do not stack: the strongest value
## stays and the duration refreshes.
func apply_damage_ward(reduction: float, seconds: float) -> void:
	ward_reduction = maxf(ward_reduction, reduction)
	ward_left = maxf(ward_left, seconds)


## Ticks status timers. Returns true while the unit is stunned.
func tick_status(delta: float) -> bool:
	if ward_left > 0.0:
		ward_left -= delta
		if ward_left <= 0.0:
			ward_reduction = 0.0
	if armor_debuff_left > 0.0:
		armor_debuff_left -= delta
		if armor_debuff_left <= 0.0:
			armor_debuff = 0.0
	if stun_left > 0.0:
		stun_left -= delta
		return true
	return false


func die(killer: Unit) -> void:
	if not alive:
		return
	alive = false
	if killer != null and not is_instance_valid(killer):
		killer = null
	died.emit(self, killer)
	_on_died()


func _on_died() -> void:
	queue_free()


func move_towards(point: Vector3, delta: float, stop_distance := 0.0) -> void:
	var d := point - global_position
	d.y = 0.0
	var dist := d.length()
	if dist <= stop_distance or dist < 0.001:
		return
	var step := minf(move_speed * delta, dist - stop_distance)
	global_position += d / dist * step
	face(d)


func face(direction: Vector3) -> void:
	if body != null and Vector2(direction.x, direction.z).length() > 0.01:
		body.rotation.y = atan2(direction.x, direction.z)


## Takes the Body mesh from the unit's scene. With tint_by_faction the scene's material is
## duplicated and recolored, so one scene serves both sides.
func bind_body() -> void:
	body = get_node_or_null("%Body") as MeshInstance3D
	if body == null:
		push_error("Unit scene '%s' has no %%Body node" % scene_file_path)
		return
	var mat := body.material_override as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
	mat = mat.duplicate()
	if tint_by_faction:
		mat.albedo_color = FACTION_COLORS[faction].darkened(tint_darken)
	body.material_override = mat
	_base_color = mat.albedo_color


func tick_flash(delta: float) -> void:
	if body == null:
		return
	if _flash > 0.0:
		_flash -= delta
		var mat: StandardMaterial3D = body.material_override
		mat.albedo_color = _base_color.lerp(Color.WHITE, 0.6) if _flash > 0.0 else _base_color
