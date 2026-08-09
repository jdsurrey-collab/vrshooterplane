# Vrgame — VR Space Dogfighter (Godot 4)

## Project

A 6DOF VR space shooter: fly a fighter in first person from the cockpit,
dogfight an AI-controlled enemy ship, and fly over a sprawling sci-fi city.
This is a pivot from an earlier "in-VR map editor" concept (see History) —
that system still exists on disk but is disabled.

Engine: **Godot 4.4.1**, using the **Godot XR Tools** addon
(`addons/godot-xr-tools/`) for the VR player rig and grab system (though
flight uses direct/kinematic movement, not the addon's ground-movement
providers — see Flight below). Headset connects via **Virtual Desktop**
(VDXR OpenXR runtime) — PCVR, not a standalone Quest build. GPU: RTX 3060 Ti.

## Collaboration model

Everything here is plain-text (`.tscn`/`.gd`/`project.godot`), so Claude
writes and wires up scenes/scripts directly.

## Architecture

- `scenes/Town.tscn` — main scene: sky, sun, `Player`, `Terrain`,
  `EnemyShip`, `City`.
- `scenes/Player.tscn` — the XR rig (`XROrigin3D` + `XRCamera3D` + two
  `XRController3D`s, both **direct children of `XROrigin3D`** — required for
  Godot's XR tracking to drive the actual per-eye render pose; nesting the
  camera under an intermediate node silently breaks rendering while
  ordinary child nodes still look correct via normal transform composition,
  which cost real debugging time — see `options_menu.gd`'s header comment
  for the full story). No hand meshes or hand-held laser pointer (removed —
  this is a cockpit game, you don't see your hands). Also holds the ship
  model, gun mounts, crosshair, HUD, options menu, engine audio, and crash
  handler — see below.
- `scripts/flight_controller.gd` — inertia-based 6DOF flight ("flight assist
  ON" style, like Star Citizen's Arrow/Gladius): grip/stick input drives
  acceleration, not position directly; releasing input lets it coast down
  under real quadratic air drag rather than snapping to a stop. Right
  grip/left grip = forward/reverse thrust; right stick = pitch/yaw; left
  stick = roll/elevation. Velocity is stored in **world space** and
  reprojected into the ship's current local frame each frame only to apply
  thrust/drag — so flipping the ship around and thrusting decelerates
  existing drift before building speed the new way, real Newtonian
  behavior, with no special-casing required. Tunables (gravity, air
  density, drag) are grounded in real NASA-sourced data — see
  `docs/flight-physics-reference.md`. Includes the **gravity compensator
  standard**: `gravity_compensator_active` (default `true`) means gravity is
  never applied during normal flight; flipping it off is the hook for a
  future "ship shutdown" state.
- `scripts/weapon_system.gd` — twin-gun laser weapon on `Ship/GunMountLeft`
  / `GunMountRight`. Fires on the right trigger (`trigger_click`),
  alternating muzzle each shot. The two mounts are **toed in** via
  `look_at()` so their fire paths actually cross at `convergence_distance`
  (229m / 250 yards, the real RAF WWII harmonization standard — see
  `docs/gunnery-reference.md`), and a crosshair sphere sits at that exact
  convergence point, fixed in the ship's own 3D space (not camera-attached)
  so it shows real parallax as you move your head — like a reticle etched
  on the glass, not a HUD marker.
- `scripts/laser_bolt.gd` (`scenes/LaserBolt.tscn`) — the projectile: a
  small tapered/arrow-shaped bolt (non-billboarded — billboarding was tried
  first and caused it to always orient vertically, since full billboard
  aligns to camera-up, not the bolt's actual travel direction) that checks
  each frame for a terrain or building hit (`_check_hit()` — the single
  point to extend when enemy/player-ship hit detection is added) and
  explodes into a small, **self-cleaning** crater/flash/smoke
  (`LaserImpactEffect.tscn`, see Crash system) instead of just despawning.
  Carries a `damage` field, unused by anything yet — reserved for a planned
  per-ship health system (bolts should already carry this before that
  system exists, not be retrofitted later). Twin `AudioStreamPlayer3D`s (one
  per gun mount) play a processed laser sound (bass-boosted, highs rolled
  off via `lowpass` so it doesn't sound tinny — see `Assets/Audio/laser.mp3`)
  on each shot.
- **Crash system** — the ship/enemy have no physics body, so nothing was
  ever stopping them flying through terrain or buildings. Fixed by direct
  position checks instead of full physics simulation:
  - `scripts/heightmap_terrain.gd` exposes `get_height_at(x, z)`, sampling
    the same height grid used to build the terrain's own collision mesh.
  - `scripts/city_generator.gd` gives every building a `StaticBody3D` +
    `CollisionShape3D`, auto-sized from the building's own measured mesh
    bounds (walked at instantiation, not hand-maintained per type), on
    `CityGenerator.BUILDING_COLLISION_LAYER` (layer 10).
  - `scripts/crash_effects.gd` (`class_name CrashEffects`) is the shared
    hit-detection + effect-spawning helper used by the player
    (`crash_handler.gd`), the enemy (`enemy_ai.gd`), and laser bolts:
    `check_building_collision()` does a physics point query against that
    layer; `spawn()` drops a **permanent** crater + a smoke column that
    never dissipates (rises hundreds of meters, GPU-particle-instanced,
    `visibility_aabb` sized generously — GPUParticles3D culls particles
    outside that box, which silently ate the smoke the first time) plus
    7-8 **permanent** scattered wreckage chunks, each in its own small
    scorch crater; `spawn_laser_impact()` is the small, deliberately
    **temporary** version for a single laser hit (a permanent effect per
    shot would pile up hundreds of craters in seconds of sustained fire —
    see `laser_impact_effect.gd`).
  - `scripts/crash_handler.gd` (player) and `scripts/enemy_ai.gd`
    (enemy) both: freeze on impact (a shared `paused` flag convention, also
    used by the options menu), spawn the crash site, wait, then respawn.
- `scripts/enemy_ai.gd` (`scenes/EnemyShip.tscn`, one `ship1.obj` from the
  "skyscraper_pack"-adjacent "Spaceship Pack" — imported as plain `.obj`,
  not FBX, to avoid needing a Blender/FBX2glTF pipeline) — autonomous wander
  AI: picks a random point within a bounded flight volume (`bounds_radius`,
  a simulated boundary since the skybox itself has no real geometry to
  bound against), steers smoothly toward it, cruises forward. Altitude
  **drifts** gradually from wherever it currently is rather than
  re-randomizing across the whole altitude band each retarget — the
  original version did the latter and it caused constant steep
  climbs/dives. `ground_avoidance_enabled` (default `true`) gates a
  reactive pull-up (checks clearance at the current position AND a
  lookahead point); this is the intended hook for a future engine-failure
  system — a damaged ship should fly with avoidance off so it can actually
  crash from bad flying.
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
- `scripts/options_menu.gd` — in-VR menu, toggled by the left controller's
  menu button. Seat height (left stick) and enemy-tracking toggle (left
  X/`ax_button`, free to reuse since guns moved to the trigger), persisted
  to `user://settings.cfg`. Seat height adjusts **`Ship`'s local Y offset**,
  not the player's position — moving the player would move the camera and
  the fixed cockpit together as one rigid unit (tried, confirmed via debug
  logging: position changed, zero visible effect), so the ship model itself
  moves instead, changing where it sits relative to your untouched tracked
  head.
- `scripts/hud.gd` + `scripts/enemy_locator.gd` — camera-attached HUD
  (speed, gun status, crash/respawn countdown, distance to enemy) and a
  small arrow that continuously rotates in full 3D to point at the enemy
  ship, computed in the camera's local space each frame so it stays correct
  regardless of head rotation. Both were built as much for **debugging as
  gameplay** — when something doesn't work in VR, there's no way to see an
  editor console mid-session, so status has to be visible in-headset to
  diagnose anything at all.
- `scripts/engine_audio.gd` — two looping engine layers (`accelerate.mp3`
  tied to forward-grip magnitude, `thrust.mp3` tied to roll/elevation/
  reverse-grip), both always playing but faded by volume/pitch based on
  input, not started/stopped per event.

## Reference docs

- `docs/flight-physics-reference.md` — real NASA-sourced constants (Earth
  atmosphere, drag equation, gravity) backing the flight tunables, plus a
  worked example of what the current `drag_coefficient` implies about the
  ship's assumed shape.
- `docs/gunnery-reference.md` — real historical gun-convergence/
  harmonization distances backing `weapon_system.gd`'s convergence math.

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
building type in the city.

## Known gaps / natural next steps

- No damage/health system yet. `laser_bolt.gd` carries a `damage` field
  reserved for it; hit detection against the enemy ship and the player's
  own ship isn't implemented (`_check_hit()` in `laser_bolt.gd` is the
  extension point) — per-ship health with the same smoke/crater treatment
  on damage is the planned next step.
- No lead-computing gunsight (PIP/"pipper") — the crosshair is a fixed
  convergence-distance point, not target-tracking. Documented as future
  work in `docs/gunnery-reference.md`; needs the health/target-tracking
  system above first.
- Buildings and terrain are unpassable (a hit crashes you), but there's no
  general ship collision hull — crash detection is a single-point check
  (the ship's own origin), same approximate philosophy used throughout.
- The old in-VR map editor (`scripts/map_editor.gd`, `tree_pickable.gd`,
  `tree_scatter.gd`, `scenes/WristMenu.tscn`) is still on disk but fully
  disconnected from the active scene tree — dead code from the pre-pivot
  concept, not deleted in case any of it gets reused.
- Asset licensing: the enemy ship pack ("Spaceship Pack") and the
  skyscraper pack included no license file — worth tracking down licensing
  before this goes anywhere public. The player cockpit is CC-BY-4.0
  ("Spacefighter Cockpit (Wasp Interdictor)" by Comrade1280 — attribution
  required if shipped).

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
