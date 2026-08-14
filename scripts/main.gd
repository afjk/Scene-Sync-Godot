extends Node3D

## Emitted when the user takes the headset off or the runtime moves the app to the background.
signal focus_lost
## Emitted when the app regains XR focus.
signal focus_gained
## Emitted when the runtime recenters the player pose.
signal pose_recentered

const HAND_TRACKER_PATHS: Array[StringName] = [
	&"/user/hand_tracker/left",
	&"/user/hand_tracker/right",
]
const HAND_COLORS: Array[Color] = [
	Color(0.05, 0.62, 1.0, 1.0),
	Color(1.0, 0.18, 0.12, 1.0),
]
const JOINT_MARKER_RADIUS := 0.006
## Sources that mean the runtime is not reporting optically tracked hands.
const INACTIVE_HAND_SOURCES: Array[int] = [
	XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER,
	XRHandTracker.HAND_TRACKING_SOURCE_NOT_TRACKED,
]

## Highest display refresh rate to request from the XR runtime.
@export var maximum_refresh_rate := 90

var xr_interface: OpenXRInterface
var xr_is_focussed := false
var hand_joint_markers: Array = []
## Meta XR_FB_render_model nodes, only created when the core extension is inactive.
var fb_render_models: Array = []
## Last motion range pushed per hand, so we only call into the runtime on change.
var hand_motion_ranges: Array[int] = [-1, -1]

@onready var viewport: Viewport = get_viewport()
@onready var environment: Environment = $WorldEnvironment.environment
@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var aim_controllers: Array[XRController3D] = [
	$XROrigin3D/LeftController,
	$XROrigin3D/RightController,
]
@onready var grip_controllers: Array[XRController3D] = [
	$XROrigin3D/LeftGripController,
	$XROrigin3D/RightGripController,
]
@onready var controller_markers: Array[Node3D] = [
	$XROrigin3D/LeftGripController/ControllerModel,
	$XROrigin3D/RightGripController/ControllerModel,
]
@onready var render_model_managers: Array[OpenXRRenderModelManager] = [
	$XROrigin3D/LeftGripController/RenderModel,
	$XROrigin3D/RightGripController/RenderModel,
]


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr_interface == null or not xr_interface.is_initialized():
		_enable_desktop_fallback("OpenXR is not initialized")
		return

	var supported_modes := xr_interface.get_supported_environment_blend_modes()
	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND not in supported_modes:
		_enable_desktop_fallback("OpenXR Alpha environment blend is not supported")
		return

	xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
	_configure_transparent_environment()
	viewport.use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_configure_foveation()
	_connect_openxr_signals()
	_setup_controller_render_models()
	_create_hand_joint_markers()
	print("OpenXR MR initialized with Alpha environment blend")


func _process(_delta: float) -> void:
	_update_hand_joint_markers()
	_update_controller_visuals()


func _configure_foveation() -> void:
	# Forward+ and Mobile drive foveation through the rendering device as VRS.
	# The Compatibility renderer used by this template has no rendering device,
	# so it relies on the OpenXR foveation project settings instead.
	if RenderingServer.get_rendering_device() != null:
		viewport.vrs_mode = Viewport.VRS_XR
	elif int(ProjectSettings.get_setting("xr/openxr/foveation_level", 0)) == 0:
		push_warning("OpenXR: set xr/openxr/foveation_level to High for standalone headsets.")


func _connect_openxr_signals() -> void:
	xr_interface.session_begun.connect(_on_openxr_session_begun)
	xr_interface.session_visible.connect(_on_openxr_visible_state)
	xr_interface.session_focussed.connect(_on_openxr_focused_state)
	xr_interface.session_stopping.connect(_on_openxr_session_stopping)
	xr_interface.pose_recentered.connect(_on_openxr_pose_recentered)


func _on_openxr_session_begun() -> void:
	var current_rate := xr_interface.get_display_refresh_rate()
	if current_rate > 0.0:
		print("OpenXR: runtime reports a refresh rate of %s" % current_rate)
	else:
		print("OpenXR: runtime did not report a refresh rate")

	# Pick the highest rate the runtime offers that we are willing to render at.
	var best_rate := current_rate
	var available_rates := xr_interface.get_available_display_refresh_rates()
	if available_rates.is_empty():
		print("OpenXR: display refresh rate extension is not available")
	else:
		for entry in available_rates:
			var rate := float(entry)
			if rate > best_rate and rate <= maximum_refresh_rate:
				best_rate = rate

	if best_rate > 0.0 and not is_equal_approx(current_rate, best_rate):
		print("OpenXR: setting refresh rate to %s" % best_rate)
		xr_interface.set_display_refresh_rate(best_rate)
		current_rate = best_rate

	# Match the physics rate to the display so tracked poses land on frame boundaries.
	if current_rate > 0.0:
		Engine.physics_ticks_per_second = int(roundf(current_rate))


func _on_openxr_visible_state() -> void:
	# Startup also passes through this state; only a later visit means the user
	# took the headset off or the app moved to the background.
	if not xr_is_focussed:
		return

	print("OpenXR lost focus")
	xr_is_focussed = false
	# The upstream template disables the whole subtree here. Scene Sync lives under
	# this node and has to keep polling its WebSocket, so only the XR visual work
	# on this node stops. Backgrounding is handled separately by the bootstrap,
	# which disconnects on NOTIFICATION_APPLICATION_PAUSED.
	set_process(false)
	focus_lost.emit()


func _on_openxr_focused_state() -> void:
	print("OpenXR gained focus")
	xr_is_focussed = true
	set_process(true)
	focus_gained.emit()


func _on_openxr_session_stopping() -> void:
	print("OpenXR session is stopping")


func _on_openxr_pose_recentered() -> void:
	# Reacting to a recenter is application specific; forward it so scenes built
	# on this template can reposition their content.
	pose_recentered.emit()


func _setup_controller_render_models() -> void:
	# Two extensions can supply controller models: the vendor neutral
	# XR_EXT_render_model that Godot 4.6 implements in core, driven by the
	# OpenXRRenderModelManager nodes already present in the scene, and the older
	# Meta XR_FB_render_model from the OpenXR Vendors plugin. Runtimes differ in
	# which one they expose, so set both up and let _update_render_models() use
	# whichever actually produces a model.
	var core_active := _is_core_render_model_active()
	var fb_available := ClassDB.class_exists(&"OpenXRFbRenderModel")

	if fb_available:
		# Instantiate by name so the project still loads without the vendors plugin.
		for hand_index in grip_controllers.size():
			var render_model := ClassDB.instantiate(&"OpenXRFbRenderModel") as Node3D
			if render_model == null:
				fb_render_models.clear()
				fb_available = false
				break

			render_model.set(&"render_model_type", hand_index)
			grip_controllers[hand_index].add_child(render_model)
			fb_render_models.append(render_model)

	print("OpenXR: render models - core %s, Meta %s" % [core_active, fb_available])
	if not core_active and not fb_available:
		print("OpenXR: no render model extension available, using marker spheres")


func _is_core_render_model_active() -> bool:
	if not Engine.has_singleton(&"OpenXRRenderModelExtension"):
		return false

	return Engine.get_singleton(&"OpenXRRenderModelExtension").is_active()


func _update_render_models(hand_index: int) -> bool:
	# The core manager parents each loaded model under itself.
	var core_has_model := render_model_managers[hand_index].get_child_count() > 0
	if hand_index >= fb_render_models.size():
		return core_has_model

	# A runtime can expose both extensions; never draw two models on one hand.
	var fb_model: Node3D = fb_render_models[hand_index]
	var fb_has_model: bool = fb_model.call(&"has_render_model_node")
	fb_model.visible = fb_has_model and not core_has_model

	return core_has_model or fb_has_model


func _create_hand_joint_markers() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = JOINT_MARKER_RADIUS
	sphere.height = JOINT_MARKER_RADIUS * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4

	for hand_index in HAND_TRACKER_PATHS.size():
		var material := StandardMaterial3D.new()
		material.albedo_color = HAND_COLORS[hand_index]
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

		var markers: Array[MeshInstance3D] = []
		for _joint in XRHandTracker.HAND_JOINT_MAX:
			var marker := MeshInstance3D.new()
			marker.mesh = sphere
			marker.material_override = material
			marker.visible = false
			xr_origin.add_child(marker)
			markers.append(marker)
		hand_joint_markers.append(markers)


func _update_hand_joint_markers() -> void:
	if not viewport.use_xr or hand_joint_markers.is_empty():
		return

	for hand_index in HAND_TRACKER_PATHS.size():
		var tracker := XRServer.get_tracker(HAND_TRACKER_PATHS[hand_index]) as XRHandTracker
		var markers: Array = hand_joint_markers[hand_index]
		if not _is_hand_tracking_active(tracker):
			for marker: MeshInstance3D in markers:
				marker.visible = false
			continue

		for joint in XRHandTracker.HAND_JOINT_MAX:
			var marker: MeshInstance3D = markers[joint]
			var flags := tracker.get_hand_joint_flags(joint)
			marker.visible = (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
			if marker.visible:
				marker.position = tracker.get_hand_joint_transform(joint).origin
				var radius := maxf(tracker.get_hand_joint_radius(joint), JOINT_MARKER_RADIUS)
				marker.scale = Vector3.ONE * (radius / JOINT_MARKER_RADIUS)


func _update_controller_visuals() -> void:
	if not viewport.use_xr:
		return

	for hand_index in HAND_TRACKER_PATHS.size():
		var hand_tracker := XRServer.get_tracker(HAND_TRACKER_PATHS[hand_index]) as XRHandTracker
		var hand_tracking_active := _is_hand_tracking_active(hand_tracker)
		var aim_controller := aim_controllers[hand_index]
		var grip_controller := grip_controllers[hand_index]

		aim_controller.visible = aim_controller.get_is_active() and not hand_tracking_active
		grip_controller.visible = grip_controller.get_is_active() and not hand_tracking_active

		# Prefer the model the runtime supplies, and keep the marker sphere as the
		# fallback for runtimes that expose no render model extension.
		controller_markers[hand_index].visible = not _update_render_models(hand_index)
		_update_hand_motion_range(hand_index, hand_tracking_active)


func _update_hand_motion_range(hand_index: int, hand_tracking_active: bool) -> void:
	# Optically tracked hands move freely; hands derived from a held controller
	# should conform to the controller shape so the fingers do not clip through it.
	var motion_range := (
		OpenXRInterface.HAND_MOTION_RANGE_UNOBSTRUCTED
		if hand_tracking_active
		else OpenXRInterface.HAND_MOTION_RANGE_CONFORM_TO_CONTROLLER
	)
	if hand_motion_ranges[hand_index] == motion_range:
		return

	hand_motion_ranges[hand_index] = motion_range
	xr_interface.set_motion_range(hand_index, motion_range)


func _is_hand_tracking_active(tracker: XRHandTracker) -> bool:
	if tracker == null or not tracker.has_tracking_data:
		return false

	return tracker.hand_tracking_source not in INACTIVE_HAND_SOURCES


func _configure_transparent_environment() -> void:
	viewport.transparent_bg = true
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.80, 0.90, 1.0)


func _enable_desktop_fallback(reason: String) -> void:
	viewport.use_xr = false
	viewport.transparent_bg = false
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.025, 0.04, 0.065, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.65, 0.82, 1.0)
	push_warning("%s; using desktop fallback." % reason)
