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
    kill. All smoke/spark particle materials use a procedurally-generated
    soft radial-alpha texture (`Assets/Textures/soft_particle.png`, a
    one-off `--headless --script` Image-generation run, not a hand-authored
    asset) — the original flat solid-color particles had hard square edges
    that read as pixelated when they overlapped.
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
  speed, gun status, crash/respawn countdown, distance to the city — the
  FPS line exists specifically to tell "the game is dropping frames" apart
  from "something external, like OBS or Virtual Desktop's own encoding, is
  the bottleneck") and a small arrow that continuously rotates in full 3D
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

200 friendly ships and 200 alien ships fight each other for control of the
city, plus the player — replacing the old single wandering HOSTILE-1
enemy (see Retired systems). This was a large enough feature that it went
through a full plan-mode design pass (including a sub-agent architecture
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
  **kills** spawn one, via `CrashEffects.spawn_laser_impact()` reused
  directly (see Crash system above) — naturally rate-limited by population
  size (max 400 total) rather than bolt volume, unlike misses would be.
  Aliens shooting *at the player* specifically instead reuse the existing
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
  VICTORY/DEFEAT/DRAW line once `game_over` is true.

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

- **Nothing in this session's build has been confirmed live in the
  headset yet** — the 400-ship Faction Battle in particular (dome math, AS
  generation feel, whether 200v200 actually holds VR framerate on the
  3060 Ti) can only be judged in-game, never headlessly. `friendly_count`/
  `enemy_count` are `@export`ed specifically so a smaller live test (e.g.
  40v40) can validate frame budget before trusting the full 200v200 — see
  Faction Battle's Rollout note.
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
