extends Node3D

## Stationary capital ship — one per faction, hovering at that faction's
## spawn point 10km out from the city. This is where every ship in the
## fleet (and, for the friendly side, the player) starts the match: they sit
## parked on the deck and launch off the top of it in waves when the match
## begins, and dead ships respawn back onto it.
##
## SOURCE ASSET: `mothership/3d-model.obj` at the project root, a 932k-
## triangle 3ds Max export with no usable .mtl (its materials are
## placeholder "wire_*" names) and no textures. It was decimated to ~124k
## triangles and converted to glTF via a one-off headless Blender script —
## two of these are on screen in VR stereo on top of a 1200-building city
## and 200 ships, and this project has an unresolved frame-rate problem, so
## shipping a million-triangle hero asset unmodified was never an option.
##
## NORMALISED GEOMETRY. The conversion recentred and rescaled the mesh so
## the numbers here are readable rather than magic: the origin sits at the
## centre of the footprint with Y=0 at the underside, and the longest axis
## is exactly 1.0. That means `length` IS the ship's length in meters and
## everything else is a fixed ratio of it (verified against the imported
## mesh's own AABB in Godot, not assumed from the exporter).

## Measured from the imported mesh's AABB: size (0.665, 0.205, 1.0) with
## position.y == 0. Update these together with the asset if it's ever
## re-exported.
const WIDTH_RATIO := 0.6653
const DECK_TOP_RATIO := 0.2054

## Ships park within this fraction of the deck's half-extents, so they sit
## on the deck rather than hanging off its edges.
const DECK_USABLE_X := 0.62
const DECK_USABLE_Z := 0.80

@export var length: float = 2000.0:
	set(value):
		length = value
		_apply_scale()

## Faction tint, applied as a material_override over all 10 of the mesh's
## surfaces — the same approach faction_battle.gd uses to tell the two
## fleets apart, and necessary here anyway since the asset shipped without
## materials.
@export var tint: Color = Color(0.35, 0.6, 0.95):
	set(value):
		tint = value
		_apply_material()

## The three drone layers, longest-wavelength first. See _start_drone().
const DRONE_LAYERS := ["DroneLow", "DroneMid", "DroneAir"]

var _mesh_instance: MeshInstance3D


func _ready() -> void:
	_mesh_instance = _find_mesh_instance(self)
	_apply_scale()
	_apply_material()
	_start_drone()


## Low engine drone, built from three user-supplied turbine recordings
## rather than one.
##
## They are deliberately kept as three simultaneous looping layers instead
## of being pre-mixed into a single file, because their processed lengths
## are 49.9s, 87.6s and 180s — mutually indivisible, so the combination
## doesn't audibly repeat for hours. A single pre-mixed loop would repeat on
## a fixed cycle, which is very noticeable on a constant ambient bed that
## the player parks on top of at the start of every match.
##
## Each layer was ffmpeg-processed into its own frequency band so they stack
## rather than compete: a pitched-down sub bed (lowpass 210Hz), a mid drone
## (45-620Hz), and a quiet machinery texture on top (130-1500Hz). All three
## are MONO on purpose — Godot's AudioStreamPlayer3D can only position a
## mono source correctly, and a stereo source would smear across the whole
## soundstage instead of coming from the ship.
##
## Looping is set here in code rather than in the import settings so it's
## visible where it matters; the streams are shared resources, so this
## applies to both motherships.
func _start_drone() -> void:
	for layer_name in DRONE_LAYERS:
		var player := get_node_or_null(layer_name) as AudioStreamPlayer3D
		if not player or not player.stream:
			continue
		if "loop" in player.stream:
			player.stream.loop = true
		# Stagger the start so the two motherships (and the layers within
		# each) don't phase-lock into an artificial-sounding beat.
		player.play(randf() * 10.0)


func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_mesh_instance(child)
		if found:
			return found
	return null


func _apply_scale() -> void:
	scale = Vector3(length, length, length)


func _apply_material() -> void:
	if not _mesh_instance:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint.lerp(Color(0.55, 0.57, 0.62), 0.55)
	mat.metallic = 0.65
	mat.roughness = 0.42
	mat.emission_enabled = true
	mat.emission = tint
	# Very low — this is a lit hull, not a glowing one. It exists so the
	# silhouette still reads as friendly/hostile from kilometres away, where
	# the diffuse shading has fallen off to nothing.
	mat.emission_energy_multiplier = 0.25
	_mesh_instance.material_override = mat


## World-space Y of the flight deck's top surface — what ships and the
## player are parked on.
func deck_y() -> float:
	return global_position.y + DECK_TOP_RATIO * length


## A random parking spot on the deck, in world space.
func random_deck_point() -> Vector3:
	var half_x := WIDTH_RATIO * length * 0.5 * DECK_USABLE_X
	var half_z := length * 0.5 * DECK_USABLE_Z
	return Vector3(
			global_position.x + randf_range(-half_x, half_x),
			deck_y(),
			global_position.z + randf_range(-half_z, half_z))


## Deck spot for a specific squad, spread deterministically down the length
## of the deck rather than randomly, so squads park in tidy rows and launch
## in a readable order instead of a scramble.
func squad_deck_point(squad_index: int, squad_count: int) -> Vector3:
	var half_x := WIDTH_RATIO * length * 0.5 * DECK_USABLE_X
	var half_z := length * 0.5 * DECK_USABLE_Z
	# Alternate sides of the centreline, stepping aft as the index grows.
	var side := 1.0 if (squad_index % 2) == 0 else -1.0
	var row := float(squad_index / 2)
	var rows := maxf(float((squad_count + 1) / 2), 1.0)
	var z := lerpf(half_z, -half_z, clampf(row / rows, 0.0, 1.0))
	return Vector3(
			global_position.x + side * half_x * randf_range(0.35, 0.9),
			deck_y(),
			global_position.z + z)
