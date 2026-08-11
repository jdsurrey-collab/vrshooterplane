extends Node3D

## Basic laser bolt — travels forward at a fixed speed, checks each frame
## for an enemy-ship, terrain, or building hit, and explodes on impact
## instead of just despawning silently. Despawns quietly if it reaches max
## range/lifetime without hitting anything.
##
## `damage` is consumed by faction_battle.gd's apply_damage() on an alien
## hit — see that script for the mass-battle health/kill design.
##
## ENEMY HIT DETECTION uses a swept segment check (previous frame's position
## to this frame's), not a single point-in-radius test at the current
## position — at 900 m/s a bolt can cover ~10-15m in one physics frame,
## comfortably more than a ship's own size, so a point check alone could
## tunnel straight through it between two sampled frames. Enemy hits are
## checked against faction_battle.gd's alien roster (the 200-ship mass
## battle, see that script) via get_nearest_alive_alien() — the old single
## hardcoded HOSTILE-1 enemy is retired.
##
## `fired_by_player` gates which side a bolt can damage — true (the
## default, and the value weapon_system.gd spawns the player's own bolts
## with) checks only for an enemy hit; false checks only for a player hit.
## Without this split, checking player hits unconditionally would
## self-damage the player on every shot, since a bolt spawns right at its
## own gun mount, well inside the player's own ShipHull bounding radius.
## faction_battle.gd's _fire_at_player() spawns the false case.
##
## SPAWN ORDER: whoever spawns a `fired_by_player = false` bolt must assign
## it BEFORE add_child(), because add_child() runs _ready() immediately and
## that's where the Player/PlayerDamage references get resolved. Getting
## this backwards is exactly why alien laser fire did no damage at all for a
## while. _resolve_player_refs() is also called lazily from
## _check_player_hit() as a belt-and-braces guard against a future caller
## making the same mistake.

@export var speed: float = 600.0  # m/s — down from 900. A bolt that crosses the whole engagement in two frames can't be seen; slower + a much longer mesh (see LaserBolt.tscn) is what makes your own fire readable
## Raised 3.0 -> 3.5s alongside gunnery.gd's range bands: speed*lifetime
## (2100m) must comfortably clear max_range (2000m) below, since the
## lifetime timer and the max_range check are two independent despawn paths
## and the shorter one always wins — a lifetime that clipped max_range would
## make the explicit range check pointless.
@export var lifetime: float = 3.5
## Hard cap on travel distance, independent of speed/lifetime — see
## gunnery.gd's `max_range` (kept in step by hand, same documented coupling
## already used elsewhere in this project, e.g. target_lock.gd's bolt_speed
## comment). Past this the AI's degraded-accuracy dispersion band ends and a
## shot flat-out cannot connect.
@export var max_range: float = 2000.0
@export var damage: float = 10.0  # consumed by enemy_ai.gd's / player_damage.gd's apply_damage()
## Widened 4.0 -> 6.0 to match faction_battle.gd's own BOLT_HIT_RADIUS
## exactly — a fairness correction, not an assist: the player's gun was
## being held to a tighter hit standard than the AI's own gun already enjoys
## against itself.
@export var enemy_hit_radius: float = 6.0
@export var player_hit_radius: float = 4.0  # meters — approximates the player's ShipHull bounding sphere
@export var fired_by_player: bool = true

## Radius override for the PLAYER'S OWN bolts only — see _thin_player_mesh().
## LaserBolt.tscn's baseline (top 0.05 / bottom 0.28) was sized for the
## ambient mass-battle bolts, where hundreds need to read as visible tracers
## from far across the city. Up close, in the player's own cockpit, that
## same radius looked like "big tubes" rather than a laser. Aliens firing at
## the player keep the scene's original thickness — this only reshapes the
## mesh on bolts this script itself confirms came from the player's own gun.
@export var player_bolt_top_radius: float = 0.015
@export var player_bolt_bottom_radius: float = 0.055

var _traveled: float = 0.0
var _max_range: float = 0.0
var _terrain: Node
var _battle: Node
var _tanks: Node  # TankObjective — the ground objective, absent in some scenes
var _player: Node3D
var _player_damage: Node
var _weapon_system: Node  # player-fired bolts only — see _check_enemy_hit


func _ready() -> void:
	# The tighter of the two independent despawn conditions wins — a bolt
	# should never travel further than max_range even if speed*lifetime
	# would technically allow more.
	_max_range = minf(speed * lifetime, max_range)
	get_tree().create_timer(lifetime).timeout.connect(queue_free)
	_terrain = get_tree().current_scene.get_node_or_null("Terrain")
	_battle = get_tree().current_scene.get_node_or_null("FactionBattle")
	_tanks = get_tree().current_scene.get_node_or_null("TankObjective")
	if fired_by_player:
		_thin_player_mesh()
		var player := get_tree().current_scene.get_node_or_null("Player")
		_weapon_system = player.get_node_or_null("WeaponSystem") if player else null
	else:
		_resolve_player_refs()


## Swaps this ONE instance's mesh for a slimmer CylinderMesh, leaving
## LaserBolt.tscn's shared SubResource (still used by every alien-fired
## bolt) completely untouched — a brand new CylinderMesh is created and
## assigned only to this node's MeshInstance3D, not edited in place, so
## there's no risk of the change leaking into other bolts. Height and
## radial_segments are read off the existing mesh rather than duplicated
## here, so the length (already tuned for player-fire visibility/timing)
## can't silently drift out of sync between the two.
##
## The MATERIAL needs the identical treatment now, for a reason the mesh
## swap alone didn't have: laser_bolt.gdshader's hot-core/cool-tail gradient
## reads `top_radius`/`bottom_radius` as UNIFORMS to know where along the
## bolt's length each vertex sits. Thinning only the mesh and leaving those
## uniforms pointing at the old (thicker) dimensions would compute the
## gradient against the wrong radii — and since the material is a shared
## SubResource, mutating those uniforms in place would silently corrupt the
## gradient on every OTHER live bolt using the same material, alien-fired
## ones included. So the material is duplicated here too, the same
## don't-touch-the-shared-resource discipline as the mesh above, and only
## then are its radius uniforms updated to match the new thin geometry.
func _thin_player_mesh() -> void:
	var mesh_instance := get_node_or_null("Mesh") as MeshInstance3D
	if not mesh_instance or not (mesh_instance.mesh is CylinderMesh):
		return
	var base := mesh_instance.mesh as CylinderMesh
	var thin := CylinderMesh.new()
	thin.top_radius = player_bolt_top_radius
	thin.bottom_radius = player_bolt_bottom_radius
	thin.height = base.height
	thin.radial_segments = base.radial_segments
	mesh_instance.mesh = thin

	var base_mat := mesh_instance.get_surface_override_material(0)
	if base_mat is ShaderMaterial:
		var thin_mat: ShaderMaterial = base_mat.duplicate()
		thin_mat.set_shader_parameter("top_radius", player_bolt_top_radius)
		thin_mat.set_shader_parameter("bottom_radius", player_bolt_bottom_radius)
		mesh_instance.set_surface_override_material(0, thin_mat)


func _resolve_player_refs() -> void:
	_player = get_tree().current_scene.get_node_or_null("Player")
	if _player:
		_player_damage = _player.get_node_or_null("PlayerDamage")


func _physics_process(delta: float) -> void:
	var previous_position := global_position
	var step := speed * delta
	translate(Vector3(0.0, 0.0, -step))
	_traveled += step

	if fired_by_player:
		if _check_tank_hit(previous_position):
			queue_free()
			return
		if _check_enemy_hit(previous_position):
			queue_free()
			return
	elif _check_player_hit(previous_position):
		queue_free()
		return

	if _check_ground_or_building_hit():
		CrashEffects.spawn_laser_impact(get_tree().current_scene, global_position)
		queue_free()
		return

	if _traveled >= _max_range:
		queue_free()


## Swept segment-vs-sphere check against the nearest living alien — see the
## class comment for why a single-point check isn't good enough at this
## speed. Only the nearest-to-current-position alien is checked (not every
## alien within the swept segment) — with 200 aliens spread across an
## 8000m-radius dome, the odds of a second alien also being within a few
## meters of this exact segment are negligible, and the player only ever
## has one bolt in flight at a time, so a full spatial-grid lookup (as
## faction_battle.gd uses internally for its own hundreds of ambient bolts)
## would be unneeded overhead here.
func _check_enemy_hit(previous_position: Vector3) -> bool:
	if not _battle:
		return false

	var index: int = _battle.get_nearest_alive_alien(global_position)
	if index < 0:
		return false

	var target_pos: Vector3 = _battle.get_alien_position(index)
	var closest := _closest_point_on_segment(target_pos, previous_position, global_position)
	if closest.distance_to(target_pos) > enemy_hit_radius:
		return false

	_battle.apply_damage(index, damage)

	# HIT CONFIRMATION — the whole reason this project's own gunnery felt
	# like a simulator rather than a game: apply_damage() used to be the
	# entire hit path, so a hit that didn't kill was visually and audibly
	# IDENTICAL to a miss. Every reference game (Ace Combat, Squadrons, CoD)
	# confirms every landed hit, kill or not — that confirmation is what this
	# adds, via weapon_system.gd's cockpit audio/reticle pulse.
	#
	# The SPARK specifically is reserved for a hit the target SURVIVES,
	# matching the exact convention already established for AI-vs-AI ambient
	# bolts in _check_ambient_bolt_hit() — a kill already spawns the much
	# bigger 200m explosion orb at the same spot, so a spark on top of that
	# would be redundant.
	if _weapon_system:
		_weapon_system.notify_hit()
	if _battle.is_alive(index):
		_battle.spawn_hit_spark(closest)

	return true


## Ground objective: the city's fuel tanks (tank_objective.gd). Checked
## BEFORE the alien test in _physics_process — a tank sits on the ground with
## a much larger body than a fighter, so if a bolt is inside one it should
## detonate there rather than continue toward whatever ship happened to be
## flying overhead.
##
## The faction gate lives in tank_objective.can_be_damaged_by(): tanks belong
## to the DEFENDING side, so this only ever connects when the player is the
## attacker that match. A defending player shooting their own tanks does
## nothing, which is the correct behaviour rather than an oversight.
func _check_tank_hit(previous_position: Vector3) -> bool:
	if _tanks == null or not _tanks.can_be_damaged_by(Combatant.Faction.FRIENDLY):
		return false
	var index: int = _tanks.check_hit(previous_position, global_position)
	if index < 0:
		return false
	_tanks.apply_damage(index, damage, "destroyed by PLAYER")
	CrashEffects.spawn_laser_impact(get_tree().current_scene, global_position)
	return true


## Mirror of _check_enemy_hit() for the player's own ship — see
## player_damage.gd for the zone/health design.
func _check_player_hit(previous_position: Vector3) -> bool:
	if not _player or not _player_damage:
		# Lazy recovery for a caller that set fired_by_player after
		# add_child() — see the class comment.
		_resolve_player_refs()
		if not _player or not _player_damage:
			return false

	var closest := _closest_point_on_segment(_player.global_position, previous_position, global_position)
	if closest.distance_to(_player.global_position) > player_hit_radius:
		return false

	var zone: String = _player_damage.classify_hit_zone(closest)
	_player_damage.apply_damage(damage, zone)
	return true


func _check_ground_or_building_hit() -> bool:
	if _terrain:
		var ground_height: float = _terrain.get_height_at(global_position.x, global_position.z)
		if global_position.y <= ground_height:
			return true

	return CrashEffects.check_building_collision(get_world_3d().direct_space_state, global_position)


func _closest_point_on_segment(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return a
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t
