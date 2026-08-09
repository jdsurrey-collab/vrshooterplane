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
## volume across a 400-ship battle would pile up permanent effects fast
## otherwise, the same reasoning that keeps spawn_laser_impact() temporary.

const LIFETIME := 14.0
const LIGHT_FADE_DURATION := 0.6

var _light_fade_time := 0.0
var _light_base_energy := 0.0
var _light: OmniLight3D


func _ready() -> void:
	_light = get_node_or_null("FireballLight")
	if _light:
		_light_base_energy = _light.light_energy
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
