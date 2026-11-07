class_name Projectile
extends Node3D
## Homing shot of towers and ranged creeps. Retargeting the shooter never cancels a shot in flight.

var source: Unit = null
var target: Unit = null
var damage := 0.0
var speed := 15.0


func launch(p_source: Unit, p_target: Unit, p_damage: float, p_speed: float, color: Color) -> void:
	source = p_source
	target = p_target
	damage = p_damage
	speed = p_speed
	# projectile.tscn: %Mesh sphere; the shooter's faction color goes on a material copy.
	var mesh := get_node_or_null("%Mesh") as MeshInstance3D
	if mesh != null:
		var mat := (mesh.material_override as StandardMaterial3D)
		mat = mat.duplicate() if mat != null else StandardMaterial3D.new()
		mat.albedo_color = color
		mat.emission_enabled = true
		mat.emission = color
		mesh.material_override = mat


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target) or not target.alive:
		queue_free()
		return
	var aim := target.global_position + Vector3(0, 1.0, 0)
	var d := aim - global_position
	var step := speed * delta
	if d.length() <= step:
		var src: Unit = source if source != null and is_instance_valid(source) else null
		target.take_damage(damage, src)
		queue_free()
		return
	global_position += d.normalized() * step
