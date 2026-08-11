extends Node3D

## Kill effect for faction_battle.gd's mass-battle deaths (and, reusing the
## same scene, tank_objective.gd's fuel-tank detonations): a big glowing ORB
## that flashes out and fades, plus a short high-energy OmniLight3D pulse.
##
## MESH, NOT PARTICLES — replaced on direct request: "move away from a
## particle explosion on ships being destroyed and move more into a mesh
## style flash of a big, glowing orb", at "around two hundred meters big in
## diameter".
##
## The particle version had a real weakness at this game's scale that the orb
## fixes for free. A particle fireball is a cloud of individually small quads,
## and their apparent size falls off with distance exactly like everything
## else — so the effect that is supposed to announce a kill across a whole
## battle was made of pieces that went sub-pixel within a few hundred metres,
## which is the same arithmetic that made distant tracers invisible (see
## faction_battle.gd's _bolt_transform). A single 200m sphere is one coherent
## shape: at 3km it still subtends nearly 4 degrees, so it reads as a
## fireball from clear across the dome instead of dissolving into speckle.
##
## TWO LAYERS, because one is flat. A hot near-white CORE punches out fast
## and dies fast; a larger orange SHELL expands behind it and lingers a little
## longer. The offset in both timing and colour is what gives the flash a
## sense of the fireball cooling as it grows, rather than a single ball
## uniformly dimming.
##
## Both are additive and use Assets/Shaders/explosion_orb.gdshader, whose
## view-facing density falloff is what stops a sphere reading as a flat disc —
## see that file. Colours are pushed above 1.0 so Town.tscn's Glow pass blooms
## them, which is most of what sells the heat.
##
## NO SMOKE. The previous version left a 12-second rising smoke column, which
## both fought the "nothing is persistent" rule and meant every kill in a
## 200-ship battle added a long-lived alpha-blended plume. The orb is the
## whole effect now.
##
## `enable_light` is faction_battle.gd's distance LOD: the OmniLight3D is by
## far the most expensive part of this effect and kills are constant once the
## AI is actually fighting, so beyond `explosion_light_range` the orb still
## spawns but without its light. It MUST be assigned BEFORE add_child(), since
## add_child() runs _ready() immediately — see faction_battle.gd's header for
## the bug that taught this project that lesson.
##
## OMNI_RANGE: 700m, cut hard from an original 6000m (energy 60 -> 22 to
## compensate for the much shorter falloff). Forward+ is a CLUSTERED renderer:
## a light is binned into every cluster of the view frustum its radius
## touches, and every fragment in those clusters then evaluates it. A 6km
## radius from anywhere near the fighting covered essentially the whole
## frustum, so each one was effectively a full-screen light — with up to 14
## live at once, over a city of 1400+ buildings, in stereo. Omni attenuation
## means 6000m contributed almost nothing visible past a few hundred metres
## anyway, so nearly all of that cost bought light too dim to see.

## Radius of the full-size shell, in metres — 100 gives the requested ~200m
## diameter. The meshes are unit spheres scaled by this, so it is the single
## dial for how big a kill reads.
@export var orb_radius: float = 100.0

## Fraction of `orb_radius` each layer starts and ends at. The core stays
## well inside the shell so it reads as a hot centre rather than a second
## surface fighting it for the same silhouette.
const CORE_START := 0.12
const CORE_END := 0.52
const SHELL_START := 0.22
const SHELL_END := 1.0

## The core is a punch; the shell is the fireball it leaves behind.
const CORE_DURATION := 0.30
const SHELL_DURATION := 0.85
const LIGHT_FADE_DURATION := 0.5

## Safety net only — the flash drives its own removal once every layer has
## finished. Comfortably longer than SHELL_DURATION.
const LIFETIME := 2.5

## Set by the spawner before add_child(). See the class comment.
var enable_light: bool = true

var _t := 0.0
var _light: OmniLight3D
var _light_base_energy := 0.0
var _core: MeshInstance3D
var _shell: MeshInstance3D
var _core_mat: ShaderMaterial
var _shell_mat: ShaderMaterial


func _ready() -> void:
	_core = get_node_or_null("Core")
	_shell = get_node_or_null("Shell")
	# Materials are duplicated per instance: several explosions are alive at
	# once and each drives its own `fade`, so sharing the scene's material
	# would make every live orb fade on whichever one updated last.
	if _core:
		_core_mat = (_core.get_surface_override_material(0) as ShaderMaterial).duplicate()
		_core.set_surface_override_material(0, _core_mat)
	if _shell:
		_shell_mat = (_shell.get_surface_override_material(0) as ShaderMaterial).duplicate()
		_shell.set_surface_override_material(0, _shell_mat)

	_light = get_node_or_null("FireballLight")
	if _light:
		if enable_light:
			_light_base_energy = _light.light_energy
		else:
			_light.visible = false
			_light = null

	# Apply frame-zero state immediately rather than waiting for the first
	# _process — otherwise the orb pops in at its authored unit size (a 1m
	# ball) for one frame before the first update scales it.
	_apply(0.0)
	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)


func _process(delta: float) -> void:
	_t += delta
	_apply(_t)
	if _t >= SHELL_DURATION:
		queue_free()


func _apply(t: float) -> void:
	if _core_mat:
		var ct: float = clampf(t / CORE_DURATION, 0.0, 1.0)
		_scale_layer(_core, lerpf(CORE_START, CORE_END, _ease_out(ct)))
		# Holds full brightness briefly, then goes — a flash, not a dimmer.
		_core_mat.set_shader_parameter("fade", 1.0 - smoothstep(0.25, 1.0, ct))

	if _shell_mat:
		var st: float = clampf(t / SHELL_DURATION, 0.0, 1.0)
		_scale_layer(_shell, lerpf(SHELL_START, SHELL_END, _ease_out(st)))
		_shell_mat.set_shader_parameter("fade", 1.0 - smoothstep(0.15, 1.0, st))

	if _light:
		var f: float = clampf(1.0 - t / LIGHT_FADE_DURATION, 0.0, 1.0)
		_light.light_energy = _light_base_energy * f
		if f <= 0.0:
			_light.visible = false
			_light = null


func _scale_layer(node: MeshInstance3D, fraction: float) -> void:
	if node == null:
		return
	var r: float = maxf(orb_radius * fraction, 0.001)
	node.scale = Vector3(r, r, r)


## Fast out of the gate, decelerating hard — an explosion's expansion is
## front-loaded, and a linear ramp reads as a balloon inflating.
func _ease_out(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3.0)
