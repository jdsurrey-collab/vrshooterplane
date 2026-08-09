extends XROrigin3D

## Scales the player's entire physical presence (camera height, hand reach,
## tracked movement) relative to the game world, independent of world
## geometry (terrain/skybox are untouched by this).
@export var player_world_scale: float = 1.0


func _ready() -> void:
	XRServer.world_scale = player_world_scale
