extends OpenXRCompositionLayerQuad

signal connect_requested(room: String, nickname: String)
signal disconnect_requested

const NO_INTERSECTION := Vector2(-1.0, -1.0)
const FULL_QUAD_SIZE := Vector2(0.78, 0.52)
const MINIMIZED_QUAD_SIZE := Vector2(0.24, 0.16)
const UI_CLICK_ACTION := &"ui_click"
const PANEL_DISTANCE_METERS := 1.2
const RECENTER_DEFER_FRAMES := 2
const FORWARD_EPSILON_SQUARED := 0.000001

@export var right_controller: XRController3D
@export var xr_camera: XRCamera3D

var _was_pressed := false
var _was_intersection := NO_INTERSECTION
var _suppress_pointer_until_release := false
var _keyboard_target: LineEdit = null
var _keyboard_uppercase := false
var _keyboard_transition_pending := false
var _pending_keyboard_target: LineEdit = null
var _pending_keyboard_target_name := ""
var _keyboard_finish_pending := false
var _openxr_interface: OpenXRInterface = null
var _placement_frames_remaining := -1
var _initial_placement_complete := false

@onready var viewport: SubViewport = $SceneSyncViewport
@onready var cursor: Control = $SceneSyncViewport/Interface/Cursor
@onready var full_panel: Control = $SceneSyncViewport/Interface/FullPanel
@onready var minimized_panel: Control = $SceneSyncViewport/Interface/MinimizedPanel
@onready var keyboard_panel: Control = $SceneSyncViewport/Interface/KeyboardPanel
# Resolved through the panels above; @onready vars initialize in declaration order,
# and the relative paths keep these lines inside the 100 column lint limit.
@onready var keyboard_target_label: Label = keyboard_panel.get_node(^"Margin/Content/Target")
@onready var keyboard_preview: LineEdit = keyboard_panel.get_node(^"Margin/Content/Preview")
@onready var keyboard_keys: GridContainer = keyboard_panel.get_node(^"Margin/Content/Keys")
@onready var keyboard_shift: Button = keyboard_panel.get_node(^"Margin/Content/Commands/Shift")
@onready var state_value: Label = full_panel.get_node(^"Margin/Content/StateRow/Value")
@onready var room_edit: LineEdit = full_panel.get_node(^"Margin/Content/RoomRow/RoomEdit")
@onready
var nickname_edit: LineEdit = full_panel.get_node(^"Margin/Content/NicknameRow/NicknameEdit")
@onready var connect_button: Button = full_panel.get_node(^"Margin/Content/Buttons/Connect")
@onready var disconnect_button: Button = full_panel.get_node(^"Margin/Content/Buttons/Disconnect")
@onready var error_value: Label = full_panel.get_node(^"Margin/Content/ErrorValue")
@onready var object_count_value: Label = full_panel.get_node(^"Margin/Content/ObjectRow/Value")


func _ready() -> void:
	layer_viewport = viewport
	quad_size = FULL_QUAD_SIZE
	cursor.visible = false
	connect_button.pressed.connect(_on_connect_pressed)
	disconnect_button.pressed.connect(_on_disconnect_pressed)
	full_panel.get_node(^"Margin/Content/Header/Minimize").pressed.connect(set_minimized.bind(true))
	minimized_panel.get_node(^"Margin/Show").pressed.connect(set_minimized.bind(false))
	room_edit.focus_entered.connect(_request_keyboard_edit.bind(room_edit, "Room code"))
	nickname_edit.focus_entered.connect(_request_keyboard_edit.bind(nickname_edit, "Nickname"))
	keyboard_shift.pressed.connect(_toggle_keyboard_case)

	var keyboard_commands := keyboard_panel.get_node(^"Margin/Content/Commands")
	keyboard_commands.get_node(^"Space").pressed.connect(_append_keyboard_text.bind(" "))
	keyboard_commands.get_node(^"Backspace").pressed.connect(_keyboard_backspace)
	keyboard_commands.get_node(^"Clear").pressed.connect(_keyboard_clear)
	keyboard_commands.get_node(^"Done").pressed.connect(_request_finish_keyboard_edit)
	_build_keyboard()
	set_connection_state("Disconnected", false, false)
	set_received_object_count(0)
	_bind_openxr_interface()


func _exit_tree() -> void:
	_unbind_openxr_interface()


func _process(_delta: float) -> void:
	_bind_openxr_interface()
	_update_panel_placement()

	cursor.visible = false
	if (
		right_controller == null
		or not is_instance_valid(right_controller)
		or not right_controller.get_is_active()
	):
		_release_pointer_if_needed()
		return

	var is_pressed := right_controller.is_button_pressed(UI_CLICK_ACTION)
	if _suppress_pointer_until_release:
		if is_pressed:
			return
		_suppress_pointer_until_release = false

	var controller_transform := right_controller.global_transform
	var intersection := intersects_ray(controller_transform.origin, -controller_transform.basis.z)
	if intersection == NO_INTERSECTION:
		_release_pointer_if_needed()
		return

	var viewport_position := _intersection_to_viewport_position(intersection)
	cursor.visible = true
	cursor.position = viewport_position - cursor.size * 0.5

	if _was_intersection == NO_INTERSECTION or intersection != _was_intersection:
		var motion := InputEventMouseMotion.new()
		var previous_position := _intersection_to_viewport_position(
			intersection if _was_intersection == NO_INTERSECTION else _was_intersection
		)
		var next_position := _intersection_to_viewport_position(intersection)
		motion.position = next_position
		motion.relative = next_position - previous_position
		if _was_pressed:
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		viewport.push_input(motion, true)

	if is_pressed != _was_pressed:
		_push_mouse_button(is_pressed, _intersection_to_viewport_position(intersection))

	_was_pressed = is_pressed
	_was_intersection = intersection


func _bind_openxr_interface() -> void:
	var candidate := XRServer.find_interface("OpenXR") as OpenXRInterface
	if candidate == _openxr_interface:
		return
	_unbind_openxr_interface()
	_openxr_interface = candidate
	if _openxr_interface == null:
		return
	if not _openxr_interface.pose_recentered.is_connected(_on_pose_recentered):
		_openxr_interface.pose_recentered.connect(_on_pose_recentered)
	if not _openxr_interface.play_area_changed.is_connected(_on_play_area_changed):
		_openxr_interface.play_area_changed.connect(_on_play_area_changed)


func _unbind_openxr_interface() -> void:
	if _openxr_interface == null or not is_instance_valid(_openxr_interface):
		_openxr_interface = null
		return
	if _openxr_interface.pose_recentered.is_connected(_on_pose_recentered):
		_openxr_interface.pose_recentered.disconnect(_on_pose_recentered)
	if _openxr_interface.play_area_changed.is_connected(_on_play_area_changed):
		_openxr_interface.play_area_changed.disconnect(_on_play_area_changed)
	_openxr_interface = null


func _on_pose_recentered() -> void:
	_schedule_panel_placement(RECENTER_DEFER_FRAMES)


func _on_play_area_changed(_mode: int) -> void:
	_schedule_panel_placement(RECENTER_DEFER_FRAMES)


func _schedule_panel_placement(frame_delay: int) -> void:
	# Resetting the delay coalesces a burst and applies the final tracking pose.
	_placement_frames_remaining = maxi(frame_delay, 0)


func _update_panel_placement() -> void:
	if (
		not _initial_placement_complete
		and _placement_frames_remaining < 0
		and _is_xr_tracking_ready()
	):
		_schedule_panel_placement(1)

	if _placement_frames_remaining < 0:
		return
	if _placement_frames_remaining > 0:
		_placement_frames_remaining -= 1
		return
	if not _is_xr_tracking_ready():
		_placement_frames_remaining = 1
		return
	if _place_in_front_of_camera():
		_placement_frames_remaining = -1
		_initial_placement_complete = true
	else:
		_placement_frames_remaining = 1


func _is_xr_tracking_ready() -> bool:
	if _openxr_interface == null or not is_instance_valid(_openxr_interface):
		return false
	if not _openxr_interface.is_initialized():
		return false
	var tracking_status := _openxr_interface.get_tracking_status()
	return (
		tracking_status != XRInterface.XR_UNKNOWN_TRACKING
		and tracking_status != XRInterface.XR_NOT_TRACKING
	)


func _place_in_front_of_camera() -> bool:
	if xr_camera == null or not is_instance_valid(xr_camera) or not xr_camera.is_inside_tree():
		return false

	var camera_transform := xr_camera.global_transform
	var horizontal_forward := -camera_transform.basis.z
	horizontal_forward.y = 0.0
	if horizontal_forward.length_squared() < FORWARD_EPSILON_SQUARED:
		horizontal_forward = global_position - camera_transform.origin
		horizontal_forward.y = 0.0
	if horizontal_forward.length_squared() < FORWARD_EPSILON_SQUARED:
		horizontal_forward = Vector3.FORWARD
	horizontal_forward = horizontal_forward.normalized()

	var panel_position := camera_transform.origin + horizontal_forward * PANEL_DISTANCE_METERS
	var panel_basis := Basis.looking_at(horizontal_forward, Vector3.UP)
	global_transform = Transform3D(panel_basis, panel_position)
	return true


func set_fields(room: String, nickname: String) -> void:
	room_edit.text = room
	nickname_edit.text = nickname


func set_connection_state(text: String, connected: bool, connecting: bool) -> void:
	state_value.text = text
	connect_button.disabled = connected or connecting
	disconnect_button.disabled = not connected and not connecting
	room_edit.editable = not connected and not connecting
	nickname_edit.editable = not connected and not connecting


func set_resetting(text: String) -> void:
	set_connection_state(text, false, true)
	disconnect_button.disabled = true


func set_last_error(text: String) -> void:
	error_value.text = text if text != "" else "None"


func set_received_object_count(count: int) -> void:
	object_count_value.text = str(maxi(count, 0))


func set_minimized(minimized: bool) -> void:
	if _keyboard_target != null:
		_finish_keyboard_edit()
	full_panel.visible = not minimized
	minimized_panel.visible = minimized
	keyboard_panel.visible = false
	quad_size = MINIMIZED_QUAD_SIZE if minimized else FULL_QUAD_SIZE
	_release_pointer_if_needed()


func _on_connect_pressed() -> void:
	connect_requested.emit(room_edit.text.strip_edges(), nickname_edit.text.strip_edges())


func _on_disconnect_pressed() -> void:
	disconnect_requested.emit()


func _intersection_to_viewport_position(intersection: Vector2) -> Vector2:
	return intersection * Vector2(viewport.size)


func _push_mouse_button(pressed: bool, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	if pressed:
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event, true)


func _release_pointer_if_needed() -> void:
	var should_release := _was_pressed and _was_intersection != NO_INTERSECTION
	var release_position := _intersection_to_viewport_position(_was_intersection)
	_was_pressed = false
	_was_intersection = NO_INTERSECTION
	if should_release:
		_push_mouse_button(false, release_position)


func _guard_pointer_during_modal_transition() -> void:
	_release_pointer_if_needed()
	_suppress_pointer_until_release = (
		right_controller != null
		and is_instance_valid(right_controller)
		and right_controller.get_is_active()
		and right_controller.is_button_pressed(UI_CLICK_ACTION)
	)


func _build_keyboard() -> void:
	var characters := "1234567890abcdefghijklmnopqrstuvwxyz-_."
	for index in characters.length():
		var character := characters.substr(index, 1)
		var button := Button.new()
		button.custom_minimum_size = Vector2(72, 48)
		button.text = character
		button.pressed.connect(_on_keyboard_character_pressed.bind(character))
		keyboard_keys.add_child(button)


func _request_keyboard_edit(target: LineEdit, target_name: String) -> void:
	if target == null or not is_instance_valid(target):
		return
	_pending_keyboard_target = target
	_pending_keyboard_target_name = target_name
	if _keyboard_transition_pending:
		return
	_keyboard_transition_pending = true
	call_deferred("_begin_keyboard_edit_deferred")


func _begin_keyboard_edit_deferred() -> void:
	_keyboard_transition_pending = false
	var target := _pending_keyboard_target
	var target_name := _pending_keyboard_target_name
	_pending_keyboard_target = null
	_pending_keyboard_target_name = ""
	if (
		target == null
		or not is_instance_valid(target)
		or not target.is_inside_tree()
		or not target.is_visible_in_tree()
	):
		return
	if not target.editable:
		target.release_focus()
		return

	_keyboard_target = target
	_guard_pointer_during_modal_transition()
	_keyboard_uppercase = false
	keyboard_shift.set_pressed_no_signal(false)
	keyboard_target_label.text = "Editing %s" % target_name
	keyboard_preview.text = target.text
	full_panel.visible = false
	minimized_panel.visible = false
	keyboard_panel.visible = true
	target.release_focus()


func _on_keyboard_character_pressed(character: String) -> void:
	_append_keyboard_text(character.to_upper() if _keyboard_uppercase else character)


func _append_keyboard_text(text: String) -> void:
	keyboard_preview.text += text
	keyboard_preview.caret_column = keyboard_preview.text.length()


func _keyboard_backspace() -> void:
	if keyboard_preview.text.length() > 0:
		keyboard_preview.text = keyboard_preview.text.left(keyboard_preview.text.length() - 1)
	keyboard_preview.caret_column = keyboard_preview.text.length()


func _keyboard_clear() -> void:
	keyboard_preview.text = ""


func _toggle_keyboard_case() -> void:
	_keyboard_uppercase = keyboard_shift.button_pressed


func _request_finish_keyboard_edit() -> void:
	if _keyboard_finish_pending:
		return
	_keyboard_finish_pending = true
	call_deferred("_finish_keyboard_edit_deferred")


func _finish_keyboard_edit_deferred() -> void:
	_keyboard_finish_pending = false
	_guard_pointer_during_modal_transition()
	_finish_keyboard_edit()


func _finish_keyboard_edit() -> void:
	if _keyboard_target != null and is_instance_valid(_keyboard_target):
		_keyboard_target.text = keyboard_preview.text
		_keyboard_target.release_focus()
	_keyboard_target = null
	keyboard_panel.visible = false
	full_panel.visible = true
