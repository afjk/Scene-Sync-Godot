extends Node3D

@onready var viewport: Viewport = get_viewport()
@onready var environment: Environment = $WorldEnvironment.environment
@onready var demo_cube: MeshInstance3D = $Demo/Cube
@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var aim_controllers: Array[XRController3D] = [
	$XROrigin3D/LeftController,
	$XROrigin3D/RightController,
]
@onready var grip_controllers: Array[XRController3D] = [
	$XROrigin3D/LeftGripController,
	$XROrigin3D/RightGripController,
]

var xr_interface: XRInterface
var hand_joint_markers: Array = []

const HAND_TRACKER_PATHS: Array[StringName] = [
	&"/user/hand_tracker/left",
	&"/user/hand_tracker/right",
]
const HAND_COLORS: Array[Color] = [
	Color(0.05, 0.62, 1.0, 1.0),
	Color(1.0, 0.18, 0.12, 1.0),
]
const JOINT_MARKER_RADIUS := 0.006


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
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
	_create_hand_joint_markers()
	print("OpenXR MR initialized with Alpha environment blend")


func _process(delta: float) -> void:
	demo_cube.rotate_y(delta * 0.55)
	demo_cube.rotate_x(delta * 0.18)
	_update_hand_joint_markers()
	_update_controller_visuals()


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


func _is_hand_tracking_active(tracker: XRHandTracker) -> bool:
	if tracker == null or not tracker.has_tracking_data:
		return false

	return tracker.hand_tracking_source not in [
		XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER,
		XRHandTracker.HAND_TRACKING_SOURCE_NOT_TRACKED,
	]


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
