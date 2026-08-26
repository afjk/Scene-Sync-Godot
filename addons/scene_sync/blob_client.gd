class_name SceneSyncBlobClient
extends Node

const MAX_GLB_SIZE: int = 50 * 1024 * 1024
const REQUEST_TIMEOUT_SECONDS: float = 120.0

var blob_base_url: String = "https://afjk.jp/presence/blob"


func upload_glb(data: PackedByteArray, path: String) -> Error:
    var request := HTTPRequest.new()
    add_child(request)

    var url := "%s/%s" % [blob_base_url.trim_suffix("/"), path.uri_encode()]
    var headers := PackedStringArray(["Content-Type: model/gltf-binary"])
    var err := request.request_raw(url, headers, HTTPClient.METHOD_POST, data)
    if err != OK:
        push_warning("[SceneSync] Blob upload request failed: %s" % error_string(err))
        request.queue_free()
        return err

    var result: Array = await request.request_completed
    request.queue_free()

    var response_code := int(result[1])
    if response_code != 201:
        push_warning("[SceneSync] Blob upload failed: HTTP %d (%s)" % [response_code, path])
        return ERR_CANT_CONNECT
    return OK


func download_glb(path: String, expected_size: int = 0) -> PackedByteArray:
    var request := HTTPRequest.new()
    request.timeout = REQUEST_TIMEOUT_SECONDS
    request.body_size_limit = MAX_GLB_SIZE
    add_child(request)

    var url := "%s/%s" % [blob_base_url.trim_suffix("/"), path.uri_encode()]
    var err := request.request(url)
    if err != OK:
        push_warning("[SceneSync] Blob download request failed: %s" % error_string(err))
        request.queue_free()
        return PackedByteArray()

    var result: Array = await request.request_completed
    request.queue_free()

    var response_code := int(result[1])
    if response_code != 200:
        return PackedByteArray()

    return normalize_downloaded_glb(result[3], expected_size)


static func normalize_downloaded_glb(data: PackedByteArray, expected_size: int = 0) -> PackedByteArray:
    if data.is_empty() or data.size() > MAX_GLB_SIZE:
        return PackedByteArray()
    if expected_size < 0 or expected_size > MAX_GLB_SIZE:
        push_warning("[SceneSync] Refusing GLB with invalid expected size: %d" % expected_size)
        return PackedByteArray()
    if _has_glb_magic(data):
        if expected_size > 0 and data.size() != expected_size:
            push_warning(
                "[SceneSync] Plain GLB size mismatch: expected=%d actual=%d"
                % [expected_size, data.size()]
            )
            return PackedByteArray()
        return data
    if not _has_gzip_magic(data):
        push_warning("[SceneSync] Blob response is neither GLB nor gzip data")
        return PackedByteArray()

    var decoded := PackedByteArray()
    if expected_size > 0:
        decoded = data.decompress(expected_size, FileAccess.COMPRESSION_GZIP)
    else:
        decoded = data.decompress_dynamic(MAX_GLB_SIZE, FileAccess.COMPRESSION_GZIP)
    if decoded.is_empty() or not _has_glb_magic(decoded):
        push_warning("[SceneSync] Failed to decode gzip blob response as GLB")
        return PackedByteArray()
    if expected_size > 0 and decoded.size() != expected_size:
        push_warning(
            "[SceneSync] Decoded gzip GLB size mismatch: expected=%d actual=%d"
            % [expected_size, decoded.size()]
        )
        return PackedByteArray()

    print(
        "[SceneSync] Decoded gzip blob response compressed=%d bytes glb=%d bytes"
        % [data.size(), decoded.size()]
    )
    return decoded


static func compute_asset_id(data: PackedByteArray) -> String:
    if data.is_empty():
        return ""

    var hashing := HashingContext.new()
    var err := hashing.start(HashingContext.HASH_SHA256)
    if err != OK:
        return ""
    hashing.update(data)
    return "sha256-" + _bytes_to_hex(hashing.finish())


static func generate_random_path() -> String:
    const CHARS := "abcdefghijklmnopqrstuvwxyz0123456789"
    var rng := RandomNumberGenerator.new()
    rng.randomize()
    var result := ""
    for i in range(8):
        result += CHARS[rng.randi_range(0, CHARS.length() - 1)]
    return result


static func _has_glb_magic(data: PackedByteArray) -> bool:
    return (
        data.size() >= 4
        and data[0] == 0x67
        and data[1] == 0x6c
        and data[2] == 0x54
        and data[3] == 0x46
    )


static func _has_gzip_magic(data: PackedByteArray) -> bool:
    return data.size() >= 2 and data[0] == 0x1f and data[1] == 0x8b


static func _bytes_to_hex(data: PackedByteArray) -> String:
    const HEX := "0123456789abcdef"
    var result := ""
    for byte_value in data:
        var value := int(byte_value)
        result += HEX.substr((value >> 4) & 0x0f, 1)
        result += HEX.substr(value & 0x0f, 1)
    return result
