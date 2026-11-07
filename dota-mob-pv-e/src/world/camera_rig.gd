class_name CameraRig
extends Camera3D
## Root of scenes/world/camera_rig.tscn: Mobile Legends style follow camera. It stands behind
## the hero on the own-base side, turned by yaw_deg so the lane runs diagonally from
## bottom-left (own base) to top-right (enemy). Tune the exports in the editor.

@export var yaw_deg := -45.0
@export var height := 19.0
@export var back := 12.0
@export var follow_speed := 8.0


func _ready() -> void:
	rotation = Vector3(-atan2(height, back), yaw_rad(), 0.0)


func yaw_rad() -> float:
	return deg_to_rad(yaw_deg)


## Camera forward on the ground is (-sin yaw, -cos yaw); the camera stands behind the target.
func offset() -> Vector3:
	var y := yaw_rad()
	return Vector3(sin(y) * back, height, cos(y) * back)


func snap_to(target: Vector3) -> void:
	global_position = target + offset()


func follow(target: Vector3, delta: float) -> void:
	global_position = global_position.lerp(target + offset(), minf(1.0, delta * follow_speed))
