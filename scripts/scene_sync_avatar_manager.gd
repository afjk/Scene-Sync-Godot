class_name SceneSyncAvatarManager
extends Node

const AVATAR_KIND := "scene-avatar"
const SEND_INTERVAL_SECONDS := 0.1
const HEARTBEAT_INTERVAL_SECONDS := 1.0
const AVATAR_TIMEOUT_MSEC := 3000
const POSITION_EPSILON_SQUARED := 0.0005 * 0.0005
const ROTATION_EPSILON_RADIANS := deg_to_rad(0.5)
const HEAD_RADIUS := 0.12
const HAND_RADIUS := 0.05
const EYE_RADIUS := 0.018
const LABEL_OFFSET := 0.22
const PALETTE: Array[Color] = [
	Color("ff6b6b"),
	Color("feca57"),
	Color("48dbfb"),
	Color("1dd1a1"),
	Color("5f27cd"),
	Color("ff9ff3"),
	Color("54a0ff"),
	Color("ee5253"),
]

@export var scene_sync_manager: SceneSyncAvatarTransport
@export var avatar_root: Node3D
@export var xr_camera: XRCamera3D
@export var left_controller: XRController3D
@export var right_controller: XRController3D

var _remote_avatars: Dictionary = {}
var _head_mesh: SphereMesh
var _hand_mesh: SphereMesh
var _eye_mesh: SphereMesh
var _eye_material: StandardMaterial3D
var _send_accumulator := 0.0
var _last_sent_monotonic := -INF
var _last_head_position := Vector3.ZERO
var _last_head_rotation := Quaternion.IDENTITY
var _has_last_head_pose := false


func _ready() -> void:
	_ensure_shared_resources()
	set_scene_sync_manager(scene_sync_manager)
	set_process(true)


func _exit_tree() -> void:
	_disconnect_manager(scene_sync_manager)
	clear_remote_avatars()


func _process(delta: float) -> void:
	_update_remote_avatars(delta)
	_remove_timed_out_avatars()
	_send_local_avatar(delta)


func set_scene_sync_manager(value: Node) -> void:
	var next_manager := value as SceneSyncAvatarTransport
	if next_manager == scene_sync_manager and _manager_signals_connected(next_manager):
		return

	_disconnect_manager(scene_sync_manager)
	scene_sync_manager = next_manager
	clear_remote_avatars()
	_reset_local_send_state()
	if scene_sync_manager == null:
		return

	if not scene_sync_manager.avatar_received.is_connected(_on_avatar_received):
		scene_sync_manager.avatar_received.connect(_on_avatar_received)
	if not scene_sync_manager.peers_updated.is_connected(_on_peers_updated):
		scene_sync_manager.peers_updated.connect(_on_peers_updated)
	if not scene_sync_manager.connected.is_connected(_on_connected):
		scene_sync_manager.connected.connect(_on_connected)
	if not scene_sync_manager.disconnected.is_connected(_on_disconnected):
		scene_sync_manager.disconnected.connect(_on_disconnected)


func handle_avatar_message(payload: Dictionary, from_info: Dictionary = {}) -> void:
	if String(payload.get("kind", payload.get("type", ""))) != AVATAR_KIND:
		return

	var peer_id := String(from_info.get("id", "")).strip_edges()
	if peer_id == "":
		peer_id = String(payload.get("peerId", "")).strip_edges()
	if peer_id == "" or peer_id == _local_peer_id():
		return

	var head_pose := _parse_pose(payload.get("head", null))
	if head_pose.is_empty():
		return

	var state: Dictionary = _remote_avatars.get(peer_id, {})
	if state.is_empty():
		state = _create_remote_avatar(peer_id, String(payload.get("nickname", "")))
		if state.is_empty():
			return
		_remote_avatars[peer_id] = state

	state["last_seen_msec"] = Time.get_ticks_msec()
	state["head_position"] = head_pose["position"]
	state["head_rotation"] = head_pose["rotation"]
	_update_avatar_label(state, String(payload.get("nickname", "")))

	var desktop_mode := String(payload.get("mode", "vr")).to_lower() == "desktop"
	_set_hand_target(state, "left", null if desktop_mode else payload.get("left", null))
	_set_hand_target(state, "right", null if desktop_mode else payload.get("right", null))

	if not bool(state.get("initialized", false)):
		_apply_targets_immediately(state)
		state["initialized"] = true


func reconcile_peers(peers: Array) -> void:
	var live_peer_ids := {}
	for peer_value in peers:
		if not (peer_value is Dictionary):
			continue
		var peer_id := String((peer_value as Dictionary).get("id", "")).strip_edges()
		if peer_id != "" and peer_id != _local_peer_id():
			live_peer_ids[peer_id] = true

	for peer_id_value in _remote_avatars.keys():
		var peer_id := String(peer_id_value)
		if not live_peer_ids.has(peer_id):
			_remove_remote_avatar(peer_id)


func clear_remote_avatars() -> void:
	for peer_id_value in _remote_avatars.keys():
		_remove_remote_avatar(String(peer_id_value))
	_remote_avatars.clear()


func get_remote_avatar_count() -> int:
	return _remote_avatars.size()


func get_remote_avatar_node(peer_id: String) -> Node3D:
	var state_value = _remote_avatars.get(peer_id, null)
	if not (state_value is Dictionary):
		return null
	return (state_value as Dictionary).get("root", null) as Node3D


func build_local_avatar_payload() -> Dictionary:
	if xr_camera == null or not is_instance_valid(xr_camera) or not xr_camera.is_inside_tree():
		return {}

	var head_transform := xr_camera.global_transform
	var payload := {
		"kind": AVATAR_KIND,
		"nickname": _local_nickname(),
		"t": int(Time.get_unix_time_from_system() * 1000.0),
		"mode": "mr" if get_viewport().use_xr else "desktop",
		"head": _transform_to_wire_pose(head_transform),
	}
	if get_viewport().use_xr:
		payload["left"] = _controller_to_wire_pose(left_controller)
		payload["right"] = _controller_to_wire_pose(right_controller)
	return payload


func _send_local_avatar(delta: float) -> void:
	if scene_sync_manager == null or not scene_sync_manager.is_connected_to_server():
		_send_accumulator = 0.0
		return

	_send_accumulator += delta
	if _send_accumulator < SEND_INTERVAL_SECONDS:
		return
	_send_accumulator = fmod(_send_accumulator, SEND_INTERVAL_SECONDS)

	var payload := build_local_avatar_payload()
	if payload.is_empty():
		return
	var head_pose: Dictionary = payload["head"]
	var head_position := _wire_position(head_pose["p"])
	var head_rotation := _wire_rotation(head_pose["q"])
	var now := float(Time.get_ticks_usec()) / 1000000.0
	var pose_changed := (
		not _has_last_head_pose
		or _last_head_position.distance_squared_to(head_position) > POSITION_EPSILON_SQUARED
		or _last_head_rotation.angle_to(head_rotation) > ROTATION_EPSILON_RADIANS
	)
	if not pose_changed and now - _last_sent_monotonic < HEARTBEAT_INTERVAL_SECONDS:
		return

	if scene_sync_manager.broadcast_avatar(payload):
		_last_sent_monotonic = now
		_last_head_position = head_position
		_last_head_rotation = head_rotation
		_has_last_head_pose = true


func _on_avatar_received(payload: Dictionary, from_info: Dictionary) -> void:
	handle_avatar_message(payload, from_info)


func _on_peers_updated(peers: Array) -> void:
	reconcile_peers(peers)


func _on_connected(_peer_id: String, _room: String) -> void:
	_reset_local_send_state()


func _on_disconnected() -> void:
	clear_remote_avatars()
	_reset_local_send_state()


func _disconnect_manager(target: SceneSyncAvatarTransport) -> void:
	if target == null or not is_instance_valid(target):
		return
	if target.avatar_received.is_connected(_on_avatar_received):
		target.avatar_received.disconnect(_on_avatar_received)
	if target.peers_updated.is_connected(_on_peers_updated):
		target.peers_updated.disconnect(_on_peers_updated)
	if target.connected.is_connected(_on_connected):
		target.connected.disconnect(_on_connected)
	if target.disconnected.is_connected(_on_disconnected):
		target.disconnected.disconnect(_on_disconnected)


func _manager_signals_connected(target: SceneSyncAvatarTransport) -> bool:
	return (
		target != null
		and is_instance_valid(target)
		and target.avatar_received.is_connected(_on_avatar_received)
		and target.peers_updated.is_connected(_on_peers_updated)
		and target.connected.is_connected(_on_connected)
		and target.disconnected.is_connected(_on_disconnected)
	)


func _create_remote_avatar(peer_id: String, nickname: String) -> Dictionary:
	_ensure_shared_resources()
	var root_node := Node3D.new()
	root_node.name = "RemoteAvatar_%s" % peer_id.sha256_text().left(8)
	root_node.set_meta("scene_sync_peer_id", peer_id)
	var color := _color_for_peer(peer_id)
	var avatar_material := _make_unshaded_material(color)

	var head := Node3D.new()
	head.name = "Head"
	root_node.add_child(head)
	head.add_child(_make_mesh_instance(_head_mesh, avatar_material, "Face"))

	var left_eye := _make_mesh_instance(_eye_mesh, _eye_material, "LeftEye")
	left_eye.position = Vector3(-0.035, 0.02, -0.105)
	head.add_child(left_eye)
	var right_eye := _make_mesh_instance(_eye_mesh, _eye_material, "RightEye")
	right_eye.position = Vector3(0.035, 0.02, -0.105)
	head.add_child(right_eye)

	var label := Label3D.new()
	label.name = "Nickname"
	label.position = Vector3(0.0, LABEL_OFFSET, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = false
	label.no_depth_test = true
	label.font_size = 32
	label.outline_size = 8
	label.pixel_size = 0.002
	label.modulate = Color.WHITE
	label.outline_modulate = Color(0.02, 0.025, 0.04, 0.95)
	head.add_child(label)

	var left_hand := Node3D.new()
	left_hand.name = "LeftHand"
	left_hand.visible = false
	left_hand.add_child(_make_mesh_instance(_hand_mesh, avatar_material, "Mesh"))
	root_node.add_child(left_hand)
	var right_hand := Node3D.new()
	right_hand.name = "RightHand"
	right_hand.visible = false
	right_hand.add_child(_make_mesh_instance(_hand_mesh, avatar_material, "Mesh"))
	root_node.add_child(right_hand)

	var parent := avatar_root if avatar_root != null else get_parent() as Node3D
	if parent == null:
		push_error("[SceneSync] Remote avatar root is missing.")
		root_node.free()
		return {}
	parent.add_child(root_node)

	var state := {
		"root": root_node,
		"head": head,
		"left": left_hand,
		"right": right_hand,
		"label": label,
		"head_position": Vector3.ZERO,
		"head_rotation": Quaternion.IDENTITY,
		"left_position": Vector3.ZERO,
		"left_rotation": Quaternion.IDENTITY,
		"left_active": false,
		"right_position": Vector3.ZERO,
		"right_rotation": Quaternion.IDENTITY,
		"right_active": false,
		"last_seen_msec": Time.get_ticks_msec(),
		"initialized": false,
	}
	_update_avatar_label(state, nickname)
	return state


func _update_remote_avatars(delta: float) -> void:
	var alpha := clampf(1.0 - pow(0.75, maxf(delta, 0.0) * 60.0), 0.0, 1.0)
	for state_value in _remote_avatars.values():
		if not (state_value is Dictionary):
			continue
		var state := state_value as Dictionary
		_interpolate_node(
			state.get("head") as Node3D, state["head_position"], state["head_rotation"], alpha
		)
		_update_hand_node(state, "left", alpha)
		_update_hand_node(state, "right", alpha)


func _update_hand_node(state: Dictionary, hand: String, alpha: float) -> void:
	var node := state.get(hand) as Node3D
	if node == null or not is_instance_valid(node):
		return
	node.visible = bool(state.get("%s_active" % hand, false))
	if node.visible:
		_interpolate_node(node, state["%s_position" % hand], state["%s_rotation" % hand], alpha)


func _interpolate_node(
	node: Node3D, target_position: Vector3, target_rotation: Quaternion, alpha: float
) -> void:
	if node == null or not is_instance_valid(node):
		return
	node.position = node.position.lerp(target_position, alpha)
	node.quaternion = node.quaternion.slerp(target_rotation, alpha).normalized()


func _remove_timed_out_avatars() -> void:
	var now := Time.get_ticks_msec()
	for peer_id_value in _remote_avatars.keys():
		var peer_id := String(peer_id_value)
		var state := _remote_avatars[peer_id] as Dictionary
		if now - int(state.get("last_seen_msec", now)) > AVATAR_TIMEOUT_MSEC:
			_remove_remote_avatar(peer_id)


func _remove_remote_avatar(peer_id: String) -> void:
	var state_value = _remote_avatars.get(peer_id, null)
	if state_value is Dictionary:
		var root_node := (state_value as Dictionary).get("root") as Node3D
		if root_node != null and is_instance_valid(root_node):
			root_node.queue_free()
	_remote_avatars.erase(peer_id)


func _set_hand_target(state: Dictionary, hand: String, value: Variant) -> void:
	var pose := _parse_pose(value)
	var active := value is Dictionary and bool((value as Dictionary).get("active", false))
	active = active and not pose.is_empty()
	state["%s_active" % hand] = active
	if active:
		state["%s_position" % hand] = pose["position"]
		state["%s_rotation" % hand] = pose["rotation"]


func _apply_targets_immediately(state: Dictionary) -> void:
	var head := state.get("head") as Node3D
	if head != null:
		head.position = state["head_position"]
		head.quaternion = state["head_rotation"]
	for hand in ["left", "right"]:
		var hand_node := state.get(hand) as Node3D
		if hand_node == null:
			continue
		hand_node.visible = bool(state.get("%s_active" % hand, false))
		if hand_node.visible:
			hand_node.position = state["%s_position" % hand]
			hand_node.quaternion = state["%s_rotation" % hand]


func _update_avatar_label(state: Dictionary, nickname: String) -> void:
	var label := state.get("label") as Label3D
	if label == null:
		return
	var display_name := nickname.strip_edges().left(48)
	label.text = display_name if display_name != "" else "Guest"


func _parse_pose(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var pose := value as Dictionary
	var position_value = pose.get("p", null)
	var rotation_value = pose.get("q", null)
	if not _valid_number_array(position_value, 3) or not _valid_number_array(rotation_value, 4):
		return {}
	var rotation := _wire_rotation(rotation_value)
	if rotation.length_squared() < 0.000001:
		return {}
	return {
		"position": _wire_position(position_value),
		"rotation": rotation.normalized(),
	}


func _valid_number_array(value: Variant, expected_size: int) -> bool:
	if not (value is Array) or (value as Array).size() != expected_size:
		return false
	for component in value:
		if not (component is int or component is float) or not is_finite(float(component)):
			return false
	return true


func _wire_position(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _wire_rotation(value: Array) -> Quaternion:
	return Quaternion(float(value[0]), float(value[1]), float(value[2]), float(value[3]))


func _transform_to_wire_pose(value: Transform3D) -> Dictionary:
	var rotation := value.basis.orthonormalized().get_rotation_quaternion().normalized()
	return {
		"p": [value.origin.x, value.origin.y, value.origin.z],
		"q": [rotation.x, rotation.y, rotation.z, rotation.w],
	}


func _controller_to_wire_pose(controller: XRController3D) -> Dictionary:
	if controller == null or not is_instance_valid(controller):
		return {"active": false}
	# Visibility is controlled by the local controller/hand model. Tracking can
	# remain active while that model is hidden, especially for optical hands.
	var active := controller.get_is_active()
	if not active:
		return {"active": false}
	var pose := _transform_to_wire_pose(controller.global_transform)
	pose["active"] = true
	return pose


func _ensure_shared_resources() -> void:
	if _head_mesh != null:
		return
	_head_mesh = _make_sphere_mesh(HEAD_RADIUS, 16, 8)
	_hand_mesh = _make_sphere_mesh(HAND_RADIUS, 12, 6)
	_eye_mesh = _make_sphere_mesh(EYE_RADIUS, 10, 5)
	_eye_material = _make_unshaded_material(Color(0.025, 0.03, 0.045, 1.0))


func _make_sphere_mesh(radius: float, radial_segments: int, rings: int) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = radial_segments
	mesh.rings = rings
	return mesh


func _make_unshaded_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _make_mesh_instance(mesh: Mesh, material: Material, node_name: String) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _color_for_peer(peer_id: String) -> Color:
	var palette_index := 0
	for index in peer_id.length():
		palette_index = (palette_index * 31 + peer_id.unicode_at(index)) % PALETTE.size()
	return PALETTE[palette_index]


func _local_peer_id() -> String:
	return scene_sync_manager.get_local_peer_id() if scene_sync_manager != null else ""


func _local_nickname() -> String:
	return String(scene_sync_manager.nickname) if scene_sync_manager != null else ""


func _reset_local_send_state() -> void:
	_send_accumulator = 0.0
	_last_sent_monotonic = -INF
	_has_last_head_pose = false
