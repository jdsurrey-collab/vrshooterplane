extends Node

## Fog as a CLOUD BAND at a fixed ABSOLUTE altitude, covering the entire
## map, with clear air underneath it.
##
## ABSOLUTE, NOT GROUND-RELATIVE. An earlier version measured the band
## above LOCAL ground, resampled under the player every frame, so it could
## "raise fog to hide the skyline" only city-by-city. Two problems with
## that: it put the visible layer low wherever the ground was low, so it
## read as far too low over the city ("raise that fog up"), and it only
## ever covered wherever `cloud_deck.gd` had built geometry, not the rest of
## the 100km map ("cover the entire map"). A fixed world-Y band fixes both
## at once — it's the same altitude everywhere, mountains can poke up into
## it exactly like real cloud-capped peaks, and it needs no per-location
## terrain sampling at all (this script no longer touches Terrain).
##
## Godot's Environment cannot express a bounded slab (height fog is
## monotonic: denser toward the ground, all the way down), so this is still
## built from two pieces:
##
##  * `cloud_deck.gd` — the VISIBLE layer, a lit mesh sitting in the middle
##    of the band, at the same absolute altitude as this script's band.
##  * this script — the FEEL of being inside it (depth fog's ramp, driven by
##    the player's absolute altitude, so visibility only collapses while the
##    player's Y is inside [cloud_base_y, cloud_base_y + cloud_thickness])
##    AND the overcast lighting for the whole space UNDER the deck — the
##    sun/ambient light dim and grey the further below cloud_base_y +
##    cloud_thickness the player has descended, so the city and battle space
##    read as genuinely overcast instead of full sunshine under a cloud
##    layer. Above the band is left completely untouched by construction
##    (see `_overcast_factor`), not clamped separately from the fog band.
##
## The Environment's HEIGHT fog stays forced to 0
## (`fog_height_density = 0`) — it's the monotonic component that reaches
## the ground, and this band model replaces it entirely.
##
## No volumetric fog is involved. Its froxel grid was ~187m per depth slice
## at this world scale, which visibly swam on any camera movement, and only
## existed within `volumetric_fog_length` of the camera. This costs three
## property writes a frame against the player's own Y and cannot jitter,
## because nothing is being resampled.

@export var enabled: bool = true:
	set(value):
		enabled = value
		set_process(enabled)

@export_group("Cloud band — absolute altitude, whole map")
## World Y of the BOTTOM of the cloud band. Set above the tallest ordinary
## buildings so the deck hides the skyline from above, the way the original
## fog did (that version used fog_height = 3200m).
@export var cloud_base_y: float = 3200.0
## Vertical thickness of the band.
@export var cloud_thickness: float = 600.0
## Softening at the top and bottom edges, so entering and leaving fades
## instead of snapping.
@export var edge_softness: float = 220.0

@export_group("Outside the band")
## The wide ramp used below and above the clouds — clear nearby, hazy at
## distance. This is what makes the city read as far away from the
## mothership.
@export var clear_depth_begin: float = 2500.0
@export var clear_depth_end: float = 70000.0
@export var clear_density: float = 0.45

@export_group("Inside the band")
## How far you can see once inside the cloud. Fog is total at this distance
## and clear at a quarter of it, so this is the practical visibility figure
## and the single dial for "how blind am I inside the cloud".
@export var interior_visibility: float = 450.0
@export var interior_density: float = 0.95

@export_group("Overcast below the clouds")
## Sun/ambient light scaled down under the deck — real sunlight is heavily
## diffused by an actual cloud layer, and everything under a supposedly
## solid overcast reading as full unobstructed sunshine looked wrong. ABOVE
## the band is deliberately left completely untouched — the transition
## itself is tied to descending THROUGH the cloud band (see
## `_overcast_factor`), so at or above the band's own top these scales never
## apply at all, by construction rather than a separate cutoff to keep in
## sync.
@export var overcast_sun_energy_scale: float = 0.32
@export var overcast_ambient_energy_scale: float = 0.55
## Sunlight also cools and greys slightly under overcast — energy scaling
## alone still reads as "the same warm sun, just dimmer" rather than a
## genuinely different sky.
@export var overcast_sun_color: Color = Color(0.72, 0.75, 0.8)

@export var sun_path: NodePath = ^"../Sun"

var _env: Environment
var _player: Node3D
var _sun: DirectionalLight3D

## Captured from the scene's own authored values in _ready() rather than
## hardcoded, so "above the clouds" always means whatever Town.tscn actually
## authors for the Sun/Environment — this script never has to duplicate
## those numbers to know what "untouched" looks like, and if the scene's
## lighting is ever retuned, the overcast state follows automatically.
var _base_sun_energy: float = 1.0
var _base_sun_color: Color = Color.WHITE
var _base_ambient_energy: float = 1.0


func _ready() -> void:
	var world_env := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_env:
		_env = world_env.environment
	_player = get_tree().current_scene.get_node_or_null("Player")
	_sun = get_node_or_null(sun_path)
	if not _env or not _player or not _sun:
		push_warning("Atmosphere: missing WorldEnvironment, Player or Sun")
		set_process(false)
		return

	_base_sun_energy = _sun.light_energy
	_base_sun_color = _sun.light_color
	_base_ambient_energy = _env.ambient_light_energy

	# Height fog is the monotonic component that runs to the ground. The
	# band model replaces it, so it is forced off here rather than relying
	# on the scene file keeping it at zero.
	_env.fog_height_density = 0.0
	set_process(enabled)


## 1.0 when fully inside the cloud band, 0.0 in clear air above or below,
## ramped over `edge_softness` at each boundary.
func _band_factor(world_y: float) -> float:
	var lo := cloud_base_y
	var hi := cloud_base_y + cloud_thickness
	if world_y <= lo - edge_softness or world_y >= hi + edge_softness:
		return 0.0
	var rising: float = clampf((world_y - (lo - edge_softness)) / maxf(edge_softness, 0.001), 0.0, 1.0)
	var falling: float = clampf(((hi + edge_softness) - world_y) / maxf(edge_softness, 0.001), 0.0, 1.0)
	return minf(rising, falling)


## 1.0 at or below the BOTTOM of the cloud band (fully under the overcast),
## 0.0 at or above the TOP of it (fully clear — untouched), ramping linearly
## as the player descends through the band's own thickness. Reusing the
## band's real bounds for this — rather than a separate softness constant —
## is deliberate: physically, sunlight is progressively cut off as you sink
## through an actual cloud layer, so "how overcast does it feel" and "how
## far down through the clouds have I come" are the same question.
func _overcast_factor(world_y: float) -> float:
	var top := cloud_base_y + cloud_thickness
	return clampf((top - world_y) / maxf(cloud_thickness, 0.001), 0.0, 1.0)


func _process(_delta: float) -> void:
	if not _env or not _player or not _sun:
		return

	var pos_y: float = _player.global_position.y
	var t := _band_factor(pos_y)

	# Compressing the ramp is what closes the world in while inside the
	# cloud; outside, the wide ramp gives ordinary aerial perspective.
	_env.fog_depth_begin = lerpf(clear_depth_begin, interior_visibility * 0.25, t)
	_env.fog_depth_end = lerpf(clear_depth_end, interior_visibility, t)
	_env.fog_density = lerpf(clear_density, interior_density, t)

	var overcast := _overcast_factor(pos_y)
	_sun.light_energy = lerpf(_base_sun_energy, _base_sun_energy * overcast_sun_energy_scale, overcast)
	_sun.light_color = _base_sun_color.lerp(overcast_sun_color, overcast)
	_env.ambient_light_energy = lerpf(_base_ambient_energy, _base_ambient_energy * overcast_ambient_energy_scale, overcast)
