# Vrgame — VR Space Dogfighter (Godot 4)

## Project

A 6DOF VR space shooter: fly a fighter in first person from the cockpit,
over a sprawling sci-fi city contested by a 400-ship alien-invasion battle
(200 friendly, 200 enemy, plus the player) fighting for "Air Superiority"
over an invisible dome around the city — see Faction Battle below. This is
a pivot from an earlier "in-VR map editor" concept (see History) — that
system still exists on disk but is disabled, the same as the single
hardcoded HOSTILE-1 enemy this session's faction battle replaced (see
Retired systems).

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
- `scripts/flight_controller.gd` — inertia-based 6DOF flight ("flight assist
  ON" style, like Star Citizen's Arrow/Gladius): grip/stick input drives
  acceleration, not position directly; releasing input lets it coast down
  under real quadratic air drag rather than snapping to a stop. Right
  grip/left grip = forward/reverse thrust; right stick = pitch/yaw; left
  stick = roll/elevation. Velocity is stored in **world space** and
  reprojected into the ship's current local frame each frame only to apply
  thrust/drag — so flipping the ship around and thrusting decelerates
  existing drift before building speed the new way, real Newtonian
  behavior, with no special-casing required. Pitch/yaw and roll use
  **separate** rotation-rate tunables — pitch/yaw capped at ~25°/s
  (grounded in real F-16 sustained/peak pitch rate data), roll left faster
  at ~86°/s. They used to share one rate 3-4x faster than a real fighter's
  sustained pitch rate, which read as "touchy" — roll wasn't flagged as a
  problem so it was left alone rather than also chased toward a real
  fighter's ~240°/s roll rate, partly because fast rotation is its own VR
  comfort issue independent of realism. All tunables (gravity, air density,
  drag, rotation rates) are grounded in real NASA/aircraft-performance data
  — see `docs/flight-physics-reference.md`. Includes the **gravity
  compensator standard**: `gravity_compensator_active` (default `true`)
  means gravity is never applied during normal flight; flipping it off is
  the hook for a future "ship shutdown" state.
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
  small tapered/arrow-shaped bolt (non-billboarded — billboarding was tried
  first and caused it to always orient vertically, since full billboard
  aligns to camera-up, not the bolt's actual travel direction) traveling at
  900 m/s (raised from an original 500 to shrink the window where a
  just-fired bolt can be occluded by the ship's own nose during a hard
  pitch). Each frame it does a **swept segment check** (previous position
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
  percentages. This system was built one session before the alien invasion
  that would actually trigger it — see `laser_bolt.gd`'s `fired_by_player`
  bullet above and Faction Battle below for how aliens now actually fire on
  the player, closing that loop.
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
  (shorter base models, modest scale, ~75-250m) and `LANDMARK_BUILDINGS`
  (tallest base models scaled up hard, ~430-625m — the "some buildings
  400m+" supertall towers). Dimensions were measured directly from the
  imported meshes via a one-off headless AABB script, not guessed.
- `scripts/target_lock.gd` — left controller's **Y button**
  (`by_button`) toggles a lock onto the **nearest living alien** from
  `faction_battle.gd`'s 200-ship roster (`get_nearest_alive_alien()`; the
  old single hardcoded HOSTILE-1 enemy is retired). Because it only ever
  queries the alien-faction array, friendlies are structurally impossible
  to lock onto — not an explicit exclusion check, just a consequence of the
  two factions being separate arrays in the manager. While locked: a red
  targeting square,
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
  a **PERF** line, speed, gun status, crash/respawn countdown, distance to
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
- `scripts/engine_audio.gd` — two looping engine layers (`accelerate.mp3`
  tied to forward-grip magnitude, `thrust.mp3` tied to roll/elevation/
  reverse-grip), both always playing but faded by volume/pitch based on
  input, not started/stopped per event.

## Faction Battle — 400-ship Air Superiority mode

Up to 200 friendly ships and 200 alien ships fight each other for control
of the city, plus the player — replacing the old single wandering
HOSTILE-1 enemy (see Retired systems). `friendly_count`/`enemy_count`
currently default to **100/100**, dialed down from the full 200/200 while
the live FPS-collapse investigation is open (see Known gaps) — the
manager, rendering, and combat logic all still support the full 400-ship
scale, this is purely a runtime-tunable knob. This was a large enough
feature that it went through a full plan-mode design pass (including a
sub-agent architecture
review) before implementation — the reasoning below reflects what that
review caught, not just the first-draft idea.

- **One manager, not 400 nodes** (`scripts/faction_battle.gd`, `FactionBattle`
  node in `Town.tscn`) — 400 individual `Node3D`+script instances (the old
  `enemy_ai.gd` pattern) would mean 400x that per-instance overhead. Every
  ship is a lightweight `Combatant` (`scripts/combatant.gd`,
  `class_name Combatant extends RefCounted` — not a Node, never enters the
  scene tree directly): position, heading, speed, faction, a single HP pool
  (30, not the player's 3-zone model — deliberately simplified for this
  ship count), target index, fire cooldown. One `_physics_process()` on the
  manager updates all 400 in tight loops, same reasoning already documented
  for why `enemy_ai.gd` keeps AI and damage in one script rather than
  paying constant cross-script calls.
- **Rendering** — two `MultiMeshInstance3D` (`instance_count=200` each,
  built in `_ready()`, same GPU-instancing technique `city_generator.gd`
  already uses for its ~1200 street tiles), both reusing `ship1.obj` (no
  separate alien model exists in this project). `ship1.mtl` has exactly one
  material, so team identity is just a `material_override` tint
  (cyan/blue friendly, magenta/purple enemy) rather than per-instance
  vertex coloring. A third `MultiMeshInstance3D` renders the ambient bolt
  pool (see Bolts). Dead ships are hidden by scaling their instance
  transform to zero (`Basis().scaled(Vector3.ZERO)`) rather than removed —
  `MultiMesh` has no per-instance visibility flag for an arbitrary middle
  index, only `visible_instance_count`, which trims from the buffer's tail.
- **Air Superiority (AS)** — a single scalar, `air_superiority`, -100 (full
  enemy control) to +100 (full friendly control), starting at 0. Every
  physics frame: `air_superiority += (friendly_in_dome - enemy_in_dome) *
  delta`, clamped to [-100, 100] — the player's own presence inside the
  dome counts as one friendly. One enemy in the dome cancels one friendly's
  contribution exactly 1-for-1, per the user's own framing of the mechanic.
  Either side hitting +/-100, or the 10-minute `match_time_remaining`
  timer expiring (higher AS wins the timeout case; exactly 0 is a draw —
  this tie-break wasn't specified by the user, it's the assumption this
  was built against), sets `game_over = true` and stops the battle
  simulation — the player's own flight/weapons are *not* frozen, only the
  400-ship spectacle stops.
- **The dome** — implemented as a cylinder, not a literal hemisphere (it's
  invisible, so only the gameplay volume needs to be right, not a rendered
  shape): horizontal distance from `dome_center` (read from
  `CityGenerator.city_center`, `(6000, 0, 0)`) within `dome_radius` (8000m
  — comfortably covers the city's own ~7637m corner-to-corner footprint)
  and altitude above terrain within `dome_ceiling` (3500m).
- **Spawn & advance** — both factions spawn ~10km from the city on opposite
  sides (friendly toward the player's own origin spawn, enemy on the far
  side) and steer toward `dome_center` until they're inside it or find a
  target — a design assumption about which side each team spawns on, not
  something the user specified precisely. AI priority per ship: outside the
  dome, advance toward it; a live target (opposing ship, or — aliens only —
  the player) takes over steering if one's in range; inside the dome with
  nothing to fight, loiter around a slowly-refreshed random point within it
  rather than wandering back out ("AI wants to be in the dome always").
- **Retargeting is staggered, not full-scan every frame** — only ~1/8 of
  the population re-evaluates its target each frame (round-robin by
  index), each scanning the ~200 opposing living units (~10k
  comparisons/frame total). A ship whose target just died force-retargets
  immediately regardless of stagger slot. Aliens additionally weigh the
  player as a target candidate, gated by `aggro_radius_player` (2500m) —
  friendlies never do; this is also what makes aliens actually reachable by
  `laser_bolt.gd`'s `fired_by_player=false` path (see `player_damage.gd`
  above) for the first time since that system was built.
- **Bolts — two separate systems.** Ambient unit-vs-unit fire ("lasers
  everywhere") is a pooled, non-Node bolt array (plain `Dictionary`
  records, capped at `max_ambient_bolts=180`), rendered via the third
  `MultiMeshInstance3D`, hit-checked with the same closest-point-on-segment
  swept test `laser_bolt.gd` already uses — a plain point/distance check
  would let bolts tunnel through targets at 900 m/s, the same bug this
  project already fixed once for the player's own bolts. Hit checks are
  spatially bucketed into a per-frame grid keyed by `city_generator.gd`'s
  own `block_pitch` (450m cells) — unstaggered bolt-vs-unit checks are the
  single biggest CPU cost in the whole system (up to ~40-100k checks/frame
  unbucketed), so bucketing is the one thing that isn't staggered like
  retargeting is (a bolt's hit check can't skip a frame without
  reintroducing tunneling). A ship whose fire attempt finds the pool full
  just doesn't fire that cooldown tick — never evicts an in-flight bolt
  early, since that pops a bolt off-screen mid-flight, a visible glitch in
  the exact spectacle this system exists to produce. Ambient bolt
  terrain/building **misses** despawn silently (no impact effect); only
  **kills** spawn one — a big fireball (see Kill effect below), naturally
  rate-limited by population size (max 400 total) rather than bolt volume,
  unlike misses would be. Aliens shooting *at the player* specifically
  instead reuse the existing
  `LaserBolt.tscn`/`laser_bolt.gd` Node-based system exactly as already
  built (`fired_by_player=false`) — low volume by construction (aggro-gated
  to nearby aliens only), so no pooling needed there.
- **Respawn, not attrition** — dead ships respawn after `RESPAWN_DELAY`
  (8s) at their faction's spawn cluster, same pattern
  `crash_handler.gd`/the old `enemy_ai.gd` used — needed so the population
  (and the "lasers everywhere" spectacle) stays sustained for the full
  10-minute match instead of thinning out and going quiet halfway through.
- **Building collision stayed on for mass units** — an earlier draft of
  this design considered skipping the physics-based building point-query
  for 400 units to save CPU; the architecture review corrected this
  (`project.godot` has no `physics/3d` threading override, so
  `intersect_point()` calls are same-thread and broad-phase-accelerated —
  cheap even at 400/frame, and "ships occasionally crash into buildings
  mid-battle" is good spectacle, not a cost worth avoiding). Kept as
  `@export var enable_building_collision_check: bool = true`, a one-line
  escape hatch if live-in-VR profiling ever says otherwise.
- **Public API surface** other scripts depend on:
  `get_nearest_alive_alien(pos)`, `is_alive(index)`,
  `get_alien_position(index)`, `get_velocity(index)`,
  `apply_damage(index, amount)`, plus the live `air_superiority` /
  `match_time_remaining` / `game_over` / `winning_faction` /
  `dome_center` vars. (`get_position` was the first name tried for
  `get_alien_position` — collided with `Node3D`'s own built-in
  `get_position()` and failed to import until renamed; a real gotcha
  worth remembering for any future manager method on a `Node3D`-derived
  script.) `scripts/target_lock.gd` and `scripts/laser_bolt.gd` (player
  shooting aliens) both consume this API instead of a hardcoded enemy
  node reference.
- `scripts/battle_hud.gd` (`BattleHUD` `Label3D`, top-center of the visor,
  alongside the existing bottom-right speed/gun and top-left damage HUDs)
  — shows the AS split as a friendly/enemy percentage
  (`(air_superiority + 100) / 2`), the MM:SS countdown, and a
  VICTORY/DEFEAT/DRAW + "PULL TRIGGER FOR MAIN MENU" line once `game_over`
  is true — see Game Flow below for what reads that same trigger press.
- `as_generation_multiplier` (`FactionBattle`, default `0.1`) — a straight
  multiplier on `net_rate`, tunable without touching the underlying
  dome-count logic. Tuned down twice: first to `0.5` (half the original 1
  AS/sec-per-net-ship rate), then to `0.1` (20% of that `0.5`, i.e. 10% of
  the original rate).
- **Target acquisition is range-capped** (`MAX_ACQUISITION_RANGE`, 3000m) —
  a real bug caught after the first live playtest ("no one is shooting
  lasers"): `_retarget_if_needed()` originally picked the *globally*
  nearest opposing ship with no distance limit, so every combatant had
  `has_target = true` from the instant it spawned (its nearest enemy was
  just ~20km away, both spawn clusters being 10km out on opposite sides of
  the city) — meaning `_update_combatant()` always steered straight at
  that far-off individual instead of ever taking the intended
  `_wander_or_advance_direction()` path toward the dome. Capping
  acquisition range restores that fallback: ships with nothing in range
  advance on `dome_center` (a tighter, faster convergence than each one
  independently chasing whatever ship happened to be nearest across the
  whole map) and only pick up an actual target once something's within
  3000m. Verified fixed via a scripted headless simulation (loads
  `Town.tscn`, calls `FactionBattle.start_battle()`, lets the real engine
  loop run — not manually driven ticks, which don't work here since
  `_ready()` is deferred a frame after `add_child()`): first ambient bolt
  fired at t=59.4s, consistent with the ~1-minute travel time the 10km
  spawn-out design requires before any real engagement — that lag is
  expected behavior, not a bug, and worth remembering before re-diagnosing
  "nothing's happening" reports that are really just "it hasn't been a
  minute yet."
- **Ships spawning into an immediate nosedive** — a second real bug the
  same live playtest surfaced ("the other team was exploding by running
  into the ground immediately"). `_respawn_combatant()`'s initial heading
  was `(dome_center - c.position).normalized()` — but `dome_center.y` is 0
  (sea level) while this terrain has real mountains (confirmed ~2713m
  elevation right at the friendly spawn point via the sim's own debug
  print), so every freshly-spawned ship aimed itself thousands of meters
  *below* its own spawn altitude and dove straight into the ground before
  it ever leveled out. Fixed by aiming at a horizontally-projected dome
  target at the ship's OWN spawn altitude
  (`Vector3(dome_center.x, c.position.y, dome_center.z)`) instead — the
  same horizontal-only approach `_wander_or_advance_direction()` already
  used correctly (that one was never affected, only the one-time spawn
  heading was).
- **Ground avoidance, ported from `enemy_ai.gd`** — fixing the nosedive
  surfaced a third, subtler issue via the same simulation: even flying
  level, ships still died to terrain mid-transit (28/200 friendlies dead
  by t=20s with combat not yet possible) because the mass battle never got
  `enemy_ai.gd`'s reactive ground-avoidance — ships fly a straight line at
  a fixed altitude offset from *their own spawn point's* ground height, and
  this terrain's elevation varies by thousands of meters along the way.
  `_needs_pull_up(c)` ports the same current-position + lookahead
  (`LOOKAHEAD_TIME=3s`) clearance check `enemy_ai.gd`'s
  `_get_desired_forward()` already uses (deliberately simplified — no
  `ground_avoidance_enabled` toggle or engine-health gating, since nothing
  in the mass battle has engine damage), overriding combat/wander steering
  with an urgent climb (`+Vector3.UP * 1.5`) whenever a ship is under
  `MIN_GROUND_CLEARANCE` (200m) now or on its projected path. All three
  fixes verified together via the same scripted simulation: 200/200 alive
  on both sides through t=20s (previously casualties before any combat was
  even possible), first shot fired even sooner than before (t=43.7s) since
  fleets no longer detour into mountains en route.
- `as_generation_multiplier` was tuned down twice more after initial
  playtesting, now `0.01` (1% of the original 1 AS/sec-per-net-ship rate) —
  see the bullet above for the `1.0 -> 0.5 -> 0.1` history; each cut was a
  direct user request after seeing the previous rate in play.
- **Kill effect** (`scenes/ShipExplosion.tscn` / `scripts/ship_explosion.gd`)
  — replaces `CrashEffects.spawn_laser_impact()` for `_kill_combatant()`
  specifically: a much bigger, brighter fireball meant to be visible from
  well across the city, not just up close. Three parts: a large one-shot
  particle flash (bright orange/white, big scale), a short `OmniLight3D`
  pulse (`omni_range=6000`, `shadow_enabled=false` to keep it cheap,
  energy faded out over 0.6s in `_process()`) — the light is what actually
  carries the "seen anywhere around the city" requirement, since at city
  scale (multi-km) any particle's real-world size is sub-pixel long before
  its light would be, and a taller/longer-lived rising smoke column (12s)
  than the small per-shot effect. Still self-cleaning
  (`queue_free()` after 14s total) like `spawn_laser_impact()`, unlike
  `CrashEffects.spawn()`'s deliberately permanent player-crash effect —
  kill volume across a 400-ship battle would pile up permanent effects
  fast otherwise, the same reasoning that kept `spawn_laser_impact()`
  temporary in the first place. Not yet confirmed live in the headset —
  the flash/light/smoke sizing and the light's actual visible range at
  real VR viewing distances are best-effort starting values, same as every
  other first-pass visual tuning in this project.
- The player now spawns **with the friendly fleet**, not at the world
  origin: `heightmap_terrain.gd` gained `spawn_position_xz` (a plain
  exported `Vector2`, not read live from `FactionBattle`, to avoid a
  `_ready()`-order dependency between the two scripts) and
  `crash_handler.gd` gained the matching `respawn_position_xz` — both set
  to `(-4000, 0)` in their `.tscn` nodes, matching
  `FactionBattle.friendly_spawn_center`'s formula
  (`city_center + (-10000, 0, 0)`). All three locations need updating by
  hand together if that formula ever changes — a documented, intentional
  coupling, same pattern already accepted for the dome/`block_pitch`/
  `city_center` reuse.

## Homing missiles

Second weapon, left trigger (guns stay on the right trigger) — a deliberate
lock-on-first weapon rather than a second trigger-happy gun. Went through
two real design iterations this session (see below) before landing here.

- **Lock now depends on `target_lock.gd`'s Y-button lock, not its own aim
  cone.** The first version had `missile_system.gd` do its own independent
  aim-cone detection against the ship's gun crosshair — replaced per direct
  request so missile lock only ever happens against a target the player
  has deliberately Y-locked, not just "whatever's under the crosshair."
  `target_lock.gd` itself changed to match: **Y no longer toggles lock
  on/off — it CYCLES** through living aliens nearest-to-farthest
  (`FactionBattle.get_alive_aliens_sorted_by_distance()`, a new query),
  wrapping back to nearest after the last one. First press locks nearest;
  each press after that steps to the next one out. There's no manual
  unlock anymore — it only drops automatically (target dies, or drifts
  past `max_lock_range`). `target_lock.gd`'s previously-private `_locked`/
  `_locked_index` are now public (`locked`/`locked_index`) so
  `missile_system.gd` can read them directly.
- `scripts/missile_system.gd` (`MissileSystem` node under `Player`) —
  every physics frame, checks whether `target_lock.locked` is true and its
  target is still alive; if so, tracks lock progress against that same
  index. Losing the Y-lock, it cycling to a different target, or the
  target dying all reset progress to zero, no partial credit. Holding it
  for `LOCK_TIME` (5s) completes the lock (`LockAudio` beep plays once,
  edge-triggered). Left trigger only fires while locked, and firing
  **consumes** the lock, so every shot needs a fresh 5-second track.
- `scripts/missile.gd` (`scenes/Missile.tscn`) — unlike `laser_bolt.gd`'s
  straight-line travel, this steers toward its target's *current* position
  every physics frame at a capped turn rate (1.2 rad/s) — real pursuit,
  not an instant snap. `speed` is 400 m/s (raised from an original 220) —
  still well under the 900 m/s laser bolt, deliberately slow enough to be
  dodgeable with hard defensive maneuvering, a direct user requirement.
  Damage (30) always meets-or-exceeds a mass-battle alien's max health
  (30, see Faction Battle), so every hit is a kill —
  `FactionBattle.apply_damage()`'s own kill path already spawns the big
  `ShipExplosion` fireball and a kill-feed entry (see below), so the
  missile doesn't need a separate impact visual, just its hit sound.
- **Overshoot -> ballistic handoff** (`MAX_ENGAGE_ANGLE`, 150°) — a target
  breaking hard enough can end up almost directly behind the missile
  before it can turn back onto its bearing. Past 150° between the
  missile's current heading and the bearing to target, `_lost_lock`
  (sticky) latches true and the missile gives up steering for good,
  continuing straight along whatever heading it already had for the rest
  of its `lifetime` — a real missile can't pull an instant U-turn either,
  and endlessly circling back would look wrong. It can still score a hit
  via the ordinary swept-segment check if something crosses its path, it
  just stops actively chasing.
- **Muffled + proximity audio**: launch/hit sounds are user-supplied
  (`weapons/missle/misslelaunch.mp3` / `misslehit.mp3`, outside the Godot
  project — processed once via `ffmpeg` with a bass boost + lowpass
  (`bass=g=8:f=100,lowpass=f=3200` launch, slightly heavier
  `f=90,lowpass=f=2600` hit) into `Assets/Audio/missile_launch.mp3` /
  `missile_hit.mp3`, matching the existing laser/crash "processed so it
  doesn't sound tinny" treatment) and played via `AudioStreamPlayer3D` for
  real proximity falloff. The hit sound specifically also tunes Godot's
  built-in distance-based low-pass (`attenuation_filter_cutoff_hz=1800`,
  `attenuation_filter_db=-36`, both more aggressive than this project's
  other 3D sounds) — missile hits can happen well away from the player,
  unlike every other sound in this project which sits close to the
  listener and never needed it; farther hits should read as quieter *and*
  more muffled, not just quieter. The hit sound is a short-lived
  standalone `AudioStreamPlayer3D` spawned at the impact point
  (`missile.gd`'s `_play_hit_sound()`), since the missile node itself is
  freed on impact. The lock beep (`missile_lock.tres`) has no source file
  to process — procedurally generated (a short 1400Hz sine tone with a
  fade envelope, `AudioStreamWAV` built and saved via a one-off
  `--headless --script` run) the same way `soft_particle.png` was, since no
  suitable sound existed for it. **`ResourceSaver.save()` gotcha**: saving
  as `.wav` failed (`ERR_FILE_UNRECOGNIZED`) — `ResourceSaver` writes
  Godot resource files, not raw playable containers; saving the same
  `AudioStreamWAV` as `.tres` instead worked immediately and loads/plays
  identically as an `AudioStream`.
- `game_flow.gd`'s `_set_player_paused()` now also pauses `MissileSystem`
  (and `FlareSystem`, see Countermeasure flares below) during the
  `MENU`/`GAME_OVER` states, same convention as
  `flight_controller.gd`/`weapon_system.gd`.

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
    in 3D space makes it reliably occlude both the title/button labels and
    the flying scene behind it). While `state == MENU`, `Fade` stays fully
    opaque (alpha 1) — a real black menu screen, not a translucent overlay
    on top of the flying scene, per a direct correction after the first
    version faded out immediately on entry. The instant `state` moves off
    `MENU` (START confirmed — `GameFlow` already unpauses the player and
    starts the battle immediately, no artificial delay to the actual
    gameplay logic), `main_menu.gd` notices independently and begins a
    **reveal**: title/button labels and audio stop right away, but `Fade`
    keeps rendering by itself, animating alpha 1 -> 0 over `FADE_DURATION`
    (2.5s), dissolving into the flight that's already underway underneath.
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
  - **START / QUIT selection is gaze-based** — whichever label
    (`StartLabel`/`QuitLabel`) the camera is currently pointing closest to
    is highlighted (full brightness vs. dimmed), the same aim-cone approach
    `missile_system.gd` used to use for its own target lock before that
    was replaced by a `target_lock.gd` dependency (see Homing missiles),
    just applied here to two fixed points instead of a moving alien. This
    script only tracks and displays `selected_action` — it doesn't confirm
    anything itself;
    `game_flow.gd` (already the sole owner of trigger-confirm logic for
    both menu states) reads it on a right-trigger press and either starts
    the match or calls `get_tree().quit()`.
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

- **Open investigation: FPS collapsed to ~6 during a live playtest of the
  400-ship battle.** Ruled out via an instrumented headless simulation
  (200v200, 180 simulated seconds): kill rate is near-zero (both sides
  stayed at ~200/200 alive throughout) and at most 1 `ShipExplosion`
  effect was ever concurrently active — so the new fireball kill effect is
  **not** the cause, contrary to the first suspicion (it was the most
  recently added heavy visual content, but headless testing can measure
  simulation state directly and disproved it). Beyond that, headless mode
  cannot measure GPU draw-call cost or actual VR stereo render time, so
  the real cause is still unknown — could be CPU-side (the ~400-580
  physics building-collision queries/frame across combatants + ambient
  bolts, `enable_building_collision_check`'s existing escape hatch) or
  GPU-side (the ship/bolt `MultiMesh` draw calls, or particle/light cost
  during combat) or something external (see the FPS line's own original
  reasoning below). `hud.gd` gained a **PERF** line
  (`PROC:_ms PHYS:_ms DRAW:_ OBJ:_`, from Godot's `Performance` singleton)
  specifically to get real numbers on the next live test instead of
  continuing to guess — compare `PHYS` (physics/AI cost) against `DRAW`
  (rendering cost) to tell which side of the budget is actually blowing
  up. `friendly_count`/`enemy_count` (`@export`ed) and
  `enable_building_collision_check` are both existing knobs that can
  bisect this further without any code changes — `friendly_count`/
  `enemy_count` were already dropped from 200/200 to **100/100** as the
  first bisection step; if FPS recovers at 100v100, the cause is CPU-side
  and scales with ship count (most likely the physics building-collision
  queries); if it's still bad, look at rendering/GPU cost instead.
- Alien bolts fired at the player (`faction_battle.gd`'s `_fire_at_player()`)
  don't play the laser sound `weapon_system.gd` plays for the player's own
  shots — that sound lives in the gun mounts' `AudioStreamPlayer3D`s, which
  the mass-battle path bypasses entirely. Being fired upon currently has no
  audio cue beyond the eventual `DamageAudio` hit sound if it connects.
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
