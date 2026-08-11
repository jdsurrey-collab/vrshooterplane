extends MeshInstance3D

## Missile smoke trail, built as a CONTINUOUS RIBBON MESH rather than a
## particle system. At 400 m/s the missile body is off-screen almost
## immediately, so the trail is the thing that actually lets you see and track
## a shot you just fired.
##
## WHY THIS IS NOT PARTICLES ANY MORE
##
## It used to be a GPUParticles3D emitting textured billboard quads, and it
## was reported from the headset as looking "like complete trash... a
## pixelated cloud... if you get close you can see they look like shapes of
## smoke, but we're just doing hundreds of pictures of pictures of smoke."
##
## That is an exact description of the technique's own ceiling, not a tuning
## problem. A particle trail IS a row of discrete camera-facing sprites: get
## close enough, or look along it, and you see the individual quads and the
## repeated texture, because that is literally what is on screen. Every dial
## available — count, size, opacity, a better flipbook, continuous animation —
## had already been turned, and the previous pass turned several of them; none
## of them can stop a sprite from being a sprite.
##
## A ribbon is a single connected surface swept along the missile's actual
## flight path. There is no sprite to recognise, nothing to repeat, and
## nothing to look "stamped" — the shape comes from the path, and the softness
## comes from the material. It is also the technique real games use for this
## exact effect.
##
## THE SHAPE. Every frame the missile's position is appended to a point list
## (only once it has moved `min_point_spacing`, which bounds the point count
## regardless of frame rate). Each point becomes a three-vertex cross-section
## — left edge, centre, right edge — where the two outer vertices carry ZERO
## alpha and the centre carries full. That is what gives a soft feathered edge
## across the width with no texture involved at all.
##
## CROSSED RIBBONS, and this is not a refinement — a single ribbon is broken.
## The obvious construction orients each cross-section perpendicular to both
## the flight direction and the direction to the camera, so it always turns
## its face to the viewer. That degenerates exactly when the missile is flying
## directly away from you: the flight direction and the view direction become
## colinear, their cross product is the zero vector, and the ribbon collapses
## to nothing. Which is a problem, because "fired straight ahead, watching it
## fly away" is the single most common way the player will ever see their own
## missile. (A headless test caught this by flying the test missile straight
## down the camera axis and getting an empty mesh.)
##
## Instead TWO ribbons are built at 90 degrees to each other around the flight
## axis, like an X in cross-section, oriented from a stable world reference
## rather than from the camera. No view angle can make both edge-on, so the
## trail always has visible cross-section; it never degenerates; and because
## the frame is world-stable rather than camera-derived it cannot swim or
## shimmer as the player turns their head — which matters more in VR than
## anywhere else. Each ribbon runs at reduced alpha so the crossing does not
## read as a bright seam down the middle.
##
## The ribbon WIDENS and FADES with age, which is what reads as smoke
## dissipating: it leaves the nozzle tight and bright and spreads into a
## broad, dim, grey band behind.
##
## GLOW, NOT A TEXTURE. The material is unshaded with emission pushed above
## 1.0, so Town.tscn's existing Glow pass blooms it — the same trick this
## project already uses for its HUD text and tracer bolts. Bloom is what makes
## the streak read as hot exhaust rather than a flat grey polygon, and it
## softens the silhouette for free.
##
## FILLRATE. The old emitter measured 14.7x the entire per-eye screen in alpha
## blending for ONE missile at its worst, and ~1.7x after the previous pass
## cut it. A ribbon of the same 1800m length averages roughly 22m wide instead
## of 100 overlapping 47m puffs, with no per-particle overdraw stacking, which
## is several times cheaper again — and it is one draw call of ~500 triangles.
##
## STILL NOT A CHILD OF THE MISSILE, for the same two reasons as before: the
## geometry is built in WORLD space so it stays where it was laid down, and a
## missile queue_free()s the instant it hits something — freeing the emitter
## would take the whole existing trail with it and pop a kilometre of smoke
## out of the sky in one frame. It lives at scene level and merely FOLLOWS.
##
## Set `follow` to the missile immediately after instantiating.

## How long a section of trail survives after being laid down.
@export var trail_lifetime: float = 4.5

## Minimum distance the missile must travel before a new cross-section is
## added. This — not the frame rate — is what bounds the vertex count, so the
## trail costs the same on a 45fps frame as a 90fps one.
@export var min_point_spacing: float = 10.0

## Hard cap on cross-sections. At 400 m/s over `trail_lifetime` the trail is
## ~1800m long, which is ~180 sections at the default spacing; the cap is
## headroom above that rather than a limit normally reached.
@export var max_points: int = 256

## Ribbon half-width in metres at the nozzle and at the dissipated tail.
@export var head_width: float = 2.5
@export var tail_width: float = 22.0

## Scales both widths. flak_missile.gd turns this down for its purely
## cosmetic SAMs — several are in the air at once and they are kilometres
## away, so they do not need the player's own weapon's presence.
@export var width_scale: float = 1.0

@export var head_color: Color = Color(1.0, 0.97, 0.92)
@export var tail_color: Color = Color(0.62, 0.63, 0.68)

## Pushed above 1.0 so the Glow pass blooms the hot end of the streak.
@export var head_energy: float = 2.4
## Per-ribbon peak alpha. Below 1.0 because the two crossed ribbons overlap
## along the centreline — at full alpha each, that crossing reads as a bright
## seam running down the middle of the trail instead of a soft column.
@export var max_alpha: float = 0.62

var follow: Node3D

# Each entry: {"pos": Vector3, "age": float}
var _points: Array[Dictionary] = []
var _mesh: ImmediateMesh
var _released: bool = false


func _ready() -> void:
	_mesh = ImmediateMesh.new()
	mesh = _mesh
	# The ribbon is built from absolute WORLD coordinates, so the node must
	# contribute no transform of its own — top_level makes that true no matter
	# what it gets parented to.
	top_level = true
	global_transform = Transform3D.IDENTITY
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	material_override = _build_material()


func _build_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	# Visible from both sides — a ribbon is a flat surface and the player can
	# fly around and past their own shot.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Transparent geometry that writes depth would occlude the rest of its own
	# ribbon wherever it crosses itself during a hard turn.
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.95, 0.9)
	mat.emission_energy_multiplier = head_energy
	# Emission is modulated per-vertex by the albedo colour, so the tail's
	# grey, low-alpha end does not bloom the way the hot head does.
	mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	return mat


func _process(delta: float) -> void:
	for p in _points:
		p["age"] = float(p["age"]) + delta

	# Points expire from the TAIL, which is the oldest end. Walking from the
	# front and removing while iterating would be wrong here.
	while not _points.is_empty() and float(_points[0]["age"]) > trail_lifetime:
		_points.remove_at(0)

	if is_instance_valid(follow):
		var here := follow.global_position
		if _points.is_empty() or here.distance_to(_points[-1]["pos"] as Vector3) >= min_point_spacing:
			_points.append({"pos": here, "age": 0.0})
			if _points.size() > max_points:
				_points.remove_at(0)
	elif not _released:
		# The missile is gone — stop extending, let what is in the air fade.
		_released = true

	if _points.size() < 2:
		_mesh.clear_surfaces()
		if _released and _points.is_empty():
			queue_free()
		return

	_rebuild()


## Rebuilds both ribbons. Runs every frame because the colours and widths are
## age-driven and every section ages continuously — which is also why this is
## an ImmediateMesh rather than a static ArrayMesh built once.
func _rebuild() -> void:
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	var emitted := 0
	var count := _points.size()
	for i in range(count - 1):
		var a: Dictionary = _points[i]
		var b: Dictionary = _points[i + 1]
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]

		var seg := pb - pa
		if seg.length_squared() < 0.0001:
			continue
		var dir := seg.normalized()

		# Stable world reference, swapped only when the flight direction is
		# near-vertical — the same guard used throughout this project for
		# Basis.looking_at()'s up vector, and for the same reason.
		var ref := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var u := dir.cross(ref).normalized()
		var v := dir.cross(u).normalized()

		var wa := _width_at(float(a["age"]))
		var wb := _width_at(float(b["age"]))
		var ca := _color_at(float(a["age"]))
		var cb := _color_at(float(b["age"]))

		_ribbon_segment(pa, pb, u, wa, wb, ca, cb)
		_ribbon_segment(pa, pb, v, wa, wb, ca, cb)
		emitted += 1

	_mesh.surface_end()

	# ImmediateMesh errors rather than no-ops if a surface is ended empty, so
	# a run of degenerate segments has to drop the surface entirely.
	if emitted == 0:
		_mesh.clear_surfaces()


## One flat ribbon across `side`: transparent outer edge -> opaque centre ->
## transparent outer edge. The soft edge is vertex alpha, not a texture.
func _ribbon_segment(pa: Vector3, pb: Vector3, side: Vector3,
		wa: float, wb: float, ca: Color, cb: Color) -> void:
	var edge_a := Color(ca.r, ca.g, ca.b, 0.0)
	var edge_b := Color(cb.r, cb.g, cb.b, 0.0)
	_quad(pa - side * wa, pa, pb, pb - side * wb, edge_a, ca, cb, edge_b)
	_quad(pa, pa + side * wa, pb + side * wb, pb, ca, edge_a, edge_b, cb)


func _quad(v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3,
		c0: Color, c1: Color, c2: Color, c3: Color) -> void:
	_mesh.surface_set_color(c0)
	_mesh.surface_add_vertex(v0)
	_mesh.surface_set_color(c1)
	_mesh.surface_add_vertex(v1)
	_mesh.surface_set_color(c2)
	_mesh.surface_add_vertex(v2)

	_mesh.surface_set_color(c0)
	_mesh.surface_add_vertex(v0)
	_mesh.surface_set_color(c2)
	_mesh.surface_add_vertex(v2)
	_mesh.surface_set_color(c3)
	_mesh.surface_add_vertex(v3)


func _width_at(age: float) -> float:
	var t: float = clampf(age / maxf(trail_lifetime, 0.001), 0.0, 1.0)
	# sqrt so the plume flares quickly just behind the nozzle and then widens
	# slowly, which is how an expanding exhaust column actually behaves —
	# a linear ramp reads as a straight-edged wedge.
	return lerpf(head_width, tail_width, sqrt(t)) * width_scale


func _color_at(age: float) -> Color:
	var t: float = clampf(age / maxf(trail_lifetime, 0.001), 0.0, 1.0)
	var col := head_color.lerp(tail_color, clampf(t * 2.0, 0.0, 1.0))
	# Hold full opacity briefly so the trail is solid right behind the
	# missile, then fade out over the remaining life.
	var alpha: float = max_alpha * (1.0 - smoothstep(0.15, 1.0, t))
	return Color(col.r, col.g, col.b, alpha)
