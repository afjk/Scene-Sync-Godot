extends Node

const PRESENCE_URL_SETTING := "scene_sync/presence_url"
const DEFAULT_ROOM_SETTING := "scene_sync/default_room"
const USER_CONFIG_PATH := "user://scene_sync.cfg"
const USER_CONFIG_SECTION := "connection"
const CONNECT_STATUS_TIMEOUT_SECONDS := 10.0
const PLAYBACK_CLOCK_LOCAL := 0
const PLAYBACK_FOLLOWER_ONLY := 2
const MANAGER_SCRIPT := preload("res://addons/scene_sync/scene_sync_manager.gd")

@export var manager: Node
@export var status_panel: Node
@export var sync_root: Node3D

var _received_object_ids: Dictionary = {}
var _wants_connection := false
var _connect_in_flight := false
var _intentional_disconnect := false
var _application_paused := false
var _resume_connection_pending := false
var _reset_in_progress := false
var _connection_generation := 0


func _ready() -> void:
	if manager == null or status_panel == null or sync_root == null:
		push_error("[SceneSync] Bootstrap requires manager, status panel, and sync root nodes.")
		set_process(false)
		return

	_configure_manager(manager)
	status_panel.connect_requested.connect(_on_connect_requested)
	status_panel.disconnect_requested.connect(_on_disconnect_requested)

	var saved := _load_connection_settings()
	status_panel.set_fields(saved.room, saved.nickname)
	status_panel.set_last_error("")
	status_panel.set_received_object_count(0)
	status_panel.set_connection_state("Disconnected", false, false)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			_application_paused = true
			_resume_connection_pending = _wants_connection
			_connection_generation += 1
			if (
				manager != null
				and is_instance_valid(manager)
				and (_wants_connection or _connect_in_flight or _manager_is_connected())
			):
				_intentional_disconnect = true
				_connect_in_flight = false
				manager.call("disconnect_from_server")
				status_panel.set_connection_state("Suspended", false, false)
		NOTIFICATION_APPLICATION_RESUMED:
			_application_paused = false
			if _resume_connection_pending and _wants_connection:
				_resume_connection_pending = false
				call_deferred("_start_connection")


func _on_connect_requested(room: String, nickname: String) -> void:
	if _reset_in_progress or _connect_in_flight or _manager_is_connected():
		return

	var presence_url := String(ProjectSettings.get_setting(PRESENCE_URL_SETTING, "")).strip_edges()
	if presence_url == "":
		_reject_connection("Presence URL is empty in Project Settings.")
		return
	if not presence_url.begins_with("wss://") and not presence_url.begins_with("ws://"):
		_reject_connection("Presence URL must use ws:// or wss://.")
		return
	# An empty room intentionally omits ?room= so the server assigns its
	# source-IP-derived LAN room, matching the Web client.
	if nickname == "":
		_reject_connection("Nickname is required.")
		return

	manager.set("presence_url", presence_url)
	manager.set("room", room)
	manager.set("nickname", nickname)
	_save_connection_settings(room, nickname)
	_wants_connection = true
	_resume_connection_pending = false
	_start_connection()


func _on_disconnect_requested() -> void:
	if _reset_in_progress:
		return
	_wants_connection = false
	_resume_connection_pending = false
	_connect_in_flight = false
	_intentional_disconnect = true
	_connection_generation += 1
	_reset_manager_after_explicit_disconnect()


func _start_connection() -> void:
	if not _wants_connection or _application_paused or _reset_in_progress:
		return
	if _connect_in_flight or _manager_is_connected():
		return
	_connect_in_flight = true
	_intentional_disconnect = false
	_connection_generation += 1
	var generation := _connection_generation
	status_panel.set_last_error("")
	status_panel.set_connection_state("Connecting", false, true)
	manager.call("connect_to_server")
	_watch_initial_connection(generation)


func _on_manager_connected(id: String, room: String) -> void:
	_connect_in_flight = false
	_intentional_disconnect = false
	_connection_generation += 1
	status_panel.set_connection_state("Connected: %s" % room, true, false)
	status_panel.set_last_error("")
	status_panel.set_minimized(true)
	print("[SceneSync] Connected as %s" % id)


func _on_manager_disconnected() -> void:
	_connect_in_flight = false
	if _intentional_disconnect:
		_intentional_disconnect = false
		if _application_paused:
			status_panel.set_connection_state("Suspended", false, false)
		else:
			status_panel.set_connection_state("Disconnected", false, false)
		return

	if _wants_connection and not _application_paused:
		_connection_generation += 1
		_connect_in_flight = true
		status_panel.set_last_error("Connection lost; SDK retrying.")
		status_panel.set_connection_state("Reconnecting", false, true)
	else:
		status_panel.set_connection_state("Disconnected", false, false)


func _on_peers_updated(peers: Array) -> void:
	if _manager_is_connected():
		status_panel.set_connection_state(
			"Connected: %d peer%s" % [peers.size(), "" if peers.size() == 1 else "s"], true, false
		)


func _on_object_added(object_id: String, _node: Node3D) -> void:
	_received_object_ids[object_id] = true
	status_panel.set_received_object_count(_received_object_ids.size())


func _on_object_removed(object_id: String) -> void:
	_received_object_ids.erase(object_id)
	status_panel.set_received_object_count(_received_object_ids.size())


func _manager_is_connected() -> bool:
	return (
		manager != null
		and is_instance_valid(manager)
		and bool(manager.call("is_connected_to_server"))
	)


func _reject_connection(message: String) -> void:
	_wants_connection = false
	_connect_in_flight = false
	_connection_generation += 1
	status_panel.set_last_error(message)
	status_panel.set_connection_state("Disconnected", false, false)


func _load_connection_settings() -> Dictionary:
	return _load_connection_settings_from_path(USER_CONFIG_PATH)


func _load_connection_settings_from_path(config_path: String) -> Dictionary:
	var default_room := String(ProjectSettings.get_setting(DEFAULT_ROOM_SETTING, ""))
	var default_nickname := _make_default_nickname()
	var config := ConfigFile.new()
	if config.load(config_path) != OK:
		return {"room": default_room, "nickname": default_nickname}
	return {
		"room": String(config.get_value(USER_CONFIG_SECTION, "room", default_room)),
		"nickname": String(config.get_value(USER_CONFIG_SECTION, "nickname", default_nickname)),
	}


func _save_connection_settings(room: String, nickname: String) -> void:
	var config := ConfigFile.new()
	config.set_value(USER_CONFIG_SECTION, "room", room)
	config.set_value(USER_CONFIG_SECTION, "nickname", nickname)
	var error := config.save(USER_CONFIG_PATH)
	if error != OK:
		push_warning("[SceneSync] Could not save connection settings: %s" % error_string(error))


func _make_default_nickname() -> String:
	var model := OS.get_model_name().strip_edges()
	var lower_model := model.to_lower()
	var device_name := ""
	if "quest 3" in lower_model or "quest3" in lower_model:
		device_name = "Quest3"
	elif "quest" in lower_model:
		device_name = "Quest"
	elif "pico" in lower_model and "ultra" in lower_model:
		device_name = "PICO4Ultra"
	elif "pico" in lower_model:
		device_name = "PICO"
	elif "focus" in lower_model and "vision" in lower_model:
		device_name = "VIVEFocusVision"
	elif "vive" in lower_model or "focus" in lower_model:
		device_name = "VIVEFocus"
	elif model != "":
		device_name = "Godot-%s" % model.replace(" ", "").left(20)
	else:
		device_name = "GodotDevice"

	var unique_id := OS.get_unique_id()
	if unique_id == "":
		return device_name
	return "%s-%s" % [device_name, unique_id.sha256_text().left(6)]


func _configure_manager(target: Node) -> void:
	manager = target
	manager.set("auto_connect", false)
	manager.set("presence_url", String(ProjectSettings.get_setting(PRESENCE_URL_SETTING, "")))
	manager.set("sync_root", sync_root)
	# XR clients never acquire Shared Playback control. They follow an active
	# room controller and otherwise continue from the same time on the local
	# monotonic clock.
	manager.set("playback_clock_mode", PLAYBACK_CLOCK_LOCAL)
	manager.set("playback_follow_policy", PLAYBACK_FOLLOWER_ONLY)
	manager.set("allow_playback_control", false)
	manager.call("set_playback_follow_policy", "follower-only")
	manager.call("set_playback_control_allowed", false)
	manager.connect(&"connected", _on_manager_connected)
	manager.connect(&"disconnected", _on_manager_disconnected)
	manager.connect(&"peers_updated", _on_peers_updated)
	manager.connect(&"object_added", _on_object_added)
	manager.connect(&"object_removed", _on_object_removed)


func _disconnect_manager_signals(target: Node) -> void:
	var signal_handlers := {
		&"connected": _on_manager_connected,
		&"disconnected": _on_manager_disconnected,
		&"peers_updated": _on_peers_updated,
		&"object_added": _on_object_added,
		&"object_removed": _on_object_removed,
	}
	for signal_name in signal_handlers:
		var handler: Callable = signal_handlers[signal_name]
		if target.is_connected(signal_name, handler):
			target.disconnect(signal_name, handler)


func _reset_manager_after_explicit_disconnect() -> void:
	_reset_in_progress = true
	status_panel.set_last_error("")
	status_panel.set_resetting("Resetting")

	var old_manager := manager
	manager = null
	if old_manager != null and is_instance_valid(old_manager):
		_disconnect_manager_signals(old_manager)
		old_manager.call("disconnect_from_server")
		if old_manager.is_inside_tree():
			old_manager.queue_free()
			await old_manager.tree_exited
		else:
			old_manager.free()

	for child in sync_root.get_children():
		child.queue_free()
	await get_tree().process_frame
	_received_object_ids.clear()
	status_panel.set_received_object_count(0)

	var fresh_manager: Node = MANAGER_SCRIPT.new()
	fresh_manager.name = "SceneSyncManager"
	_configure_manager(fresh_manager)
	get_parent().add_child(fresh_manager)

	_intentional_disconnect = false
	_reset_in_progress = false
	status_panel.set_connection_state("Disconnected", false, false)


func _watch_initial_connection(generation: int) -> void:
	await get_tree().create_timer(CONNECT_STATUS_TIMEOUT_SECONDS).timeout
	if generation != _connection_generation:
		return
	if _reset_in_progress or _application_paused or not _wants_connection:
		return
	if _manager_is_connected():
		return
	status_panel.set_last_error("Still connecting; SDK will keep retrying.")
