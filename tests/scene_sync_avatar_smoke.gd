extends SceneTree

const AVATAR_MANAGER_SCRIPT := preload("res://scripts/scene_sync_avatar_manager.gd")
const AVATAR_TRANSPORT_SCRIPT := preload("res://scripts/scene_sync_avatar_transport.gd")

var _failures: Array[String] = []
var _transport_message_count := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_assert_equal(AVATAR_MANAGER_SCRIPT.VR_MODE, "vr", "Web-compatible XR mode")

	var world := Node3D.new()
	root.add_child(world)
	var remote_root := Node3D.new()
	world.add_child(remote_root)

	var transport: SceneSyncAvatarTransport = AVATAR_TRANSPORT_SCRIPT.new()
	_assert_true(transport.get_script().is_tool(), "avatar transport retains editor execution")
	transport.auto_connect = false
	world.add_child(transport)
	transport._client.id = "local-peer"
	transport.avatar_received.connect(_on_transport_avatar_received)

	var camera := XRCamera3D.new()
	camera.position = Vector3(1.0, 1.6, 2.0)
	world.add_child(camera)

	var avatar_manager: SceneSyncAvatarManager = AVATAR_MANAGER_SCRIPT.new()
	avatar_manager.avatar_root = remote_root
	avatar_manager.xr_camera = camera
	world.add_child(avatar_manager)
	avatar_manager.set_scene_sync_manager(transport)

	var local_payload := avatar_manager.build_local_avatar_payload()
	_assert_equal(local_payload.get("kind"), "scene-avatar", "local payload kind")
	_assert_equal(local_payload.get("mode"), "desktop", "headless payload mode")
	_assert_vector(local_payload["head"]["p"], camera.global_position, "local head position")
	var second_remote_root := Node3D.new()
	world.add_child(second_remote_root)
	var second_avatar_manager: SceneSyncAvatarManager = AVATAR_MANAGER_SCRIPT.new()
	second_avatar_manager.avatar_root = second_remote_root
	world.add_child(second_avatar_manager)
	second_avatar_manager.handle_avatar_message(local_payload, {"id": "local-peer"})
	_assert_equal(
		second_avatar_manager.get_remote_avatar_count(),
		1,
		"Godot avatar payload is consumable by another client",
	)

	var remote_payload := {
		"kind": "scene-avatar",
		"peerId": "spoofed-peer",
		"nickname": "Web Player",
		"mode": "vr",
		"head": {"p": [2.0, 1.7, -1.0], "q": [0.0, 0.0, 0.0, 1.0]},
		"left": {"p": [1.8, 1.3, -1.0], "q": [0.0, 0.0, 0.0, 1.0], "active": true},
		"right": {"p": [2.2, 1.3, -1.0], "q": [0.0, 0.0, 0.0, 1.0], "active": true},
	}
	transport._dispatch_scene_payload(
		remote_payload, {"id": "remote-peer", "nickname": "Web Player"}
	)
	_assert_equal(_transport_message_count, 1, "transport forwards scene-avatar")
	_assert_equal(avatar_manager.get_remote_avatar_count(), 1, "remote avatar created")
	_assert_true(
		avatar_manager.get_remote_avatar_node("spoofed-peer") == null,
		"sender identity overrides payload peerId",
	)

	var avatar := avatar_manager.get_remote_avatar_node("remote-peer")
	_assert_true(avatar != null, "avatar indexed by sender peer")
	if avatar != null:
		var head := avatar.get_node("Head") as Node3D
		_assert_true(
			head.position.is_equal_approx(Vector3(2.0, 1.7, -1.0)), "first pose applies immediately"
		)
		_assert_equal((head.get_node("Nickname") as Label3D).text, "Web Player", "nickname label")
		_assert_true((avatar.get_node("LeftHand") as Node3D).visible, "active VR hand is visible")

	var moved_payload := remote_payload.duplicate(true)
	moved_payload["mode"] = "desktop"
	moved_payload["head"]["p"] = [3.0, 1.7, -1.0]
	avatar_manager.handle_avatar_message(moved_payload, {"id": "remote-peer"})
	avatar_manager._process(1.0 / 60.0)
	if avatar != null:
		var moved_head := avatar.get_node("Head") as Node3D
		_assert_true(
			moved_head.position.x > 2.0 and moved_head.position.x < 3.0, "pose is interpolated"
		)
		_assert_true(
			not (avatar.get_node("LeftHand") as Node3D).visible, "desktop mode hides hands"
		)

	avatar_manager.handle_avatar_message(
		{"kind": "scene-avatar", "peerId": "invalid", "head": {"p": [0.0], "q": []}}
	)
	_assert_equal(avatar_manager.get_remote_avatar_count(), 1, "invalid pose is ignored")

	avatar_manager.reconcile_peers([{"id": "local-peer"}])
	_assert_equal(avatar_manager.get_remote_avatar_count(), 0, "departed peer is removed")

	avatar_manager.handle_avatar_message(remote_payload, {"id": "remote-peer"})
	avatar_manager._remote_avatars["remote-peer"]["last_seen_msec"] = (
		Time.get_ticks_msec() - AVATAR_MANAGER_SCRIPT.AVATAR_TIMEOUT_MSEC - 1
	)
	avatar_manager._remove_timed_out_avatars()
	_assert_equal(avatar_manager.get_remote_avatar_count(), 0, "stale avatar times out")

	world.queue_free()
	await process_frame
	if _failures.is_empty():
		print("Scene Sync avatar smoke: PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _on_transport_avatar_received(_payload: Dictionary, _from_info: Dictionary) -> void:
	_transport_message_count += 1


func _assert_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		_failures.append("%s: expected %s, got %s" % [label, expected, actual])


func _assert_true(value: bool, label: String) -> void:
	if not value:
		_failures.append(label)


func _assert_vector(value: Variant, expected: Vector3, label: String) -> void:
	if not (value is Array) or (value as Array).size() != 3:
		_failures.append("%s: invalid vector payload" % label)
		return
	var actual := Vector3(float(value[0]), float(value[1]), float(value[2]))
	if not actual.is_equal_approx(expected):
		_failures.append("%s: expected %s, got %s" % [label, expected, actual])
