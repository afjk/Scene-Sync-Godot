extends Node

const ASSET_META := "scene_sync_asset"
const OBJECT_ID_META := "scene_sync_object_id"
const APPLIED_META := "scene_sync_adapter_applied_type"
const MAX_GLB_BYTES := 50 * 1024 * 1024
const MAX_IMAGE_BYTES := 20 * 1024 * 1024
const MAX_TEXT_BYTES := 1024 * 1024
const TEXT_PIXEL_SIZE := 1.0 / 512.0
const GLTF_HELPER := preload("res://addons/scene_sync/gltf_helper.gd")
const BLOB_CLIENT := preload("res://addons/scene_sync/blob_client.gd")

var _manager: Node = null
var _sync_root: Node3D = null
var _generation := 0
var _records: Dictionary = {}
var _revisions: Dictionary = {}
var _retry_states: Dictionary = {}
var _warned: Dictionary = {}
var _active_requests: Array[HTTPRequest] = []
var _reconcile_elapsed := 0.0


func bind_manager(next_manager: Node) -> void:
	_generation += 1
	if _manager != null and is_instance_valid(_manager):
		if _manager.is_connected(&"object_added", _on_object_added):
			_manager.disconnect(&"object_added", _on_object_added)
		if _manager.is_connected(&"object_removed", _on_object_removed):
			_manager.disconnect(&"object_removed", _on_object_removed)
	for request in _active_requests:
		if is_instance_valid(request):
			request.cancel_request()
			request.queue_free()
	_active_requests.clear()
	_records.clear()
	_revisions.clear()
	_retry_states.clear()
	_warned.clear()
	_manager = next_manager
	_sync_root = _manager.get("sync_root") as Node3D if _manager != null and is_instance_valid(_manager) else null
	if _manager != null and is_instance_valid(_manager):
		_manager.connect(&"object_added", _on_object_added)
		_manager.connect(&"object_removed", _on_object_removed)
	set_process(true)


func _process(delta: float) -> void:
	_reconcile_elapsed += delta
	if _reconcile_elapsed < 0.5:
		return
	_reconcile_elapsed = 0.0
	if _sync_root == null or not is_instance_valid(_sync_root):
		return
	for child in _sync_root.get_children():
		if child is Node3D:
			var object_id := _safe_string(child.get_meta(OBJECT_ID_META, ""))
			if object_id != "":
				_consider_object(object_id, child as Node3D)


func _on_object_added(object_id: String, node: Node3D) -> void:
	_consider_object(object_id, node)


func _on_object_removed(object_id: String) -> void:
	_revisions[object_id] = int(_revisions.get(object_id, 0)) + 1
	_records.erase(object_id)
	_retry_states.erase(object_id)
	_warned.erase(object_id)


func _consider_object(object_id: String, node: Node3D) -> void:
	if node == null or not is_instance_valid(node) or not node.has_meta(ASSET_META):
		return
	var value = node.get_meta(ASSET_META)
	if not (value is Dictionary):
		_warn_once(object_id, "invalid asset metadata")
		return
	var asset := value as Dictionary
	var signature := JSON.stringify(asset).sha256_text()
	var node_id := node.get_instance_id()
	var previous_value = _records.get(object_id, {})
	var previous: Dictionary = previous_value if previous_value is Dictionary else {}
	var retry_value = _retry_states.get(object_id, {})
	var retry_state: Dictionary = retry_value if retry_value is Dictionary else {}
	if (
		int(retry_state.get("nodeId", 0)) != node_id
		or String(retry_state.get("signature", "")) != signature
	):
		_retry_states.erase(object_id)
	if int(previous.get("nodeId", 0)) == node_id and String(previous.get("signature", "")) == signature:
		return
	var revision := int(_revisions.get(object_id, 0)) + 1
	_revisions[object_id] = revision
	_records[object_id] = {"nodeId": node_id, "signature": signature, "revision": revision}
	var ticket := {"generation": _generation, "nodeId": node_id, "signature": signature, "revision": revision}
	call_deferred("_adapt_object", ticket, object_id, node, asset.duplicate(true))


func _adapt_object(ticket: Dictionary, object_id: String, node: Node3D, asset: Dictionary) -> void:
	if not _is_current(ticket, object_id, node):
		return
	var asset_type := _safe_string(asset.get("type", "")).to_lower()
	var source := _safe_string(asset.get("source", "")).to_lower()

	match asset_type:
		"mesh":
			if source == "url" or asset.has("url"):
				await _adapt_url_mesh(ticket, object_id, node, asset)
			else:
				_restore_fallback_if_adapter_owned(node)
		"image":
			if source == "url" or asset.has("url"):
				await _adapt_url_image(ticket, object_id, node, asset)
			else:
				_restore_fallback_if_adapter_owned(node)
		"text":
			if source == "url" or asset.has("url"):
				await _adapt_url_text(ticket, object_id, node, asset)
			else:
				_apply_inline_text(ticket, object_id, node, asset, _safe_string(asset.get("text", "")))
		"video":
			_restore_fallback_if_adapter_owned(node)
			_warn_once(object_id, "unsupported asset type video")
		"primitive":
			_restore_primitive_if_adapter_owned(node, asset)
		_:
			_restore_fallback_if_adapter_owned(node)
			_warn_once(object_id, "unsupported asset type %s" % (asset_type if asset_type != "" else "unknown"))


func _adapt_url_mesh(ticket: Dictionary, object_id: String, node: Node3D, asset: Dictionary) -> void:
	var response := await _fetch_bytes(int(ticket["generation"]), _safe_string(asset.get("url", "")), MAX_GLB_BYTES)
	if not bool(response.get("ok", false)):
		await _handle_fetch_failure(ticket, object_id, node, "mesh", response)
		return
	_retry_states.erase(object_id)
	var data: PackedByteArray = response["data"]
	if data.size() < 12 or data.decode_u32(0) != 0x46546c67 or data.decode_u32(8) != data.size():
		_warn_once(object_id, "invalid GLB container")
		return
	var asset_id := _safe_string(asset.get("assetId", ""))
	if asset_id.begins_with("sha256-") and BLOB_CLIENT.compute_asset_id(data) != asset_id:
		_warn_once(object_id, "mesh assetId mismatch")
		return
	var visual: Node3D = GLTF_HELPER.import_glb(data)
	if visual == null:
		_warn_once(object_id, "GLB parse failed")
		return
	if not _is_current(ticket, object_id, node):
		visual.free()
		return
	visual.name = "RemoteAssetVisual"
	visual.set_meta("scene_sync_adapter_owned", true)
	if _safe_string(asset.get("visualBasis", "")) == "unity":
		visual.rotation.y = PI
	_clear_fallback_mesh(node)
	node.add_child(visual)
	node.set_meta(APPLIED_META, "mesh")
	_play_first_animation(visual)
	print("[SceneSyncAdapter] loaded object %s type mesh bytes %d" % [object_id, data.size()])


func _adapt_url_image(ticket: Dictionary, object_id: String, node: Node3D, asset: Dictionary) -> void:
	var response := await _fetch_bytes(int(ticket["generation"]), _safe_string(asset.get("url", "")), MAX_IMAGE_BYTES)
	if not bool(response.get("ok", false)):
		await _handle_fetch_failure(ticket, object_id, node, "image", response)
		return
	_retry_states.erase(object_id)
	var data: PackedByteArray = response["data"]
	var image := Image.new()
	var error := ERR_FILE_UNRECOGNIZED
	if _is_png(data):
		error = image.load_png_from_buffer(data)
	elif _is_jpeg(data):
		error = image.load_jpg_from_buffer(data)
	elif _is_webp(data):
		error = image.load_webp_from_buffer(data)
	if error != OK or image.is_empty():
		_warn_once(object_id, "unsupported or invalid image data")
		return
	if not _is_current(ticket, object_id, node):
		return
	var target := _fallback_mesh(node)
	if target == null:
		_warn_once(object_id, "image fallback mesh is unavailable")
		return
	_clear_fallback_mesh(node)
	var quad := QuadMesh.new()
	var aspect := float(image.get_width()) / maxf(float(image.get_height()), 1.0)
	quad.size = (
		Vector2(2.0, maxf(2.0 / aspect, 0.1))
		if aspect >= 1.0
		else Vector2(maxf(2.0 * aspect, 0.1), 2.0)
	)
	target.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = ImageTexture.create_from_image(image)
	target.material_override = material
	node.set_meta(APPLIED_META, "image")
	print("[SceneSyncAdapter] loaded object %s type image bytes %d" % [object_id, data.size()])


func _adapt_url_text(ticket: Dictionary, object_id: String, node: Node3D, asset: Dictionary) -> void:
	var response := await _fetch_bytes(int(ticket["generation"]), _safe_string(asset.get("url", "")), MAX_TEXT_BYTES)
	if not bool(response.get("ok", false)):
		await _handle_fetch_failure(ticket, object_id, node, "text", response)
		return
	_retry_states.erase(object_id)
	var data: PackedByteArray = response["data"]
	_apply_inline_text(ticket, object_id, node, asset, data.get_string_from_utf8())


func _apply_inline_text(ticket: Dictionary, object_id: String, node: Node3D, asset: Dictionary, text: String) -> void:
	if not _is_current(ticket, object_id, node):
		return
	_clear_fallback_mesh(node)
	var layout_value = asset.get("layout", {})
	var layout: Dictionary = layout_value if layout_value is Dictionary else {}
	var width_m := maxf(float(layout.get("width", asset.get("width", 2.4))), 0.05)
	var height_m := maxf(float(layout.get("height", asset.get("height", 1.6))), 0.05)
	var padding := _layout_padding(layout.get("padding", asset.get("padding", 0.08)))
	var content_width_m := maxf(width_m - padding.x - padding.z, TEXT_PIXEL_SIZE * 16.0)
	var background := MeshInstance3D.new()
	background.name = "RemoteTextBackground"
	background.set_meta("scene_sync_adapter_owned", true)
	var quad := QuadMesh.new()
	quad.size = Vector2(width_m, height_m)
	background.mesh = quad
	var background_material := StandardMaterial3D.new()
	background_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	background_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	background_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	background_material.albedo_color = _parse_css_color(
		_safe_string(asset.get("backgroundColor", null), "rgba(0,0,0,0.65)"),
		Color(0.0, 0.0, 0.0, 0.65)
	)
	background.material_override = background_material
	node.add_child(background)
	var label := Label3D.new()
	label.name = "RemoteTextLabel"
	label.set_meta("scene_sync_adapter_owned", true)
	label.text = text
	label.pixel_size = TEXT_PIXEL_SIZE
	label.font_size = clampi(int(layout.get("fontSize", asset.get("fontSize", 42))), 12, 96)
	label.width = maxi(int(round(content_width_m / TEXT_PIXEL_SIZE)), 16)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate = _parse_css_color(_safe_string(asset.get("color", null), "#ffffff"), Color.WHITE)
	label.outline_size = 6
	label.position = Vector3((padding.x - padding.z) * 0.5, (padding.w - padding.y) * 0.5, 0.003)
	var scroll_value = layout.get("scroll", asset.get("scroll", {}))
	if scroll_value is Dictionary:
		label.position.y += float((scroll_value as Dictionary).get("y", 0.0))
	var line_height_ratio := float(layout.get("lineHeight", asset.get("lineHeight", 1.35)))
	label.line_spacing = int(round(float(label.font_size) * (line_height_ratio - 1.0)))
	var alignment := _safe_string(
		asset.get("align", layout.get("alignment", asset.get("alignment", null))),
		"center"
	).to_lower()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if alignment == "left" else (HORIZONTAL_ALIGNMENT_RIGHT if alignment == "right" else HORIZONTAL_ALIGNMENT_CENTER)
	node.add_child(label)
	node.set_meta(APPLIED_META, "text")
	print("[SceneSyncAdapter] loaded object %s type text bytes %d" % [object_id, text.to_utf8_buffer().size()])


func _fetch_bytes(generation: int, url: String, maximum_size: int) -> Dictionary:
	if not _is_allowed_url(url):
		return _fetch_failure("url-policy", -1, 0, 0, false)
	var request := HTTPRequest.new()
	request.body_size_limit = maximum_size
	request.max_redirects = 8
	add_child(request)
	_active_requests.append(request)
	var error := request.request(url)
	if error != OK:
		_active_requests.erase(request)
		request.queue_free()
		return _fetch_failure("request-start-%s" % error_string(error), error, 0, 0, true)
	var result: Array = await request.request_completed
	_active_requests.erase(request)
	request.queue_free()
	if generation != _generation or result.size() < 4:
		return _fetch_failure("stale-or-incomplete", -1, 0, 0, false)
	var body: PackedByteArray = result[3]
	var request_result := int(result[0])
	var response_code := int(result[1])
	if request_result != HTTPRequest.RESULT_SUCCESS:
		var can_retry := request_result != HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED
		return _fetch_failure("request-result", request_result, response_code, body.size(), can_retry)
	if response_code < 200 or response_code >= 300:
		var can_retry := response_code in [408, 425, 429] or response_code >= 500
		return _fetch_failure("http-status", request_result, response_code, body.size(), can_retry)
	if body.is_empty():
		return _fetch_failure("empty-body", request_result, response_code, 0, true)
	if body.size() > maximum_size:
		return _fetch_failure("body-too-large", request_result, response_code, body.size(), false)
	return {"ok": true, "data": body}


func _fetch_failure(reason: String, result: int, status: int, size: int, transient: bool) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"result": result,
		"status": status,
		"size": size,
		"transient": transient,
	}


func _handle_fetch_failure(
	ticket: Dictionary,
	object_id: String,
	node: Node3D,
	asset_type: String,
	response: Dictionary
) -> void:
	var result := int(response.get("result", -1))
	var status := int(response.get("status", 0))
	var size := int(response.get("size", 0))
	var reason := String(response.get("reason", "unknown"))
	if not bool(response.get("transient", false)):
		_warn_once(
			object_id,
			"%s fetch failed reason=%s result=%d status=%d bytes=%d retry=disabled"
			% [asset_type, reason, result, status, size]
		)
		return
	if not _is_current(ticket, object_id, node):
		return
	var state_value = _retry_states.get(object_id, {})
	var state: Dictionary = state_value if state_value is Dictionary else {}
	var failures := int(state.get("failures", 0)) + 1
	var retry_delay := minf(pow(2.0, float(failures - 1)), 30.0)
	_retry_states[object_id] = {
		"nodeId": int(ticket.get("nodeId", 0)),
		"signature": String(ticket.get("signature", "")),
		"failures": failures,
	}
	push_warning(
		"[SceneSyncAdapter] object %s: %s fetch failed reason=%s result=%d status=%d bytes=%d; retry in %.0fs"
		% [object_id, asset_type, reason, result, status, size, retry_delay]
	)
	var tree := get_tree()
	if tree == null:
		return
	await tree.create_timer(retry_delay).timeout
	if not _is_current(ticket, object_id, node):
		return
	var current_state_value = _retry_states.get(object_id, {})
	var current_state: Dictionary = current_state_value if current_state_value is Dictionary else {}
	if (
		int(current_state.get("nodeId", 0)) != int(ticket.get("nodeId", -1))
		or String(current_state.get("signature", "")) != String(ticket.get("signature", "!"))
		or int(current_state.get("failures", 0)) != failures
	):
		return
	_records.erase(object_id)


func _is_allowed_url(url: String) -> bool:
	if url.begins_with("https://"):
		return true
	if not url.begins_with("http://") or OS.has_feature("mobile"):
		return false
	var authority := url.trim_prefix("http://").split("/", false, 1)[0].to_lower()
	return authority.begins_with("localhost") or authority.begins_with("127.0.0.1") or authority.begins_with("[::1]")


func _is_current(ticket: Dictionary, object_id: String, node: Node3D) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if int(ticket.get("generation", -1)) != _generation or int(ticket.get("revision", -1)) != int(_revisions.get(object_id, -2)):
		return false
	var record_value = _records.get(object_id, {})
	var record: Dictionary = record_value if record_value is Dictionary else {}
	if int(record.get("nodeId", 0)) != int(ticket.get("nodeId", -1)) or String(record.get("signature", "")) != String(ticket.get("signature", "!")):
		return false
	return (
		node.get_instance_id() == int(ticket.get("nodeId", -1))
		and _manager != null
		and is_instance_valid(_manager)
		and node.is_inside_tree()
		and _safe_string(node.get_meta(OBJECT_ID_META, "")) == object_id
	)


func _fallback_mesh(node: Node3D) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		if child is MeshInstance3D:
			return child as MeshInstance3D
	return null


func _clear_fallback_mesh(node: Node3D) -> void:
	var fallback := _fallback_mesh(node)
	if fallback != null:
		fallback.mesh = null
		fallback.material_override = null
	for child in node.get_children():
		if bool(child.get_meta("scene_sync_adapter_owned", false)):
			node.remove_child(child)
			child.queue_free()


func _restore_fallback_if_adapter_owned(node: Node3D) -> void:
	if not node.has_meta(APPLIED_META):
		return
	_clear_fallback_mesh(node)
	var fallback := _fallback_mesh(node)
	if fallback != null:
		fallback.mesh = BoxMesh.new()
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.53, 0.53, 0.53)
		fallback.material_override = material
	node.remove_meta(APPLIED_META)


func _restore_primitive_if_adapter_owned(node: Node3D, asset: Dictionary) -> void:
	if not node.has_meta(APPLIED_META):
		return
	_clear_fallback_mesh(node)
	var fallback := _fallback_mesh(node)
	if fallback != null:
		match _safe_string(asset.get("primitive", null), "box").to_lower():
			"sphere":
				fallback.mesh = SphereMesh.new()
			"cylinder":
				fallback.mesh = CylinderMesh.new()
			"cone":
				var cone := CylinderMesh.new()
				cone.top_radius = 0.0
				fallback.mesh = cone
			"plane":
				fallback.mesh = PlaneMesh.new()
			"torus":
				fallback.mesh = TorusMesh.new()
			_:
				fallback.mesh = BoxMesh.new()
		var material := StandardMaterial3D.new()
		material.albedo_color = _parse_css_color(
			_safe_string(asset.get("color", null), "#888888"),
			Color(0.53, 0.53, 0.53)
		)
		fallback.material_override = material
	node.remove_meta(APPLIED_META)


func _safe_string(value: Variant, fallback: String = "") -> String:
	if value == null:
		return fallback
	if value is String:
		return value
	if value is StringName:
		return String(value)
	return fallback


func _layout_padding(value: Variant) -> Vector4:
	if value is Dictionary:
		var dictionary := value as Dictionary
		var horizontal := float(dictionary.get("horizontal", 0.0))
		var vertical := float(dictionary.get("vertical", horizontal))
		return Vector4(
			float(dictionary.get("left", horizontal)),
			float(dictionary.get("top", vertical)),
			float(dictionary.get("right", horizontal)),
			float(dictionary.get("bottom", vertical))
		)
	var padding := maxf(float(value), 0.0)
	return Vector4(padding, padding, padding, padding)


func _parse_css_color(value: String, fallback: Color) -> Color:
	var text := value.strip_edges().to_lower()
	if text.begins_with("#") and text.length() in [4, 7, 9]:
		return Color.from_string(text, fallback)
	var is_rgba := text.begins_with("rgba(") and text.ends_with(")")
	var is_rgb := text.begins_with("rgb(") and text.ends_with(")")
	if is_rgb or is_rgba:
		var start := 5 if is_rgba else 4
		var parts := text.substr(start, text.length() - start - 1).split(",")
		if parts.size() == (4 if is_rgba else 3):
			var channels: Array[float] = []
			for index in 3:
				if not parts[index].strip_edges().is_valid_float():
					return fallback
				channels.append(clampf(float(parts[index]) / 255.0, 0.0, 1.0))
			var alpha := 1.0
			if is_rgba:
				if not parts[3].strip_edges().is_valid_float():
					return fallback
				alpha = float(parts[3])
				if alpha > 1.0:
					alpha /= 255.0
			return Color(channels[0], channels[1], channels[2], clampf(alpha, 0.0, 1.0))
	return fallback


func _play_first_animation(root_node: Node) -> void:
	for candidate in root_node.find_children("*", "AnimationPlayer", true, false):
		var player := candidate as AnimationPlayer
		if player == null:
			continue
		for animation_name in player.get_animation_list():
			var animation := player.get_animation(animation_name)
			if animation == null:
				continue
			var library_name := player.find_animation_library(animation)
			var library := player.get_animation_library(library_name)
			if library == null:
				continue
			var local_name := StringName()
			for candidate_name in library.get_animation_list():
				if library.get_animation(candidate_name) == animation:
					local_name = candidate_name
					break
			if local_name == &"" or local_name == &"RESET":
				continue
			# The wire asset has no animation playback policy. Remote GLBs therefore
			# default to looping their first non-RESET clip without mutating an
			# imported/shared Animation or AnimationLibrary resource.
			var local_library := library.duplicate(true) as AnimationLibrary
			if local_library == null:
				continue
			var local_animation := local_library.get_animation(local_name)
			if local_animation == null:
				continue
			if local_animation == animation:
				local_animation = animation.duplicate(true) as Animation
				if local_animation == null:
					continue
				local_library.remove_animation(local_name)
				if local_library.add_animation(local_name, local_animation) != OK:
					continue
			local_animation.loop_mode = Animation.LOOP_LINEAR
			player.remove_animation_library(library_name)
			if player.add_animation_library(library_name, local_library) != OK:
				player.add_animation_library(library_name, library)
				continue
			player.play(animation_name)
			return


func _is_png(data: PackedByteArray) -> bool:
	return data.size() >= 8 and data.slice(0, 8) == PackedByteArray([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])


func _is_jpeg(data: PackedByteArray) -> bool:
	return data.size() >= 3 and data[0] == 0xff and data[1] == 0xd8 and data[2] == 0xff


func _is_webp(data: PackedByteArray) -> bool:
	return data.size() >= 12 and data.get_string_from_ascii().begins_with("RIFF") and data.slice(8, 12).get_string_from_ascii() == "WEBP"


func _warn_once(object_id: String, message: String) -> void:
	var key := "%s:%s" % [object_id, message]
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("[SceneSyncAdapter] object %s: %s" % [object_id, message])
