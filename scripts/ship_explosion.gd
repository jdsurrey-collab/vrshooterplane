extends Node3D

## Big, dramatic kill effect for faction_battle.gd's mass-battle deaths —
## distinct from the small, per-shot LaserImpactEffect (laser_impact_effect.gd):
## a bright expanding flash plus a short high-energy OmniLight3D pulse (so
## it actually reads as visible from a real distance across the city — at
## city scale, a light source carries much farther than any particle's
## real-world size, which becomes sub-pixel within a few hundred meters)
## plus a taller, longer-lived rising smoke column.
##
## Still self-cleaning (queue_free()s itself after LIFETIME), unlike
## CrashEffects.spawn()'s deliberately PERMANENT player-crash effect — kill
## volume across a full-scale battle would pile up permanent effects fast
## otherwise, the same reasoning that keeps spawn_laser_impact() temporary.
##
## `enable_light` is faction_battle.gd's distance LOD: the OmniLight3D is by
## far the most expensive part of this effect, and once the AI actually
## fights, kills are constant. Beyond explosion_light_range the fireball
## still spawns (particles read fine at range) but without its light. NOTE
## it must be assigned BEFORE add_child(), since add_child() runs _ready()
## immediately — see faction_battle.gd's header for the bug that taught this
## project that lesson the hard way.

const LIFETIME := 14.0
const LIGHT_FADE_DURATION := 0.6

## Set by the spawner before add_child(). See the class comment.
var enable_light: bool = true

var _light_fade_time := 0.0
var _light_base_energy := 0.0
var _light: OmniLight3D


func _ready() -> void:
	_light = get_node_or_null("FireballLight")
	if _light:
		if enable_light:
			_light_base_energy = _light.light_energy
		else:
			_light.visible = false
			_light = null
	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)


func _process(delta: float) -> void:
	if not _light:
		set_process(false)
		return
	_light_fade_time += delta
	var f := clampf(1.0 - _light_fade_time / LIGHT_FADE_DURATION, 0.0, 1.0)
	_light.light_energy = _light_base_energy * f
	if f <= 0.0:
		_light.visible = false
		set_process(false)
