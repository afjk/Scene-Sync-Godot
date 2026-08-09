extends Node3D

@export_enum("Left", "Right") var hand := 0

const HAND_COLORS: Array[Color] = [
	Color(0.05, 0.62, 1.0, 1.0),
	Color(1.0, 0.18, 0.12, 1.0),
]


func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = HAND_COLORS[hand]
	material.metallic = 0.12
	material.roughness = 0.3
	$Body.material_override = material
