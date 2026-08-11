extends Node

## IN-HEADSET PERFORMANCE PROFILER — writes a log you can hand back for
## analysis. Built because the frame-rate question cannot be answered any
## other way: headless testing genuinely cannot measure GPU fill, draw-call
## cost, or VR stereo render time, so the only real instrument is the running
## game on the actual headset.
##
## TWO MODES, and the difference matters.
##
## PASSIVE just records. That gives CORRELATION — "frames got long while there
## were 9 flak bursts up" — which is weak evidence here, because every suspect
## co-varies: flak, crash sites, missile trails and heavy combat all happen
## over the city at the same time, so they are statistically almost impossible
## to separate by observation alone.
##
## SWEEP switches one suspect off at a time on a timer while you fly normally,
## and tags every frame with which configuration was live. Comparing the same
## suspect on vs off is a real controlled experiment, so the result is CAUSAL.
## This is the mode to use for an actual diagnosis. It WILL look odd — shadows
## and clouds visibly disappear and come back on a timer. That's the tool
## working, not a bug.
##
## WHAT IT COSTS. One `delta` accumulation per frame (free) plus a sample every
## `sample_interval` that walks the scene tree counting particle nodes. The
## walk is the only real cost and it runs 4x a second, not per frame. Leave
## `mode = OFF` for normal play and it does nothing at all.
##
## WHERE THE FILES GO. Godot's `user://` on Windows is
##   %APPDATA%\Godot\app_userdata\JuggyVRGame\
## which resolves to
##   C:\Users\<you>\AppData\Roaming\Godot\app_userdata\JuggyVRGame\
## Two files are written there:
##   perf_summary.txt — the aggregated per-configuration table. This is the
##                      one to read/hand over; it's short.
##   perf_log.csv     — every raw sample, for digging deeper if the summary
##                      is ambiguous.
##
## A REAL LIMITATION, STATED UP FRONT. Godot 4.4 does not expose a GPU frame
## time, so this measures FRAME TIME (wall clock per frame), not GPU time
## directly. That's fine for the question being asked: if switching a suspect
## off makes frames measurably shorter, that suspect was costing you, whatever
## part of the pipeline it was costing you in. `PROC`/`PHYS` are logged
## alongside so CPU-side cost can still be separated out — if frame time is
## long while both of those are small, the time is going to the GPU.

enum Mode { OFF, PASSIVE, SWEEP }

## Configurations the sweep rotates through. BASELINE appears FIRST and is
## re-measured on every cycle rather than once at the start — the scene
## changes constantly as you fly, so a baseline taken once at t=0 would be
## compared against configs measured in completely different conditions.
## Interleaving it means every config has a near-in-time baseline to be
## compared against.
enum Config {
	BASELINE,
	NO_FLAK,
	NO_PARTICLES,
	NO_SHADOWS,
	NO_GLOW,
	NO_CLOUDS,
	SCALE_85,
}

const CONFIG_NAMES := {
	Config.BASELINE: "BASELINE",
	Config.NO_FLAK: "NO_FLAK",
	Config.NO_PARTICLES: "NO_PARTICLES",
	Config.NO_SHADOWS: "NO_SHADOWS",
	Config.NO_GLOW: "NO_GLOW",
	Config.NO_CLOUDS: "NO_CLOUDS",
	Config.SCALE_85: "SCALE_85",
}

@export var mode: Mode = Mode.OFF

## Seconds each configuration is held during a sweep.
@export var sweep_seconds: float = 8.0

## Frames immediately after a switch are discarded — toggling shadows or
## render scale forces shader/texture reallocation that spikes for a moment
## and would otherwise be blamed on the configuration itself.
@export var settle_seconds: float = 1.5

@export var sample_interval: float = 0.25

## A small readout so you can see which configuration is live without leaving
## the headset. Built here rather than added to Player.tscn, the same
## convention target_lock.gd and missile_system.gd already use for their own
## HUD geometry.
@export var show_overlay: bool = true

const LOG_PATH := "user://perf_log.csv"
const SUMMARY_PATH := "user://perf_summary.txt"

## Bounded so a long session can't grow these without limit — 6000 frames at
## 90Hz is over a minute of samples per configuration, far more than needed
## for a stable median.
const MAX_SAMPLES_PER_CONFIG := 6000

var _config: int = Config.BASELINE
var _config_timer: float = 0.0
var _settle_timer: float = 0.0
var _sample_timer: float = 0.0
var _elapsed: float = 0.0
var _cycles: int = 0

# Per-config frame-time samples, in milliseconds.
var _samples: Dictionary = {}

var _rows: PackedStringArray = []
var _overlay: Label3D

var _sun: DirectionalLight3D
var _env: Environment
var _flak: Node3D
var _cloud_deck: Node
var _cloud_top: Node
var _battle: Node
var _player: Node3D
var _flow: Node

var _base_glow: bool = true
var _base_shadow: bool = true
var _base_scale: float = 1.0


func _ready() -> void:
	if mode == Mode.OFF:
		set_process(false)
		return

	_sun = get_node_or_null("../Sun") as DirectionalLight3D
	var we := get_node_or_null("../WorldEnvironment") as WorldEnvironment
	if we:
		_env = we.environment
	_flak = get_node_or_null("../GroundFlak") as Node3D
	_cloud_deck = get_node_or_null("../CloudDeck")
	_cloud_top = get_node_or_null("../CloudTop")
	_battle = get_node_or_null("../FactionBattle")
	_player = get_node_or_null("../Player") as Node3D
	_flow = get_node_or_null("../GameFlow")

	if _sun:
		_base_shadow = _sun.shadow_enabled
	if _env:
		_base_glow = _env.glow_enabled
	_base_scale = get_viewport().scaling_3d_scale

	for c in Config.values():
		_samples[c] = PackedFloat32Array()

	_rows.append("t,config,frame_ms,fps,proc_ms,phys_ms,draw_calls,prims,objects,"
			+ "particle_nodes,particles_emitting,particle_budget,"
			+ "flak_bolts,flak_shells,flak_bursts,flak_missiles,"
			+ "crash_sites,explosions,sparks,ambient_bolts,"
			+ "alt_m,dist_to_city_m,in_cloud_band,vram_mb")

	if show_overlay:
		_build_overlay()

	_apply_config(Config.BASELINE)


func _build_overlay() -> void:
	var cam := get_node_or_null("../Player/XRCamera3D") as Node3D
	if cam == null:
		return
	_overlay = Label3D.new()
	_overlay.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_overlay.no_depth_test = true
	_overlay.fixed_size = true
	_overlay.pixel_size = 0.0007
	_overlay.font_size = 30
	_overlay.outline_size = 8
	_overlay.modulate = Color(2.0, 1.6, 0.2)
	_overlay.position = Vector3(0.0, -0.28, -1.2)
	cam.add_child(_overlay)


func _process(delta: float) -> void:
	_elapsed += delta

	# Frame time is accumulated EVERY frame, not only on sample ticks — a
	# median over every frame in a configuration is a far better statistic
	# than 4 spot readings a second, and it costs one array append.
	if _settle_timer <= 0.0:
		var arr: PackedFloat32Array = _samples[_config]
		if arr.size() < MAX_SAMPLES_PER_CONFIG:
			arr.append(delta * 1000.0)
			_samples[_config] = arr
	else:
		_settle_timer -= delta

	_sample_timer -= delta
	if _sample_timer <= 0.0:
		_sample_timer = sample_interval
		_record_sample(delta)

	if mode == Mode.SWEEP:
		_config_timer -= delta
		if _config_timer <= 0.0:
			_advance_config()

	if _overlay:
		_overlay.text = "%s  %.1f fps\ncycle %d" % [
				CONFIG_NAMES[_config] if mode == Mode.SWEEP else "LOGGING",
				Engine.get_frames_per_second(), _cycles]


func _advance_config() -> void:
	var next: int = _config + 1
	if next > Config.SCALE_85:
		next = Config.BASELINE
		_cycles += 1
		_write_summary()
		_flush_rows()
	_apply_config(next)


## Every configuration is applied from the CAPTURED baseline values rather
## than toggled relative to whatever is currently set — so a missed frame or
## an interrupted sweep can never leave a setting stuck off, and the scene's
## own authored values are always what "on" means.
func _apply_config(c: int) -> void:
	_config = c
	_config_timer = sweep_seconds
	_settle_timer = settle_seconds

	if _sun:
		_sun.shadow_enabled = _base_shadow and c != Config.NO_SHADOWS
	if _env:
		_env.glow_enabled = _base_glow and c != Config.NO_GLOW
	if _flak:
		_flak.visible = c != Config.NO_FLAK
		_flak.set_process(c != Config.NO_FLAK)
	if _cloud_deck:
		_cloud_deck.enabled = c != Config.NO_CLOUDS
	if _cloud_top:
		_cloud_top.enabled = c != Config.NO_CLOUDS
	get_viewport().scaling_3d_scale = 0.85 if c == Config.SCALE_85 else _base_scale

	# Particles are hidden rather than stopped: `emitting = false` would drain
	# existing trails over their lifetime and the effect would fade in slowly
	# over several seconds, smearing the measurement across the settle window
	# and into the next configuration. Hiding removes their fill cost on the
	# very next frame, which is exactly what's being measured.
	var hide_particles := c == Config.NO_PARTICLES
	for p in _all_particles():
		p.visible = not hide_particles


func _all_particles() -> Array:
	var found: Array = []
	_collect_particles(get_tree().current_scene, found)
	return found


func _collect_particles(n: Node, into: Array) -> void:
	if n is GPUParticles3D:
		into.append(n)
	for c in n.get_children():
		_collect_particles(c, into)


func _record_sample(delta: float) -> void:
	var particles := _all_particles()
	var emitting := 0
	var budget := 0
	for p in particles:
		if p.emitting and p.visible:
			emitting += 1
			budget += p.amount

	var alt := 0.0
	var dist := 0.0
	if _player:
		alt = _player.global_position.y
		if _battle:
			dist = _player.global_position.distance_to(_battle.dome_center)

	var in_band := 0
	var atmo := get_node_or_null("../Atmosphere")
	if atmo and "cloud_base_y" in atmo:
		var base: float = atmo.cloud_base_y
		var thick: float = atmo.cloud_thickness
		in_band = 1 if (alt >= base and alt <= base + thick) else 0

	var crash_sites: int = CrashEffects._crash_sites.size()

	var fb := 0
	var fs := 0
	var fbu := 0
	var fm := 0
	if _flak:
		fb = (_flak._bolts as Array).size()
		fs = (_flak._shells as Array).size()
		fbu = _flak._burst_count
		fm = _flak._missile_count

	var expl := 0
	var sparks := 0
	var ambient := 0
	if _battle:
		expl = (_battle._live_explosions as Array).size()
		sparks = (_battle._live_sparks as Array).size()
		ambient = (_battle._ambient_bolts as Array).size()

	_rows.append("%.2f,%s,%.3f,%.1f,%.3f,%.3f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.0f,%.0f,%d,%.1f" % [
			_elapsed,
			CONFIG_NAMES[_config] if mode == Mode.SWEEP else "PASSIVE",
			delta * 1000.0,
			Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
			particles.size(), emitting, budget,
			fb, fs, fbu, fm,
			crash_sites, expl, sparks, ambient,
			alt, dist, in_band,
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])

	if _rows.size() >= 240:
		_flush_rows()


func _flush_rows() -> void:
	if _rows.is_empty():
		return
	var existed := FileAccess.file_exists(LOG_PATH)
	var f := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE if existed else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	for r in _rows:
		f.store_line(r)
	f.close()
	_rows.clear()


## Median and 95th percentile, NOT mean. Frame time is a long-tailed
## distribution — a handful of 200ms hitches (a shader compile, an asset
## stream) drags a mean far enough to hide a real 2ms difference between
## configurations. The median says what a typical frame costs and p95 says
## how bad the stutters are, and those are the two questions worth asking.
func _write_summary() -> void:
	var lines: PackedStringArray = []
	lines.append("PERF SWEEP SUMMARY — %d complete cycle(s), %.0fs elapsed" % [_cycles, _elapsed])
	lines.append("mode=%s  sweep_seconds=%.1f  settle=%.1f" % [
			Mode.keys()[mode], sweep_seconds, settle_seconds])
	lines.append("")
	lines.append("%-14s %8s %8s %8s %8s %9s" % ["CONFIG", "FRAMES", "MED_ms", "P95_ms", "MED_fps", "vs BASE"])

	var base_med := _median(_samples[Config.BASELINE])
	for c in Config.values():
		var arr: PackedFloat32Array = _samples[c]
		if arr.is_empty():
			continue
		var med := _median(arr)
		var p95 := _percentile(arr, 0.95)
		var delta_str := "--"
		if c != Config.BASELINE and base_med > 0.0:
			# NEGATIVE means this configuration was FASTER than baseline, i.e.
			# the thing switched off was costing that many ms a frame.
			delta_str = "%+.2f ms" % (med - base_med)
		lines.append("%-14s %8d %8.2f %8.2f %8.1f %9s" % [
				CONFIG_NAMES[c], arr.size(), med, p95,
				(1000.0 / med) if med > 0.0 else 0.0, delta_str])

	lines.append("")
	lines.append("Read: a NEGATIVE 'vs BASE' means frames got SHORTER with that")
	lines.append("suspect disabled — that is the cost of the suspect. A value")
	lines.append("near 0.00 means it is not what is slowing you down.")

	var f := FileAccess.open(SUMMARY_PATH, FileAccess.WRITE)
	if f:
		for l in lines:
			f.store_line(l)
		f.close()


func _median(arr: PackedFloat32Array) -> float:
	return _percentile(arr, 0.5)


func _percentile(arr: PackedFloat32Array, p: float) -> float:
	if arr.is_empty():
		return 0.0
	var copy := arr.duplicate()
	copy.sort()
	var idx := int(floor(float(copy.size() - 1) * p))
	return copy[idx]


## Restore everything and write a final summary — a sweep left half-applied
## because the session ended would otherwise persist into the next run via
## the scene's own saved state if any of these were ever serialized.
func _exit_tree() -> void:
	if mode == Mode.OFF:
		return
	if _sun:
		_sun.shadow_enabled = _base_shadow
	if _env:
		_env.glow_enabled = _base_glow
	get_viewport().scaling_3d_scale = _base_scale
	_write_summary()
	_flush_rows()
