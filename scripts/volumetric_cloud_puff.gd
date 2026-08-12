class_name VolumetricCloudPuff
extends MeshInstance3D

## A single genuinely VOLUMETRIC cloud formation, using
## `addons/texture3d_visualizer`'s raymarched sampler3D shader — a real
## ray-through-a-3D-texture renderer, not the mesh-based CloudDeck/CloudTop
## trick the rest of this project's clouds use.
##
## NOT A CLOUDDECK REPLACEMENT. CloudDeck/CloudTop cover the ENTIRE ~110km
## map as flat-ish meshes specifically because that's affordable at that
## scale; raymarching a volume that size, filling most of the screen while
## flying through it, is exactly the cost this project's whole
## performance-audit history has fought. This is instead a small, BOUNDED
## pool of individually-placed "hero" formations — genuinely fly-through-able
## 3D cloud puffs layered on top of the cheap full-map systems, the same
## budgeted-spectacle philosophy already used for flak bursts and crash
## sites. See `VolumetricClouds` in Town.tscn for the actual placement.
##
## WHY THIS ADDON, SPECIFICALLY, AFTER GODOT'S OWN VOLUMETRIC FOG WAS
## REJECTED THREE TIMES (see CLAUDE.md's "Volumetric fog is deliberately not
## used" section): the built-in system's three killers were temporal-
## reprojection jitter, a range limited to `volumetric_fog_length` of the
## camera, and a fixed froxel-grid cost paid every frame regardless of what
## was visible. This raymarcher has none of those structurally — no
## reprojection to jitter, the volume is just a box placed anywhere at any
## size, and cost is bound by the 3D texture's resolution and how much
## screen the box covers, not a fixed enormous grid.
##
## THE DENSITY TEXTURE IS BUILT AT RUNTIME, NOT A SAVED ASSET — a real
## blocker found during implementation, not a stylistic choice.
## `ImageTexture3D.create()` works correctly (confirmed: right dimensions,
## round-trips cleanly through a ShaderMaterial), but `ResourceSaver.save()`
## on it produces an empty resource stub (`_get_images()` returns nothing
## when the saver tries to serialize the pixel data back out) — so the
## established "generate once with a --headless script, save the asset"
## pattern this project uses for soft_particle.png/missile_lock.tres simply
## doesn't have a working path for this particular resource type in this
## Godot version. Building it once at runtime instead is not a workaround so
## much as this project's OTHER established precedent for procedural
## textures — `cloud_deck.gd`'s own `_build_cloud_texture()` already builds
## its `NoiseTexture2D` the exact same way, every time the game runs, rather
## than as a pre-saved asset.
##
## SHARED, NOT PER-INSTANCE. The NxNxN generation is real CPU work (~48^3
## voxels), and every puff in the pool uses the identical shape/noise
## pattern, so it is built ONCE into a class-level static cache the first
## time any instance needs it, and every subsequent puff (and any instance
## created later, e.g. if the pool grows) reads the same cached texture
## rather than repeating the generation.

const VISUALIZER_SHADER := preload("res://addons/texture3d_visualizer/visualizer.gdshader")

## Full side length of the cube, in metres — this world runs ~100x a normal
## Godot scene (see CLAUDE.md's History section), so this needs to be large
## to read as a real formation; several hundred metres is the same scale as
## everything else out here.
@export var puff_size: float = 700.0

## Beyond this the MeshInstance3D is hidden entirely — costs nothing when
## nobody is near it, the same "nothing renders beyond X" convention already
## used for explosion_cull_range/spark_range.
@export var cull_range: float = 20000.0

## Voxels per axis of the shared density texture. This is the real
## quality/cost dial: visualizer.gdshader's own raymarch step count is
## derived from the texture's resolution in texture-space units, so a
## coarser texture directly means fewer ray steps per covered pixel.
@export var volume_resolution: int = 48

static var _shared_texture: ImageTexture3D
static var _shared_resolution: int = -1

var _player: Node3D


func _ready() -> void:
	_player = get_tree().current_scene.get_node_or_null("Player")

	mesh = BoxMesh.new()
	mesh.size = Vector3(puff_size, puff_size, puff_size)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := ShaderMaterial.new()
	mat.shader = VISUALIZER_SHADER
	mat.set_shader_parameter("tex", _get_shared_texture(volume_resolution))
	# Must match the BoxMesh's own size exactly — visualizer.gdshader's own
	# doc comment is explicit this "must be set manually, cannot be
	# inferred," so it's read from the same puff_size the mesh itself used
	# rather than a second, separately-tunable number that could drift.
	mat.set_shader_parameter("model_size", Vector3(puff_size, puff_size, puff_size))
	mat.set_shader_parameter("translation", 0)  # XYZ — our texture's axes already match model space directly
	mat.set_shader_parameter("lod_bias", 0.0)
	material_override = mat


func _process(_delta: float) -> void:
	if not _player:
		return
	visible = global_position.distance_to(_player.global_position) <= cull_range


## Returns the shared density texture, building it once per resolution.
## Class-level (static) rather than per-instance — see the class comment.
static func _get_shared_texture(resolution: int) -> ImageTexture3D:
	if _shared_texture == null or _shared_resolution != resolution:
		_shared_texture = _build_density_texture(resolution)
		_shared_resolution = resolution
	return _shared_texture


## Builds an NxNxN RGBA volume. Alpha carries density: a radial envelope
## gives the raymarched BOX a rounded, non-cube silhouette (the shader does
## no edge softening of its own, so this has to live in the texture), and
## 3D fBm noise on top gives real internal puffy/cauliflower structure — the
## same "keep the base noise frequency low to avoid a lace/spider-web look"
## lesson `cloud_deck.gd`'s own 2D version already documents, ported to 3D.
static func _build_density_texture(n: int) -> ImageTexture3D:
	var noise := FastNoiseLite.new()
	noise.seed = 1
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.06
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.45

	var images: Array[Image] = []
	for z in n:
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		var nz := (float(z) / float(n - 1)) * 2.0 - 1.0
		for y in n:
			var ny := (float(y) / float(n - 1)) * 2.0 - 1.0
			for x in n:
				var nx := (float(x) / float(n - 1)) * 2.0 - 1.0
				var radial := Vector3(nx, ny, nz).length()
				var envelope: float = 1.0 - smoothstep(0.55, 1.0, radial)
				var raw: float = noise.get_noise_3d(nx * 40.0, ny * 40.0, nz * 40.0)
				var density_noise: float = clampf((raw + 1.0) * 0.5, 0.0, 1.0)
				var density: float = clampf(envelope * (0.3 + 0.7 * density_noise), 0.0, 1.0)
				img.set_pixel(x, y, Color(0.92, 0.94, 0.98, density))
		images.append(img)

	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGBA8, n, n, n, false, images)
	return tex
