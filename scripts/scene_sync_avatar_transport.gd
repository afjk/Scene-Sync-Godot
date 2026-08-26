@tool
class_name SceneSyncAvatarTransport
extends SceneSyncManager

## Emitted for the Web-compatible transient avatar payload. Avatar state is
## intentionally kept outside SceneSyncRoot because it is presence, not scene data.
signal avatar_received(payload: Dictionary, from_info: Dictionary)


func get_local_peer_id() -> String:
	return _client.id if _client != null else ""


func broadcast_avatar(payload: Dictionary) -> bool:
	if not is_connected_to_server() or _client == null:
		return false
	if String(payload.get("kind", "")) != "scene-avatar":
		return false

	var outbound := payload.duplicate(true)
	outbound["peerId"] = _client.id
	_client.broadcast(outbound)
	return true


func _dispatch_scene_payload(payload: Dictionary, from_info: Dictionary) -> void:
	super._dispatch_scene_payload(payload, from_info)
	if String(payload.get("kind", payload.get("type", ""))) != "scene-avatar":
		return
	if String(from_info.get("id", "")) == get_local_peer_id():
		return
	avatar_received.emit(payload.duplicate(true), from_info.duplicate(true))
