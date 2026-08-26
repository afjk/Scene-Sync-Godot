extends SceneTree

const MANAGER_SCRIPT := preload("res://addons/scene_sync/scene_sync_manager.gd")

var _failures: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var manager: SceneSyncManager = MANAGER_SCRIPT.new()
	manager.auto_connect = false
	root.add_child(manager)
	await process_frame
	manager._client.id = "local-peer"

	var request_id := "slow-transfer"
	manager._pending_recoveries[request_id] = {
		"requestId": request_id,
		"objectId": "lion",
		"assetId": "sha256-test",
		"meshPath": "lion.glb.gz",
		"expectedSize": 30 * 1024 * 1024,
		"requestedAt": Time.get_ticks_msec() / 1000.0,
		"requestedPeerIds": {},
	}
	manager._retry_recovery_peers(request_id, [{"id": "web-peer"}])
	await create_timer(MANAGER_SCRIPT.PEER_RETRY_INTERVAL_SECONDS + 0.25).timeout
	_assert_true(
		manager._pending_recoveries.has(request_id),
		"recovery remains active after all peers have been requested",
	)

	manager._pending_recoveries.erase(request_id)
	manager.queue_free()
	await process_frame
	if _failures.is_empty():
		print("Scene Sync asset recovery smoke: PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _assert_true(value: bool, label: String) -> void:
	if not value:
		_failures.append(label)
