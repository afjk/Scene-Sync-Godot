extends Node3D

const HAND_COLORS: Array[Color] = [
	Color(0.05, 0.62, 1.0, 1.0),
	Color(1.0, 0.18, 0.12, 1.0),
]

@export_enum("Left", "Right") var hand := 0


func _ready() -> void:
	# The scene is a single sphere marker; tint it per hand.
	var primary_material := StandardMaterial3D.new()
	primary_material.albedo_color = HAND_COLORS[hand]
	primary_material.metallic = 0.12
	primary_material.roughness = 0.3

	$Body.material_override = primary_material
