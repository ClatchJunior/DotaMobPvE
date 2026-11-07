extends Node3D
## Root of scenes/main.tscn. The scene holds the environment, %Map (map.tscn), %Match,
## %CameraRig (camera_rig.tscn) and %Hud (hud.tscn); this script only wires them together.
## Dev options after `--` on the command line:
##   --capture=<png path> --capture-time=<match seconds> --demo-x=<x>  take a screenshot and quit
##   --capture-pause  open the pause menu before the screenshot
##   --capture-shop   buy a few items and open the shop window before the screenshot
##   --timescale=<n>  speed up the simulation
##   --input-test     run tests/input_probe.gd on this scene

var match_node: Match = null
var camera: CameraRig = null
var hud: Hud = null
var _capture_path := ""
var _capture_at := 30.0
var _demo_x := INF
var _capturing := false


func _ready() -> void:
	_parse_args()
	match_node = %Match
	camera = %CameraRig
	hud = %Hud
	if not GameData.errors.is_empty():
		hud.show_fatal(tr("error.data"))
		match_node = null
		return
	match_node.yaw = camera.yaw_rad()
	match_node.start(GameData, Settings, %Map)
	camera.snap_to(match_node.hero.global_position)
	hud.bind(match_node, camera)
	if _demo_x != INF:
		match_node.hero.global_position = Vector3(_demo_x, 0.0, 2.0)
		match_node.hero.attack_held = true


func _process(delta: float) -> void:
	if match_node == null:
		return
	camera.follow(match_node.hero.global_position, delta)
	if _capture_path != "" and not _capturing and match_node.time >= _capture_at:
		_capturing = true
		_capture()


func _capture() -> void:
	if "--capture-pause" in OS.get_cmdline_user_args():
		hud._toggle_pause()
		for i in 3:
			await get_tree().process_frame
	if "--capture-shop" in OS.get_cmdline_user_args():
		_demo_shop()
		for i in 3:
			await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_capture_path)
	print("captured ", _capture_path, " at match time ", match_node.time)
	get_tree().quit()


## Screenshot setup: a few items bought at the base and the shop window open on Bastion.
func _demo_shop() -> void:
	var m := match_node
	m.hero.position = m.fountain_position(Unit.Faction.PLAYER)
	m.hero.last_combat_at = -1000.0
	m.unreliable_gold = 3200
	for id in ["blade", "hilt", "onslaught_blade", "plate", "potion_hp", "potion_hp", "march_boots"]:
		m.buy(id)
	hud.shop_panel.selected_item = "bastion"
	hud.shop_panel.selected_slot = 1
	hud.toggle_shop()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="):
			_capture_path = arg.get_slice("=", 1)
		elif arg.begins_with("--capture-time="):
			_capture_at = float(arg.get_slice("=", 1))
		elif arg.begins_with("--demo-x="):
			_demo_x = float(arg.get_slice("=", 1))
		elif arg.begins_with("--timescale="):
			Engine.time_scale = float(arg.get_slice("=", 1))
		elif arg == "--input-test":
			var probe: Node = load("res://tests/input_probe.gd").new()
			probe.set("main", self)
			add_child.call_deferred(probe)
