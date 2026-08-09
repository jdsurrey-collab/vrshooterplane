extends Node

## Altitude-driven fog: a thick smog layer that hides the skyline when seen
## from above, which THINS OUT to a controllable visibility once the ship is
## actually inside it.
##
## This is the fix for the one real complaint about the original tall fog —
## the look was right, but flying into it meant seeing nothing at all.
##
## WHY THAT HAPPENED, AND WHY THIS FIXES IT WITHOUT VOLUMETRIC FOG. Godot's
## depth fog ramps from `fog_depth_begin` (clear) to `fog_depth_end` (fully
## fogged). Those were 2500m and 70000m, tuned so a city 20km away sat in
## the right amount of haze. Flying inside that layer, every single thing
## around the player was still tens of thousands of metres from being
## "clear", so the entire view saturated to flat fog colour. The fog wasn't
## too dense — its RAMP was calibrated for looking at things 20km away.
##
## So instead of switching techniques, the ramp itself is driven by
## altitude. Above the layer it stays at the wide exterior range that makes
## the smog read properly from the mothership. Once inside, it compresses to
## `interior_visibility`, so there is a genuine clear bubble around the ship
## and fog closes in beyond it. `interior_visibility` is exactly the "how
## many metres can I see" dial that was asked for.
##
## VOLUMETRIC FOG IS DELIBERATELY NOT USED for the interior, even though it
## is the more obvious answer. It was tried and rejected in play for being
## jittery, and the cause was structural rather than a setting: volumetric
## fog accumulates into a camera-aligned froxel grid, and stretched across
## this 100x world that grid was ~187m PER DEPTH SLICE. Every camera
## movement resampled across those enormous cells and the fog swam, with
## temporal reprojection fighting VR head motion on top. Shrinking the grid
## to a bubble around the ship would fix the froxel size, but it reintroduces
## a per-frame 3D grid evaluated per eye, and this project has an open
## frame-rate question. Driving the ramp costs three property writes a frame
## and cannot jitter, because nothing is being resampled.
##
## Everything here is exported and live-tunable; nothing about the look is
## hardcoded.

@export var enabled: bool = true:
	set(value):
		enabled = value
		set_process(enabled)

## World Y of the top of the smog layer. The player is considered "inside"
## below this. Should sit above the tallest buildings for the layer to hide
## the skyline the way the original did.
@export var fog_top: float = 3200.0

## Blend distance either side of `fog_top`, so entering and leaving fades
## rather than snapping.
@export var transition_band: float = 500.0

@export_group("Exterior — seen from above")
## The wide ramp that makes a distant city sit in haze. This is the look
## that was liked from the mothership.
@export var exterior_depth_begin: float = 2500.0
@export var exterior_depth_end: float = 70000.0
@export var exterior_density: float = 0.55

@export_group("Interior — flying inside the layer")
## How far you can see once inside. Fog is fully opaque at this distance and
## clear at a quarter of it, so this is the practical "visibility" figure.
@export var interior_visibility: float = 450.0
@export var interior_density: float = 0.95

var _env: Environment
var _player: Node3D


func _ready() -> void:
	var world_env := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_env:
		_env = world_env.environment
	_player = get_tree().current_scene.get_node_or_null("Player")
	if not _env or not _player:
		push_warning("Atmosphere: missing WorldEnvironment or Player")
		set_process(false)
		return
	# The layer top and the height-fog reference are the same thing by
	# definition — keeping them in sync here means there's one number to
	# tune rather than two that can silently disagree.
	_env.fog_height = fog_top
	set_process(enabled)


func _process(_delta: float) -> void:
	if not _env or not _player:
		return

	# 0.0 fully above the layer, 1.0 fully inside it.
	var depth_into_fog: float = fog_top - _player.global_position.y
	var t: float = clampf(depth_into_fog / maxf(transition_band, 0.001), 0.0, 1.0)

	# Compressing the ramp is what opens up a clear bubble around the ship.
	# A quarter of the visibility figure stays completely clear; fog reaches
	# full strength at the figure itself.
	_env.fog_depth_begin = lerpf(exterior_depth_begin, interior_visibility * 0.25, t)
	_env.fog_depth_end = lerpf(exterior_depth_end, interior_visibility, t)
	_env.fog_density = lerpf(exterior_density, interior_density, t)
