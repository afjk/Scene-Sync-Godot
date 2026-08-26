extends SceneTree

const BLOB_CLIENT_SCRIPT := preload("res://addons/scene_sync/blob_client.gd")

var _failures: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var glb := PackedByteArray([0x67, 0x6c, 0x54, 0x46, 0x02, 0x00, 0x00, 0x00])
	var compressed := glb.compress(FileAccess.COMPRESSION_GZIP)
	_assert_true(not compressed.is_empty(), "gzip fixture is created")
	_assert_equal(
		BLOB_CLIENT_SCRIPT.normalize_downloaded_glb(compressed, glb.size()),
		glb,
		"gzip blob response is decoded",
	)
	_assert_equal(
		BLOB_CLIENT_SCRIPT.normalize_downloaded_glb(glb, glb.size()),
		glb,
		"plain GLB response remains unchanged",
	)
	_assert_true(
		BLOB_CLIENT_SCRIPT.normalize_downloaded_glb(glb, glb.size() + 1).is_empty(),
		"plain GLB with a size mismatch is rejected",
	)
	_assert_true(
		BLOB_CLIENT_SCRIPT.normalize_downloaded_glb(PackedByteArray([1, 2, 3, 4])).is_empty(),
		"invalid blob response is rejected for peer recovery",
	)

	if _failures.is_empty():
		print("Scene Sync blob client smoke: PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _assert_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		_failures.append("%s: expected %s, got %s" % [label, expected, actual])


func _assert_true(value: bool, label: String) -> void:
	if not value:
		_failures.append(label)
