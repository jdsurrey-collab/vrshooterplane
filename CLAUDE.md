# Vrgame — VR Space Dogfighter (Godot 4)

## Project

A 6DOF VR space shooter: fly a fighter in first person from the cockpit,
over a sprawling sci-fi city contested by a large alien-invasion battle —
two fleets of 1-5 ship squadrons (currently 100 a side, plus the player)
fighting for "Air Superiority" over an invisible dome around the city, see
Faction Battle below. This is a pivot from an earlier "in-VR map editor"
concept (see History) — that system still exists on disk but is disabled,
the same as the single hardcoded HOSTILE-1 enemy the faction battle
replaced (see Retired systems).

Engine: **Godot 4.4.1**, using the **Godot XR Tools** addon
(`addons/godot-xr-tools/`) for the VR player rig and grab system (though
flight uses direct/kinematic movement, not the addon's ground-movement
providers — see Flight below). Headset connects via **Virtual Desktop**
(VDXR OpenXR runtime) — PCVR, not a standalone Quest build. GPU: RTX 3060 Ti.

## Collaboration model

Everything here is plain-text (`.tscn`/`.gd`/`project.godot`), so Claude
writes and wires up scenes/scripts directly.

## Architecture

- `scenes/Town.tscn` — main scene: sky, sun, `Player`, `Terrain`, `City`,
  `FactionBattle` (the 400-ship battle — see below).
- `scenes/Player.tscn` — the XR rig (`XROrigin3D` + `XRCamera3D` + two
  `XRController3D`s, both **direct children of `XROrigin3D`** — required for
  Godot's XR tracking to drive the actual per-eye render pose; nesting the
  camera under an intermediate node silently breaks rendering while
  ordinary child nodes still look correct via normal transform composition,
  which cost real debugging time — see `options_menu.gd`'s header comment
  for the full story). No hand meshes or hand-held laser pointer (removed —
  this is a cockpit game, you don't see your hands). Also holds the ship
  model, gun mounts, crosshair, HUD, options menu, engine audio, target
  lock, and crash handler — see below.
- `ShipHull` — a plain `MeshInstance3D` sibling of `Ship`, the same
  `ship1.obj` mesh the enemy uses (`Assets/EnemyShip/ship1.obj`), at the
  same 2x scale, sharing `Ship`'s translation but otherwise fully
  independent — this is the player's exterior hull, added so the player
  flies "the same ship" as the AI visually. **`Ship` itself (the cockpit
  interior model, its transform, gun mounts, crosshair) was left completely
  untouched** — the two models were never designed to nest together
  (different asset packs, ship1.obj is a flat/low ~0.75m-tall hull vs. the
  cockpit's ~3m of vertical interior geometry), so this is a best-effort
  placeholder placement, not a precise fit, and — like the original cockpit
  placement — will likely need live-in-VR position/scale correction once
  seen in the headset. `options_menu.gd`'s seat-height calibration still
  only moves `Ship` by name, so raising/lowering the seat does not move the
  hull with it (a minor cosmetic gap at the ±1m seat-height extremes, not
  worth entangling the two nodes over). Unlike `Ship`, `ShipHull` carries
  **no rotation**, just uniform 2x scale — `Ship`'s 180°-flip basis exists
  only to correct the cockpit glTF's own backwards-authored forward
  direction, a problem specific to that asset; `ship1.obj` doesn't have it
  (the enemy uses the identical mesh completely unrotated and its
  confirmed-working wander/chase AI depends on local -Z already being
  forward), so copying the flip onto `ShipHull` would have pointed the
  hull's modeled nose backwards.
- `scripts/flight_controller.gd` — inertia-based 6DOF flight, **flight
  assist OFF on every axis, no exceptions**: grip/stick input directly
  commands an acceleration, never a goal to return to. Right grip/left grip
  = forward/reverse thrust; right stick = pitch/yaw; left stick =
  roll/elevation. Velocity is stored in **world space** and reprojected
  into the ship's current local frame each frame only to apply thrust — so
  flipping the ship around and thrusting decelerates existing drift before
  building speed the new way, real Newtonian behavior, with no
  special-casing required.
  **Every axis runs through `OmegaMotion.step_acceleration()`
  (`scripts/omega_motion.gd`) against a shared `ShipFlightProfile` resource
  (`Assets/ShipProfiles/standard_fighter.tres`)** — see
  `docs/omega-flight-model.md` for the full design, condensed from two
  flight-model-design PDFs the user supplied (John Pritchett's X4 "Omega"
  motion doc and his Star Citizen IFCS design doc). Short version: the old
  `move_toward(current, goal, accel*delta)` ramps were 2nd-order motion —
  acceleration snapped instantly to its max the moment a stick was touched,
  and back to zero the moment input released. Omega bounds that:
  acceleration itself ramps smoothly up and down (the jerk limit). **This
  profile is shared with every AI combatant in `faction_battle.gd`** —
  direct answer to "the player's ship should have the same characteristics
  as the AI ship": both draw the same max speeds/accelerations from the
  same resource, not two separately-tuned approximations of each other.
  Pitch, yaw and roll each keep **separate** rotation-rate caps — pitch
  ~25°/s (grounded in real F-16 sustained/peak pitch rate data), roll ~86°/s
  (deliberately well under a real fighter's ~240°/s — fast rotation is its
  own VR-comfort issue independent of realism). **Yaw was originally
  shared with pitch** (one `max_pitch_yaw_speed` inherited from this
  project's pre-Omega flight code) until direct feedback that the two
  "felt identical" and shouldn't — real fighters have distinctly weaker,
  rudder-limited yaw authority, so yaw is now its own tunable, cut to
  ~65% of pitch's rate/accel (`ship_flight_profile.gd`'s "Yaw" group).
  **Pitch is also asymmetric, nose-up vs. nose-down** — nose-down capped
  at `pitch_down_fraction` (70%) of nose-up's rate/accel. Grounded in a
  real IFCS subsystem, "G-force Safety" (thruster output limited by pilot
  g-tolerance), and real g-tolerance genuinely is asymmetric (~+9G pulling
  up vs. only ~-3G pushing over) — NOT "air friction," which was floated
  first and doesn't actually apply here: this ship is a pure RCS-thruster
  craft with an always-active gravity compensator, and `IFCS3_0.pdf`'s own
  atmospheric-flight section is explicit these ships "do not use
  aerodynamic forces to achieve flight." (A real drag-based mechanism DOES
  exist in that same document — center-of-pressure offset from center of
  mass creating a torque — but that's a shape-dependent disturbance bias
  requiring actual hull geometry measurement, a different and bigger
  undertaking than a control-authority scaling; left for later if wanted.)
  70% (not the real ~33%) because the literal ratio reads as extreme
  stacked on this game's already-arcade acceleration scale. Carried over
  into the shared profile; see `docs/flight-physics-reference.md` for the
  F-16/roll grounding.
  **Afterburner — right controller's B (`by_button`, previously unused).**
  Holding it raises the forward speed CEILING by
  `afterburner_speed_bonus` (200 m/s, 300 -> 500) for as long as fuel
  lasts (`afterburner_max_duration`, 10s), recharging over
  `afterburner_recharge_time` (16s, first-pass, not otherwise specified)
  while not held. Does NOT auto-thrust — the pilot still has to hold the
  right grip to actually use the extra headroom, keeping it consistent
  with flight-assist OFF rather than becoming a second kind of assist,
  the same reasoning already applied to reverse thrust and the air brake.
  `flight_hud.gd` gained a second vertical gauge (`BoostTrack`/
  `BoostFill`, hot red-orange, distinct from the thrust gauge's amber)
  showing remaining fuel, positioned further right of the existing thrust
  gauge. A real bug was caught and fixed while touching this code:
  `_apply_air_brake()` still referenced `profile.pitch_yaw_max_accel`,
  deleted by the earlier pitch/yaw split — would have thrown at runtime
  the moment anyone actually held the air brake button, never caught by
  the headless parse gate.
  **Two REAL momentum bugs, found by reproducing a live report.** Reported
  as "if I drift off, I'm not able to recompensate into a different
  direction with boost, and I should be able to." Both were genuine
  physics errors, not missing features:
  - **The speed governor was deleting real momentum on every turn.** A
    naive `clampf(new_value, min_value, max_value)` inside
    `OmegaMotion.step_acceleration()` ran against a single LOCAL axis —
    but turning the ship reprojects EXISTING momentum onto different local
    axes, and the moment a turn moved speed onto a lower-ceilinged axis
    (lateral caps at 100 m/s vs. forward's 300) the clamp silently
    destroyed it. Measured: **300 m/s dropped to 100 m/s in a single
    frame** after a 90° turn with zero thrust input. Fixed by making the
    clamp one-sided — it now only engages while acceleration is actively
    pushing FURTHER past a boundary, so momentum that arrived by
    reprojection is left alone. Momentum retention went from 33% to 99%.
  - **Acceleration was stored in world space and reprojected like
    velocity.** Wrong: velocity is momentum (conserved in world space, must
    survive a turn), but acceleration is engine thrust (body-fixed, must
    turn WITH the ship). Reprojecting it dragged the previous frame's
    thrust direction into the new local frame, which then tripped the
    governor above on whatever axis it landed on. `_linear_accel` is now
    stored in the ship's LOCAL frame; only the engine's spool state
    persists, never a stale direction.
  **Per-axis aerodynamic drag — the real reason velocity settles onto the
  nose.** Straight from `IFCS3_0.pdf`: "Each ship is tuned with a separate
  coefficient for each axial direction to indicate its relative
  performance when moving along each axial direction through atmosphere."
  A fighter is streamlined nose-on and barn-door broadside, so
  `drag_coefficient_lateral`/`_vertical` (0.0025) are ~125x
  `drag_coefficient_forward` (0.00002). This is the airframe's shape doing
  the work, **not an assist** — and it's genuinely load-bearing: with pure
  vacuum physics, thrusting forward while drifting sideways only ever ADDS
  a forward component and never removes the sideways one, leaving the ship
  **permanently diagonal** (measured: locked at a 45° offset forever).
  With it, a 90°-off velocity vector converges to ~10° of the nose within
  6 seconds of thrust (most of that in the first 3), which is the "turn,
  thrust, and within a few seconds you're going that way" behaviour that
  was reported missing. Verified not to break flight-assist-OFF coasting:
  releasing the throttle at 300 m/s still retains **95.6% of speed after
  10 full seconds**. The AI is unaffected (98/97 ships alive at t=150s in
  a 100v100 regression run).
  **No auto-braking, anywhere, ever — corrected live, twice.** The
  original coasting-drag model (a real quadratic air-drag curve on throttle
  release) was replaced first with an assisted brake to a goal velocity of
  zero, which direct playtest feedback immediately flagged as still an
  assist and far too strong ("if I let off the gas I slow down incredibly
  fast, this should not be the case"). The actual, final design has no
  goal-seeking on the player's ship at all: `step_acceleration()` commands
  acceleration directly from input (-1..1 fraction of `max_accel`, jerk-
  smoothed), clamps the resulting velocity/rate to the profile's governor
  (`[min_value, max_value]` — an artificial top-speed ceiling every ship
  has, matching IFCS's own "Speed Regulation," but the clamp only ever
  engages exactly at the ceiling, never pulling the value back down), and
  otherwise never touches velocity. Releasing input idles thrust and
  leaves the ship coasting at whatever velocity/rotation rate it already
  had — true inertia, including sideways drift/skid picked up mid-turn,
  which is left completely alone rather than auto-corrected. **The AI is
  unaffected**: its autopilot is legitimately goal-seeking
  (`OmegaMotion.step_velocity()`/`step_position()`, see the Faction Battle
  section below) because it always has a concrete target speed/heading to
  hold — the split between "player = pure acceleration control" and
  "AI = goal-seeking control" is drawn directly from the reference
  material's own distinction between decoupled pilot input and automated
  ship control. See `docs/omega-flight-model.md`.
  Includes the **gravity compensator standard**: `gravity_compensator_active`
  (default `true`) means gravity is never applied during normal flight;
  flipping it off is the hook for a future "ship shutdown" state.
  **Reverse thrust is a distinct, weaker system from the main drive, not
  the same engine run backwards** — `ShipFlightProfile.reverse_thrust_fraction`
  (0.4) scales the commanded acceleration whenever the LEFT grip is what's
  driving the forward axis, so reverse tops out at 40% of forward's power:
  "not reliable for space braking and also not incredibly powerful for
  flying backwards." Implemented by scaling the INPUT before it reaches
  `step_acceleration()`, not by branching the function itself.
  **Air brake (right controller's A/`ax_button`) is the ONE deliberate
  exception to flight-assist OFF** — a direct, explicit pilot command,
  not an automatic assist. Holding it skips `_update_rotation()`/
  `_update_translation()` entirely for that frame (real input is not even
  read) and instead decelerates all six axes toward zero via
  `_apply_air_brake()`: linear axes at `ShipFlightProfile.air_brake_fraction`
  (0.6) of `forward_max_accel`, rotation at each axis's own existing
  max_accel. Uses plain `Vector3.move_toward()`/`move_toward()` rather than
  `OmegaMotion` — the goal is always exactly zero for as long as the button
  is held, so there's no goal-switching/overshoot concern to manage, and a
  flat linear approach is both correct and simpler than reusing the
  jerk-limited machinery built for a continuously-changing goal. Zeroes the
  stored acceleration state every frame it runs, so releasing the brake
  resumes normal flight from a clean idle engine rather than whatever
  acceleration happened to be stored the instant the brake was pressed.
- `scripts/weapon_system.gd` — twin-gun laser weapon on `Ship/GunMountLeft`
  / `GunMountRight`. Fires on the right trigger (`trigger_click`),
  alternating muzzle each shot. The two mounts are **toed in** via
  `look_at()` so their fire paths actually cross at `convergence_distance`
  (229m / 250 yards, the real RAF WWII harmonization standard — see
  `docs/gunnery-reference.md`), and a crosshair sphere sits at that exact
  convergence point, fixed in the ship's own 3D space (not camera-attached)
  so it shows real parallax as you move your head — like a reticle etched
  on the glass, not a HUD marker. Mounts sit at local Z=0.9 (nudged forward
  from an original 0.6) to give bolts more clearance from the cockpit's own
  silhouette before depth-testing can occlude them mid-pitch.
- `scripts/laser_bolt.gd` (`scenes/LaserBolt.tscn`) — the projectile: a
  tapered/arrow-shaped bolt (non-billboarded — billboarding was tried
  first and caused it to always orient vertically, since full billboard
  aligns to camera-up, not the bolt's actual travel direction) traveling at
  **600 m/s** and 14m long. Speed went 500 -> 900 -> 600 and length 2.5m ->
  14m: the 900 m/s bump was to stop a just-fired bolt being occluded by the
  ship's own nose mid-pitch, but it overshot — at 900 m/s a bolt crosses the
  whole 229m convergence distance in a quarter second, which live-tested as
  "lasers are moving too fast to see as a player." Making the bolt much
  longer solves the occlusion problem better than raw speed did, and lets
  the speed come back down to something you can actually watch travel.
  `target_lock.gd`'s `bolt_speed` (its PIP intercept solution) must be kept
  equal to this.
  **Width is now split by who fired it.** `LaserBolt.tscn`'s shared mesh
  (top 0.05 / bottom 0.28) was sized for the ambient mass-battle bolts,
  where hundreds need to read as visible tracers from across the city — up
  close, in the player's own cockpit, that same radius looked like "big
  tubes" rather than a laser beam. `_thin_player_mesh()` swaps in a slimmer
  CylinderMesh (top 0.015 / bottom 0.055 — about a fifth of the original)
  on `fired_by_player = true` bolts only, reading height/radial_segments
  off the existing mesh so length can't drift out of sync between the two.
  Crucially this creates a brand-new `CylinderMesh` and assigns it to just
  that one `MeshInstance3D`, never editing the scene's shared SubResource
  in place — alien-fired bolts (`_fire_at_player()` in `faction_battle.gd`)
  keep the original thicker mesh completely untouched. Verified: player
  bolts measure 0.055 vs. an unmodified 0.28 for alien fire, same length,
  and the two mesh resources are confirmed distinct objects.
  Each frame it does a **swept segment check** (previous position
  to current, not just a point test — at 900 m/s a bolt can cover 10-15m
  per physics frame, easily enough to tunnel through a ship between two
  sampled positions) against terrain, buildings, and — depending on
  `fired_by_player` — either the nearest living alien
  (`FactionBattle.get_nearest_alive_alien()`/`apply_damage()`, checking only
  the one nearest-to-current-position candidate, which is a safe
  simplification given how sparse 200 aliens are across an 8000m-radius
  dome and that the player only ever has one bolt in flight at a time) or
  the player's own ship (`player_damage.gd`, see below). A terrain/building
  hit explodes into a small self-cleaning crater/flash/smoke
  (`LaserImpactEffect.tscn`). Twin `AudioStreamPlayer3D`s (one per gun
  mount) play a processed laser sound (bass-boosted, highs rolled off via
  `lowpass` so it doesn't sound tinny — `Assets/Audio/laser.mp3`) on each
  shot fired by the player specifically (aliens firing at the player via
  `faction_battle.gd` don't play this sound — see Faction Battle below).
- `scripts/player_damage_audio.gd` (`DamageAudio` node under `Player`) —
  four hit sounds (`Assets/Audio/damage_hit_1.mp3` through `_4.mp3`,
  sourced from `damage/` at the project root); `play_random_hit()` picks
  one at random (never repeating the immediately-previous pick) and plays
  it. Now consumed by `player_damage.gd` on every hit.
- `scripts/player_damage.gd` (`PlayerDamage` node under `Player`) — the
  player's own three independent health pools (cockpit 40 HP / engine 60 HP
  / hull 100 HP), classified by local-Z position along `ShipHull` (same
  mesh/scale as `faction_battle.gd`'s aliens; since `ShipHull` carries no
  rotation, see above, classification just undoes the 2x scale via
  `ShipHull.global_transform.affine_inverse()`, no sign-flip correction
  needed). Cockpit or hull reaching 0 calls `CrashHandler.trigger_crash()`
  (a public entry point alongside the existing terrain/building path — both
  funnel into the same `_crash()` freeze/sound/spawn/respawn sequence).
  Engine reaching 0 is tracked but has no flight-degradation effect yet, see
  Known gaps. Every hit plays a random `DamageAudio` sound.
  `crash_handler.gd`'s `_respawn()` now also calls `reset_health()`.
  `scripts/player_health_hud.gd` (`HealthHUD` Label3D, top-left of the
  visor) reads the three fractions every frame and shows them as
  percentages.
- **The player genuinely could not be damaged** until the bug described
  under Faction Battle's "before-`add_child()`" rule was fixed — every
  alien bolt and missile silently no-op'd. The reported symptom was
  "I hear the hull taking hits but I'm actually not getting hurt", which
  was exactly right: `missile.gd` plays its impact sound unconditionally,
  but the `apply_damage()` call behind it was reaching a null reference.
- `scripts/damage_feedback.gd` (`DamageFeedback` node under `Player`) —
  called from `player_damage.gd.apply_damage()` on every hit, scaled by
  damage amount. Three layers: a **translational-only** camera shake
  (rotational shake is the classic VR nausea trigger, so it's deliberately
  never used), a red **damage flash** quad parented to `XRCamera3D`, and a
  **haptic pulse** on both controllers. The shake offsets the `XROrigin3D`
  because `XRCamera3D`'s own transform is overwritten every frame by the XR
  tracker and can't be offset directly — and it does so by *subtracting
  last frame's offset before adding this frame's*, never by setting a
  position, so it composes cleanly with `flight_controller.gd` writing
  `_origin.global_position += velocity * delta` on the same node and can
  never integrate into a permanent drift.
- **Crash system** — the player ship has no physics body, so nothing was
  ever stopping it flying through terrain or buildings. Fixed by direct
  position checks instead of full physics simulation:
  - `scripts/heightmap_terrain.gd` exposes `get_height_at(x, z)`, sampling
    the same height grid used to build the terrain's own collision mesh.
  - `scripts/city_generator.gd` gives every building a `StaticBody3D` +
    `CollisionShape3D`, auto-sized from the building's own measured mesh
    bounds (walked at instantiation, not hand-maintained per type), on
    `CityGenerator.BUILDING_COLLISION_LAYER` (layer 10).
  - `scripts/crash_effects.gd` (`class_name CrashEffects`) is the shared
    hit-detection + effect-spawning helper used by the player
    (`crash_handler.gd`), the mass battle (`faction_battle.gd`), and laser
    bolts: `check_building_collision()` does a physics point query against
    that layer; `spawn()` drops a **permanent** crater + a smoke column
    that never dissipates (rises hundreds of meters, GPU-particle-
    instanced, `visibility_aabb` sized generously — GPUParticles3D culls
    particles outside that box, which silently ate the smoke the first
    time) plus 7-8 **permanent** scattered wreckage chunks, each in its own
    small scorch crater — reserved for the **player only** now (see Faction
    Battle below for why mass-battle deaths use the temporary path
    instead); `spawn_laser_impact()` is the small, deliberately
    **temporary** version for a single laser hit (a permanent effect per
    shot would pile up hundreds of craters in seconds of sustained fire —
    see `laser_impact_effect.gd`), reused directly for every mass-battle
    kill. Flash/spark particle materials use a procedurally-generated soft
    radial-alpha texture (`Assets/Textures/soft_particle.png`, a one-off
    `--headless --script` Image-generation run, not a hand-authored asset)
    — the original flat solid-color particles had hard square edges that
    read as pixelated when they overlapped. **Smoke specifically** (in
    `CrashEffect.tscn`, `LaserImpactEffect.tscn`, and `ShipExplosion.tscn`)
    was later upgraded to a real 64-frame simulated-smoke flipbook
    (`Assets/Textures/smoke_flipbook.png`, user-supplied, an 8x8 grid) —
    genuine turbulent billowing motion instead of a single soft blob just
    scaling/fading. Wired via `StandardMaterial3D`'s
    `particles_anim_h_frames`/`particles_anim_v_frames=8` +
    `particles_anim_loop=false`, paired with `ParticleProcessMaterial`'s
    `anim_speed_min/max` (~1.0, so each particle plays through the full
    64-frame animation roughly once over its own lifetime — lifetimes vary
    wildly across these three effects, from 4s to a permanent/continuous
    60s, so this scales the playback rate to whatever each effect already
    uses rather than a fixed frame rate) and `anim_offset_min/max` (0-0.3,
    a little randomized start offset so simultaneously-spawned particles,
    e.g. `ShipExplosion`'s burst, don't all show the identical frame at
    once). Only the texture and these animation properties changed —
    each effect's existing color grading (gradient/albedo tint) was left
    alone. First-pass tuning, not yet confirmed live in the headset, same
    as every other visual first pass in this project. Two more textures
    the user supplied alongside the flipbook (`T_smoke_b7.png`, a single
    high-quality static smoke shape, and `T_Noise_001R.png`, a turbulence
    noise map) are sitting in `smoke/` at the project root, unused —
    likely inputs for a custom panning-noise-distortion shader technique
    (the reference video this was modeled on couldn't be watched directly),
    a reasonable next step if the flipbook alone doesn't fully match what
    was wanted.
  - `scripts/crash_handler.gd` — freezes the player on impact (a shared
    `paused` flag convention, also used by the options menu), plays a crash
    sound (bass-boosted, slowed to 80% speed the same way as the laser
    sound — `Assets/Audio/crash.mp3`), spawns the crash site, waits, then
    respawns. Both the initial spawn and post-crash respawn altitude are
    100m above terrain (raised from an original 2m).
- `scripts/city_generator.gd` (`class_name CityGenerator`) — procedural
  city block grid near the starting area (offset from spawn so it doesn't
  overlap it or the enemy's spawn corridor). A real street lattice (dark
  tiles at every grid line, GPU-instanced via a single
  `MultiMeshInstance3D` — ~1,200 individual tiles would be 1,200 draw calls
  otherwise), with skyscrapers centered in each block and rotation snapped
  to 0/90/180/270° — grid-aligned buildings + a visible street pattern is
  what actually reads as "a city" from altitude; the first version scattered
  buildings with full random rotation and no streets, which just looked
  like debris from a distance. Two building pools: `REGULAR_BUILDINGS`
  (shorter base models) and `LANDMARK_BUILDINGS` (tallest base models
  scaled up hard — the supertall towers). Dimensions were measured directly
  from the imported meshes via a one-off headless AABB script, not guessed.
  **Density and height are tuned independently of sprawl.** `grid_size` and
  `block_pitch` are deliberately inverse: the footprint is
  `grid_size * block_pitch`, held at **10800m** across, so packing in more
  blocks means shrinking the pitch rather than growing the grid outward
  (24 blocks at 450m and 30 at 360m cover identical ground). `skip_chance`
  is then tuned so the *building count* lands where intended rather than
  the raw block count. Current: **42 x 42 blocks at 257.14m pitch, ~1432
  buildings**, up from 744 (which was itself up from ~490) — footprint
  measured unchanged throughout.
  `height_multiplier` (**3.0**) scales **Y only**, so towers get taller
  without getting wider (tallest measured **1868m**); scaling all three axes
  would have widened every footprint, crowded the blocks and effectively
  grown the city. `building_jitter` was reduced to 20m alongside the tighter
  257m blocks so buildings stay off the streets. The `CollisionShape3D` is a child of the scaled
  `StaticBody3D`, so it inherits the non-uniform scale and collision stays
  correct for free.
  **Coupled to `faction_battle.gd`'s `MAX_BUILDING_HEIGHT`** (now 1400m):
  that is the altitude above which ships and bolts skip their
  building-collision physics query entirely, so it must stay above the
  tallest building this can produce. Raising building height without
  raising that gate silently makes ships fly through the tops of towers.
  `dome_radius` (8000m) is likewise sized against the city's ~7637m
  half-diagonal, which only holds while the footprint does.
  **Buildings are batched into MultiMeshes, like the streets already were**
  — this is what makes density affordable. Every building used to be its
  own instantiated scene, so 745 buildings meant ~745 draw calls despite
  the city being built from only **18 distinct meshes**. They're now
  bucketed by mesh and emitted as `MultiMeshInstance3D`s: **~19 draw calls
  for the entire city, down from ~746.** Collision is unaffected — each
  building keeps its own `StaticBody3D` + `BoxShape3D` (with the scale baked
  into the shape rather than applied to the body, so the collision shape
  never carries a non-uniform scale, which Godot flags as unsupported).
  `render_chunks` can split the batches into a spatial grid to restore
  per-district frustum culling, but **defaults to 1 (no chunking) on
  measured evidence**: the entire city's building geometry is only ~26,000
  triangles (these models average ~35 triangles each), so there is nothing
  for culling to save, and a 4x4 grid cost ~215 draw calls instead of 19 to
  guard against a vertex cost that doesn't exist. Raise it only if the
  building models are ever replaced with something genuinely heavy.
  Net effect: **adding city density is now nearly free on the render side**
  — more buildings means more instances in an existing batch, not more draw
  calls.
  **The FBX import does not bring the building textures across.** Every
  model imports with a material whose `albedo_texture` is null and whose
  `albedo_color` is a flat off-white (0.906, 0.906, 0.906) — which is why
  the city rendered as untextured white blocks for a long time despite all
  eight textures sitting in `Assets/City/Textures` the whole time. The
  meshes themselves carry correct UVs; only the material link is missing.
  This is a common Godot FBX limitation (texture references in FBX are
  frequently embedded or absolute authoring-tool paths that don't resolve).
  `_material_for_scene()` rebuilds the material and recovers the texture
  from the model path by family — `Models/building_04.2.fbx` ->
  `Textures/building_04.png` — rather than a hand-maintained table.
  Verified: 18 of 18 batches textured, all 8 textures in use.
- `scripts/target_lock.gd` — left controller's **Y button**
  (`by_button`) **cycles** a lock through living aliens from
  `faction_battle.gd`'s roster, nearest-to-farthest
  (`get_alive_aliens_sorted_by_distance()`), wrapping back to nearest after
  the last one. There is no manual unlock; it drops automatically when the
  target dies or drifts past `max_lock_range`. Because it only ever queries
  the alien-faction array, friendlies are structurally impossible
  to lock onto — not an explicit exclusion check, just a consequence of the
  two factions being separate arrays in the manager. `missile_system.gd`
  prefers this target for its own missile lock when one is active (see
  Homing missiles). Its `bolt_speed` export must stay equal to
  `laser_bolt.gd`'s `speed` (both 600) or the PIP ring lies. While locked:
  a red targeting square,
  an info readout (name/distance/closing-or-opening speed), and a yellow
  PIP ("predicted impact point") ring showing exactly where to put the
  crosshair to hit a moving target — a real firing-solution intercept
  (quadratic solve for soonest valid hit time given the target's exact
  velocity and the bolt's fixed speed), not a visual approximation. All
  three are **visor-anchored HUD elements**, not true 3D world objects: each
  is placed at a fixed distance from the camera along the real direction to
  its target point, so apparent size never changes with actual range — an
  earlier version placed them at the target's true position/distance and
  they became unreadable at range. The targeting box is a flat square
  rotated as one rigid unit to match the camera's basis each frame, NOT
  via per-edge material billboarding, which would rotate each of its 4
  edges independently around its own origin and warp the shape. Auto-
  unlocks past `max_lock_range` (12km). The info label is anchored from the
  **top** of its text block (`vertical_alignment = VERTICAL_ALIGNMENT_TOP`),
  not its center — with a center anchor the multi-line block's top edge
  crept back up toward (and over) the target as the box/label were shrunk;
  anchoring from the top means the gap below the box (`label_offset`) is
  the actual visible gap, and the text can only grow further away, not back
  over the target.
- `scripts/options_menu.gd` — in-VR menu, toggled by the left controller's
  menu button. Seat height (left stick) and enemy-tracking toggle (left
  X/`ax_button`, free to reuse since guns moved to the trigger), persisted
  to `user://settings.cfg`. Seat height adjusts **`Ship`'s local Y offset**,
  not the player's position — moving the player would move the camera and
  the fixed cockpit together as one rigid unit (tried, confirmed via debug
  logging: position changed, zero visible effect), so the ship model itself
  moves instead, changing where it sits relative to your untouched tracked
  head.
- `scripts/hud.gd` + `scripts/enemy_locator.gd` — camera-attached HUD (FPS,
  a **PERF** line, speed, gun status, an **MSL** missile-lock line (see
  Homing missiles), crash/respawn countdown, distance to
  the city — the FPS line exists specifically to tell "the game is
  dropping frames" apart from "something external, like OBS or Virtual
  Desktop's own encoding, is the bottleneck") and a small arrow that
  continuously rotates in full 3D
  to point at `FactionBattle.dome_center` (the city — repurposed from
  pointing at the old single enemy, since there isn't one anymore),
  computed in the camera's local space each frame so it stays correct
  regardless of head rotation. `enemy_locator.gd`'s public var was renamed
  `distance_to_enemy` -> `distance_to_objective` to match (a genuine
  semantic change, not just refactor churn) and `hud.gd`'s label changed
  from `ENEMY:` to `CITY:`. Both were built as much for **debugging as
  gameplay** — when something doesn't work in VR, there's no way to see an
  editor console mid-session, so status has to be visible in-headset to
  diagnose anything at all.
- `scripts/engine_audio.gd` — two looping engine layers (`accelerate.ogg`
  tied to forward-grip magnitude, `thrust.ogg` tied to roll/elevation/
  reverse-grip), both always playing but faded by volume/pitch based on
  input, not started/stopped per event.
  **Converted from `.mp3` to `.ogg`** — MP3 has an inherent encoder
  delay/padding gap at the exact sample a loop restarts, and for an 11-27s
  loop held for minutes at a time that gap was audible as a "pop" on every
  cycle; on VBR-encoded files the loop-point math can also be imprecise
  enough that playback occasionally reaches true end-of-stream and simply
  doesn't restart, which read as "the acceleration audio stops even though
  I'm still holding the trigger." Ogg Vorbis loops sample-accurately in
  Godot — the same fix already used for `ship_engine.ogg` and the
  mothership drone layers. `_process()` also defensively restarts either
  player if it's ever found stopped while unpaused, as a second line of
  defense against the same symptom recurring from any other cause.
  Verified by directly reproducing the bug (force-stopping the player mid
  simulated grip-hold) and confirming the watchdog brings it back within
  two frames without the simulated trigger ever releasing.
  `paused` (set by `game_flow.gd`, same convention as
  `flight_controller.gd`/`weapon_system.gd`) pulls both layers' TARGET
  volume to silent rather than leaving them at their last idle level —
  without it the player's own engine hum was still clearly audible over the
  MENU/DEAD/GAME_OVER black screens (0 grip is quiet, `-30dB`, not actually
  silent), when those screens are meant to have only the main menu's own
  music/chatter. `ship_engine_audio.gd`'s pooled proximity engines
  (`FactionBattle/ShipEngineAudio`) get the identical `paused` treatment for
  the same reason, but the effect there was worse: the player starts the
  match parked on the mothership deck surrounded by up to 100 other parked
  ships within `audible_radius`, so the whole pool ramped up almost
  immediately and the menu screen was reported as "way too loud." Its
  setter forces every voice silent and releases its target ship immediately
  on `paused = true` rather than waiting for the normal gain ramp, and
  `_process()` returns early while paused so the very next reassignment
  pass can't immediately re-attach a nearby ship and ramp volume back up.

## Faction Battle — squadron Air Superiority mode

Two fleets of squadrons fight each other for control of the city, plus the
player — replacing the old single wandering HOSTILE-1 enemy (see Retired
systems). `friendly_count`/`enemy_count` default to **100/100**; the
manager, rendering, and combat logic all still support the original 200/200
scale, this is purely a runtime-tunable knob. This was a large enough
feature that it went through a full plan-mode design pass (including a
sub-agent architecture review) before implementation.

The AI was then **rebuilt** after a live playtest, which reported it as
"clustering together and flying in huge packs" and generally not engaging.
The sections below marked *(AI rebuild)* are that work.

- **One manager, not hundreds of nodes** (`scripts/faction_battle.gd`,
  `FactionBattle` node in `Town.tscn`) — individual `Node3D`+script
  instances (the old `enemy_ai.gd` pattern) would mean that per-instance
  overhead multiplied by the whole population. Every ship is a lightweight
  `Combatant` (`scripts/combatant.gd`, `class_name Combatant extends
  RefCounted` — not a Node, never enters the scene tree directly), and
  ships are grouped into `Squad`s (`scripts/squad.gd`, also `RefCounted`).
  One `_physics_process()` on the manager updates everything in tight
  loops, same reasoning already documented for why `enemy_ai.gd` kept AI
  and damage in one script rather than paying constant cross-script calls.

### Squads *(AI rebuild)*

The single biggest change. Previously every ship independently spawned in
one cluster and flew at one shared `dome_center`, which produced exactly
what it sounds like — two enormous undifferentiated clouds. Now:

- The population is cut into **squads of 1-5** (`SQUAD_SIZE_MIN/MAX`).
  Verified in a headless run: 100 ships became ~31-34 squads with a healthy
  spread across all five sizes.
- Each squad gets its **own spawn point** scattered along a wide front
  (`SPAWN_FRONT_HALF_WIDTH` 7000m perpendicular to the approach axis,
  `SPAWN_DEPTH` 2500m of stagger) and its **own objective** inside the
  dome, instead of everyone sharing one.
- Wingmen hold a **formation station** on their leader (staggered
  V/echelon, `_formation_station()`) with a **throttle** that speeds up or
  slows down to close on that station — flying at one fixed speed either
  strings a squad out behind its leader or piles it into them. Throttle
  response now runs through the same `OmegaMotion.step_velocity()` the
  player's own throttle uses (see `docs/omega-flight-model.md`), against
  the identical shared `ShipFlightProfile` — cruise speed is
  `flight_profile.max_forward_speed * (0.75-0.95, per pilot)`, up from a
  flat, disconnected `140-210 m/s` band.
- Squads **focus fire**: the leader's target is weighted as much closer
  than it is during retargeting, so a squad concentrates rather than
  fragmenting onto five separate targets the moment it arrives.
- Squad membership is **fixed for the match** — a dead member respawns back
  into the same slot, matching the `MultiMesh` instance buffer's fixed
  indexing. Leadership is reassigned to a living member when the leader
  dies.

### Pilot behaviour *(AI rebuild)*

Per-pilot state machine (`Combatant.State`), layered under the squad's
orders, modelled on how modern combat-flight AI reads:

**Heading convergence uses `OmegaMotion.step_position()`**
(`_turn_toward()`), replacing a flat `heading.slerp(desired,
TURN_RATE*delta)` that had two problems: its effective angular speed scaled
with how far off the target was (a 180° reversal swung faster than a small
correction — backwards from how an airframe behaves), and it had no
acceleration at all, so a ship went from flying straight to turning at full
rate within a single frame. The new version turns at a real, bounded,
ramped rate — `flight_profile.ai_turn_max_rate`, the same F-16-grounded
pitch/yaw cap the player's own ship obeys, not a separate AI-only number —
ramping up, cruising, and braking into alignment with zero overshoot (the
textbook trapezoidal-velocity-profile switch, `sqrt(2*accel*angle_remaining)`).
Reuses the pitch/yaw cap rather than roll's deliberately: an AI ship
re-points its nose omnidirectionally instead of rolling into a turn, so
letting it turn at roll speed would make it strictly more maneuverable
than the player flying the identical ship.

- **FORMATION** — holding station (or, for a leader, flying the objective).
- **PURSUE** — running in on a target using a real lead/intercept solution
  (`_lead_point()`, the same quadratic firing solution `target_lock.gd`'s
  PIP ring uses for the player), not a straight chase of where the target
  is *now*.
- **BREAK_OFF** — after closing inside `BREAK_OFF_RANGE` (140m), the
  attacker flies **through and past** its target for a couple of seconds
  before turning back. This is the single biggest readability win: fights
  became a series of recognisable passes instead of two dots stuck
  together forever.
- **RETREAT** — disengaging. Both halves the user asked for are real: a
  pilot under `RETREAT_HEALTH_FRACTION` (35%) health may break off on its
  own, and a squad that has lost **half its members** breaks off as a unit
  (`Squad.State.RETREAT`), runs to a rally point outside the dome,
  `REGROUP`s, resets its loss count and comes back.
- **Separation** — every ship pushes away from same-faction ships within
  `SEPARATION_RADIUS` (130m), read from the existing 3x3 spatial-grid
  neighbourhood and capped at `MAX_SEPARATION_NEIGHBORS` so the cost stays
  bounded however dense traffic gets. This is what actually stops squads
  collapsing into one mass.
- **Per-squad rally points** (`_make_rally_point`, assigned once at build
  and never recomputed) — each squad retreats to its own point, spread
  along a broad line on its own side of the map (measured: 35/35 squads
  distinct, ~3200m spread). This is a **regression fix**: rally points used
  to be derived from `Squad.spawn_center`, which was fine while squads
  spawned scattered across a 7000m front, but became a bug the moment
  motherships took over spawning and every squad's `spawn_center` became
  the same single point. Every retreating squad then flew to the
  *identical* location, and with a dozen squads typically in RETREAT at
  once that formed a large permanent pack — reported as the AI "grouping
  again after the mothership add". Nearest-neighbour distance recovered to
  ~714m after the fix.
- **Reaction delay and per-pilot accuracy** — a ship doesn't fire the
  instant it acquires (`reaction_timer`, 0.35-1.1s), and its aim is
  displaced from the true firing solution by `(1 - accuracy) * range *
  AIM_ERROR_SCALE`, with `accuracy` rolled per pilot (0.55-0.95). Error
  grows with range, so distant AI sprays and close AI is genuinely
  dangerous. This is the "threatening but not unfair" knob.
- **Firing requires the target roughly ahead** (`FIRE_CONE`, 14°). They
  used to fire at anything in range regardless of where their nose pointed
  — both unreadable and free damage from impossible angles.

Measured in a 120s headless run at 100v100: a steady mix of ~60% PURSUE,
~20% BREAK_OFF, ~10% RETREAT, ~10% FORMATION, with squads split across
ENGAGE/ADVANCE/RETREAT/REGROUP — i.e. all of it is actually firing, not
just present in the code. Mean distance to the nearest same-faction ship
rose from ~150m (the old clustered behaviour) to ~550-620m in combat.

### Hunting the player *(AI rebuild)*

Two knobs, both standard modern-encounter pacing devices:

- `max_aliens_targeting_player` (3) — an **attacker cap**. Without it,
  every alien inside `aggro_radius_player` converges on the player at once
  and the fight stops being winnable or readable.
- `player_target_bias` (0.55) — the player is weighted as if that much
  closer than they really are when an alien picks a target. The player
  flies *with* the friendly fleet, so without this there was almost always
  a friendly ship marginally nearer and the player was essentially never
  hunted.

### Rendering

Two `MultiMeshInstance3D` (one per faction, built in `_ready()`, the same
GPU-instancing technique `city_generator.gd` uses for its ~1200 street
tiles), both reusing `ship1.obj` (no separate alien model exists in this
project). `ship1.mtl` has exactly one material, so team identity is just a
`material_override` tint (cyan/blue friendly, magenta/purple enemy). A
third `MultiMeshInstance3D` renders the ambient bolt pool, now with
`use_colors` so friendly and hostile tracers are tinted differently
per-instance. Dead ships are hidden by scaling their instance transform to
zero (`Basis().scaled(Vector3.ZERO)`) rather than removed — `MultiMesh` has
no per-instance visibility flag for an arbitrary middle index, only
`visible_instance_count`, which trims from the buffer's tail.

### Air Superiority (AS)

A single scalar, `air_superiority`, -100 (full enemy control) to +100 (full
friendly control), starting at 0: `air_superiority += (friendly_in_dome -
enemy_in_dome) * delta * as_generation_multiplier`, clamped to [-100, 100]
— the player's own presence inside the dome counts as one friendly, and one
enemy in the dome cancels one friendly exactly 1-for-1, per the user's own
framing. Either side hitting +/-100, or the 10-minute `match_time_remaining`
timer expiring (higher AS wins the timeout case; exactly 0 is a draw — an
assumption, not something the user specified), sets `game_over = true` and
stops the battle simulation — the player's own flight/weapons are *not*
frozen, only the spectacle stops.

`as_generation_multiplier` is now `0.01`, tuned down across four separate
user requests after seeing each previous rate in play (`1.0 -> 0.5 -> 0.1
-> 0.01`).

Scoring is **recomputed every `AS_UPDATE_INTERVAL` (6) frames**, not every
frame, integrating the accumulated delta — mathematically identical, but it
cuts the per-frame terrain sampling that counting every ship in the dome
requires. See Performance below.

### The dome

Implemented as a cylinder, not a literal hemisphere (it's invisible, so
only the gameplay volume needs to be right, not a rendered shape):
horizontal distance from `dome_center` (read from
`CityGenerator.city_center`, `(6000, 0, 0)`) within `dome_radius` (8000m —
comfortably covers the city's own ~7637m corner-to-corner footprint) and
altitude above terrain within `dome_ceiling` (3500m).

### Bolts — two separate systems

Ambient unit-vs-unit fire ("lasers everywhere") is a pooled, non-Node bolt
array (plain `Dictionary` records, capped at `max_ambient_bolts`, now 320),
rendered via the third `MultiMeshInstance3D`, hit-checked with the same
closest-point-on-segment swept test `laser_bolt.gd` uses — a plain
point/distance check would let bolts tunnel through targets, the same bug
this project already fixed once for the player's own bolts. Hit checks are
spatially bucketed into a per-frame grid keyed by `city_generator.gd`'s own
`block_pitch` (450m cells); the 3x3 neighbourhood is now walked **inline**
rather than building a candidate `Array` per bolt per frame, which at
hundreds of bolts was pure garbage churn in the hottest loop in the game.
A ship whose fire attempt finds the pool full just doesn't fire that
cooldown tick — never evicts an in-flight bolt early, since that pops a
bolt off-screen mid-flight.

**Ambient bolts are now visible.** They were 900 m/s and 2.5m x 0.06m — far
below one pixel from any real viewing distance, so a battle of hundreds of
simultaneous shots read as nothing at all. Now **520 m/s** and **26m x
0.55m**, brightly emissive and faction-tinted. The slower speed also gives
the AI's lead/intercept solution real work to do. Grids are rebuilt at the
**top** of the frame so separation steering can use them; only the
bucketing is a frame stale by the time bolt checks run (positions
themselves are read live), and at 450m cells a frame of movement can't move
anything meaningfully between buckets.

Aliens shooting *at the player* specifically instead reuse the existing
`LaserBolt.tscn`/`laser_bolt.gd` Node-based system (`fired_by_player=false`)
— low volume by construction, and it's what feeds `player_damage.gd`.

### The before-`add_child()` rule — a real, load-bearing bug

`add_child()` runs the child's `_ready()` **immediately**, so any property
that scene's `_ready()` reads must be assigned **before** `add_child()`,
not after. Both `_fire_at_player()` and `_fire_missile_at_player()`
originally set `fired_by_player = false` / `target_is_player = true`
*after* `add_child()`. Consequences, all of which were live for several
sessions:

- `laser_bolt.gd`'s `_ready()` saw `fired_by_player` still `true`, so it
  never resolved `Player`/`PlayerDamage`, so **alien gun fire could not
  damage the player at all**.
- `missile.gd`'s `_ready()` saw `target_is_player` still `false`, so it
  never joined the `"player_seeking_missiles"` group (so `missile_alert.gd`
  never fired) and never resolved `PlayerDamage`/`FlareSystem` (so alien
  missiles did no damage and the flare countermeasure had nothing to
  defend against).
- The reported symptom was **"I hear the hull taking hits but I'm actually
  not getting hurt"** — precisely correct, because `missile.gd` plays its
  impact sound unconditionally while the damage call behind it hit a null
  reference.

`laser_bolt.gd` additionally got a lazy `_resolve_player_refs()` fallback
in its hit check as belt-and-braces against a future caller repeating the
mistake. `ship_explosion.gd`'s new `enable_light` follows the same rule.

### Effect and audio budgets

Now that the AI actually fights, kills are constant — and every kill used
to spawn an unconditional `ShipExplosion` (a particle tree plus a 6000m
`OmniLight3D`). Everything spawned from the battle is now budgeted:

- **Kill fireballs** — hard cap (`max_concurrent_explosions`, 14), no
  `OmniLight3D` beyond `explosion_light_range` (4000m, passed in as
  `enable_light` before `add_child()`), nothing at all beyond
  `explosion_cull_range` (15000m).
- **Hit sparks** (`scenes/HitSpark.tscn` / `scripts/hit_spark.gd`) — a small
  mid-air spark burst for a hit the target **survived** (a kill already
  spawns the far bigger fireball at the same spot). Deliberately not
  `CrashEffects.spawn_laser_impact()`, which is built around a scorch
  crater on a *surface* and makes no sense floating in the sky. Capped and
  only spawned within `spark_range` (2500m) of the player.
- **Battle audio** — `_play_battle_sound()` spawns short-lived
  `AudioStreamPlayer3D`s for distant fighting, capped at
  `max_battle_sounds` (12) and distance-gated. Uses Godot's built-in
  distance low-pass (`attenuation_filter_cutoff_hz`) aggressively, which is
  what makes far-off combat read as *muffled* rather than merely quiet.
  Two new assets, both `ffmpeg`-processed from existing sounds rather than
  sourced new: `battle_explosion.mp3` (from `crash.mp3` — pitched down via
  `asetrate`, heavy bass, `lowpass=1250`, echo) and `battle_laser.mp3`
  (from `laser.mp3`, quieter and rolled off). Ambient laser fire only plays
  a sound for `laser_sound_chance` (7%) of nearby shots — every shot would
  be a wall of noise.

### Respawn, not attrition

Dead ships respawn after `RESPAWN_DELAY` (8s) at their **squad's** spawn
cluster, same pattern `crash_handler.gd`/the old `enemy_ai.gd` used —
needed so the population (and the spectacle) stays sustained for the full
10-minute match instead of thinning out and going quiet halfway through.

### Performance

The physics building point-query and the terrain sampler were being called
per ship *and* per bolt, every frame. Three gates were added, all of which
are exact rather than approximations:

- **Altitude gate** (`MAX_BUILDING_HEIGHT`, 700m) — the tallest landmark in
  `city_generator.gd` is ~625m, so anything flying further than that above
  the terrain underneath it *cannot* be intersecting a building and the
  physics query is skipped outright. The ground height is already sampled
  for the terrain check, so the gate itself is free. Applied to both
  combatants and ambient bolts.
- **One terrain sample per ship per frame**, reused by both the
  ground-avoidance test and the terrain-crash test, which previously
  sampled independently.
- **Staggered lookahead** (`LOOKAHEAD_STAGGER`, 4) — the ground-avoidance
  *lookahead* sample runs for a quarter of the population per frame and
  latches its result on `Combatant.pull_up_latched`. Terrain elevation
  along a 3-second flight path doesn't change meaningfully frame to frame.
  The *immediate* clearance check still runs every frame — that's the one
  that actually saves a ship's life.
- Plus the AS staggering and the bolt-grid allocation removal noted above.

`enable_building_collision_check` remains as an `@export` escape hatch.

### Earlier fixes still in force

- **Target acquisition is range-capped** (`MAX_ACQUISITION_RANGE`, 3000m) —
  a real bug caught after the first live playtest ("no one is shooting
  lasers"): retargeting originally picked the *globally* nearest opposing
  ship with no distance limit, so every combatant had a target from the
  instant it spawned (its nearest enemy just ~20km away) and steered
  straight at that far-off individual instead of ever advancing on the
  dome.
- **Ships spawning into an immediate nosedive** — the initial heading was
  `(dome_center - position).normalized()`, but `dome_center.y` is 0 (sea
  level) while this terrain is genuinely mountainous (~2713m right at the
  friendly spawn, confirmed by the sim's own debug print), so every
  freshly-spawned ship aimed thousands of meters *below* its own altitude
  and dove into the ground. Fixed by aiming at a horizontally-projected
  target at the ship's own altitude.
- **Ground avoidance**, ported from `enemy_ai.gd` — ships fly a straight
  line at a fixed altitude offset from their own spawn point's ground
  height, and this terrain's elevation varies by thousands of meters along
  the way, so flying level is not automatically safe here.
- Note that the ~40-60s lag before the first shot is **expected**, not a
  bug: both fleets spawn 10km out and have to close. Measured at t=41.5s
  and t=44.0s across two runs. Worth remembering before re-diagnosing
  "nothing's happening" reports that are really "it hasn't been a minute
  yet."

### Kill attribution — verified

The live report that the kill feed "is not displaying friendly kills" did
**not** reproduce. Instrumented headless runs counted 18-22 FRIENDLY losses
against 19-32 HOSTILE losses over 120s, with `FRIENDLY-NNN shot down by
HOSTILE-NNN` entries present throughout the feed. The most likely
explanation is the old AI: before the rebuild, combat was rare and lopsided
enough (and the feed expires entries after 8s) that friendly deaths simply
weren't happening often enough to see. Kept under observation rather than
"fixed", since nothing was found to fix.

### Public API surface

`get_nearest_alive_alien(pos)`, `get_alive_aliens_sorted_by_distance(pos)`,
`get_nearest_alive_alien_in_cone(origin, dir, angle, range)`,
`is_alive(index)`, `get_alien_position(index)`, `get_velocity(index)`,
`apply_damage(index, amount, cause)`, `try_deploy_alien_flare(index)`, plus
the live `air_superiority` / `match_time_remaining` / `game_over` /
`winning_faction` / `dome_center` / `kill_feed_text` vars.
(`get_position` was the first name tried for `get_alien_position` — it
collided with `Node3D`'s own built-in `get_position()` and failed to
import until renamed; a real gotcha worth remembering for any future
manager method on a `Node3D`-derived script.)

### Player spawn coupling

The player spawns **with the friendly fleet**, not at the world origin:
`heightmap_terrain.gd`'s `spawn_position_xz`, `crash_handler.gd`'s
`respawn_position_xz` and `game_flow.gd`'s `player_spawn_xz` are all set to
`(-4000, 0)` by hand, matching `FactionBattle`'s friendly spawn formula
(`city_center + (-10000, 0, 0)`). All of them need updating together if
that formula changes — a documented, intentional coupling, same pattern
already accepted for the dome/`block_pitch`/`city_center` reuse.

## Motherships — the two spawn platforms

One stationary capital ship per faction, hovering at that faction's spawn
point 10km out from the city. Every ship in the fleet — and the player, on
the friendly side — starts the match parked on its flight deck and launches
off the top of it, and every death respawns back onto it.

### The asset

`mothership/3d-model.obj` at the project root: a **932,000-triangle** 3ds
Max export, 58MB, with no usable `.mtl` (its materials are placeholder
`wire_*` names) and no textures. Shipping that unmodified was never an
option — two of them are on screen in VR stereo on top of a 1200-building
city and 200 ships, with an unresolved frame-rate problem already open.

Processed once through a one-off headless **Blender** script (Blender 5.2 is
installed locally; `blender.exe` lives one directory deeper than expected,
at `Blender Foundation/Blender 5.2/5.2/blender.exe`):

- **Decimated** to ~124k triangles (`DECIMATE` modifier, `COLLAPSE`, ratio
  0.08), joined into a single mesh so each instance is one draw call.
- **Normalised** so the Godot side is readable rather than magic: origin at
  the centre of the footprint, `Y = 0` at the underside, longest axis
  scaled to exactly 1.0. `mothership.gd`'s `length` is therefore literally
  the ship's length in meters, and everything else is a fixed ratio of it —
  `WIDTH_RATIO` 0.6653 and `DECK_TOP_RATIO` 0.2054, both verified against
  the imported mesh's own AABB *in Godot*, not assumed from the exporter.
- **Exported as glTF** (`Assets/MotherShip/mothership.glb`, 5.2MB), which
  Godot imports natively — unlike the `.stl` the conversation started
  around, which Godot cannot read at all.

### Placement

Three exported knobs on `FactionBattle`, all live-tunable. Current values
are the result of two rounds of user-requested scaling-up (2000m/11000m/
1500m, then doubled):

- `mothership_length` — **4000m** long, giving a ~2660m-wide deck and ~822m
  of deck height. Chosen to read as a capital ship against a city whose
  tallest towers are ~625m. Unverified in the headset, like every asset
  scale in this project.
- `spawn_distance_from_city` — **22000m** out from `dome_center` on each
  side. This used to be hardcoded in two places; it's now the single value
  that positions a faction's mothership, its fleet and its rally points.
- `mothership_altitude` — **3000m** above the terrain below it, putting the
  flight deck ~3820m above ground.

**Pacing consequence, measured — worth knowing before changing it again.**
Everything launches from the deck, so `spawn_distance_from_city` directly
sets the opening transit. The two fleets now start **44km apart**, and the
first shot is fired at **t=116.6s — 19% of the 600s match elapsed with no
combat at all**. The fleet is fully airborne at t=29.1s; the rest is pure
approach. The battle itself is healthy once joined (94-99 alive per side
through t=300s with a full pursue/break-off/retreat mix), so this is a
deliberate pacing choice rather than a bug — but if that opening lull reads
as dead air in the headset, `spawn_distance_from_city` is the dial, and
`match_duration` is the other one. For reference: ~6 seconds of extra
approach per 1000m of spawn distance, per side.

This is also the standing answer to "nothing is happening" reports — for
the first two minutes, that is now correct behaviour.

The exported `player_spawn_xz` / `respawn_position_xz` /
`spawn_position_xz` fallbacks in `game_flow.gd`, `crash_handler.gd` and
`Town.tscn` track this at `(-16000, 0)`. They are **fallbacks only** (see
Player spawn below), but a fallback that's kilometres wrong is worse than
no fallback.

The asset arrived with no materials, so `mothership.gd` applies a
`material_override` per faction — a metallic hull tinted toward the faction
colour with a very low emission (0.25), enough that the silhouette still
reads as friendly or hostile from kilometres out where diffuse shading has
fallen off to nothing.

### Engine drone

Three user-supplied turbine recordings (`mothership/freesound_community-*`)
blended into a low drone, kept as **three simultaneous looping layers**
rather than pre-mixed into one file. Their processed lengths are 49.9s,
87.6s and 180s — mutually indivisible, so the combination doesn't audibly
repeat for hours. A single pre-mixed loop would cycle on a fixed period,
which is very noticeable on a constant ambient bed the player parks on top
of at the start of every match.

Each layer was `ffmpeg`-processed into its own frequency band so they stack
instead of competing, all pitched down via `asetrate`:

- `mothership_drone_low.ogg` — the sub bed, lowpass 210Hz, heavy bass boost.
- `mothership_drone_mid.ogg` — the body of the drone, 45-620Hz.
- `mothership_drone_air.ogg` — quiet machinery texture on top, 130-1500Hz.

All three are **mono on purpose**: Godot's `AudioStreamPlayer3D` can only
position a mono source correctly, and a stereo source smears across the
whole soundstage instead of coming from the ship. OGG rather than MP3
because MP3's encoder padding puts a gap at the loop point. Looping is set
in code (`mothership.gd._start_drone()`) rather than in import settings so
it's visible where it matters, and each layer starts at a random offset so
the two motherships don't phase-lock into an artificial beat. Per-layer
`unit_size`/`max_distance`/attenuation filtering are tuned so the drone
carries several km but muffles with distance — first-pass values, needs the
headset.

### Launching

- `Combatant.State` gained **PARKED** and **LAUNCHING**. A parked ship
  doesn't move, steer, retarget or shoot — it's sitting on a flight deck.
- Squads leave in **waves** (`LAUNCH_WAVE_INTERVAL`, 0.85s apart), ordered
  down the length of the deck via `MotherShip.squad_deck_point()`, which
  parks squads in alternating rows either side of the centreline. The whole
  fleet lifting at once looks like a swarm rather than a carrier launch, and
  dumps the entire population into one volume of air for the separation
  steering to fight. Measured: the last ship clears the deck at **t=28.4s**.
- A **LAUNCHING** ship climbs (`LAUNCH_CLIMB_BIAS` 2.6 toward `UP`, leaned
  toward its squad's objective so the fleet fans out as it climbs rather
  than forming one vertical column) and ignores combat entirely until it is
  `LAUNCH_CLEAR_HEIGHT` (420m) above the deck it left. Clearance is measured
  against `Combatant.launch_deck_y`, not the terrain — the deck sits ~1400m
  above ground.
- **Mid-match respawns don't queue behind the opening launch** — they get a
  short random delay (`LAUNCH_RESPAWN_DELAY_MAX`, 2.5s) instead of the
  fleet-wide wave ordering.

This replaced the previous spawn arrangement, where squads scattered over a
7000m front — that spread was the original fix for "the AI clusters in huge
packs", and it is no longer needed because the launch waves, each squad's
own dome objective, and the separation steering all provide spread
independently of where ships start. Verified: combat still develops
normally, first shot at t=54.5s, both fleets holding ~96-97 alive at 150s
with a full mix of pursue/break-off/retreat.

### Player spawn — the coupling is finally gone

`FactionBattle.get_player_spawn_position()` is now the single source of
truth for where the player starts and respawns (a random spot on the
friendly deck). `game_flow.gd` and `crash_handler.gd` both ask for it,
falling back to their exported coordinates only if no battle exists in the
scene. This retires the documented three-to-four-place hand-synced
`(-4000, 0)` coupling between `heightmap_terrain.gd`, `crash_handler.gd`
and `game_flow.gd` — those exports remain as fallbacks but are no longer
the thing that has to be kept in step.

`game_flow.gd` also repositions the player when *entering* the menu, so the
black-screen reveal opens onto the flight deck rather than wherever the
player happened to be left.

### Known limitations

- The motherships have **no collision** — they're `MeshInstance3D`s, not on
  `CityGenerator.BUILDING_COLLISION_LAYER`. Ships, bolts and the player all
  pass straight through the hull. Fine while they're spawn platforms parked
  far from the fighting; it would need a real collision shape (or a simple
  bounding-volume test, matching this project's approximate-collision
  philosophy) before they become something you fly around in combat.
- They are indestructible and take no part in the battle — no guns, no
  health, no effect on Air Superiority.

## Homing missiles

Second weapon, **left trigger** (guns stay on the right trigger) — a
deliberate lock-on-first weapon rather than a second trigger-happy gun.
This system went through **three** design iterations; the current one is
hold-to-lock, release-to-fire.

### Current design: hold the left trigger

Modelled on how modern combat flight games (Ace Combat, Star Wars:
Squadrons, Project Wingman) actually do it:

1. **Hold** the left trigger. Whatever you're pointed at gets designated.
2. A **search tone** pulses while the lock builds, accelerating as it
   approaches completion (`beep_interval_start` 0.55s -> `beep_interval_end`
   0.11s) — the audio alone tells you how close you are.
3. At `lock_time` (**3.0s**, exported and tunable) the tone goes solid:
   lock acquired.
4. **Release** the trigger and the missile launches. If the lock hadn't
   completed, nothing fires and progress is discarded.

Target designation, in priority order: `target_lock.gd`'s Y-locked target
if one is active and alive (Y-lock remains the way to deliberately pick a
specific ship out of a furball, and it's what the targeting box and PIP
ring are already drawn around, so honouring it keeps one obvious "this is
my target" concept rather than two competing ones); otherwise the nearest
living alien inside `lock_cone_degrees` (9°) of the nose and within
`lock_range` (6km), via `FactionBattle.get_nearest_alive_alien_in_cone()`.
Progress resets to zero — no partial credit — if the designated target
changes, dies, or leaves the cone while you're holding.

`hud.gd` gained a permanent **MSL** line (`hold left trigger` / `no target
in cone` / `LOCKING n%` / `LOCKED — release to fire`). Without a readout
there is no way to tell "nothing is designated" from "locking" from "the
weapon is broken", which is exactly how the previous design failed
silently.

### Why the two earlier designs failed

Worth keeping, because both failures were about the same mistake — making
lock *acquisition* implicit.

- **v1 (own aim cone against the gun crosshair)** re-picked "nearest in
  cone" every frame, so it flickered between clustered targets and never
  accumulated progress.
- **v2 (required `target_lock.gd`'s Y-lock held for 5 continuous seconds)**
  meant the missile could only be used after a separate, unrelated button
  ritual, with no feedback at all if that precondition wasn't met. From the
  cockpit it simply looked like the weapon did nothing — reported as "the
  rocket targeting system is not working."

### The silent-feedback bug — why it still "didn't work" after the rewrite

Even with the lock logic correct and the launch direction fixed, the weapon
still read as completely dead in the headset, because **every piece of its
feedback was inaudible**. `LaunchAudio` and `LockAudio` were
`AudioStreamPlayer3D` nodes parented to `MissileSystem` — which is a plain
`Node`, not a `Node3D`. With no `Node3D` ancestor their global transform
falls back to identity, so both sounds played at the **world origin**,
roughly 4.9km from the player's spawn, against a `max_distance` of 800. No
search tone, no lock tone, no launch sound, ever.

The gun sounds were never affected because they live under
`Ship/GunMountLeft` / `GunMountRight`, a real `Node3D` chain — which is
exactly why this looked like "missiles are broken, guns are fine."

Both are now plain `AudioStreamPlayer`s, which is what they should always
have been: your own lock tone and your own launch happen inside your own
cockpit, so proximity is meaningless — the same reasoning `main_menu.gd`'s
music and `missile_alert.gd`'s warnings already use. **The general rule for
this project: an `AudioStreamPlayer3D` is only correct under a `Node3D`
parent that is actually positioned where the sound happens.**

Feedback no longer depends on audio alone. The left controller now pulses
on every search beep and harder on lock and on launch — a buzz in the hand
that is pressing the trigger cannot be missed, drowned out by the battle,
or routed to the wrong place. The lock cone was also widened from 9° to
22°, since aliens are sparse across an 8km dome and holding a 9° bead on
one was most of the difficulty; the Y-lock still takes priority, so the
generous fallback cone can't steal a deliberately chosen target. The
missile mesh went from 1.8m to 5m with a larger exhaust, because at 400 m/s
a 1.8m body was gone before you could register that anything had launched.

Verified end to end by a scripted test (`designate -> lock -> fire -> fly ->
kill`): lock completes, the missile spawns **0.0° off the bearing to
target**, closes 898m and kills in 2.25s, and the kill feed records
"destroyed by PLAYER missile".

### The backwards-launch bug

Independent of the lock design, and enough on its own to make the weapon
look broken: **do not take the ship's facing from the `Ship` node.** `Ship`
carries a 180° flip basis to correct the cockpit glTF's backwards-authored
forward direction (see Player.tscn), so `-Ship.global_transform.basis.z`
points *behind* the craft. `missile_system.gd` was spawning the missile
with `Ship`'s basis, so every missile launched **rearward** — and because
`missile.gd` then measured ~180° between its heading and the bearing to
target on frame one, it immediately latched its overshoot/ballistic handoff
(`MAX_ENGAGE_ANGLE` 150°, see below) and flew away forever without ever
steering. Both the aim cone and the launch orientation now use the
**`XROrigin3D` rig**, whose -Z is unambiguously forward and is what
`flight_controller.gd` actually flies. The guns were never affected because
`weapon_system.gd` spawns from the gun mounts, which carry their own
compensating flip.

### The missile itself

- `scripts/missile.gd` (`scenes/Missile.tscn`) — unlike `laser_bolt.gd`'s
  straight-line travel, this steers toward its target's *current* position
  every physics frame at a capped turn rate (1.2 rad/s) — real pursuit, not
  an instant snap. `speed` is **400 m/s**, deliberately slow enough to be
  dodgeable with hard defensive maneuvering, a direct user requirement.
  Damage (30) always meets-or-exceeds a mass-battle alien's max health, so
  every hit is a kill — `FactionBattle.apply_damage()`'s kill path already
  spawns the fireball and a kill-feed entry, so the missile needs no
  separate impact visual, just its hit sound.
- **Overshoot -> ballistic handoff** (`MAX_ENGAGE_ANGLE`, 150°) — a target
  breaking hard enough can end up almost directly behind the missile. Past
  150° between the missile's heading and the bearing to target, `_lost_lock`
  (sticky) latches and the missile gives up steering for good, continuing
  straight for the rest of its `lifetime` — a real missile can't pull an
  instant U-turn either, and endlessly circling back would look wrong. It
  can still score a hit via the ordinary swept-segment check if something
  crosses its path.
- **Smoke trail** (`scenes/MissileTrail.tscn` / `scripts/missile_trail.gd`)
  — at 400 m/s the missile body is out of view almost immediately, so the
  trail is what actually lets you see and track your own shot. Thick smoke
  (140 particles, 4.5s lifetime, `smoke_flipbook.png` like the rest of this
  project's smoke), which at 400 m/s lays down a trail well over a
  kilometre long.
  It is deliberately **not a child of the missile**, for two reasons that
  both matter: the particles emit in world space (`local_coords = false`)
  so they stay where they were laid down instead of being dragged along
  with the emitter, and a missile `queue_free()`s the instant it hits
  something — freeing the emitter would take the entire existing trail with
  it, popping a kilometre of smoke out of the sky in one frame. Instead the
  trail lives at scene level and merely *follows* the missile; when the
  missile dies it stops emitting and dissipates naturally.
- **Terrain and buildings now stop a missile** like they stop everything
  else in this project. Previously a missile chasing a low target, or one
  that had gone ballistic after an overshoot, simply flew on through a
  mountain forever.
- **Muffled + proximity audio**: launch/hit sounds are user-supplied
  (`weapons/missle/misslelaunch.mp3` / `misslehit.mp3`, outside the Godot
  project — processed once via `ffmpeg` with a bass boost + lowpass
  (`bass=g=8:f=100,lowpass=f=3200` launch, heavier `f=90,lowpass=f=2600`
  hit) into `Assets/Audio/missile_launch.mp3` / `missile_hit.mp3`, matching
  this project's existing "processed so it doesn't sound tinny" treatment)
  and played via `AudioStreamPlayer3D` for real proximity falloff. The hit
  sound also tunes Godot's distance low-pass
  (`attenuation_filter_cutoff_hz=1800`, `attenuation_filter_db=-36`) —
  missile hits can happen well away from the player, so farther hits should
  read as quieter *and* more muffled. It's spawned as a short-lived
  standalone player at the impact point, since the missile node itself is
  freed on impact. The lock beep (`missile_lock.tres`) had no source file —
  procedurally generated (a 1400Hz sine with a fade envelope, built and
  saved via a one-off `--headless --script` run) the same way
  `soft_particle.png` was. **`ResourceSaver.save()` gotcha**: saving as
  `.wav` failed (`ERR_FILE_UNRECOGNIZED`) — `ResourceSaver` writes Godot
  resource files, not raw playable containers; saving the same
  `AudioStreamWAV` as `.tres` worked immediately and loads/plays
  identically as an `AudioStream`.
- Pausing: `game_flow.gd`, `options_menu.gd` **and** `crash_handler.gd` all
  pause `MissileSystem` and `FlareSystem` alongside flight and guns. The
  latter two only paused flight and guns until a bug sweep caught it —
  which meant opening the options menu also burned a flare on every X press
  (the menu and `flare_system.gd` share that button), and you could keep
  firing missiles while sitting crashed waiting to respawn.

### Lock reticle

A visor-anchored HUD cursor that swoops in from an off-axis angle and spins
around the designated target while the lock builds, settling to a steady
ring and turning green the instant `locked` goes true — the lock-on reticle
modern combat-flight games use (Ace Combat, Star Wars: Squadrons). Built
and driven entirely inside `missile_system.gd`, the same convention
`target_lock.gd` uses for its own targeting box/PIP ring/info label — no
extra HUD node in `Player.tscn` to keep in sync.

- **Positioning is visor-anchored**, the identical technique `target_lock.gd`
  already uses: placed at a fixed `RETICLE_HUD_DISTANCE` (5m) from the
  camera along the real direction to the target, so it tracks the right
  screen position at any actual range without its apparent size changing.
- **The "flies in from outside the screen" entrance is a direction slerp,
  not screen-space UI math.** A start direction is picked by rotating the
  true target direction off-axis by `RETICLE_FLY_IN_ANGLE` (38°) around a
  random perpendicular, then every frame the reticle's direction eases
  (quadratic ease-out) from that start toward the true target direction
  over `RETICLE_FLY_IN_TIME` (0.3s). Composed with the fixed HUD distance,
  that reads as the reticle swooping in from a wide angle and snapping onto
  the target, reusing the same 3D placement math as the rest of the lock
  HUD rather than adding a second system.
- **Spin is a rigid-unit rotation about the reticle's own local Z**, same
  reasoning as `target_lock.gd`'s targeting box: four bracket ticks
  arranged in a ring are children of one root, and the whole root's
  transform is set to `camera_basis * Basis(FORWARD, spin_angle)` each
  frame — never per-tick billboarding, which would rotate each tick
  independently around its own origin and break the ring shape.
- **Spin speed decays to zero as the lock completes**
  (`RETICLE_SPIN_SPEED_START` 7.5 rad/s -> `RETICLE_SPIN_SPEED_LOCKED` 0),
  so spinning reads as "still working" and a steady ring reads as "ready" —
  a second signal alongside the colour shift (red/orange while acquiring,
  lerping to green as `lock_progress` approaches `lock_time`, with a small
  cosmetic breathing pulse on the emission energy once locked).
- **A fresh designation restarts the whole animation**, including switching
  targets mid-hold — `tracked_target_index` changing is what triggers a new
  fly-in and resets the spin, matching that a target switch is a fresh lock
  attempt with no partial credit (same rule the audio/haptic feedback
  already follows).
- **Disappears the instant tracking stops** — trigger released, target
  lost, or (transiently, before the next designation) mid-switch. Visibility
  is driven directly off `tracked_target_index >= 0 and _battle.is_alive(...)`,
  so there's no separate state to fall out of sync with the actual lock.
- Verified headlessly end to end: designates, flies in and converges exactly
  onto the true target direction, spins while acquiring, settles and turns
  green on lock, and vanishes on release — 15/15 checks passing.

## Countermeasure flares

Left controller's X button ("ax_button", free during normal flight —
`options_menu.gd` only reads it while its own menu is open). Direct user
request, described as a general "whoever's targeted can defend themselves"
mechanic — implemented on both sides, and both sides are real: the player
shoots missiles at aliens, and (rarely) aliens shoot missiles back at the
player — see Alien missiles at the player below for how that loop closed.

- `scripts/flare_system.gd` (`FlareSystem` node under `Player`) — the
  player-facing half: X deploys a flare from the ship
  (`_deploy_flare()`), and tracks it as `last_flare` — whatever a
  player-targeting missile checks (see missile.gd below) the first time
  it enters the flare window. `is_instance_valid(last_flare)` doubles as
  "is it still burning," since `Flare.tscn` self-frees after its 10s
  lifetime, so an old/expired flare just reads as "no flare available."
- The other half: **aliens auto-deploy flares against the player's own
  missiles**, since aliens have no button to press. Either direction,
  `missile.gd`'s `_maybe_check_flare()` is edge-triggered the first frame
  a missile is within [`FLARE_MIN_RANGE` 100m, `FLARE_MAX_RANGE` 400m] of
  its target: against an alien, calls
  `FactionBattle.try_deploy_alien_flare(index)` (always spawns — no
  limited flare supply was specified); against the player, reads
  `FlareSystem.last_flare` directly instead. Either way then rolls
  `FLARE_REDIRECT_CHANCE` (40%) — on success the missile's tracked target
  permanently switches to the flare `Node3D` itself, so it flies at and
  detonates on the flare instead — a miss for the real target. Only one
  attempt per missile per flight (matching "push the button before the
  missile hits you" as a single reaction, not a repeatable trick).
- `scenes/Flare.tscn` / `scripts/flare.gd` — "just like real flares," per
  the request: two pellets eject from the single deploy point and
  fall/diverge under gravity (800 m/s², the same scaled-gravity convention
  `falling_debris.gd` already uses) while burning, converged at the source
  and spreading apart below/behind it as they fall — tracing an
  upside-down "Y", the same shape real flare pairs make. Each pellet is a
  bright `OmniLight3D` (dims out over the last 2s, not an instant cutoff)
  + a hot core sprite + a trailing smoke column, reusing the same
  `smoke_flipbook.png` the rest of this project's smoke uses (see the
  Crash system bullet). Burns for 10 seconds (real flare burn time), then
  self-cleans.

**Both directions of this were dead code until recently** — the flare
countermeasure had nothing to defend against and no alien missile could
damage the player, because of the before-`add_child()` property-ordering
bug documented under Faction Battle. Flares are only genuinely exercised
now that that's fixed, so the 40% redirect roll and the 100-400m window are
still unverified in play.

## Alien missiles at the player

`missile.gd` gained a second mode (`target_is_player: bool`) so the same
homing/flare/overshoot logic works both directions instead of needing a
parallel script: `false` (the original/default) tracks an alien by index
through `battle`; `true` tracks the player's own ship directly and, on
impact, damages `player_damage.gd` by hit zone the same way
`laser_bolt.gd`'s existing player-hit path already does
(`classify_hit_zone()` / `apply_damage()`), instead of
`FactionBattle.apply_damage()`. A `target_is_player=true` instance also
adds itself to the `"player_seeking_missiles"` Godot group in `_ready()`
— see Missile alert below for who reads that.

This is deliberately **rare**, not symmetric with the player's own
missile — real teeth for `flare_system.gd`'s X button (which otherwise had
nothing to defend against) and the alert below, without turning every
alien encounter into a missile barrage. `combatant.gd` gained a second,
independent cooldown (`missile_cooldown`, separate from the existing
`fire_cooldown` ambient-laser one) seeded randomly on spawn
(`MISSILE_COOLDOWN_MIN`/`MAX`, 15-30s) so aliens don't all become
missile-ready in lockstep after a mass respawn. In `_update_combatant()`,
an alien currently `targeting_player` and off cooldown fires a real
`missile.gd` instance (`_fire_missile_at_player()`) whenever the player is
within `MISSILE_ENGAGE_RANGE` (2500m — deliberately longer stand-off than
the 700m ambient-bolt `ENGAGE_RANGE`, missiles are a real threat, not
routine) — independent of and in addition to that same alien's ordinary
ambient-laser fire, which keeps happening on its own much shorter
cooldown.

## Missile alert

`scripts/missile_alert.gd` (`MissileAlert` node under `Player`) — plays
two layered warning sounds the instant the player becomes tracked by an
incoming alien missile, stopping (well, the sounds finish naturally —
nothing interrupts them) the moment none remain. Detection is
group-based, not polling anything directly: checks whether
`get_tree().get_nodes_in_group("player_seeking_missiles")` is non-empty
each frame — a missile leaves the group automatically the moment it's
freed (hit, expired, or redirected to a flare), no manual bookkeeping
needed on this end.

Both alert sounds are user-supplied (`alert/fnx_sound-alien-alert-noise-
287332.mp3` / `alert/u_00gvvdfqjf-alert-369027.mp3`, outside the Godot
project) and played simultaneously as two separate `AudioStreamPlayer`s —
same "two tracks at once" pattern the main menu's music+chatter already
established, and non-positional for the same reason the menu tracks are:
this is a cockpit alert, not a world-space effect. Processed once via
`ffmpeg` per explicit request — bass boost, soft reverb, highs rolled off,
volume trimmed down: `bass=g=8:f=100:w=0.5,lowpass=f=3200,aecho=0.8:0.7:
60:0.25,volume=0.7`, saved as `Assets/Audio/missile_alert_1.mp3` /
`missile_alert_2.mp3`.

## Flight HUD — projected on the ship's own glass, not the helmet

Two genuinely different HUD layers now exist in this game, and the
distinction is load-bearing, not cosmetic:

- **Helmet-anchored** — `hud.gd`, `kill_feed_hud.gd`, `player_health_hud.gd`,
  `battle_hud.gd`, all `Label3D`s parented under `XRCamera3D`. These stay
  centered on the player's VIEW regardless of head rotation — appropriate
  for debug info (FPS/PERF), kill feed, health, and match stats
  (Air Superiority %/timer), none of which is about *flying the ship*, all
  of which were explicitly kept here per direct instruction.
- **Ship-anchored (glass)** — `scripts/flight_hud.gd` (`FlightHUD` node,
  child of `Ship`, not `XRCamera3D`). This is the new one: speed, altitude,
  heading, thrust input, and the flight-path (velocity vector) marker — the
  actual flight-dynamics telemetry, "a holographic image on the glass of
  the ship itself above the dashboard." Being parented under `Ship` instead
  of the camera is what makes that true: it shows real parallax as the
  player moves their head, exactly like `weapon_system.gd`'s pre-existing
  `Ship/Crosshair` already does ("like a reticle etched on the glass, not a
  HUD marker") — `FlightHUD` reuses that same parenting convention for
  every element it builds, rather than introducing a second HUD philosophy.
  `hud.gd` had its `SPEED` line removed to match (moved here); FPS/PERF/
  GUN/MSL/CITY are debug or weapon/objective status, not flight dynamics,
  and stayed on the helmet by the same reasoning that kept kill feed and
  match stats there.

**`hud_center` (local `y=1.9, z=0.9` in `Ship`'s space) is a first-pass
placement, unverified in the headset** — seeded near the existing
`GunMountLeft`/`GunMountRight` position (an already-established
in-front-of-the-pilot spot) rather than guessed from nothing, but this
cockpit's actual dashboard/glass geometry has never been measured. Same
caveat as `ShipHull`'s placement and every other cockpit-relative
placement in this project: will likely need live-in-VR correction.
`+Z is forward` in `Ship`'s local space throughout this script (not
Godot's usual `-Z`), matching `weapon_system.gd`'s own convergence-point
math — `Ship` carries a 180-degree flip basis to correct its glTF's
backwards-authored forward direction (see `Player.tscn`'s node comment
history), and every offset in `flight_hud.gd` follows that same
convention rather than reintroducing the flip as a bug.

- **Flight path marker** — "shows where your ship will be in the next
  1000 meters," i.e. the real velocity-vector direction, not the nose
  direction — meaningfully different information on a flight-assist-off
  ship (see the flight-model section above), where momentum and heading
  routinely diverge. Positioned each frame at `hud_center +
  ship_local_velocity_direction * marker_distance` — `flight_controller.gd`
  gained a `get_velocity()` getter (previously only `get_speed()`, the
  scalar magnitude, existed) so this could read the real vector. This is
  the exact same "fixed apparent distance along a real direction" HUD
  placement trick `target_lock.gd`'s PIP ring already uses, just anchored
  to `Ship`'s frame instead of the camera's — anchored differently because
  it needs to sit fixed on the glass, not track the player's view. Hidden
  below `marker_min_speed` (2 m/s) rather than showing a jittery direction
  near-zero velocity.
- **Crosshair — open ring, not a dot, replacing the sphere.** `Player.tscn`'s
  `Ship/Crosshair` keeps the exact position `weapon_system.gd` already
  computes (the real 229m gun-convergence point — no code changes there);
  only its mesh/material sub-resources changed, `SphereMesh` →
  `TorusMesh` (inner 0.22 / outer 0.32), restyled to the neon palette
  below. **Real gotcha hit and fixed**: Godot's `TorusMesh` lies flat with
  its hole-axis along local Y by default (confirmed by `target_lock.gd`'s
  own PIP ring needing `BILLBOARD_ENABLED` just to face the camera at
  all) — without a fix the ring would render edge-on as a sliver from the
  cockpit. Fixed with a baked 90-degree rotation on the `Crosshair` node's
  own transform (not billboarding — this needs to keep real depth/parallax
  like the sphere it replaced, not always face the camera). The open shape
  is deliberate: designed to be visually lined up over `target_lock.gd`'s
  existing yellow PIP ring for a lead-computing gunsight read, the same way
  a real HUD's static reticle and dynamic funnel/pipper work together —
  no conflict between the two even though one is ship-anchored (real
  parallax) and the other is visor-anchored (fixed apparent size), since
  both ultimately render toward the correct real-world direction.
- **Altitude ladder** — two thin vertical lines flanking the crosshair plus
  a moving tick, encoding `Ship.global_position.y` directly. No terrain
  sampling needed: this project already treats world `Y=0` as sea level
  (motherships/`dome_center` are placed against that same convention), so
  the ship's own altitude *is* the sea-level-relative figure. Linearly
  mapped and clamped across `altitude_range` (±3000m first-pass) rather
  than left unbounded, so an extreme altitude doesn't fling the tick
  off-frame.
- **Thrust gauge** — a simple two-part vertical bar (dim track + bright
  fill scaled 0..1) reading `absf(right_grip_value - left_grip_value)`
  (both already exposed on `flight_controller.gd`). Deliberately INPUT, not
  resulting velocity — on a flight-assist-off ship those are genuinely
  different signals (see the flight-model section above), and speed is
  already shown separately.
- **Heading readout** — small addition beyond the literal request, cheap
  given the data was already on hand. Derived from `Ship`'s actual forward
  DIRECTION vector (`basis * Vector3(0,0,1)`, then `atan2`), **not**
  `Basis.get_euler()` — a real bug caught before it shipped: `Ship`'s baked
  180-degree flip basis would have corrupted an Euler-angle decomposition,
  reading 180 degrees off. Reading where local +Z actually points in world
  space sidesteps the decomposition entirely.

**Font — Orbitron**, SIL Open Font License 1.1 (`Assets/Fonts/`, license
text included), fetched from Google Fonts' variable-font release (one file,
all weights, selectable via Godot's `FontVariation` if a specific weight is
ever needed — no separate Regular/Bold files to keep in sync). Applied via
each `Label3D`'s `font` property, project-wide: both the new `FlightHUD`
labels and every existing helmet HUD/menu/death-screen label, per direct
instruction that any text currently on the helmet or screen should match.
"Neon/electronic" is styling on top of the glyphs, not a font-shape
property: `modulate` colors pushed **above 1.0** per channel (e.g.
`Color(0, 2.2, 2.4)`) so the existing Glow post-process (`Town.tscn`'s
Environment, already enabled, threshold 1.15) actually blooms the text —
the same technique this project's emissive materials already use via
`emission_energy_multiplier`, just applied to text instead — plus a dark
outline for legibility against a bright sky, matching the existing
`DeathScreen` label convention. Colors that already carried meaning
(`DeathScreen`'s red, `MainMenu`/`DeathScreen`'s grey hint text) were left
alone; only the plain-white labels got the neon treatment.

Verified headlessly: `FlightHUD` builds all its child nodes without error
inside a standalone `Player.tscn` instantiation, the flight path marker
correctly hides at rest (zero velocity), and the altitude tick's mapped
position matches the expected clamped value at both an extreme-positive
and below-sea-level altitude.

**Real bugs caught on the first live pass, all fixed:**

- **Backwards text.** A non-billboarded `Label3D`'s readable front face
  points along its own local +Z by default. The pilot sits at a lower Z
  than `hud_center` looking toward +Z — the same direction the label
  itself faced, un-rotated — so the pilot only ever saw the text's BACK,
  which renders mirrored. Every existing `Label3D` in this project before
  `flight_hud.gd` used `billboard = 1`, which sidesteps this entirely by
  always facing the camera — these are the first non-billboarded labels in
  the project, so this was a fresh bug, not a regression. Fixed with
  `label.rotation.y = PI` in `_build_label()` — a real 180-degree rotation,
  not a mirror, so the text reads correctly rather than just relocating
  which side looks wrong.
- **Invisible/edge-on crosshair**, same root cause class as the text bug.
  `TorusMesh` lies flat with its hole-axis along local Y by default; the
  first version hand-picked a fixed 90-degree rotation to face it forward,
  which is exactly the kind of guess that's easy to get backwards. Fixed by
  billboarding the material instead (`billboard_mode = 1` on
  `StandardMaterial3D_crosshair`), the same technique `target_lock.gd`'s
  PIP ring already uses for this identical shape — guaranteed correct from
  any angle, position/parallax untouched.
- **Elevation track and thrust gauge fully invisible.** Ordinary depth
  testing let the cockpit's own dashboard mesh occlude them — they sit
  close in front of the pilot (unlike the original crosshair, which was
  always 229m out, past any physical cockpit geometry regardless of depth
  testing). Fixed with `no_depth_test = true` on every close-in `FlightHUD`
  element's material — a real HUD combiner reflects light off glass in
  front of everything in the cockpit, so always-on-top is the physically
  correct behavior here, not a hack.
- **Scale and placement, tuned twice against direct feedback**: the flight
  path marker sits close to the camera (~1.6m) rather than far away like
  the crosshair (229m), so the same radius that reads as a fine reticle at
  range read as a huge ring up close — cut to `marker_inner/outer_radius`
  0.009/0.012 (previously 0.09/0.12, a 10x reduction, per "needs to be
  about ten percent of the size it currently is") and recolored plain white
  (`MARKER_WHITE`, not green — real HUDs use a neutral velocity-vector
  symbol so it isn't mistaken for a faction-tinted or weapon-status color).
  `hud_center` was raised twice — 1.9 → 2.35 → 2.9 — after two rounds of
  "too low"/"sitting on the dashboard, half on the dash, half in the
  glass," and `element_scale` was halved (1.0 → 0.5) after "way too big"
  covering the whole cluster.
- **Real, reproducible Godot quirk worth remembering**: running
  `godot --headless --editor --quit` appears to strip
  `emission_enabled`/`emission`/`emission_energy_multiplier` from
  `StandardMaterial3D_crosshair` specifically on resave, even though the
  identical properties on programmatically-built materials elsewhere
  (everything in `flight_hud.gd`, built at runtime in GDScript, never
  written to the `.tscn` at all) are unaffected. Reproduced twice across
  separate edits. The crosshair still renders — `shading_mode = 0`
  (unshaded) shows its flat `albedo_color` regardless — it just loses the
  extra bloom glow on scenes that get resaved this way. Not yet root-caused
  beyond "this specific static-scene material, this specific property
  set"; worth a look if it recurs elsewhere.

**Second live pass — a real drift bug, fixed at the source:**

- **Crosshair read as a dot, not a circle.** At 229m out, the original
  ring (inner 0.22 / outer 0.32) subtended well under a fifth of a degree —
  invisible as an "open" shape at any plausible VR angular resolution.
  Sized up roughly 9x (inner 2.0 / outer 3.0), landing around 1.5 degrees
  of apparent diameter, comfortably legible as a ring rather than a point.
- **Ladder not centered on the crosshair — root-caused, not just
  re-tuned.** Reported as "the bottom of [the ladder] is sitting even with
  the crosshair... the crosshair needs to sit between those two bars."
  The actual cause: `hud_center.y` had been raised twice (1.9 -> 2.35 ->
  2.9) to fix the STATIC cluster's own placement, but the crosshair's
  Y is computed entirely separately, in `weapon_system.gd`, from
  `GunMountLeft`/`GunMountRight`'s own fixed y=1.9 — the two values were
  never linked, so every ladder-placement fix silently pulled the ladder
  further from the crosshair instead of closer. Fixed at the source rather
  than by hand-copying another number: `flight_hud.gd` now reads
  `GunMountLeft`/`GunMountRight`'s average Y itself in `_ready()` (a static
  scene value, available immediately — no dependency on
  `weapon_system.gd`'s own `_ready()` having already run) and overwrites
  `hud_center.y` with it, so the two literally cannot drift apart again.
  Verified headlessly: crosshair Y, gun-mount average Y, and
  `flight_hud.hud_center.y` all read exactly 1.9 after this fix.
- **Ladder bars widened 50%** (`ladder_x_offset` 0.16 -> 0.24) for
  clearance around the now-larger crosshair sitting between them, per
  direct request.

**Third pass — a screenshot this time, not just a description:**

- **The Y-lock-to-crosshair fix from the second pass was itself wrong**,
  caught immediately: "that is way too low again, now you drop the
  elevation into the dashboard... it was almost in the perfect spot, it
  just needed to go down a couple inches." Root cause: matching two
  objects' raw local-Y coordinates does not make them appear vertically
  aligned on screen unless they're at the same DEPTH — the crosshair sits
  229m out and the ladder sits 0.9m out, so the same Y offset from the
  camera's real eye height subtends a far bigger apparent angle up close
  than it does 229m away. The crosshair barely moves on screen across a
  wide range of Y values for exactly this reason, which is what made the
  coordinate-matching fix look plausible in code while being visually
  wrong. Reverted to a plain, directly-tunable `hud_center.y` (2.8 — "2.9
  was almost perfect, just needed to go down a couple inches") rather than
  deriving it from anything. **The lesson**: apparent on-screen alignment
  between elements at different depths has to be tuned by eye against real
  feedback, not solved with a coordinate trick — the same category of
  mistake as assuming two things "look aligned" just because a formula
  says their numbers match.
- **Crosshair enlarged again** after a screenshot showed it reading as
  a small mark rather than a clear circle even after the first size pass —
  `TorusMesh_crosshair` inner/outer radius 2.0/3.0 (up from 0.22/0.32
  originally, roughly 9x), which at 229m works out to roughly 1.5 degrees
  of apparent diameter.
- **Yellow objective arrow removed entirely**, per direct instruction
  ("get rid of the yellow objective marker") — visible in a supplied
  screenshot as a distracting wedge floating in the sky. Only the visual
  `Arrow` `MeshInstance3D` (and its now-unused `CylinderMesh`/
  `StandardMaterial3D` sub-resources) came out of `Player.tscn`;
  `enemy_locator.gd` keeps running every frame and still exposes
  `distance_to_objective`, which `hud.gd`'s `CITY:` line still reads (with
  the now-stale "follow the yellow arrow" wording dropped from that line).

**Not yet verified**: actual on-glass position/legibility/minimalism in VR
with all of the above applied — needs another live headset pass, same as
every other cockpit placement in this project.

## Visual grade — smoggy, wet, and not cartoony

The scene originally had a nearly empty `Environment`: no tonemapping, no
fog, no glow, no colour grading. Godot's default `tonemap_mode` is **Linear**,
which is exactly what "it looks sort of cartoony" is — flat, clipped
highlights and oversaturated mids. All of this lives in `Town.tscn`'s
`Env_1` sub-resource.

- **ACES filmic tonemapping** (`tonemap_mode = 3`, white 6.0). Single
  biggest change, and it costs nothing — it's the same fullscreen pass that
  was already running.
- **Fog is altitude-driven** (`scripts/atmosphere.gd`, `Atmosphere` in
  `Town.tscn`) — see Altitude-driven fog below. `fog_mode = 1` (Depth) with
  an explicit metre range, because exponential density is unmanageable at
  100x world scale.
- **Glow** at low intensity (0.5, threshold 1.15, Screen blend). This is
  what makes the emissive lasers, engine trails and explosion fireballs
  read as hot rather than as flat coloured shapes. It's the one genuinely
  non-free item here (several half-res blur passes).
- **Colour grading** — contrast 1.14, saturation **0.78**, ambient dropped
  1.2 -> 0.85. The desaturation is most of the "Skyrim" character.
- **Wet surfaces are material, not post.** Roughness was lowered across the
  board so things catch a specular highlight off the sun instead of reading
  as matte cardboard: buildings 0.5 (`building_roughness`), roads 0.28 with
  `metallic_specular` 0.85 (`road_roughness` — wet asphalt is the shiniest
  thing down there), terrain 1.0 -> 0.72.

All of it is first-pass and unverified in the headset, like every other
visual tuning in this project. The exported roughness knobs and the
Environment's grade values are the dials.

### Altitude-driven cloud band + lit deck (`atmosphere.gd` + `cloud_deck.gd`)

Fog as a genuine **cloud layer at a fixed absolute altitude, covering the
entire map**, with clear air below it — not fog filling the sky down to the
ground. Two pieces, each doing what it's good at:

- `atmosphere.gd` (`Atmosphere`) — the FEEL of being inside the layer:
  drives depth fog's ramp from the player's absolute world Y, so visibility
  only collapses while inside `[cloud_base_y, cloud_base_y +
  cloud_thickness]`.
- `cloud_deck.gd` (`CloudDeck`) — the VISIBLE layer: a single lit mesh at
  the midpoint of that same band, alpha-blended with a soft noise pattern.

**Why absolute altitude, not local-ground-relative.** An earlier version
measured the band above LOCAL ground, resampled under the player every
frame. Two real complaints came out of that: the visible layer read as "way
too low" wherever the ground itself was low (since it was anchored to the
terrain directly under the city, ~800m up), and it only covered wherever
`cloud_deck.gd` had built geometry — the city footprint, not the rest of
the 100km map ("I'd like that fog to cover the entire map"). A fixed world-Y
band fixes both: it's the same altitude everywhere, mountains can poke up
into it exactly like real cloud-capped peaks, and it needs no per-location
terrain sampling in `_process()` at all.

**Why a mesh deck, not volumetric fog, for the visible layer.** This is the
cheap way to get the one thing volumetric fog was wanted for — building
shadows crossing the fog. Because the deck is an ordinary LIT surface
(`shading_mode = PER_PIXEL`), the sun's shadow map applies to it exactly as
it does to the ground, no froxel grid required. It's 1 draw call and
~18k triangles for the *entire map*, visible from any distance (it's
geometry, not a screen-space effect), and it cannot jitter because nothing
is resampled as the camera moves.

**The deck sits below the tallest towers on purpose** — shadows fall away
from the light, and the overhead sun cannot cast onto anything above
itself. With the deck at the band's midpoint, several hundred buildings
punch through it (measured: 483 of 1466 at the earlier city-only sizing),
and it's those protruding towers that lay real shadows across the cloud
surface below. Soft edges are carried in vertex alpha (`_edge_alpha`, a
radial fade using the larger of the two axis distances so the mesh's
corners fade too), so the deck doesn't terminate in a hard rectangle
against the sky at the map's own boundary.

**The "spider web" bug.** The first cloud texture (noise frequency 0.9, 4
fractal octaves, a gradient snapping from 0.0 to 0.12 alpha within the
first 38% of its range) read as a lace/web pattern from above rather than
fog. High-frequency fractal noise is naturally made of thin connected
ridges, and a high-contrast alpha cutoff turns those ridges into visible
tendrils instead of soft puffs. Fixed on both ends: the noise itself is
lower frequency with fewer octaves (fewer, bigger blobs), and the gradient
floor is raised with the whole ramp widened so there's no sharp edge for a
ridge to snap into — density now fades gradually instead of tracing the
noise's contour lines.

**A real node-ordering bug worth remembering.** `CloudDeck`'s original
`_ready()` sampled `Terrain.get_height_at()` to place itself, but Godot
calls `_ready()` parent-to-child, sibling-by-declaration-order — not
dependency order — and `CloudDeck` was declared before `Terrain` in
`Town.tscn`. The heightmap was still empty, `get_height_at()` returned 0
for every sample, and the entire deck landed 55m above sea level instead of
hundreds of metres above the actual ground. Moving to an absolute-altitude
model (reading `Atmosphere.cloud_base_y` and `Terrain.world_size`, both
plain exported values available immediately, not `_ready()`-computed state)
removed the dependency entirely rather than just reordering the fix.

**Measured response at the city** (band 3200-3800m, 220m soft edges):

| altitude | zone | clear to | opaque at |
|---|---|---|---|
| 4400m | above the clouds | 2500m | 70000m |
| 1400m | below — clear | 2500m | 70000m |
| 3200-3800m | **IN CLOUD** | 113m | 450m |

Confirmed identical at a point 40km from the city, near the world edge —
the band is genuinely global. `interior_visibility` (450m) is the single
dial for "how blind am I inside the cloud"; `cloud_base_y`/`cloud_thickness`
on `Atmosphere` are the only two numbers that define the band's real-world
position, and `CloudDeck` reads them directly rather than duplicating them.

**Volumetric fog is deliberately not used**, despite three separate
attempts. All three failed structurally, not on tuning:

- **Jitter.** The froxel grid stretched over this 100x world worked out to
  **~187m per depth slice** (12000m over 64 slices). Every camera movement
  resampled across those enormous cells and the fog visibly swam, with
  temporal reprojection fighting VR head motion on top.
- **Range.** The grid only exists within `volumetric_fog_length` of the
  camera, so nothing was visible until the player had nearly flown into
  whatever it covered.
- **Cost is the grid itself, not the fog's thickness** — a 147,456-cell
  (48x48x64) 3D grid evaluated every frame, per eye in VR, with a shadow
  lookup per lit cell if shadows were wanted. A thin volumetric layer costs
  exactly the same as a thick one, since the expense is the grid existing
  at all.

Driving the depth-fog ramp by altitude costs three property writes a frame
and cannot jitter, because nothing is being resampled. The mesh deck is 1
draw call. `volumetric_fog_enabled` is absent from the Environment, so no
grid runs at all.

**Rejected approaches kept in history rather than re-attempted:** plain
height fog (monotonic, can't bound a slab, reaches the ground everywhere);
drifting volumetric fog banks (read as blobs arriving nearby); a
player-following volumetric sheet (fixed the blobs, put fog everywhere);
city-only volumetric tiles (still jittered, invisible until close); a thin
volumetric layer above the fog purely for shadows (costs the same as a
thick one, for the reason above); ground-relative cloud placement (too low
over low terrain, city-footprint-only coverage).

### Overcast lighting under the deck

`atmosphere.gd` also dims and cools the sun and ambient light for the whole
space **underneath** the cloud band, since real direct sunlight is heavily
diffused by an actual cloud layer and everything below was reading as full
unobstructed sunshine under a sky that's nominally overcast.

- Reuses the cloud band's own bounds for the transition rather than a
  separate softness constant (`_overcast_factor`): 0.0 (untouched) at or
  above the band's own TOP, ramping linearly to 1.0 (fully overcast) at the
  band's BOTTOM, staying at 1.0 for everything further down. Physically,
  sunlight is progressively cut off as you sink through an actual cloud
  layer, so "how overcast does it feel" and "how far down through the
  clouds have you come" are treated as the same question rather than two
  separately tuned curves that could drift out of sync.
  **Above the clouds is left completely untouched by construction** — this
  was a direct requirement, verified bit-for-bit equal to the scene's
  authored sun energy/colour/ambient at and above the band's top, not just
  approximately close.
- `overcast_sun_energy_scale` (0.32) and `overcast_ambient_energy_scale`
  (0.55) scale `DirectionalLight3D.light_energy` and
  `Environment.ambient_light_energy`; `overcast_sun_color` (a cool grey,
  0.72/0.75/0.8) is lerped in alongside the energy scale, because dimming
  alone still reads as "the same warm sun, just turned down" rather than a
  genuinely different sky.
- **Base values are captured from the scene's own authored numbers in
  `_ready()`** (`_base_sun_energy`, `_base_sun_color`,
  `_base_ambient_energy`), not hardcoded — if `Town.tscn`'s lighting is
  ever retuned, "untouched" automatically follows the new baseline instead
  of silently reverting to a stale constant.
- Verified across the full range: exactly the base values above and at the
  band's top, partial dimming partway down that's strictly between the base
  and the floor, the exact configured floor once fully below, and full
  recovery on climbing back above — 10/10 checks.

### Shadows
`shadow_enabled` was **already true** on the Sun and had been the whole
time — but Godot's default `directional_shadow_max_distance` is **100
metres**, in a world where the city is 10800m across and buildings are
hundreds of metres tall. Shadows were being rendered for a 100m bubble
around the camera and were effectively invisible. That default is the bug,
not the shadow setting.

Made affordable rather than merely enabled:

- `directional_shadow_max_distance` 100m -> **14000m**, and
  `directional_shadow_mode = 1` (PSSM, **2 splits**) so the near split keeps
  resolution on whatever you're flying past while the far split reaches
  across the city. Started at 6000m/Orthogonal for cheapness, but 6000m
  turned out to be shorter than the distances that matter here — the city
  is 22500m from spawn, so nothing cast a shadow anywhere in view and it
  read as "no shadows".
- **Shadows deliberately do NOT reach the city from spawn**, and chasing
  that would be wrong: at 22km a building's shadow is far below one pixel,
  and covering it would mean ~12m shadow texels plus worse acne everywhere
  else. Shadows fade in as you approach and are crisp where the fighting
  actually happens. The immediately visible one at spawn is the
  mothership's own shadow cast onto the terrain 3822m below it.
- `shadow_bias` 1.5 / `shadow_normal_bias` 12.0, scaled up hard from the
  defaults because the depth range is 60x larger than the value they were
  tuned for. Acne vs peter-panning is the thing to watch in the headset.
- **The terrain is excluded from the shadow pass**
  (`SHADOW_CASTING_SETTING_OFF`, still receives). It is a 513x513 grid —
  **524,288 triangles, roughly ten times the entire city** — so letting it
  cast would dominate the whole cost of having shadows, purely for mountain
  self-shadowing barely visible from a cockpit. This single exclusion is
  what makes building shadows cheap.
- Ships, ambient bolts and street tiles are also excluded — 200 small
  fast-moving ships would re-render into the shadow map every frame for
  shadows a few pixels across, and flat road slabs have nothing to cast.
- Measured result: **the shadow pass renders ~50,000 triangles instead of
  ~574,000.**

## Proximity engine audio

Every AI ship has a sphere of influence: fly close enough and you hear its
engine, falling off and muffling with distance.

- **Source** — `Assets/Audio/ship_engine.ogg`, one 72s mono loop merged
  from three user-supplied rocket recordings (`externalengines/`) via
  `ffmpeg`: each pitched down with `asetrate`, mixed with `amix`, then bass
  boosted, given resonant peaks at 240Hz and 560Hz, run through `vibrato`
  for the wail, and low-passed. Mono because `AudioStreamPlayer3D` can only
  position a mono source.
- **Pooled emitters, not one player per ship** (`scripts/ship_engine_audio.gd`,
  `ShipEngineAudio` under `FactionBattle`). 200 simultaneous positional
  voices with per-voice distance filtering is far past what Godot's audio
  server will do and would be a serious CPU cost on its own — and the
  combatants aren't Nodes anyway. Instead a fixed pool (`voice_count`, 12)
  is dynamically attached to whichever ships are nearest the player. This
  is the standard approach for crowd/vehicle audio; among ships you can't
  hear, you can't tell which one isn't emitting.
- **Voice stealing is the part that needs care**, since naive reassignment
  pops audibly. Two mitigations: **hysteresis** (a voice keeps its ship
  until it dies or leaves `audible_radius * release_hysteresis`, so ships
  hovering at the boundary don't cause churn) and **gain ramps** (voices
  fade rather than cut, and a released voice must fade essentially to
  silence before it can be reused). The streams never stop — only the gain
  moves — and each starts at a random offset so the pool doesn't phase-lock
  into unison.
- **Distance behaviour** is mostly Godot doing the work: `unit_size` /
  `max_distance` / inverse-distance attenuation for volume, and crucially
  `attenuation_filter_cutoff_hz` for **air absorption** — high frequencies
  die with distance far faster than low ones, so a distant engine is duller
  as well as quieter. That single property sells distance more than the
  volume curve does.
- **Doppler wail** is computed here from the combatant's own known velocity
  (`_voice_pitch`), NOT Godot's built-in `doppler_tracking`. The built-in
  derives velocity from how the node moved between frames, and these
  emitters *teleport* when reassigned — which would fire an enormous pitch
  spike on every voice steal. Each ship also gets a per-ship base pitch so a
  formation doesn't sound like one engine played twelve times.
- Verified headlessly: 12/12 voices attach inside the fleet with 12 distinct
  pitches, and all release and fade to silence after flying 30km away.

`FactionBattle` gained `get_ships_near()` / `is_ship_alive_by_key()` /
`get_ship_position_by_key()` / `get_ship_velocity_by_key()` for this. Ship
"keys" pack faction and index into one int (`SHIP_KEY_ENEMY_OFFSET`), since
combatants live in two separate arrays and a bare index is ambiguous.

## Death screen

`scripts/death_screen.gd` (`DeathScreen` under `XRCamera3D`) plus
`GameFlow.State.DEAD`. Previously the player was frozen on death and
silently auto-respawned on a 10-second timer with no explanation.

- Fades to red on death (`FADE_IN_DURATION` 1.1s) but only to `max_alpha`
  (0.62), never opaque — a solid red screen would hide the wreck the player
  presumably wants to see.
- Offers **RESPAWN** / **MAIN MENU**, selected by thumbstick and confirmed
  with the right trigger. Built as a close sibling of `main_menu.gd` and
  for the same reasons — including that selection is NOT gaze-based, since
  this node is a child of `XRCamera3D` and gaze selection on head-locked UI
  is mathematically inert (see the Game Flow section for that bug).
- `crash_handler.gd` no longer respawns on a timer. `RESPAWN_DELAY` dropped
  from 10s to **2s** and now only gates how soon the choice becomes
  available (`can_respawn()`), so a trigger still held at the moment of
  impact can't instantly skip the wreck. `respawn_now()` is the public
  entry point `game_flow.gd` calls on confirm.

### The persisting hull-damage noise

Reported as hit sounds still playing after respawn. The cause was the
assets, not the logic: two of the four supplied `damage_hit_*.mp3` files
were **33 and 64 seconds** long — full recordings rather than impacts — so
a single hit started a sound that played straight through the death, the
crash sequence and the respawn. All four are now trimmed to ~1.2s impacts
(`silenceremove` to strip leading silence, then a 1.3s window with a fade).
`player_damage_audio.gd` also gained `stop_all()`, called from
`crash_handler.gd` on both crash and respawn — whatever the assets are,
nothing it started should survive the player dying.

## Kill feed

Bottom-left of the visor (`scripts/kill_feed_hud.gd`, `KillFeedHUD`
`Label3D`, mirroring the bottom-right speed/gun HUD's position) — who died
and how. `faction_battle.gd` owns the actual state (`kill_feed_text`, a
pre-joined string the HUD script just displays): a ring buffer capped at
`KILL_FEED_MAX_ENTRIES` (6) with per-entry age-based expiry
(`KILL_FEED_ENTRY_LIFETIME`, 8s), so it can't grow into a wall of text
during heavy combat. Anchored from the label's **bottom** (matching
`target_lock.gd`'s top-anchor trick in spirit) so new entries push the
block upward rather than growing off-screen downward.

Attribution required threading a `cause: String` through the whole
damage/kill call chain that didn't exist before:
`_kill_combatant(c, index, cause)` now takes the victim's own index
(previously derived nowhere — every call site already had it in scope,
just wasn't passing it) and a cause string, formats
`"%s %s" % [_combatant_label(c.faction, index), cause]`
(`FRIENDLY-042`/`HOSTILE-077`, same naming convention `target_lock.gd`
already used) and appends it. Causes: `"crashed"` (terrain/building),
`"shot down by FRIENDLY-NNN"`/`"shot down by HOSTILE-NNN"` (ambient
bolts — required adding `shooter_index` to the previously-anonymous bolt
dict, `_spawn_ambient_bolt()` now takes the firing combatant's own index),
`"destroyed by PLAYER"` (the player's guns, `apply_damage()`'s new default
`cause` parameter), `"destroyed by PLAYER missile"` (explicit `cause` from
`missile.gd`).

## Game Flow — start menu / end-of-match menu

`scripts/game_flow.gd` (`class_name GameFlow`, `GameFlow` node in
`Town.tscn`) is a small state machine (`MENU` -> `PLAYING` -> `GAME_OVER`
-> back to `MENU`) wrapping the player's controls and
`FactionBattle.simulation_active` — **everything still lives in one scene**
(`project.godot`'s `run/main_scene` has only ever pointed at `Town.tscn`;
there's no second menu scene). "Returning to main menu" is a soft reset
back to the pre-match state, not a real scene reload — reloading a live
OpenXR session mid-play would be real added risk/complexity a "basic" menu
request didn't call for.

- **MENU** (shown at launch, and again after `reset_battle()`): player
  flight/weapons/missiles paused (the same `paused` flag convention already
  shared by `flight_controller.gd`/`weapon_system.gd`/`missile_system.gd`/
  the options menu). Both fleets are already spawned and visible, just
  frozen — `FactionBattle` always writes its `MultiMesh` transforms every
  frame regardless of `simulation_active`, specifically so ships don't
  vanish (never having been given a transform) while the sim is paused.
  **The actual main menu** (`scripts/main_menu.gd`, `MainMenu` node under
  `XRCamera3D`, replacing an earlier plain text-prompt version
  `start_menu_hud.gd`, now removed):
  - **Solid black the whole time it's up, not a quick reveal** — `Fade`,
    an opaque `MeshInstance3D` quad positioned *closer to the camera*
    (z=-0.15) than every other menu element or the background scene, using
    **ordinary depth testing** rather than the `no_depth_test` trick the
    rest of this project's HUD uses (deliberate: being genuinely nearest
    in 3D space makes it reliably occlude the flying scene behind it).
    While `state == MENU`, `Fade` stays fully opaque (alpha 1) — a real
    black menu screen, not a translucent overlay on top of the flying
    scene, per a direct correction after the first version faded out
    immediately on entry. The instant `state` moves off `MENU` (START
    confirmed — `GameFlow` already unpauses the player and starts the
    battle immediately, no artificial delay to the actual gameplay logic),
    `main_menu.gd` notices independently and begins a **reveal**:
    title/button labels and audio stop right away, but `Fade` keeps
    rendering by itself, animating alpha 1 -> 0 over `FADE_DURATION`
    (2.5s), dissolving into the flight that's already underway underneath.
    **Real bug hit live**: being nearer to the camera than the
    Title/StartLabel/QuitLabel labels (z=-0.55) also meant `Fade` was
    painting *over* them — Godot sorts transparent objects back-to-front
    by camera distance, so the nearer, fully-opaque black quad was drawn
    last and completely overwrote the label pixels underneath every frame,
    even though the labels are `visible=true` with `no_depth_test=true`
    (audio played fine, since that path never touches rendering, which is
    what actually made this "no text, but sound's there" instead of "menu
    doesn't work at all"). Fixed with an explicit
    `render_priority = -1` on `Fade`'s material — transparent-pass sort
    order is priority-first, distance-second, so this guarantees `Fade`
    always draws before (visually underneath) the default-priority labels
    regardless of which one is physically nearer the camera.
    Re-entering `MENU` later (post-match) snaps `Fade` straight back to
    fully opaque.
  - **Two simultaneous audio tracks** — `Music` (`menu_music.mp3`,
    converted from a user-supplied `.m4a` via `ffmpeg`; Godot's importer
    doesn't support `.m4a` directly) and `Chatter` (`menu_radio_chatter.mp3`,
    distorted radio-chatter ambience, already an mp3), both plain
    (non-positional) `AudioStreamPlayer`s — this is cockpit-ambient sound,
    not a world-space effect, so proximity/attenuation doesn't apply here
    the way it does for `missile.gd`'s hit sound. Manually looped (`finished`
    reconnected to `play()`) rather than relying on the imported stream's
    own loop flag, for explicit control. Both start when the MENU state is
    entered and stop the moment it's left (`PLAYING` or otherwise).
  - **START / QUIT selection is by THUMBSTICK** — push either stick left
    for START or right for QUIT, then pull the right trigger to confirm.
    The selection is latched through a deadzone (`STICK_DEADZONE`) so one
    push moves it once instead of re-triggering while held. The highlight
    is deliberately heavy-handed (colour + 1.25x scale + outline together)
    because a subtle brightness difference between two small labels on a
    black screen is genuinely hard to read at VR resolutions, and a `Hint`
    label spells the controls out. This script only tracks and displays
    `selected_action` — it doesn't confirm anything itself; `game_flow.gd`
    (already the sole owner of trigger-confirm logic for both menu states)
    reads it on a right-trigger press and either starts the match or calls
    `get_tree().quit()`.
  - **This replaced a gaze-based version that could never have worked**, and
    the failure is worth remembering because any future head-locked UI here
    would hit it. `MainMenu` is a child of `XRCamera3D`, so the labels are
    rigidly attached to the player's face. Gaze selection compared the angle
    between the camera's forward vector and the direction to each label —
    but since the labels move with the head, those directions are constant
    in camera space, so both angles were fixed no matter where you looked.
    Worse, the two labels sat symmetrically (x = -0.13 and +0.13, identical
    y and z), making the two angles *exactly equal*, so the `<=` comparison
    always resolved to START: **QUIT was literally unselectable.** Gaze
    selection can only ever work against WORLD-locked UI. `_update_selection()`
    now takes the stick axis as a parameter rather than reading controllers
    itself, specifically so a headless test can drive it (there are no
    controllers without a live OpenXR session, which is precisely why the
    original bug shipped) — verified with a scripted run covering push,
    hold-without-repeat, release, and deadzone.
- **PLAYING**: right trigger confirms `_start_match()` (unpauses the
  player, calls `FactionBattle.start_battle()` which flips
  `simulation_active = true` — this is also the point the 10-minute timer
  and AS scoring actually start counting, not scene load). Normal
  gameplay from here, unchanged.
- **GAME_OVER**: entered when `FactionBattle.game_over` flips true (polled
  each frame by `GameFlow`, not signal-driven — simplest given the small
  state count involved). Player paused again; `battle_hud.gd`'s existing
  VICTORY/DEFEAT/DRAW line gains a "PULL TRIGGER FOR MAIN MENU" prompt.
- Right trigger is reused for both weapon fire (`PLAYING`) and menu
  confirm (`MENU`/`GAME_OVER`) with no real conflict —
  `weapon_system.gd` only reads it while `not paused`, and `GameFlow` sets
  `paused = true` for the whole player during both menu states, so the two
  readers are never live at the same time.
- **Return to menu** (`_return_to_menu()`): `player_damage.gd.reset_health()`,
  reposition the player back to `player_spawn_xz` (a fourth copy of the
  same `(-4000, 0)` coordinate — see the spawn-with-friendlies bullet
  above), `FactionBattle.reset_battle()` (re-`_respawn_combatant()`s every
  ship back to alive/full-health at their faction's spawn cluster, resets
  AS/timer/`game_over`, clears in-flight ambient bolts), then back to
  `MENU`.

## Retired systems

- `scenes/EnemyShip.tscn` / `scripts/enemy_ai.gd` (the old single wandering
  "HOSTILE-1", with its detailed 3-zone cockpit/engine/hull damage/smoke
  model, ground-avoidance, and dead-engine-glide behavior) — removed from
  `Town.tscn`'s active tree in favor of Faction Battle above, left on disk
  unused. Same convention already established for the old in-VR map editor
  below — not deleted in case any of its patterns (particularly the
  per-zone damage/smoke design, which the mass battle deliberately
  simplified away from for performance) get reused later.
- The old in-VR map editor (`scripts/map_editor.gd`, `tree_pickable.gd`,
  `tree_scatter.gd`, `scenes/WristMenu.tscn`) — still on disk, fully
  disconnected from the active scene tree, dead code from the pre-pivot
  concept.

## Reference docs

- `docs/flight-physics-reference.md` — real NASA/aircraft-performance-
  sourced constants (Earth atmosphere, drag equation, gravity, F-16
  pitch/roll rates) backing the flight tunables, plus a worked example of
  what the current `drag_coefficient` implies about the ship's assumed
  shape.
- `docs/gunnery-reference.md` — real historical gun-convergence/
  harmonization distances backing `weapon_system.gd`'s convergence math,
  plus the PIP/lead-computing intercept math used by `target_lock.gd`.
- `docs/damage-reference.md` — the 3-zone cockpit/engine/hull health model,
  sourced from DCS World's and Star Citizen's real component-damage models.
  Describes the retired `enemy_ai.gd`'s system (still the model
  `player_damage.gd` mirrors for the player's own ship) — the 400-ship
  Faction Battle mass units deliberately use a simpler single-HP pool
  instead, for performance at that scale.

## Testing workflow

Headless validation (`godot --headless --editor --quit`) catches
parse/script errors and forces asset (re)import before ever touching the
headset — run after nearly every change this session. **One known gap**:
`XRToolsFunctionPickup` (still present for the grab system, though nothing
in the current scene actually needs picking up) hangs indefinitely in
`--headless` **game** mode with no live OpenXR session — confirmed not a
project bug, just an addon limitation without real controller state. Net
effect: scene structure, parsing, and all gameplay logic can be verified
headlessly, but actual flight feel, VR rendering correctness, and audio can
only be confirmed live in the headset.

**Scripted simulations** (`--headless --script <path>.gd`, a
`SceneTree`-extending script that instantiates `Town.tscn`, sets
`current_scene`, calls `FactionBattle.start_battle()` and then `await
physics_frame` in a loop) are the only way to verify gameplay behaviour
without the headset, and this project leans on them heavily. Four hard-won
mechanics, all of which cost real time to rediscover:

- **Pass `--fixed-fps 60`.** Without it the loop is pinned to real time, so
  a 150-simulated-second run takes 150+ real seconds — and with the battle
  at full scale it ran *slower* than real time and appeared to hang. With
  it, the same run takes ~20s and total wall time becomes a clean,
  trustworthy measure of CPU work (see the A/B in Known gaps).
- **Log through `FileAccess` with an explicit `flush()`, not just `print`.**
  Piping Godot's stdout through `tail`/`head`/`grep` buffers or truncates
  it, which repeatedly looked like "the script never ran" when it had run
  fine. Writing to `res://<name>.txt` also means partial results survive a
  hang or a kill.
- `await process_frame` **twice** before touching anything a `_ready()`
  sets up — `_ready()` is deferred a frame after `add_child()`.
- `Performance.get_monitor(TIME_PHYSICS_PROCESS)` is **not trustworthy** in
  this mode — two identical runs disagreed with their own intermediate
  readings. Use wall-clock timing of a fixed workload instead.

**Blender is available locally** (4.2 and 5.2) and is the tool for anything
the Godot importer can't do — decimating, joining, renormalising, or
converting a format Godot doesn't read (it has no STL importer; glTF/`.glb`
is the target). Run headless as
`blender.exe -b --factory-startup -P script.py`. Two gotchas: the
executable sits one directory deeper than expected
(`Blender Foundation/Blender 5.2/5.2/blender.exe`), and Blender 4.2+ uses
`bpy.ops.wm.obj_import`, not the old `import_scene.obj`. See the Motherships
section for a worked example (932k triangles -> 124k, renormalised so the
Godot-side scale value is meaningful).

For measuring imported-but-unauthored mesh dimensions (building heights,
ship footprints) before choosing scale/placement values: a one-off
`--headless --script <path>` run with a `SceneTree`-extending script that
loads the resource and walks its `MeshInstance3D` nodes' AABBs — faster and
more reliable than guessing, used for both the enemy ship and every
building type in the city. The same `--headless --script` approach also
generated `soft_particle.png` (an `Image`/`ImageTexture` radial-gradient
draw, saved once via `save_png`) rather than needing an external image
tool.

**Exporting**: `export_presets.cfg`'s `include_filter` must contain
`*.raw16` — Godot's exporter only bundles files it recognizes as
resources (anything with a generated `.import` file), and the heightmap's
raw file deliberately has none (see the terrain bullet above for why the
raw file exists at all). Without that filter entry the terrain silently
doesn't ship in an exported build. Verified by an actual
`--headless --export-debug` run, not just reasoned about — confirmed
`res://Assets/Terrain/heightmap.raw16` appears in the pack log.

## Known gaps / natural next steps

- **Still open: FPS collapsed to ~6 during a live playtest.** Two
  hypotheses have now been *measured and eliminated*, which is progress
  even though the cause isn't found:
  - **Not the `ShipExplosion` kill effect** (the original suspicion, as the
    most recently added heavy visual). An instrumented headless run showed
    kill rate was near zero at the time and at most one explosion was ever
    concurrently live.
  - **Not the physics building-collision queries.** A wall-clock A/B over
    an identical 90-second fixed-fps workload measured 22729ms with the
    queries enabled vs 22353ms with them disabled — a 1.7% difference, i.e.
    noise. Separately, the new `MAX_BUILDING_HEIGHT` altitude gate was
    measured to skip **95-97%** of those queries outright, because combat
    almost always happens well above the rooftops.
  - Total headless main-loop cost at 100v100 works out to roughly 4ms/frame
    (5400 frames in ~22.5s wall). Meaningful, but nowhere near the ~166ms
    a 6 FPS frame implies, so **the remaining suspicion is firmly
    GPU-side.** The strongest candidate is `ShipExplosion`'s
    `OmniLight3D` at `omni_range = 6000` — a 6km-radius realtime light over
    a city of 1200+ buildings is enormous in a clustered renderer, and
    several at once would be devastating. It is now capped at
    `max_concurrent_explosions` (14) and dropped entirely beyond
    `explosion_light_range`, but **that range is still 4000m and the value
    itself has never been sanity-checked** — dropping `omni_range` hard
    (to a few hundred meters) is the first thing to try if this recurs.
    Other candidates: 200 un-LOD'd `ship1.obj` instances rendered in VR
    stereo, and the city itself.
  - `hud.gd`'s **PERF** line (`PROC:_ms PHYS:_ms DRAW:_ OBJ:_`) is still the
    tool for the next live test — compare `PHYS` against `DRAW` to settle
    CPU vs GPU. `friendly_count`/`enemy_count` and
    `enable_building_collision_check` remain `@export`ed bisection knobs.
    Note headless testing genuinely cannot measure GPU draw-call cost or VR
    stereo render time; this has to be read in the headset.
- **None of the new visual/audio work is confirmed in VR yet** — bolt size
  and speed, hit sparks, the kill-fireball budget, the damage flash's
  intensity, and especially the **screen shake amplitude** (`shake_amplitude`,
  0.11m, translation-only) are all first-pass values. Shake in particular is
  a VR comfort risk and is exported specifically so it can be dialled down
  or to zero without a code change.
- Alien laser fire at the player now plays the muffled `battle_laser.mp3`
  from `faction_battle.gd`'s own budgeted battle-audio path (it previously
  had no audio cue at all, since the gun-mount `AudioStreamPlayer3D`s the
  player's own shots use are bypassed by the mass-battle path). It is
  deliberately quiet and heavily low-passed; it may need raising once heard
  in the headset.
- The player's engine health has no flight-degradation effect (speed/turn
  rate don't drop as it takes damage) — unlike the retired `enemy_ai.gd`'s
  `_effective_cruise_speed()`/`_effective_turn_rate()` (still the reference
  pattern), this wasn't ported over for the player. Would be a small,
  direct port into `flight_controller.gd` if wanted.
- `ShipHull`'s placement (position/scale/rotation, matching `Ship`'s
  translation at 2x scale) is an unverified best-effort guess — ship1.obj
  and the cockpit glTF are from unrelated asset packs with very different
  proportions (a flat ~0.75m-tall hull vs. a ~3m-tall cockpit interior) and
  were never designed to nest together, so this needs live-in-VR viewing
  and likely correction, the same as every other asset placement in this
  project so far.
- `laser_bolt.gd`'s hit detection (both the player-vs-alien and
  alien-vs-player paths) is a swept segment-vs-sphere check (a single
  bounding radius, not the actual mesh shape) — fine for combat purposes
  but not exact collision. Same approximate philosophy applies to
  buildings/terrain being unpassable for ships (a hit crashes/kills you) via
  a single-point test on the ship's own origin, not a full collision hull.
- Asset licensing: the ship pack ("Spaceship Pack", now used by both the
  friendly and enemy factions) and the skyscraper pack included no license
  file — worth tracking down licensing before this goes anywhere public.
  The player cockpit is CC-BY-4.0 ("Spacefighter Cockpit (Wasp
  Interdictor)" by Comrade1280 — attribution required if shipped).

## History

Godot was the original engine. The project went through several concept
pivots before landing here: a town walkthrough → forest exploration →
heightmap mountain terrain → an in-VR map/tree-placement editor (briefly
considered switching to Unreal for landscape work, abandoned) → finally
a 6DOF space dogfighter, the current direction. Extensive early work also
went into getting the player/world scale relationship right — shrinking
the player via `XRServer.world_scale` was tried first and caused cascading
addon bugs (hands, lasers, ground detection all hardcoded non-scale-aware
constants); the fix that stuck was leaving the player at normal scale and
scaling the world geometry up 100x instead (`Terrain.world_size` /
`height_scale` in `Town.tscn`).

The project is version-controlled and pushed to
`https://github.com/jdsurrey-collab/vrshooterplane.git` (`main` branch) —
initialized at the `juggyvrgame/` project root specifically, not the
parent `Vrgame/` folder, which also contains unrelated loose asset-source
directories (`enemyships/`, `city/`, `weapons/`, `damage/`, etc.) that
aren't part of the actual game and were never meant to be committed.
