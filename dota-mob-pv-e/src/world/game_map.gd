class_name GameMap
extends Node3D
## Root of scenes/world/map.tscn. Level geometry and trees are nodes of the scene; gameplay
## positions are Marker3D nodes under Markers/: PlayerT1..T3, PlayerCore, PlayerSpawn,
## PlayerFountain and the same with Enemy. Edit them in the Godot editor.

## Half length of the playable area along the lane (x) and the lane / forest widths (z).
@export var half_length := 78.0
@export var lane_half_width := 5.0
@export var forest_depth := 20.0

const SIDES := ["Player", "Enemy"]
const MARKERS := ["T1", "T2", "T3", "Core", "Spawn", "Fountain"]


func half_depth() -> float:
	return lane_half_width + forest_depth


## Position of a gameplay marker, e.g. marker(Unit.Faction.ENEMY, "T2").
func marker(faction: int, name: String) -> Vector3:
	var node := get_node_or_null("Markers/%s%s" % [SIDES[faction], name]) as Node3D
	if node == null:
		push_error("map.tscn: missing marker Markers/%s%s" % [SIDES[faction], name])
		return Vector3.ZERO
	return node.position


## Names of required markers that are missing (empty when the scene is complete).
func missing_markers() -> PackedStringArray:
	var out := PackedStringArray()
	for side in SIDES:
		for m in MARKERS:
			if get_node_or_null("Markers/%s%s" % [side, m]) == null:
				out.append("%s%s" % [side, m])
	return out
