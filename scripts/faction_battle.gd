extends Node3D

## Alien invasion: two fleets of squadrons fighting for control of the city,
## plus the player. Replaces the old single wandering HOSTILE-1
## (enemy_ai.gd/EnemyShip.tscn, left on disk unused, same convention as the
## retired map editor).
##
## ARCHITECTURE — one manager, not hundreds of nodes. Individual
## Node3D+script instances (the old enemy_ai.gd pattern) would mean that
## per-instance overhead multiplied by the whole population. Instead every
## combatant is a lightweight Combatant (RefCounted, see combatant.gd) held
## in a plain Array, grouped into Squads (RefCounted too, see squad.gd), and
## this single script updates all of them in tight loops every
## _physics_process, then writes the results into two MultiMeshInstance3D
## (one per faction, GPU-instanced — the same technique city_generator.gd
## already uses for its ~1200 street tiles) instead of one draw call per
## ship.
##
## SQUADS, not one big cloud. The first version had every ship independently
## spawn in one cluster and fly at one shared dome_center, which produced
## exactly what it sounds like: two enormous undifferentiated packs. Now the
## population is cut into squads of 1-5 (SQUAD_SIZE_MIN/MAX), each with its
## OWN spawn point spread along a wide front, its OWN objective inside the
## dome, formation-keeping on a leader, focus fire on the leader's target,
## and its own morale state. Combined with the separation steering below,
## that's what breaks the fleet up into readable individual fights.
##
## AI BEHAVIOURS, modelled on how modern combat-flight AI actually reads:
##   * FORMATION — wingmen hold a station offset from their leader, with a
##     throttle that speeds up/slows down to close on that station instead
##     of flying at one fixed speed (which strings a squad out or piles it
##     up).
##   * PURSUE — run in on a target using a real lead/intercept solution
##     (_lead_point), not a straight chase of where the target is *now*.
##   * BREAK_OFF — after closing inside BREAK_OFF_RANGE, the attacker flies
##     THROUGH and past its target for a couple of seconds before turning
##     back, instead of gluing itself to the target's tail forever. This is
##     the single biggest readability win: fights become a series of
##     recognisable passes rather than two dots stuck together.
##   * RETREAT — a hurt pilot (health under RETREAT_HEALTH_FRACTION) may
##     break off entirely; a squad that has lost enough of its members
##     (Squad.losses) breaks off as a unit, runs to a rally point, REGROUPs
##     and comes back. "They may pull off if they are hurt, or if too many
##     of their squad mates die."
##   * SEPARATION — every ship pushes away from nearby friendly ships, which
##     is what actually stops squads from collapsing into a single point.
##   * Reaction delay + per-pilot accuracy — ships don't fire the instant
##     they acquire (Combatant.reaction_timer), and their aim is displaced
##     from the true firing solution by an amount scaled by their own
##     `accuracy` and the range. This is the "threatening but not unfair"
##     knob.
##
## AIR SUPERIORITY (RETIRED AS SCORING — see CONQUEST below) — an invisible
## cylindrical column over the city (city_center, dome_radius horizontally,
## and by default UNBOUNDED vertically — it runs from the ground straight up
## through the cloud deck into the skybox). `dome_radius`/`dome_center`/
## `_is_in_dome()`/`_random_point_in_dome()` are all still very much alive
## and still govern where squads fly and engage — only the SCORING use of
## dome presence (`_update_air_superiority()`) was ever removed; direct
## instruction, "we're not gonna count how many people are inside the dome
## for points anymore." `air_superiority` the variable and
## `_update_air_superiority()` the function are both left defined but no
## longer called from `_physics_process()`, same "retired, not deleted"
## convention as everything else in this project.
##
## CONQUEST — the actual scoring now. Direct instruction: "instead of the
## one dome that we had earlier, we have multiple domes, kind of like
## battlefield games where you have the conquest areas... this could be
## signified by the main big buildings... straight rip from battlefield in
## every regard." See `capture_zone.gd` and this file's own "Conquest"
## section below for the full design — one `CaptureZone` per mega tower
## (`CityGenerator.get_mega_tower_positions()`), presence-based capture,
## `friendly_score`/`enemy_score` racing to `score_target` (1000), fed by
## +1 per kill and a continuous per-second rate for every zone currently
## controlled.
##
## BOLTS are two separate systems. Ambient unit-vs-unit fire ("lasers
## everywhere") uses a pooled, non-Node bolt array (Dictionaries), rendered
## via a third MultiMeshInstance3D, hit-checked with the same closest-point-
## on-segment swept test laser_bolt.gd already uses (a plain point/distance
## check would let bolts tunnel through targets — this project already fixed
## that bug once for the player's own bolts). Hit checks are spatially
## bucketed into a per-frame grid keyed by city_generator.gd's own
## block_pitch (450m cells) — unstaggered bolt-vs-unit checks are the single
## biggest CPU cost in this system, dwarfing retargeting, so they're the one
## thing that gets bucketed instead of staggered (a bolt's hit check can't
## skip frames without reintroducing tunneling). Aliens shooting AT THE
## PLAYER specifically instead reuse the existing
## LaserBolt.tscn/laser_bolt.gd Node-based system (fired_by_player=false) —
## low volume by construction (aggro-gated), and it's what feeds
## player_damage.gd's already-built hit path.
##
## SPAWN-TIME PROPERTY GOTCHA (a real bug this cost us): add_child() runs the
## child's _ready() immediately, so any exported/plain property a scene's
## _ready() reads MUST be assigned BEFORE add_child(), not after. Both
## _fire_at_player() and _fire_missile_at_player() originally set
## `fired_by_player = false` / `target_is_player = true` after add_child,
## so those scripts' _ready() saw the defaults, never resolved their player
## references, and the player could not be damaged by aliens AT ALL — while
## still hearing the missile's own impact sound, which is exactly what
## "I hear the hull taking hits but I'm not getting hurt" was.
##
## EFFECT BUDGETS. Now that the AI actually fights, kills happen constantly,
## and every kill used to spawn an unconditional ShipExplosion (a particle
## tree plus a 6000m-range OmniLight3D). At battle scale that is a real
## frame-budget problem, so kill effects are now budgeted three ways: a hard
## cap on concurrent explosions, no light beyond explosion_light_range, and
## nothing at all beyond explosion_cull_range. Battle audio is budgeted the
## same way — see _play_battle_sound().
##
## The PLAYER's own weapon damages aliens through this manager too —
## laser_bolt.gd's _check_enemy_hit() calls get_nearest_alive_alien() /
## apply_damage() below. Friendlies are a structurally separate array the
## player-facing API never touches, so they can never be targeted or damaged
## — not an explicit exclusion check, just a consequence of the split.

const LASER_BOLT := preload("res://scenes/LaserBolt.tscn")
const LASER_BOLT_SHADER := preload("res://Assets/Shaders/laser_bolt.gdshader")
const SHIP_EXPLOSION := preload("res://scenes/ShipExplosion.tscn")
const FLARE := preload("res://scenes/Flare.tscn")
const MISSILE := preload("res://scenes/Missile.tscn")
const HIT_SPARK := preload("res://scenes/HitSpark.tscn")
const BATTLE_EXPLOSION_SOUND := preload("res://Assets/Audio/battle_explosion.mp3")
const BATTLE_LASER_SOUND := preload("res://Assets/Audio/battle_laser.mp3")

const SHIP_MESH_PATH := "res://Assets/EnemyShip/ship1.obj"
const SHIP_SCALE := 2.0  # matches EnemyShip.tscn / Player.tscn's ShipHull

const MAX_HEALTH := 30.0  # ~3 player hits (10 dmg/bolt) to kill — visible, not one-shot
const BOLT_DAMAGE := 10.0

## Dropped from 900 m/s. At 900 an ambient bolt crossed a whole engagement
## in a couple of frames — individually invisible, so a battle of hundreds
## of simultaneous shots read as nothing at all. Slower + much longer/
## brighter bolt geometry (see _build_multimesh_nodes) is what turns the
## fighting into something you can actually watch from a distance. It also
## means the AI's lead/intercept solution has real work to do.
const BOLT_SPEED := 520.0
const BOLT_LIFETIME := 3.0
const BOLT_HIT_RADIUS := 6.0  # a little wider than laser_bolt.gd's, since ambient bolts are bucketed one frame stale

const MISSILE_ENGAGE_RANGE := 2500.0  # longer stand-off than ENGAGE_RANGE — missiles are a real threat, not routine
const MISSILE_COOLDOWN_MIN := 15.0
const MISSILE_COOLDOWN_MAX := 30.0

const RETARGET_STAGGER := 8
## Bolt-hit / separation spatial-hash cell size. Originally chosen to match
## city_generator.gd's `block_pitch`; that has since dropped to 360m for
## density, and this is deliberately NOT following it — 450m is a good cell
## size for this workload on its own, and there's no requirement that the
## two agree.
const GRID_CELL_SIZE := 450.0
## 800 -> 1200, unifying the AI onto the same lethal range the player's own
## guns now use (gunnery.gd's `lethal_range`) — a confirmed decision from the
## gunnery overhaul rather than an oversight: one range model governs
## everyone instead of the player out-ranging the AI or vice versa. Verified
## against a fresh 600s pacing sim after the change (see CLAUDE.md).
const ENGAGE_RANGE := 1200.0  # inside this a pilot will actually shoot
const MAX_ACQUISITION_RANGE := 3000.0  # targets beyond this aren't acquired at all — see _retarget_if_needed
const FIRE_CONE := deg_to_rad(14.0)  # must have the target roughly ahead, not abeam, to fire

## AI afterburner burst/cooldown envelope — see _update_ai_afterburner().
## Randomised per burn so a squad doesn't light up in lockstep, the same
## reasoning as the staggered missile cooldowns.
const AB_BURN_MIN := 1.6
const AB_BURN_MAX := 3.4
const AB_COOLDOWN_MIN := 6.0
const AB_COOLDOWN_MAX := 14.0
## Below this range to target, more speed just overshoots — no burn.
const AB_PURSUE_MIN_RANGE := 600.0
## Still this far from the squad objective with nothing to fight — worth
## burning to close the gap.
const AB_ADVANCE_MIN_RANGE := 2500.0
const MIN_GROUND_CLEARANCE := 200.0  # meters; pull up if under this, same convention as enemy_ai.gd
const LOOKAHEAD_TIME := 3.0  # seconds ahead to also check clearance for
const LOOKAHEAD_STAGGER := 4  # only 1/4 of the population re-runs the lookahead terrain sample per frame
const RESPAWN_DELAY := 8.0

## PERFORMANCE GATES. The physics building point-query and the terrain
## sampler are called per ship AND per bolt, every frame, which at battle
## scale was measured (headless, 100v100) at ~8ms of physics per frame on
## its own — more than an entire 90Hz VR frame budget, and the most likely
## explanation for the live FPS collapse this project has been chasing.
##
## Anything flying more than MAX_BUILDING_HEIGHT above the terrain
## underneath it cannot possibly be intersecting a building, so the physics
## query is skipped outright. The ground height is already sampled for the
## terrain check, so the gate itself is free.
##
## MUST STAY ABOVE THE TALLEST BUILDING city_generator.gd can produce, or
## ships and bolts silently pass through the tops of towers. That is
## `LANDMARK_BUILDINGS` base height (~125m) * `landmark_scale_max` (5.0) *
## `height_multiplier` (6.0, doubled from 3.0 alongside a matching halving
## of both scale_min exports — see that file's own header) = ~3750m, hence
## 4000m with margin. This value has moved twice already as the city's
## height settings changed (700m -> 2000m -> 4000m) — if they change again,
## this has to move with them.
##
## Widening this gate ALSO widens the altitude band where the real
## building-collision physics query actually runs (see the PERFORMANCE
## GATES note above) — combined with the city's building count also
## roughly tripling in the same change (map-wide placement gated at a
## doubled terrain-height threshold), this is genuinely more physics load
## than this project has measured before. The prior 1.7% A/B (queries
## fully off vs. fully on) is why it wasn't treated as disqualifying, but
## it was measured at a smaller building count and a lower gate — worth a
## fresh measurement if a live session's PERF line shows PHYS climbing.
const MAX_BUILDING_HEIGHT := 4000.0

## Air Superiority is a slow scalar (as_generation_multiplier is 0.01) and
## counting every ship in the dome costs a terrain sample each. Recomputing
## it 60x/second was pure waste, so it runs every AS_UPDATE_INTERVAL frames
## and integrates the accumulated delta — mathematically identical, ~6x
## fewer samples.
const AS_UPDATE_INTERVAL := 6

## Squadron organisation.
const SQUAD_SIZE_MIN := 1
const SQUAD_SIZE_MAX := 5
const FORMATION_SPACING := 75.0  # meters between formation stations
const FORMATION_SPEED_GAIN := 0.45  # how hard a wingman throttles to close on its station

## Attack-run shaping.
const BREAK_OFF_RANGE := 140.0  # closing inside this ends the run — fly through, then turn back
const BREAK_OFF_TIME_MIN := 1.8
const BREAK_OFF_TIME_MAX := 3.4
const REACTION_TIME_MIN := 0.35
const REACTION_TIME_MAX := 1.1
const AIM_ERROR_SCALE := 0.055  # aim offset = (1 - accuracy) * range * this

## Morale.
const RETREAT_HEALTH_FRACTION := 0.35
const RETREAT_ROLL_CHANCE := 0.55  # a hurt pilot only sometimes breaks — not every one, every time
const RETREAT_TIME_MIN := 7.0
const RETREAT_TIME_MAX := 14.0
const SQUAD_RETREAT_TIME := 14.0
const SQUAD_REGROUP_TIME := 10.0

## Separation — the actual fix for "the AI clusters together in huge packs".
# --- Ground attack (STRIKE squads vs tank_objective.gd's fuel tanks) --------

## A strike pilot steers at EXACTLY the point it shoots at (the tank's body
## centre), so "nose on the thing I am firing at" is true by construction and
## GROUND_ATTACK_FIRE_CONE below is the only alignment tuning there is.
##
## The first version instead steered at a point 300m ABOVE the tank, on the
## reasoning that a shallow approach would stay clear of the ground. It made
## the weapon unusable: the gun cone is measured to the tank, so at break
## range the nose was ~35 degrees off the thing it was shooting at, and the
## AI destroyed 0 of 20 tanks across a full 600-second match.

## Distance to the tank at which the pass ends and the pilot pulls off. Well
## outside GROUND_ATTACK_FIRE_RANGE so every run gets a real firing window,
## and far enough out to turn: at ~250 m/s against ai_turn_max_rate this is
## about two seconds of warning, which is ample for the shallow approach the
## turn-rate limit produces naturally.
const GROUND_ATTACK_BREAK_RANGE := 520.0

## Ground clearance floor for a pilot actually making a strafing run, against
## MIN_GROUND_CLEARANCE (200m) for everyone else. A striker is deliberately
## descending at a ground target; a cruise safety margin is the wrong rule for
## it. See _needs_pull_up().
const GROUND_ATTACK_MIN_CLEARANCE := 90.0

## Far longer than ENGAGE_RANGE (800m) because a tank is a ~100m STATIONARY
## target rather than a jinking fighter — a striker can open up much earlier
## and still be shooting at something it can actually hit.
##
## Sized against the measured bottleneck rather than picked for feel. A strike
## flight crosses 22km from its mothership to reach the city, and at 950m this
## bought a ~1.7-second firing window at the end of it: of 2655 striker
## ship-seconds spent in GROUND_ATTACK across a 420-second match, only 18.6
## were inside firing range — 0.7%. The approach, not the aim, was the whole
## problem.
##
## Capped by the bolt itself: BOLT_SPEED (520) x BOLT_LIFETIME (3.0) = 1560m,
## so anything beyond that would expire in flight and silently never arrive.
const GROUND_ATTACK_FIRE_RANGE := 1400.0
const GROUND_ATTACK_FIRE_CONE := deg_to_rad(12.0)

## How close a TANK_GUARD patrols to the tank it is watching over. Wide enough
## that guards aren't stacked on the tank itself, tight enough that an
## attacker running in has to come through them.
const TANK_GUARD_PATROL_RADIUS := 1100.0
const TANK_GUARD_PATROL_ALT_MIN := 400.0
const TANK_GUARD_PATROL_ALT_MAX := 1600.0

const SEPARATION_RADIUS := 130.0
const SEPARATION_WEIGHT := 2.2
const MAX_SEPARATION_NEIGHBORS := 6

const SPAWN_ALT_MIN := 300.0
const SPAWN_ALT_MAX := 1400.0

## Motherships — one stationary capital ship per faction, hovering at that
## faction's spawn point. Every ship starts the match parked on its deck and
## launches off the top of it, and dead ships respawn back onto it.
const MOTHERSHIP := preload("res://scenes/MotherShip.tscn")
const LAUNCH_CLEAR_HEIGHT := 420.0  # meters above the deck before a launching ship resumes normal flight
const LAUNCH_CLIMB_BIAS := 2.6  # how hard a launching ship prioritises "up" over "toward the objective"
## Squads leave the deck in waves. The whole fleet lifting simultaneously
## looks like a swarm rather than a carrier launch, and dumps the entire
## population into one volume of air at once — which the separation steering
## then has to fight. Staggering also spreads the spawn cost over ~30s.
const LAUNCH_WAVE_INTERVAL := 0.85  # seconds between squads at match start
const LAUNCH_RESPAWN_DELAY_MAX := 2.5  # mid-match respawns don't queue behind the whole fleet

const FRIENDLY_COLOR := Color(0.25, 0.65, 1.0)
const ENEMY_COLOR := Color(0.85, 0.1, 0.85)
const FRIENDLY_BOLT_COLOR := Color(0.35, 0.8, 1.0)
const ENEMY_BOLT_COLOR := Color(1.0, 0.25, 0.15)
const ZONE_NEUTRAL_COLOR := Color(0.55, 0.55, 0.58)

const ZONE_LETTER_FONT := preload("res://Assets/Fonts/Orbitron-Variable.ttf")

## Low, droning, heavily-reverbed one-shot played the instant a tower
## genuinely flips ownership — see `_maybe_play_capture_sound()`. Sourced
## from a user-supplied impact SFX (`capture/` at the project root),
## pitched way down (asetrate*0.52) and run through a 5-tap `aecho` chain
## for the "a lot of reverb to kind of echo through the map" ask, the same
## ffmpeg-processing-not-a-new-recording convention already used for every
## other sound in this project.
const CAPTURE_CONFIRMED_SOUND := preload("res://Assets/Audio/capture_confirmed.mp3")

# --- Conquest clock-hand visuals (see _build_zone_letters/_update_zone_visual) ---
const ZONE_HAND_LENGTH := 220.0  # a "small hand" against the ~600m-tall letters
const ZONE_HAND_WIDTH := 16.0
const ZONE_HAND_THICKNESS := 6.0
const ZONE_HAND_FORWARD_OFFSET := 15.0  # sits just in front of the glyph plane, avoids z-fighting
const ZONE_PULSE_SPEED := 3.2  # rad/s, cosmetic pulse frequency while a capture is actively contested
const ZONE_PULSE_MIN := 0.7  # brightness multiplier at the pulse trough
const ZONE_PULSE_MAX := 2.6  # pushed above 1.0 so the pulse peak actually blooms via the Glow pass

# --- Tracer readability at range (see _bolt_transform) ----------------------

## The bolt mesh's own dimensions, kept next to the sizes they are built from
## in _build_multimesh_nodes() so the distance compensation can't drift out of
## step with the mesh it is compensating.
const BOLT_MESH_LENGTH := 26.0
const BOLT_MESH_WIDTH := 1.1  # 2 x bottom_radius

## How long after firing the muzzle flare lasts, and how much wider the bolt
## is at the instant of the shot.
const BOLT_FLASH_TIME := 0.09
const BOLT_FLASH_SCALE := 3.4

const KILL_FEED_MAX_ENTRIES := 6
const KILL_FEED_ENTRY_LIFETIME := 8.0

## The SAME performance definition the player's own ship flies by (see
## flight_controller.gd, scripts/omega_motion.gd and
## docs/omega-flight-model.md). Every combatant's cruise speed, throttle
## response and turn rate is derived from this resource, so "the player
## flies the same ship as the AI" holds in code — retuning
## standard_fighter.tres retunes the player and all 200 ships together
## instead of letting the two drift apart, which is exactly what had
## happened before (the AI cruised at 140-210 m/s against the player's 300,
## and turned at an unbounded slerp rate with no relation to the player's
## pitch/yaw limit).
@export var flight_profile: ShipFlightProfile = preload("res://Assets/ShipProfiles/standard_fighter.tres")

@export var friendly_count: int = 100
@export var enemy_count: int = 100
## Was 8000.0, sized against the ORIGINAL fixed-footprint city's ~7637m
## corner-to-corner diagonal — left untouched through the map-wide city
## rework specifically because that was a building-placement change, not
## a scoring one (see city_generator.gd's own note on this). Direct
## follow-up request once the city and its mega towers actually spanned
## the map: "I think the dome for the city is too small and should extend
## through majority of the map." 40000.0 against the terrain's 50000m
## half-extent gives an 80000m-diameter contested column — a circle
## covering just over half the SQUARE map's total area, and the majority
## of anywhere actually worth flying (the corners are the most extreme,
## least-built-up mountain terrain). Every formula already reading this
## export (rally points, squad objective radii, in-dome checks) scales
## automatically; nothing needed a separate fix.
@export var dome_radius: float = 40000.0

## The "1 V 1" game mode (game_flow.gd's GameMode.ONE_V_ONE). Direct
## request, deliberately scoped tiny: "we won't really do much work into
## it... it's just gonna be a one v one... play against one bot... a five
## kilometer by five kilometer version of this map." friendly_count/
## enemy_count can't actually be resized at runtime — squads and
## MultiMeshes are built ONCE in _ready(), long before the player has
## picked a mode from the main menu — so duel_mode doesn't touch fleet
## size at all. Instead it gates ONE existing, well-tested transition
## (PARKED -> LAUNCHING, see _update_combatant) so every combatant except
## a single designated enemy (index 0 of `_enemies`) stays parked on its
## mothership deck forever — invisible, inert, and 44km away, so it might
## as well not exist. That one opponent is then hand-placed close to the
## player by `_start_duel()` rather than launched normally (the normal
## launch-wave/mothership-transit system is exactly the "22-44km away"
## geometry the small-arena request is asking NOT to have), and the
## EXISTING proximity-based player-aggro logic (`aggro_radius_player`,
## already how any alien acquires the player as a target in the normal
## game) is what actually gets it hunting — no separate duel-specific
## combat AI needed.
@export var duel_mode: bool = false

## Lid on the contested volume, in metres above terrain.
##
## **0 or less means NO lid (the default)** — the contested airspace is an
## unbounded cylinder running from the ground straight up through the cloud
## deck and on into the skybox, so holding air superiority means holding the
## column over the city at ANY altitude rather than only up to an arbitrary
## line. That is what "air superiority" should mean, and the previous 3500m
## ceiling had the odd side effect of putting the boundary *inside* the cloud
## band (3200-3800m), so climbing through the weather quietly dropped you out
## of scoring.
##
## A positive value re-imposes a hard ceiling at that height above terrain.
##
## Note this is deliberately NOT the altitude the AI flies at — see
## `ai_objective_ceiling`. How high the contested volume reaches and how high
## the fleet chooses to operate are separate questions, and coupling them was
## an accident of the original implementation.
@export var dome_ceiling: float = 0.0

## Ceiling on where squads pick their in-dome objectives, in metres above
## terrain. Previously derived from `dome_ceiling * 0.7`, which meant
## removing the scoring lid would have scattered the whole fleet toward the
## stratosphere; this preserves the exact altitude band the AI already fought
## in (3500 * 0.7) as its own independent value.
@export var ai_objective_ceiling: float = 2450.0
@export var match_duration: float = 600.0  # 10 minutes
@export var aggro_radius_player: float = 2500.0
@export var max_ambient_bolts: int = 320  # raised with the slower bolts — they live longer on screen
@export var enable_building_collision_check: bool = true
@export var as_generation_multiplier: float = 0.01  # RETIRED — see the class header's CONQUEST note

@export_group("Conquest — tower capture scoring")
## Horizontal distance from a tower a ship (or the player) counts as
## "present" for capture purposes. 4000m against a 32000m ring radius
## between neighbouring towers leaves each zone clearly its own contested
## area rather than overlapping the next one.
@export var capture_radius: float = 4000.0
## CLOCK-SWEEP CAPTURE MODEL — replaced the old flat `zone_capture_rate`.
## Direct follow-up request, after the flat-rate version read as "it just
## instantly captures when somebody gets in that field": a capture should
## visibly sweep like a clock hand (see `_build_zone_letters()`'s hand
## meshes and `_update_capture_zones()`'s own header), taking
## `capture_base_time` seconds for a FULL 0->100% sweep with exactly ONE
## ship of the dominant faction present — "a capture takes about thirty
## seconds for one person" — getting exponentially faster as more of that
## faction pile onto the zone, and never faster than `capture_min_time`
## however many show up: "it can never be faster than a five second
## capture." See `_capture_sweep_duration()` for the exact curve.
@export var capture_base_time: float = 30.0
## Floor on sweep duration no matter how many ships are present.
@export var capture_min_time: float = 5.0
## How quickly additional presence shortens the sweep below
## `capture_base_time`, applied as an exponential decay toward
## `capture_min_time` (see `_capture_sweep_duration()`) — first-pass, needs
## live tuning like every other rate in this project.
@export var capture_decay_rate: float = 0.5
## Points per second, per zone currently controlled, added to that zone's
## owning faction's score. Six zones held for the whole 10-minute match
## would alone contribute 6 * 0.2 * 600 = 720 of the 1000-point target —
## strong enough that map control can matter on its own, but not so strong
## it trivially dominates kills. First-pass, needs live tuning.
@export var zone_score_rate: float = 0.2
## Added to a faction's score per confirmed kill (ship-vs-ship combat only
## — a crash into terrain/a building isn't credited to anyone). Direct
## instruction: "we're gonna go by kills... for every one kill is one
## point."
@export var kill_score_value: float = 1.0
## First side to reach this score wins outright; if the 10-minute timer
## expires first, whichever score is higher wins (exactly equal is a
## draw). Direct instruction: "the score is gonna go all the way to a
## thousand."
@export var score_target: float = 1000.0

@export_group("Capture confirmation audio")
## Direct request: "trigger[ed] once an objective has been captured by
## either side... directional, come from the way that the capture point
## is, and everybody on the map can hear it." `max_distance` (0 = no hard
## cutoff, per Godot's own AudioStreamPlayer3D convention) combined with a
## deliberately huge `unit_size` is what makes "everybody on the map" true
## — a real inverse-distance falloff, not a range gate that silently skips
## spawning the sound past some radius the way `_play_battle_sound()`'s
## budgeted ambience does.
@export var capture_sound_unit_size: float = 6000.0
@export var capture_sound_max_distance: float = 0.0
@export var capture_sound_volume_db: float = 6.0
## Distance low-pass — kept modest since the source is already heavily
## darkened at the mix stage (see CAPTURE_CONFIRMED_SOUND's own header);
## this only adds a little extra muffling the further away you are.
@export var capture_sound_cutoff_hz: float = 2200.0

## How many aliens may hunt the player at once. An "attacker cap" is a
## standard modern-combat-AI pacing device: without it, every alien inside
## aggro_radius_player converges on the player at the same time and the
## fight stops being winnable or readable.
@export var max_aliens_targeting_player: int = 3

## The player is weighted as if this much closer than it really is when an
## alien picks a target, so the player actually gets hunted instead of
## always losing out to whichever friendly ship happens to be marginally
## nearer (the player flies with the friendly fleet, so that was almost
## always the case).
@export var player_target_bias: float = 0.55

@export_group("Tracer readability")
## Minimum on-screen size a tracer is allowed to shrink to, in DEGREES of
## visual angle. Exported in degrees rather than pixels because that is the
## unit that stays true across headsets and render-scale settings; at roughly
## 20.6 px/degree per eye here, 0.12 deg is about 2.5 pixels of width and 0.5
## deg about 10 pixels of length. Raise for a more stylised, tracer-heavy
## look; set to 0 to disable the compensation entirely and get true
## world-space scale back.
@export var bolt_min_angular_width_deg: float = 0.12
@export var bolt_min_angular_length_deg: float = 0.5

@export_group("Ground objective doctrine")
## What fraction of the ATTACKING faction's squads fly ground strikes against
## tank_objective.gd's fuel tanks instead of dogfighting. Deliberately a small
## minority — "I don't want that to be the main focus of every AI in the game
## is to blow up tankers. They should be mostly involved in dogfighting and
## defending." At the default ~33 squads a side that is roughly 6 strike
## flights, ~15 ships out of 100.
##
## Because `Combatant.ground_attack_affinity` is rolled uniformly on 0..1,
## this value IS the threshold's percentile — set it to 0.0 to switch AI
## ground attack off entirely without touching any other number.
@export_range(0.0, 1.0, 0.01) var strike_squad_fraction: float = 0.18

## The defending counterpart: what fraction of the DEFENDING faction's squads
## patrol over their own tanks rather than roaming the dome. Higher than the
## strike fraction on purpose — a defender loitering near a tank is still a
## fully normal fighter that will engage anything it meets, so it costs the
## air war much less than committing a flight to a ground run does.
@export_range(0.0, 1.0, 0.01) var tank_guard_squad_fraction: float = 0.28

## Damage one AI bolt does to a fuel tank, against BOLT_DAMAGE (10) for a
## ship. HIGHER than a ship hit, which is the opposite of the first guess and
## the opposite of how it reads — the reason is that a striker gets very few
## shots away per sortie, not that its guns are special.
##
## Measured: a strike flight crosses 22km each way, so even after widening
## GROUND_ATTACK_FIRE_RANGE a pilot lands only a handful of rounds per pass,
## and it dies often enough (strikers do not defend themselves) to restart
## that transit repeatedly. At 3.0 the whole attacking fleet dealt 12 total
## damage in 420 seconds — one fifth of a single tank. This is the dial that
## turns measured shots-on-target into a sane number of tanks per match; it
## is not a difficulty knob for how well the AI shoots, which is already
## covered per pilot by `accuracy`.
@export var ai_tank_damage: float = 8.0

@export_group("Effect budget")
@export var max_concurrent_explosions: int = 14
@export var explosion_light_range: float = 4000.0  # past this, the kill fireball spawns without its OmniLight3D
@export var explosion_cull_range: float = 15000.0  # past this, no kill effect at all
@export var max_concurrent_sparks: int = 10
@export var spark_range: float = 2500.0  # non-lethal hit sparks only spawn this close to the player
@export var max_battle_sounds: int = 12
@export var explosion_sound_range: float = 7000.0
@export var laser_sound_range: float = 1500.0
@export_group("Motherships")
## Length in meters. The mesh is normalised so this IS the length — width
## and deck height are fixed ratios of it (see mothership.gd). 2000m makes
## it read as a capital ship against a city whose tallest towers are ~625m.
## Unverified in VR, like every other asset scale in this project.
@export var mothership_length: float = 4000.0
## Height of the mothership's underside above the terrain below it.
@export var mothership_altitude: float = 3000.0
## RETIRED — replaced by `mothership_corner_inset` below. This drove both
## motherships along a single straight line THROUGH `dome_center`
## (west/east); the corner-placement rework replaced that axis-locked
## geometry entirely rather than just retuning the distance. Left defined,
## not deleted, purely so old saved values in a `.tscn` override don't
## error — nothing reads it anymore.
@export var spawn_distance_from_city: float = 22000.0
## Direct follow-up request: "the cruisers have to get moved to the
## corners of the map... on the opposite sides of each other" — each
## faction's mothership (and therefore its whole fleet, since everything
## launches from the deck) now sits at a DIAGONALLY OPPOSITE corner of the
## whole terrain square, not on a fixed cardinal axis through the middle.
## This is the margin kept back from the literal map edge
## (`terrain.world_size / 2`) so a mothership's own ~2660m-wide deck (see
## `mothership_length`) has room to sit fully on the terrain. See
## `_ready()`'s corner computation and CLAUDE.md's own measured opening-
## transit figures for this new, much longer diagonal — raising/lowering
## this is now the pacing dial `spawn_distance_from_city` used to be.
@export var mothership_corner_inset: float = 8000.0
@export var laser_sound_chance: float = 0.07  # only this fraction of nearby shots get a sound — the rest would be a wall of noise

## Live status, readable by battle_hud.gd / target_lock.gd / enemy_locator.gd.
var air_superiority: float = 0.0  # RETIRED — see the class header's CONQUEST note
var match_time_remaining: float = 0.0
var game_over: bool = false
var winning_faction: int = -1  # Combatant.Faction.FRIENDLY/ENEMY, or -1 for a draw
var dome_center: Vector3 = Vector3(6000.0, 0.0, 0.0)

## The real score now — see the class header's CONQUEST note and the
## "Conquest" section below. Readable by battle_hud.gd.
var friendly_score: float = 0.0
var enemy_score: float = 0.0

## One CaptureZone per mega tower, built once in _ready() from
## CityGenerator.get_mega_tower_positions() — see capture_zone.gd.
var capture_zones: Array[CaptureZone] = []

## Gated by game_flow.gd — false until the player confirms the start menu,
## so ships spawn and sit visibly (frozen) rather than fighting/scoring
## before the match has actually begun.
var simulation_active: bool = false

## Pre-joined recent-kills text ("who died and how"), read directly by
## kill_feed_hud.gd — see _add_kill_feed_entry()/_update_kill_feed().
var kill_feed_text: String = ""

var _kill_feed_entries: Array = []  # Array of {"text": String, "age": float}

var _friendlies: Array[Combatant] = []
var _enemies: Array[Combatant] = []
var _friendly_squads: Array[Squad] = []
var _enemy_squads: Array[Squad] = []
var _ambient_bolts: Array[Dictionary] = []
var _friendly_grid: Dictionary = {}
var _enemy_grid: Dictionary = {}
var _frame_counter: int = 0
var _aliens_on_player: int = 0
var _as_accumulated_delta: float = 0.0

var _friendly_spawn_center: Vector3
var _enemy_spawn_center: Vector3

var _terrain: Node
var _player: Node3D
var _city: Node
## tank_objective.gd, if the ground objective is in the scene at all. Every
## use is null-guarded — the mass battle predates the ground objective and
## must still run without it (headless sims instantiate it, but a stripped
## test scene may not).
var _tank_objective: Node

## The actual camera, not the XROrigin3D rig — bolt sizes are compensated
## against the distance to the player's EYE, and in VR the rig and the head
## can be metres apart. Resolved once; every use is null-guarded so the
## battle still runs headless with no camera at all.
var _view_point: Node3D
var _bolt_min_width_rad: float = 0.0
var _bolt_min_length_rad: float = 0.0

var _friendly_mmi: MultiMeshInstance3D
var _enemy_mmi: MultiMeshInstance3D
var _bolt_mmi: MultiMeshInstance3D

var _friendly_mothership: Node3D
var _enemy_mothership: Node3D

var _live_explosions: Array = []
var _live_sounds: Array = []
var _live_sparks: Array = []


func _ready() -> void:
	randomize()
	_terrain = get_node_or_null("../Terrain")
	_player = get_tree().current_scene.get_node_or_null("Player")
	_tank_objective = get_node_or_null("../TankObjective")
	if _player:
		_view_point = _player.get_node_or_null("XRCamera3D") as Node3D
	if _view_point == null:
		_view_point = _player
	_bolt_min_width_rad = deg_to_rad(bolt_min_angular_width_deg)
	_bolt_min_length_rad = deg_to_rad(bolt_min_angular_length_deg)

	_city = get_node_or_null("../City")
	if _city and "city_center" in _city:
		dome_center = _city.city_center

	# Diagonally opposite corners of the whole terrain square — NOT
	# dome_center-relative, since "corners of the map" means the map's own
	# extent (world_size), and dome_center sits only 6000m off true world
	# origin, negligible against a 50000m half-extent. Southwest vs.
	# northeast is an arbitrary choice of diagonal (the other diagonal
	# would be exactly as valid); what matters is that the two are on
	# OPPOSITE corners, not opposite ends of one cardinal axis like before.
	var terrain_half: float = (_terrain.world_size * 0.5) if _terrain else 50000.0
	var corner: float = terrain_half - mothership_corner_inset
	_friendly_spawn_center = Vector3(-corner, 0.0, -corner)
	_enemy_spawn_center = Vector3(corner, 0.0, corner)
	match_time_remaining = match_duration
	_build_capture_zones()

	_build_multimesh_nodes()
	_build_motherships()
	_spawn_faction(_friendlies, friendly_count, Combatant.Faction.FRIENDLY)
	_spawn_faction(_enemies, enemy_count, Combatant.Faction.ENEMY)
	_build_squads(_friendlies, _friendly_squads, Combatant.Faction.FRIENDLY, _friendly_spawn_center)
	_build_squads(_enemies, _enemy_squads, Combatant.Faction.ENEMY, _enemy_spawn_center)
	_place_all_at_spawn()

	_friendly_mmi.multimesh.instance_count = friendly_count
	_enemy_mmi.multimesh.instance_count = enemy_count


func _physics_process(delta: float) -> void:
	if simulation_active and not game_over:
		_update_match_timer(delta)

		# Grids are rebuilt at the TOP of the frame so separation steering
		# below can use them. Only the bucketing is a frame stale by the time
		# the bolt checks run (positions themselves are read live), and at
		# 450m cells a frame of movement can't move anything meaningfully
		# between buckets.
		_rebuild_spatial_grids()
		_aliens_on_player = 0

		for sq in _friendly_squads:
			_update_squad(sq, _friendlies, delta)
		for sq in _enemy_squads:
			_update_squad(sq, _enemies, delta)

		for i in _friendlies.size():
			_update_combatant(_friendlies[i], i, _enemies, _friendlies, _friendly_grid, _friendly_squads, false, delta)
		for i in _enemies.size():
			_update_combatant(_enemies[i], i, _friendlies, _enemies, _enemy_grid, _enemy_squads, true, delta)

		# duel_mode's whole win condition: kill or be killed. The player
		# losing is already handled organically by crash_handler.gd's own
		# death flow (GameFlow._process() checks _crash_handler.crashed
		# independently of this battle's own game_over) — this only needs
		# to catch the other direction. _kill_combatant() still sets a
		# respawn timer on the opponent same as any normal kill; harmless,
		# since declare_winner() below stops simulation before it ever fires.
		if duel_mode and not _enemies.is_empty() and not (_enemies[0] as Combatant).alive:
			declare_winner(Combatant.Faction.FRIENDLY, "duel opponent destroyed")

		_update_ambient_bolts(delta)
		_update_capture_zones(delta)
		_update_score(delta)
		_update_kill_feed(delta)
		_frame_counter += 1

	# Always write transforms, even while paused (pre-match menu / post-match
	# summary) — ships stay visibly present, just frozen, instead of vanishing
	# because their MultiMesh instances were never given a transform.
	_write_multimesh_transforms()


## Called by game_flow.gd once the player confirms the start menu.
func start_battle() -> void:
	simulation_active = true
	if duel_mode:
		_start_duel()


## Hand-places the one active duel opponent close to the player instead of
## launching it from its mothership — see duel_mode's own export header
## for why. Deliberately simple: just position + a safe non-PARKED state;
## the EXISTING proximity-based player-aggro logic (_retarget_if_needed,
## aggro_radius_player) takes over from there and transitions it into
## PURSUE on its own within a frame or two, same as it would for any
## alien that happens to fly close to the player in a normal match.
func _start_duel() -> void:
	if _enemies.is_empty() or not _player:
		return
	var opponent: Combatant = _enemies[0]
	var player_pos: Vector3 = _player.global_position
	# Comfortably inside aggro_radius_player (2500m default) so it notices
	# the player almost immediately, but not point-blank.
	var offset := Vector3(randf_range(-1200.0, 1200.0), randf_range(-100.0, 300.0), -1800.0)
	opponent.position = player_pos + offset
	opponent.heading = (player_pos - opponent.position).normalized()
	opponent.state = Combatant.State.FORMATION
	opponent.launch_delay = 0.0
	opponent.speed = opponent.base_speed
	opponent.target_index = -1
	opponent.targeting_player = false


## Called by game_flow.gd on "return to main menu" — puts the battle back
## in its pre-match state (everyone alive and repositioned, AS/timer reset)
## without a real scene reload.
func reset_battle() -> void:
	simulation_active = false
	game_over = false
	winning_faction = -1
	air_superiority = 0.0
	friendly_score = 0.0
	enemy_score = 0.0
	for zone in capture_zones:
		zone.capture_value = 0.0
		# Reset so a zone captured by the SAME faction again next match
		# still fires the confirmation sound — without this, last_captured_owner
		# would still read that faction from the previous match and the
		# "genuinely changed" check in _maybe_play_capture_sound() would
		# silently skip it the first time around.
		zone.last_captured_owner = CaptureZone.NEUTRAL
		# Explicit rather than waiting for the next _update_capture_zones()
		# tick (which only runs while simulation_active) — a player who
		# returns to the menu and looks at a tower shouldn't still see last
		# match's colour, glow, or hand position.
		_update_zone_visual(zone, 0, 0.0)
	match_time_remaining = match_duration
	_ambient_bolts.clear()
	_kill_feed_entries.clear()
	kill_feed_text = ""
	for sq in _friendly_squads:
		_reset_squad(sq)
	for sq in _enemy_squads:
		_reset_squad(sq)
	_place_all_at_spawn()


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

## Explicit bounds for every MultiMesh this manager drives, generously sized
## to cover the whole playable volume (the terrain is 100km across and the
## motherships sit 22km either side of the city).
##
## Why set it at all: writing an instance transform marks a MultiMesh's AABB
## dirty, and a dirty MultiMesh with no custom_aabb has its bounds
## RECOMPUTED by walking every instance it owns. This manager rewrites all
## ~520 instance transforms (100 + 100 ships, up to 320 bolts) every single
## frame, so that recompute ran every frame too — pure overhead, since the
## result was only ever used to decide whether to cull a batch that spans
## the entire map and is therefore never actually culled. Handing it fixed
## bounds skips the walk entirely.
const MULTIMESH_WORLD_AABB := AABB(
		Vector3(-60000.0, -20000.0, -60000.0), Vector3(120000.0, 40000.0, 120000.0))


func _build_multimesh_nodes() -> void:
	var ship_mesh: Mesh = load(SHIP_MESH_PATH)
	_friendly_mmi = _make_ship_multimesh(ship_mesh, FRIENDLY_COLOR)
	_enemy_mmi = _make_ship_multimesh(ship_mesh, ENEMY_COLOR)

	# Long and fat compared to the player's own bolt. These are being viewed
	# from hundreds or thousands of meters away across a whole battle, where
	# the original 2.5m x 0.06m sliver was far below one pixel. Per-instance
	# COLOR carries the faction tint (see _bolt_transform / MultiMesh's
	# use_colors below), read directly by laser_bolt.gdshader.
	var bolt_mesh := CylinderMesh.new()
	bolt_mesh.top_radius = 0.15
	bolt_mesh.bottom_radius = 0.55
	bolt_mesh.height = 26.0
	bolt_mesh.radial_segments = 6

	# laser_bolt.gdshader — see that file's header. Same glowing hot-core/
	# cool-tail energy-bolt look as the player's own LaserBolt.tscn, so the
	# whole battle's tracers read as one consistent weapon rather than the
	# player firing something visually unrelated to the AI's own guns.
	var bolt_mat := ShaderMaterial.new()
	bolt_mat.shader = LASER_BOLT_SHADER
	bolt_mat.set_shader_parameter("top_radius", bolt_mesh.top_radius)
	bolt_mat.set_shader_parameter("bottom_radius", bolt_mesh.bottom_radius)
	bolt_mat.set_shader_parameter("energy", 6.0)
	# Set explicitly rather than left to the shader's own GLSL default, even
	# though the two happen to match — an implicit reliance here would be a
	# silent trap for a future edit to the shader's default, and
	# get_shader_parameter() (unlike the shader itself at render time) does
	# NOT fall back to the GLSL default for anything never explicitly set.
	bolt_mat.set_shader_parameter("head_color", Color(1.0, 0.97, 0.9))
	# Neutral WHITE, deliberately — this is what carries forward the earlier
	# "every tracer bloomed the same flat white, swamping the faction tint"
	# fix (see CLAUDE.md's tracer-readability section) into the new shader's
	# own blend: the fragment shader computes `tail_color * COLOR`, so a
	# white tail_color makes that multiply a pass-through and the per-bolt
	# faction COLOR (cyan friendly / red hostile) is what actually shows at
	# the tail, unmodified. Only the LEADING TIP is a shared, faction-neutral
	# hot white — every bolt in the battle now has the identical two-tier
	# "white-hot punch, faction-coloured cooling tail" look, matching the
	# player's own weapon exactly.
	bolt_mat.set_shader_parameter("tail_color", Color(1.0, 1.0, 1.0))

	_bolt_mmi = MultiMeshInstance3D.new()
	# Bolts are unshaded emissive tracers — a shadow from one would be both
	# wrong and a per-frame cost on hundreds of moving instances.
	_bolt_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bolt_mmi)
	var bolt_multimesh := MultiMesh.new()
	bolt_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	bolt_multimesh.use_colors = true
	bolt_multimesh.mesh = bolt_mesh
	bolt_multimesh.instance_count = max_ambient_bolts
	bolt_multimesh.visible_instance_count = 0
	bolt_multimesh.custom_aabb = MULTIMESH_WORLD_AABB
	_bolt_mmi.multimesh = bolt_multimesh
	_bolt_mmi.material_override = bolt_mat


## One stationary capital ship per faction, hovering at that faction's spawn
## point. Built here rather than placed in Town.tscn so the visual and the
## spawn logic can never drift apart — this project already carries a
## documented multi-place coupling for the player's own spawn coordinate and
## does not need another one.
func _build_motherships() -> void:
	_friendly_mothership = _make_mothership(_friendly_spawn_center, FRIENDLY_COLOR)
	_enemy_mothership = _make_mothership(_enemy_spawn_center, ENEMY_COLOR)


func _make_mothership(at_xz: Vector3, tint: Color) -> Node3D:
	var ship := MOTHERSHIP.instantiate()
	# Assigned before add_child(), since mothership.gd's _ready() applies
	# both of these — the same ordering rule documented in this file's header.
	ship.length = mothership_length
	ship.tint = tint
	add_child(ship)
	var ground: float = _terrain.get_height_at(at_xz.x, at_xz.z) if _terrain else 0.0
	ship.global_position = Vector3(at_xz.x, ground + mothership_altitude, at_xz.z)
	return ship


func _mothership_for(faction: int) -> Node3D:
	return _friendly_mothership if faction == Combatant.Faction.FRIENDLY else _enemy_mothership


func _make_ship_multimesh(mesh: Mesh, tint: Color) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	# 200 small, fast-moving ships would re-render into the shadow map every
	# frame for shadows that are a few pixels across from any distance the
	# player actually sees them at. Not worth the pass.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 0.6
	mmi.material_override = mat

	# transform_format must be set before instance_count — instance_count
	# allocates the multimesh buffer sized to whatever format is active at
	# that moment (set later in _ready(), once friendly/enemy_count are known).
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.custom_aabb = MULTIMESH_WORLD_AABB
	mmi.multimesh = mm
	return mmi


func _spawn_faction(target: Array, count: int, faction: int) -> void:
	for i in count:
		var c := Combatant.new()
		c.faction = faction
		# Cruise as a FRACTION of the shared profile's top speed, so raising
		# the ship's performance carries the whole fleet with it rather than
		# leaving the AI behind at stale absolute numbers.
		c.base_speed = randf_range(
				flight_profile.ai_cruise_fraction_min,
				flight_profile.ai_cruise_fraction_max) * flight_profile.max_forward_speed
		c.speed = c.base_speed
		c.accuracy = randf_range(0.55, 0.95)
		# Uniform on purpose — see Combatant.ground_attack_affinity. A uniform
		# roll is its own percentile, so strike_squad_fraction /
		# tank_guard_squad_fraction below are exact proportions rather than
		# thresholds that need requantifying if the curve is ever changed.
		c.ground_attack_affinity = randf()
		c.health = MAX_HEALTH
		c.alive = true
		target.append(c)


## Cuts a faction's flat array into squads of 1-5, each with its own spawn
## point along a wide front and its own objective inside the dome. Squad
## membership is fixed for the whole match — a dead member respawns back
## into the same slot, matching the MultiMesh instance buffer's fixed
## indexing.
func _build_squads(units: Array, squads: Array[Squad], faction: int, base_center: Vector3) -> void:
	var i := 0
	while i < units.size():
		var size: int = mini(randi_range(SQUAD_SIZE_MIN, SQUAD_SIZE_MAX), units.size() - i)
		var sq := Squad.new()
		sq.faction = faction
		sq.spawn_center = base_center
		sq.objective = _random_point_in_dome()
		sq.rally_point = _make_rally_point(base_center)
		for k in size:
			var idx: int = i + k
			var c: Combatant = units[idx]
			c.squad_id = squads.size()
			c.squad_slot = k
			sq.members.append(idx)
		sq.leader = sq.members[0]
		squads.append(sq)
		i += size


## Parks the whole fleet on its mothership's deck, in launch order. Squads
## previously spawned scattered over a 7km front, which was the original fix
## for "the AI clusters in huge packs" — that spread is now provided instead
## by the launch waves (squads leave one at a time), each squad's own
## objective inside the dome, and the separation steering, none of which
## depend on where they started.
func _place_all_at_spawn() -> void:
	_park_faction(_friendlies, _friendly_squads)
	_park_faction(_enemies, _enemy_squads)


func _park_faction(units: Array, squads: Array[Squad]) -> void:
	for s in squads.size():
		var sq: Squad = squads[s]
		for idx in sq.members:
			var c: Combatant = units[idx]
			_respawn_combatant(c, sq)
			c.respawn_time_remaining = 0.0
			# Launch order runs down the deck, so the fleet leaves in a
			# readable procession instead of a scramble.
			c.launch_delay = float(s) * LAUNCH_WAVE_INTERVAL + randf_range(0.0, 0.4)


func _reset_squad(sq: Squad) -> void:
	sq.state = Squad.State.ADVANCE
	sq.state_timer = 0.0
	sq.losses = 0
	sq.focus_target = -1
	sq.focus_is_player = false
	sq.role = Squad.Role.FIGHTER
	sq.strike_target = -1
	sq.objective = _squad_next_objective(sq)
	sq.rally_point = _make_rally_point(sq.spawn_center)
	sq.leader = sq.members[0] if not sq.members.is_empty() else -1


# ---------------------------------------------------------------------------
# Ground doctrine — which squads care about tank_objective.gd's fuel tanks
# ---------------------------------------------------------------------------

## Called by game_flow.gd at match start, immediately AFTER
## TankObjective.start_objective() has flipped the attacker/defender coin —
## which is the whole reason this can't live in _build_squads(): a squad's
## ground role depends on which side its faction drew this match, and that is
## rerolled every match while squads are built once in _ready().
##
## Only a minority of squads get a ground role at all. Everything else keeps
## the pre-existing pure-dogfight behaviour untouched.
func assign_ground_roles() -> void:
	var attacker := -1
	if _tank_objective and _tank_objective.active:
		attacker = _tank_objective.attacking_faction
	_assign_roles_for(_friendly_squads, _friendlies, Combatant.Faction.FRIENDLY, attacker)
	_assign_roles_for(_enemy_squads, _enemies, Combatant.Faction.ENEMY, attacker)


## Ranks a faction's squads by their LEADER's ground_attack_affinity and gives
## the role to the top N, where N is the exported fraction of the squad count.
##
## Deliberately the LEADER's trait, not the max across members: taking the max
## would make a 5-ship squad roughly five times likelier to draw a ground role
## than a lone pilot, and squad size has nothing to do with doctrine. The lead
## decides where the flight goes, which is already true of every other
## steering decision in this file.
##
## RANKING rather than testing each leader against a threshold independently.
## Both honour the trait identically, but an independent per-squad test is a
## binomial draw, and at ~31 squads that has real spread: two measured runs
## produced 3 strike squads in one match and 10 in another — a 3x swing in
## ground pressure that the player can neither see nor diagnose, and a match
## at the low end has almost no ground war at all, which is the exact failure
## this whole feature exists to fix. Ranking makes strike_squad_fraction mean
## precisely what it says in every match, while leaving WHICH squads draw the
## role fully random.
func _assign_roles_for(squads: Array[Squad], units: Array, faction: int, attacker: int) -> void:
	for sq in squads:
		sq.role = Squad.Role.FIGHTER
		sq.strike_target = -1
	if attacker < 0:
		return

	var is_attacker := faction == attacker
	var fraction: float = strike_squad_fraction if is_attacker else tank_guard_squad_fraction
	var role: int = Squad.Role.STRIKE_ROLE if is_attacker else Squad.Role.TANK_GUARD
	if fraction <= 0.0:
		return

	var ranked: Array[Squad] = []
	for sq in squads:
		if sq.leader >= 0 and sq.leader < units.size():
			ranked.append(sq)
	ranked.sort_custom(func(a: Squad, b: Squad) -> bool:
			return (units[a.leader] as Combatant).ground_attack_affinity \
					> (units[b.leader] as Combatant).ground_attack_affinity)

	var n: int = mini(int(round(float(ranked.size()) * fraction)), ranked.size())
	for i in n:
		ranked[i].role = role


## True while this squad is actually committed to a live ground target.
func _is_striking(sq: Squad) -> bool:
	return sq.state == Squad.State.STRIKE and sq.strike_target >= 0


## Where a strike flight steers — the same point _try_fire_ground() shoots at,
## deliberately. See GROUND_ATTACK_BREAK_RANGE's comment for what happened
## when these two were allowed to differ.
func _strike_aim_point(sq: Squad) -> Vector3:
	if _tank_objective == null or sq.strike_target < 0:
		return Vector3.ZERO
	return _tank_objective.get_tank_aim_point(sq.strike_target)


## Keeps the squad's current tank if it's still standing, otherwise picks the
## nearest live one. Returns false when there is no ground target to be had —
## no objective in the scene, this faction isn't the attacker, or every tank
## is already destroyed — at which point the squad reverts to a fighter.
func _acquire_strike_target(sq: Squad, from: Vector3) -> bool:
	if _tank_objective == null or not _tank_objective.active:
		sq.strike_target = -1
		return false
	if _tank_objective.attacking_faction != sq.faction:
		sq.strike_target = -1
		return false
	if _tank_objective.is_tank_alive(sq.strike_target):
		return true
	sq.strike_target = _tank_objective.get_nearest_live_tank(from)
	return sq.strike_target >= 0


## The squad's next patrol point. Identical to the old
## `_random_point_in_dome()` for everyone except a TANK_GUARD, which instead
## loiters in the airspace around one of its own tanks — no new state machine,
## it still fights exactly like any other squad, it just happens to already be
## where an attacker has to come.
##
## A RANDOM live tank rather than the nearest: guards picking nearest would
## all converge on whichever tank sits closest to their mothership, which is
## the same single-point clustering bug _make_rally_point() had to be fixed
## for once already.
func _squad_next_objective(sq: Squad) -> Vector3:
	if sq.role == Squad.Role.TANK_GUARD and _tank_objective and _tank_objective.active \
			and _tank_objective.attacking_faction != sq.faction:
		var idx: int = _tank_objective.get_random_live_tank()
		if idx >= 0:
			var t: Vector3 = _tank_objective.get_tank_position(idx)
			var angle := randf() * TAU
			var r := randf_range(TANK_GUARD_PATROL_RADIUS * 0.3, TANK_GUARD_PATROL_RADIUS)
			return Vector3(
					t.x + cos(angle) * r,
					t.y + randf_range(TANK_GUARD_PATROL_ALT_MIN, TANK_GUARD_PATROL_ALT_MAX),
					t.z + sin(angle) * r)
	return _random_point_in_dome()


# ---------------------------------------------------------------------------
# Squad-level orders
# ---------------------------------------------------------------------------

func _update_squad(sq: Squad, units: Array, delta: float) -> void:
	sq.state_timer -= delta

	# Leadership succession — a squad whose leader is dead has no formation
	# anchor, so promote the first living member.
	var leader: Combatant = units[sq.leader] if sq.leader >= 0 else null
	if leader == null or not leader.alive:
		sq.leader = -1
		for idx in sq.members:
			if (units[idx] as Combatant).alive:
				sq.leader = idx
				break
		if sq.leader < 0:
			return
		leader = units[sq.leader]

	# The leader's target becomes the squad's focus, so wingmen concentrate
	# on one ship instead of each independently chasing its own nearest.
	sq.focus_target = leader.target_index
	sq.focus_is_player = leader.targeting_player

	# STRIKE doctrine is evaluated BEFORE the ordinary state machine, and that
	# ordering is the whole feature: a strike flight has to cross 22km of
	# contested air to reach the city, and if an air engagement could take
	# priority on the way in it would be absorbed into a dogfight and never
	# arrive. Its ground target outranks anything in the sky.
	#
	# RETREAT/REGROUP are excluded — morale still overrides doctrine, so a
	# strike flight that has been mauled still runs for its rally point.
	if sq.role == Squad.Role.STRIKE_ROLE \
			and sq.state != Squad.State.RETREAT and sq.state != Squad.State.REGROUP:
		if _acquire_strike_target(sq, leader.position):
			sq.state = Squad.State.STRIKE
			sq.objective = _strike_aim_point(sq)
		elif sq.state == Squad.State.STRIKE:
			# Every tank is down (or the objective ended) — nothing left to
			# strike, so this flight spends the rest of the match as an
			# ordinary fighter squad.
			sq.state = Squad.State.ADVANCE
			sq.objective = _squad_next_objective(sq)

	match sq.state:
		Squad.State.ADVANCE:
			if leader.position.distance_to(sq.objective) < 600.0:
				sq.objective = _squad_next_objective(sq)
			if sq.focus_target >= 0 or sq.focus_is_player:
				sq.state = Squad.State.ENGAGE
		Squad.State.ENGAGE:
			if sq.losses >= _squad_break_threshold(sq):
				sq.state = Squad.State.RETREAT
				sq.state_timer = SQUAD_RETREAT_TIME
			elif sq.focus_target < 0 and not sq.focus_is_player:
				sq.state = Squad.State.ADVANCE
		Squad.State.STRIKE:
			# The only way out other than running out of tanks (handled above)
			# is the same morale rule every other squad obeys. A strike flight
			# does not defend itself (see _update_combatant), so this is what
			# stops one grinding itself to nothing on a defended target.
			if sq.losses >= _squad_break_threshold(sq):
				sq.state = Squad.State.RETREAT
				sq.state_timer = SQUAD_RETREAT_TIME
		Squad.State.RETREAT:
			if sq.state_timer <= 0.0:
				sq.state = Squad.State.REGROUP
				sq.state_timer = SQUAD_REGROUP_TIME
		Squad.State.REGROUP:
			if sq.state_timer <= 0.0:
				sq.losses = 0
				sq.objective = _squad_next_objective(sq)
				sq.state = Squad.State.ADVANCE


## Half the squad (rounded up) is what it takes to break them. A single-ship
## "squad" is governed by its own health instead — it's dead before this
## could ever fire.
func _squad_break_threshold(sq: Squad) -> int:
	return maxi(1, ceili(float(sq.members.size()) * 0.5))


## Somewhere back toward the squad's own side of the map, well away from the
## dome — where a broken squad runs to before re-forming. Assigned ONCE per
## squad at build time and never recomputed.
##
## Each squad gets its own point, spread widely across its side of the map.
## This matters more than it looks: every squad in a faction used to derive
## its rally point from `spawn_center`, which was fine while squads spawned
## scattered across a 7000m front, but became a real bug when the
## motherships took over spawning and every squad's `spawn_center` became
## the same single point. Every retreating squad then ran to the *identical*
## location — and with a dozen squads typically in RETREAT at once, that is
## a large, permanent pack forming off to one side. It was the AI "grouping
## again" after the mothership change.
func _make_rally_point(base_center: Vector3) -> Vector3:
	var away := base_center - dome_center
	away.y = 0.0
	if away.length() < 1.0:
		away = Vector3.RIGHT * 1000.0
	away = away.normalized()
	# Lateral spread perpendicular to the away-from-city axis, so squads
	# rally along a broad line rather than at a single dot.
	var lateral := away.cross(Vector3.UP).normalized()
	var base := dome_center + away * (dome_radius + randf_range(2000.0, 5000.0))
	return base \
			+ lateral * randf_range(-6000.0, 6000.0) \
			+ Vector3(0.0, randf_range(900.0, 2400.0), 0.0)


# ---------------------------------------------------------------------------
# Per-combatant update
# ---------------------------------------------------------------------------

func _update_combatant(c: Combatant, my_index: int, opposing: Array, own_units: Array,
		own_grid: Dictionary, squads: Array[Squad], can_target_player: bool, delta: float) -> void:
	if not c.alive:
		c.respawn_time_remaining -= delta
		if c.respawn_time_remaining <= 0.0:
			_respawn_combatant(c, squads[c.squad_id])
		return

	c.state_timer -= delta
	c.reaction_timer -= delta

	var sq: Squad = squads[c.squad_id]

	# Parked on the mothership deck, waiting for its launch slot. Doesn't
	# move, steer, retarget or shoot — it's sitting on a flight deck.
	if c.state == Combatant.State.PARKED:
		# duel_mode: only the one designated opponent (enemy index 0) is ever
		# allowed off the deck — see duel_mode's own export header. Everyone
		# else stays parked for the rest of the match, which given they're
		# 44km away and never rendered near the player is functionally the
		# same as not existing.
		if duel_mode and not (c.faction == Combatant.Faction.ENEMY and my_index == 0):
			return
		c.launch_delay -= delta
		if c.launch_delay <= 0.0:
			c.state = Combatant.State.LAUNCHING
			c.speed = c.base_speed * 0.5  # rolls off the deck rather than leaving at cruise
		return

	# Sampled once and reused by both the ground-avoidance test and the
	# terrain/building crash test below — they used to sample independently.
	var ground_here: float = _terrain.get_height_at(c.position.x, c.position.z) if _terrain else 0.0

	# STRIKE DOCTRINE: a committed striker does not dogfight at all. It drops
	# any air target and never acquires another until the run is over.
	#
	# This is deliberate rather than a simplification. A loaded strike aircraft
	# that stops to dogfight isn't pressing an attack, and making strikers
	# genuinely vulnerable is precisely what gives the DEFENDING side something
	# to do — without it, defending the tanks would mean intercepting ships
	# that fight back exactly as well as any other fighter, and the attack /
	# defend split would carry no real difference in play. Their outs are the
	# ordinary ones: squad morale and their own health.
	#
	# Also removes the retarget scan (and its _aliens_on_player accounting)
	# entirely for these pilots, so the doctrine is slightly cheaper, not
	# dearer, than the behaviour it replaces.
	var on_strike := _is_striking(sq)
	if on_strike:
		c.target_index = -1
		c.targeting_player = false
	else:
		_retarget_if_needed(c, my_index, opposing, sq, can_target_player)

	var has_target := false
	var target_pos := Vector3.ZERO
	var target_vel := Vector3.ZERO
	if c.targeting_player and _player:
		has_target = true
		target_pos = _player.global_position
	elif c.target_index >= 0 and c.target_index < opposing.size() and (opposing[c.target_index] as Combatant).alive:
		has_target = true
		var t: Combatant = opposing[c.target_index]
		target_pos = t.position
		target_vel = t.heading * t.speed

	_update_pilot_state(c, sq, has_target, target_pos)

	var desired_dir := _steering_direction(c, sq, own_units, has_target, target_pos, target_vel)
	desired_dir += _separation(c, own_units, own_grid) * SEPARATION_WEIGHT

	# Ground avoidance overrides everything else when low or about to be low —
	# same reactive-pull-up pattern enemy_ai.gd used. Ships fly a straight
	# line at a fixed altitude offset from their own spawn point's ground
	# height, and this map's mountains reach into the thousands of meters, so
	# flying level is not automatically safe here.
	if _needs_pull_up(c, my_index, ground_here):
		var level_forward := desired_dir if desired_dir.length() > 0.01 else c.heading
		desired_dir = level_forward.normalized() + Vector3.UP * 1.5

	_turn_toward(c, desired_dir, delta)

	_update_throttle(c, sq, own_units, has_target, target_pos, delta)
	c.position += c.heading * c.speed * delta

	if _check_ground_or_building(c, ground_here):
		_kill_combatant(c, my_index, sq, "crashed")
		return

	c.fire_cooldown -= delta
	if c.state == Combatant.State.GROUND_ATTACK:
		if c.reaction_timer <= 0.0 and c.fire_cooldown <= 0.0:
			_try_fire_ground(c, my_index, sq)
	elif has_target and c.state != Combatant.State.RETREAT and c.state != Combatant.State.LAUNCHING \
			and c.reaction_timer <= 0.0 and c.fire_cooldown <= 0.0:
		_try_fire(c, my_index, target_pos, target_vel)

	# Rare, longer-range, longer-cooldown missile shot at the player
	# specifically — independent of the ambient laser cooldown above, so a
	# player-targeting alien fires both its routine lasers and, much less
	# often, an actual homing missile (see missile.gd's target_is_player
	# mode). This is what gives flare_system.gd's X button a real target.
	c.missile_cooldown -= delta
	if c.targeting_player and c.state != Combatant.State.RETREAT and c.missile_cooldown <= 0.0 \
			and c.position.distance_to(target_pos) <= MISSILE_ENGAGE_RANGE:
		c.missile_cooldown = randf_range(MISSILE_COOLDOWN_MIN, MISSILE_COOLDOWN_MAX)
		_fire_missile_at_player(c, target_pos)


## Rotates a ship's nose toward `desired_dir` under the SAME bounded turn
## rate the player's ship obeys (flight_profile.ai_turn_max_rate, which is
## the profile's real pitch/yaw limit), ramping that rate up and braking it
## back down through OmegaMotion rather than snapping.
##
## This replaced a flat `heading.slerp(desired, TURN_RATE * delta)`. That
## form has two problems this fixes: its effective angular speed was
## proportional to how far off the target was (a 180-degree reversal swung
## faster than a small correction — the opposite of how an airframe
## behaves), and it had no acceleration at all, so a ship changed from
## flying straight to turning at full rate within a single frame.
##
## Steering is a POSITIONAL problem — "close this angle to zero" — which is
## why it uses step_position rather than step_velocity: the controller has
## to invent the whole ramp-up/cruise/brake rate profile itself. The player
## never needs this because their stick input already IS a rate command.
func _turn_toward(c: Combatant, desired_dir: Vector3, delta: float) -> void:
	if desired_dir.length() <= 0.01:
		# Nothing commanded — bleed any residual turn rate off so the ship
		# doesn't keep rotating on a stale rate from a previous frame.
		c.turn_rate = move_toward(c.turn_rate, 0.0, flight_profile.ai_turn_max_accel * delta)
		return

	var goal_dir := desired_dir.normalized()
	var angle_off := c.heading.angle_to(goal_dir)
	if angle_off < 0.0001:
		c.turn_rate = move_toward(c.turn_rate, 0.0, flight_profile.ai_turn_max_accel * delta)
		return

	var step := OmegaMotion.step_position(
			angle_off, c.turn_rate, 0.0,
			flight_profile.ai_turn_max_rate, flight_profile.ai_turn_max_accel, delta)
	# step.y is signed toward closing the angle (i.e. negative, since the
	# error runs from angle_off down to 0); only its magnitude matters here
	# because the slerp below already carries the direction.
	c.turn_rate = step.y
	var swept: float = absf(step.y) * delta
	# Rotate the heading by AT MOST `swept` radians toward the goal, as a
	# fraction of the total angle — the same bounded-slerp pattern missile.gd
	# uses for its own turn-rate limiting.
	var new_heading := c.heading.slerp(goal_dir, clampf(swept / angle_off, 0.0, 1.0))
	if new_heading.length() > 0.01:
		c.heading = new_heading.normalized()


## Pilot-level state machine, layered under the squad's orders. A squad that
## has broken drags all its members into RETREAT; individually, a hurt pilot
## may break off on its own while the rest of its squad keeps fighting.
func _update_pilot_state(c: Combatant, sq: Squad, has_target: bool, target_pos: Vector3) -> void:
	# Climbing off the deck. Nothing else applies until it's clear of the
	# ship — no combat, no formation, no squad orders. Throttles up to cruise
	# as it goes, so a takeoff looks like a takeoff.
	if c.state == Combatant.State.LAUNCHING:
		if c.position.y - c.launch_deck_y >= LAUNCH_CLEAR_HEIGHT:
			c.state = Combatant.State.FORMATION
		return

	if sq.state == Squad.State.RETREAT or sq.state == Squad.State.REGROUP:
		c.state = Combatant.State.RETREAT
		return

	if c.state == Combatant.State.RETREAT:
		if c.state_timer > 0.0:
			return
		c.state = Combatant.State.FORMATION

	# Hurt enough to think about leaving — rolled once per crossing, not
	# every frame, via the health check plus the state guard above.
	if c.health <= MAX_HEALTH * RETREAT_HEALTH_FRACTION and randf() < RETREAT_ROLL_CHANCE * 0.02:
		c.state = Combatant.State.RETREAT
		c.state_timer = randf_range(RETREAT_TIME_MIN, RETREAT_TIME_MAX)
		return

	if c.state == Combatant.State.BREAK_OFF:
		if c.state_timer > 0.0:
			return
		c.state = Combatant.State.PURSUE

	# Strike run. Reuses BREAK_OFF to end the pass rather than inventing a
	# separate pull-off state, so a strafing run has the same recognisable
	# rhythm as an attack run on a ship: close, shoot, fly through and past,
	# come back around. Sits above the `not has_target` early-out below
	# because a striker has no air target BY CONSTRUCTION (see
	# _update_combatant) and would otherwise be dropped straight to FORMATION.
	if _is_striking(sq):
		if c.state != Combatant.State.GROUND_ATTACK:
			c.state = Combatant.State.GROUND_ATTACK
		elif c.position.distance_to(_strike_aim_point(sq)) < GROUND_ATTACK_BREAK_RANGE:
			c.state = Combatant.State.BREAK_OFF
			c.state_timer = randf_range(BREAK_OFF_TIME_MIN, BREAK_OFF_TIME_MAX)
		return

	# The squad's ground target died, or the objective ended, while this pilot
	# was mid-run — hand it back to the air war.
	if c.state == Combatant.State.GROUND_ATTACK:
		c.state = Combatant.State.FORMATION

	if not has_target:
		c.state = Combatant.State.FORMATION
		return

	if c.state == Combatant.State.FORMATION:
		c.state = Combatant.State.PURSUE

	# The attack run ends when the attacker gets close — it flies through and
	# past its target rather than sticking to its tail, then turns back for
	# another pass. This is what makes the battle read as dogfighting.
	if c.state == Combatant.State.PURSUE and c.position.distance_to(target_pos) < BREAK_OFF_RANGE:
		c.state = Combatant.State.BREAK_OFF
		c.state_timer = randf_range(BREAK_OFF_TIME_MIN, BREAK_OFF_TIME_MAX)


func _steering_direction(c: Combatant, sq: Squad, own_units: Array, has_target: bool,
		target_pos: Vector3, target_vel: Vector3) -> Vector3:
	match c.state:
		Combatant.State.LAUNCHING:
			# Mostly straight up, leaned toward the squad's objective so the
			# fleet fans out in the right direction as it climbs instead of
			# forming one vertical column above the deck.
			var outbound := Vector3(sq.objective.x - c.position.x, 0.0, sq.objective.z - c.position.z)
			if outbound.length() > 0.01:
				outbound = outbound.normalized()
			return Vector3.UP * LAUNCH_CLIMB_BIAS + outbound

		Combatant.State.RETREAT:
			return sq.rally_point - c.position

		Combatant.State.BREAK_OFF:
			# Keep flying the heading it already had, pulled slightly off-axis
			# and up so the pass separates cleanly instead of driving straight
			# through the target's position.
			return c.heading * 3.0 + Vector3.UP * 0.6 + c.heading.cross(Vector3.UP) * 0.8

		Combatant.State.GROUND_ATTACK:
			if _is_striking(sq):
				return _strike_aim_point(sq) - c.position
			return _formation_or_objective(c, sq, own_units)

		Combatant.State.PURSUE:
			if has_target:
				return _lead_point(c.position, target_pos, target_vel, BOLT_SPEED) - c.position
			return _formation_or_objective(c, sq, own_units)

		_:
			return _formation_or_objective(c, sq, own_units)


## Leaders fly the squad's objective; wingmen hold a station on the leader.
func _formation_or_objective(c: Combatant, sq: Squad, own_units: Array) -> Vector3:
	if sq.leader < 0 or c.squad_slot == 0 or sq.leader >= own_units.size():
		return _advance_direction(c, sq)
	var leader: Combatant = own_units[sq.leader]
	if not leader.alive:
		return _advance_direction(c, sq)
	return _formation_station(leader, c.squad_slot) - c.position


func _advance_direction(c: Combatant, sq: Squad) -> Vector3:
	var horiz := Vector2(c.position.x - dome_center.x, c.position.z - dome_center.z).length()
	if horiz > dome_radius:
		# Head for the dome at this ship's OWN altitude, not dome_center's
		# raw y (which is sea level while this terrain is mountainous).
		return Vector3(sq.objective.x, c.position.y, sq.objective.z) - c.position
	return sq.objective - c.position


## Staggered V/echelon: odd slots to the right, even slots to the left,
## stepping further back and out with each rank.
func _formation_station(leader: Combatant, slot: int) -> Vector3:
	var fwd := leader.heading
	var up_ref := Vector3.FORWARD if absf(fwd.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var right := fwd.cross(up_ref).normalized()
	var up := right.cross(fwd).normalized()
	var side := 1.0 if (slot % 2) == 1 else -1.0
	var rank := float((slot + 1) / 2)
	return leader.position \
			- fwd * (FORMATION_SPACING * rank) \
			+ right * (side * FORMATION_SPACING * rank * 0.85) \
			+ up * (side * 15.0)


## Wingmen throttle up to close on their station and back off when they
## overshoot it — flying at one fixed speed either strings a squad out
## behind its leader or piles it into them.
func _update_throttle(c: Combatant, sq: Squad, own_units: Array, has_target: bool, target_pos: Vector3, delta: float) -> void:
	var wanted := c.base_speed
	if c.state == Combatant.State.LAUNCHING:
		# Accelerating off the deck to cruise, not leaving at full speed.
		wanted = c.base_speed
	elif c.state == Combatant.State.RETREAT:
		wanted = c.base_speed * 1.15
	elif has_target and c.state == Combatant.State.PURSUE:
		wanted = c.base_speed * 1.1
	elif c.squad_slot > 0 and sq.leader >= 0 and sq.leader < own_units.size():
		var leader: Combatant = own_units[sq.leader]
		if leader.alive:
			var gap := c.position.distance_to(_formation_station(leader, c.squad_slot))
			wanted = clampf(leader.speed + gap * FORMATION_SPEED_GAIN, c.base_speed * 0.6, c.base_speed * 1.6)

	_update_ai_afterburner(c, sq, has_target, target_pos, delta)
	if c.afterburner_active:
		wanted += flight_profile.afterburner_speed_bonus

	var step := OmegaMotion.step_velocity(
			c.speed, c.speed_accel, wanted,
			flight_profile.forward_max_accel, flight_profile.forward_accel_time, delta)
	c.speed = step.x
	c.speed_accel = step.y


## The AI's counterpart to the player's B button — same
## `afterburner_speed_bonus` from the same shared ShipFlightProfile, so a
## boosting alien surges exactly as hard as a boosting player.
##
## Lit in BURSTS with a cooldown, never held permanently: a boost that's
## always on isn't a boost, it's just a higher cruise speed, and it would
## also mean every nearby ship permanently smoking (thruster_trails.gd
## reads this flag). A pilot only burns when there's a real reason —
## closing on a target that's still some distance off, or running away —
## which is also exactly when a plume reads as meaningful to the player.
func _update_ai_afterburner(c: Combatant, sq: Squad, has_target: bool, target_pos: Vector3, delta: float) -> void:
	if c.afterburner_active:
		c.afterburner_time -= delta
		if c.afterburner_time <= 0.0:
			c.afterburner_active = false
			c.afterburner_cooldown = randf_range(AB_COOLDOWN_MIN, AB_COOLDOWN_MAX)
		return

	c.afterburner_cooldown -= delta
	if c.afterburner_cooldown > 0.0:
		return

	# Chasing something still far enough away that closing the gap matters,
	# or disengaging outright. Not used inside knife-fight range, where
	# more speed just overshoots the target.
	var wants_burn := c.state == Combatant.State.RETREAT
	if not wants_burn and has_target and c.state == Combatant.State.PURSUE:
		wants_burn = c.position.distance_to(target_pos) > AB_PURSUE_MIN_RANGE
	# Still crossing the map toward the objective with nothing to fight —
	# the natural time to use a burner, and it covers the long opening
	# transit (the fleets start 44km apart, see the Motherships section in
	# CLAUDE.md) where there'd otherwise be no burns and no trails at all.
	if not wants_burn and not has_target and sq != null:
		wants_burn = c.position.distance_to(sq.objective) > AB_ADVANCE_MIN_RANGE
	if not wants_burn:
		return

	c.afterburner_active = true
	c.afterburner_time = randf_range(AB_BURN_MIN, AB_BURN_MAX)


## Pushes away from nearby same-faction ships. Without this, formation and
## objective steering alone let whole squadrons converge onto identical
## points and fly as one solid mass — the "huge packs" problem. Capped at
## MAX_SEPARATION_NEIGHBORS and read from the 3x3 grid neighbourhood so the
## cost stays bounded no matter how dense the local traffic gets.
func _separation(c: Combatant, units: Array, grid: Dictionary) -> Vector3:
	var push := Vector3.ZERO
	var counted := 0
	var cx := int(floor(c.position.x / GRID_CELL_SIZE))
	var cz := int(floor(c.position.z / GRID_CELL_SIZE))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var key := Vector2i(cx + dx, cz + dz)
			if not grid.has(key):
				continue
			for idx in (grid[key] as Array):
				var o: Combatant = units[idx]
				if o == c or not o.alive:
					continue
				var away := c.position - o.position
				var dist := away.length()
				if dist > SEPARATION_RADIUS or dist < 0.01:
					continue
				push += (away / dist) * (1.0 - dist / SEPARATION_RADIUS)
				counted += 1
				if counted >= MAX_SEPARATION_NEIGHBORS:
					return push
	return push


func _retarget_if_needed(c: Combatant, my_index: int, opposing: Array, sq: Squad, can_target_player: bool) -> void:
	var target_invalid := true
	if c.targeting_player:
		target_invalid = not _player
	elif c.target_index >= 0:
		target_invalid = c.target_index >= opposing.size() or not (opposing[c.target_index] as Combatant).alive

	var is_stagger_turn := (my_index % RETARGET_STAGGER) == (_frame_counter % RETARGET_STAGGER)
	if not target_invalid and not is_stagger_turn:
		if c.targeting_player:
			_aliens_on_player += 1
		return

	var previous_target := c.target_index
	var was_targeting_player := c.targeting_player

	var best_index := -1
	var best_dist := INF
	var max_acquisition_sq := MAX_ACQUISITION_RANGE * MAX_ACQUISITION_RANGE
	for j in opposing.size():
		var o: Combatant = opposing[j]
		if not o.alive:
			continue
		var d := c.position.distance_squared_to(o.position)
		if d > max_acquisition_sq:
			continue
		# Squad focus fire: the leader's target is treated as substantially
		# closer than it is, so a squad concentrates rather than fragmenting
		# onto five separate targets the moment it arrives.
		if j == sq.focus_target and not sq.focus_is_player:
			d *= 0.35
		if d < best_dist:
			best_dist = d
			best_index = j

	var use_player := false
	if can_target_player and _player and _aliens_on_player < max_aliens_targeting_player:
		var pd := c.position.distance_squared_to(_player.global_position)
		if pd <= aggro_radius_player * aggro_radius_player and pd * player_target_bias < best_dist:
			use_player = true

	if use_player:
		c.target_index = -1
		c.targeting_player = true
		_aliens_on_player += 1
	elif best_index >= 0:
		c.target_index = best_index
		c.targeting_player = false
	else:
		c.target_index = -1
		c.targeting_player = false

	# Acquiring something NEW costs a reaction beat before it can shoot.
	if (c.targeting_player and not was_targeting_player) or (c.target_index >= 0 and c.target_index != previous_target):
		c.reaction_timer = randf_range(REACTION_TIME_MIN, REACTION_TIME_MAX)


func _random_point_in_dome() -> Vector3:
	var angle := randf() * TAU
	var dist := randf_range(0.0, dome_radius * 0.85)
	var x := dome_center.x + cos(angle) * dist
	var z := dome_center.z + sin(angle) * dist
	var ground: float = _terrain.get_height_at(x, z) if _terrain else 0.0
	# Bounded by ai_objective_ceiling, NOT by dome_ceiling — the contested
	# volume is unbounded upward, but the fleet should still fight at combat
	# altitudes over the city rather than climbing forever.
	var altitude := randf_range(SPAWN_ALT_MIN, ai_objective_ceiling)
	return Vector3(x, ground + altitude, z)


## Reactive pull-up check — true if current or projected (LOOKAHEAD_TIME
## ahead, along the current heading) ground clearance is under
## MIN_GROUND_CLEARANCE. Deliberately simple compared to enemy_ai.gd's
## version (no ground_avoidance_enabled toggle, no engine-health gating —
## nothing here has engine damage) but the same core current+lookahead
## check, since that's the part that actually matters.
func _needs_pull_up(c: Combatant, my_index: int, ground_here: float) -> bool:
	if not _terrain:
		return false

	# A striker is DELIBERATELY descending at a ground target it has chosen,
	# so the cruise avoidance rule cannot apply to it unchanged — and this was
	# a real, measured bug, not a precaution. The LOOKAHEAD probes 3 seconds
	# (~750m at cruise) along the nose, which ANY attack dive trips; a pull-up
	# then overrides steering entirely, so strikers were being levelled out on
	# every frame they tried to aim down and could never get their nose onto a
	# tank. Measured before this exemption: 5952 samples inside firing range
	# across a 300-second match, only 7 of them nose-on, and 0 of 20 tanks
	# destroyed in a full 600-second match.
	#
	# The IMMEDIATE clearance check still applies — that's the one that
	# actually saves a ship's life — just at the lower floor a strafing run
	# needs. The lookahead is what has to go, not ground avoidance itself.
	if c.state == Combatant.State.GROUND_ATTACK:
		return c.position.y - ground_here < GROUND_ATTACK_MIN_CLEARANCE

	# Immediate clearance is checked every frame — this is the one that
	# actually saves a ship's life.
	if c.position.y - ground_here < MIN_GROUND_CLEARANCE:
		return true

	# The lookahead sample is staggered and its result latched on the
	# Combatant — see Combatant.pull_up_latched for why that's accurate.
	if (my_index % LOOKAHEAD_STAGGER) != (_frame_counter % LOOKAHEAD_STAGGER):
		return c.pull_up_latched

	var lookahead_pos := c.position + c.heading * c.speed * LOOKAHEAD_TIME
	var ground_ahead: float = _terrain.get_height_at(lookahead_pos.x, lookahead_pos.z)
	c.pull_up_latched = lookahead_pos.y - ground_ahead < MIN_GROUND_CLEARANCE
	return c.pull_up_latched


func _check_ground_or_building(c: Combatant, ground_here: float) -> bool:
	if _terrain and c.position.y <= ground_here:
		return true
	# Altitude gate — see MAX_BUILDING_HEIGHT. Nothing flying this far above
	# the terrain can be inside a building, so the physics query is skipped.
	if enable_building_collision_check and (c.position.y - ground_here) <= MAX_BUILDING_HEIGHT:
		return CrashEffects.check_building_collision(get_world_3d().direct_space_state, c.position)
	return false


## Puts a ship back on its faction's mothership deck, parked and waiting for
## a launch slot.
func _respawn_combatant(c: Combatant, sq: Squad) -> void:
	var mothership := _mothership_for(c.faction)
	var deck_point: Vector3
	if mothership:
		deck_point = mothership.squad_deck_point(maxi(c.squad_id, 0), _squad_count_for(c.faction))
		# Spread a squad's own members across their slot rather than stacking
		# them on one point.
		deck_point += Vector3(randf_range(-60.0, 60.0), 0.0, randf_range(-60.0, 60.0))
	else:
		# No mothership (shouldn't happen, but the sim must not depend on it)
		# — fall back to the old airborne spawn.
		var ground: float = _terrain.get_height_at(sq.spawn_center.x, sq.spawn_center.z) if _terrain else 0.0
		deck_point = Vector3(sq.spawn_center.x, ground + randf_range(SPAWN_ALT_MIN, SPAWN_ALT_MAX), sq.spawn_center.z)

	c.position = deck_point
	c.launch_deck_y = deck_point.y
	# Horizontal-only heading toward the objective — NOT `(objective -
	# position)` directly, since a ship sitting on a deck 1400m up aiming at
	# a point near sea level would nose straight down off the bow.
	var level_target := Vector3(sq.objective.x, c.position.y, sq.objective.z)
	c.heading = (level_target - c.position).normalized()
	c.wander_point = c.position + c.heading * 500.0
	c.health = MAX_HEALTH
	c.alive = true
	c.speed = c.base_speed
	c.speed_accel = 0.0
	c.turn_rate = 0.0
	c.afterburner_active = false
	c.afterburner_time = 0.0
	c.afterburner_cooldown = randf_range(0.0, AB_COOLDOWN_MAX)
	c.state = Combatant.State.PARKED
	c.state_timer = 0.0
	# Mid-match respawns don't queue behind the whole fleet the way the
	# opening launch does — see _park_faction for the match-start ordering.
	c.launch_delay = randf_range(0.0, LAUNCH_RESPAWN_DELAY_MAX)
	c.target_index = -1
	c.targeting_player = false
	c.reaction_timer = randf_range(REACTION_TIME_MIN, REACTION_TIME_MAX)
	c.fire_cooldown = randf_range(0.4, 1.0)
	c.missile_cooldown = randf_range(MISSILE_COOLDOWN_MIN, MISSILE_COOLDOWN_MAX)
	c.respawn_time_remaining = RESPAWN_DELAY


func _squad_count_for(faction: int) -> int:
	return _friendly_squads.size() if faction == Combatant.Faction.FRIENDLY else _enemy_squads.size()


func _kill_combatant(c: Combatant, index: int, sq: Squad, cause: String) -> void:
	c.alive = false
	c.target_index = -1
	c.targeting_player = false
	c.respawn_time_remaining = RESPAWN_DELAY
	if sq:
		sq.losses += 1

	_spawn_kill_effect(c.position)
	_add_kill_feed_entry("%s %s" % [_combatant_label(c.faction, index), cause])


## Budgeted three ways, because now that the AI actually fights, kills are
## constant and each unbudgeted ShipExplosion is a particle tree plus a
## 6000m-range OmniLight3D: nothing at all beyond explosion_cull_range, no
## light beyond explosion_light_range, and a hard cap on how many can be
## live at once.
func _spawn_kill_effect(at_position: Vector3) -> void:
	_purge_freed(_live_explosions)
	if _live_explosions.size() >= max_concurrent_explosions:
		return

	var player_dist := INF
	if _player:
		player_dist = _player.global_position.distance_to(at_position)
	if player_dist > explosion_cull_range:
		return

	var explosion := SHIP_EXPLOSION.instantiate()
	# Assigned BEFORE add_child — add_child() runs _ready() immediately, and
	# ship_explosion.gd reads this there. See this file's header for the bug
	# that taught us to be careful about this ordering.
	explosion.enable_light = player_dist <= explosion_light_range
	get_tree().current_scene.add_child(explosion)
	explosion.global_position = at_position
	_live_explosions.append(explosion)

	_play_battle_sound(BATTLE_EXPLOSION_SOUND, at_position, explosion_sound_range, 900.0, -30.0)


func _combatant_label(faction: int, index: int) -> String:
	return ("FRIENDLY-%03d" % index) if faction == Combatant.Faction.FRIENDLY else ("HOSTILE-%03d" % index)


func _add_kill_feed_entry(text: String) -> void:
	_kill_feed_entries.append({"text": text, "age": 0.0})
	if _kill_feed_entries.size() > KILL_FEED_MAX_ENTRIES:
		_kill_feed_entries.pop_front()
	_rebuild_kill_feed_text()


func _update_kill_feed(delta: float) -> void:
	var changed := false
	var i := 0
	while i < _kill_feed_entries.size():
		var entry: Dictionary = _kill_feed_entries[i]
		entry["age"] = (entry["age"] as float) + delta
		if (entry["age"] as float) > KILL_FEED_ENTRY_LIFETIME:
			_kill_feed_entries.remove_at(i)
			changed = true
		else:
			i += 1
	if changed:
		_rebuild_kill_feed_text()


func _rebuild_kill_feed_text() -> void:
	var lines: Array = []
	for entry in _kill_feed_entries:
		lines.append(entry["text"])
	kill_feed_text = "\n".join(lines)


# ---------------------------------------------------------------------------
# Firing
# ---------------------------------------------------------------------------

## Shoots only if the target is in range AND roughly ahead (FIRE_CONE) —
## ships used to fire at anything within range regardless of where their nose
## was pointed, which is both unreadable and free damage from impossible
## angles.
func _try_fire(c: Combatant, my_index: int, target_pos: Vector3, target_vel: Vector3) -> void:
	var range_to_target := c.position.distance_to(target_pos)
	if range_to_target > ENGAGE_RANGE:
		return

	var aim := _aim_point(c, target_pos, target_vel, range_to_target)
	var to_aim := aim - c.position
	if to_aim.length() < 0.01 or c.heading.angle_to(to_aim.normalized()) > FIRE_CONE:
		return

	c.fire_cooldown = randf_range(0.35, 0.9)
	if c.targeting_player:
		_fire_at_player(c, aim)
	else:
		_spawn_ambient_bolt(c, my_index, c.faction, aim)


## A strike pilot shooting at its squad's fuel tank. Separate from _try_fire()
## rather than folded into it because almost none of that function applies: a
## tank is stationary, so there is no intercept solution to solve (_lead_point
## would return the target's own position anyway, just after doing the
## quadratic), and it's a ~100m body rather than a fighter, so it gets its own
## longer range and tighter cone.
##
## The pilot's accuracy still displaces the shot exactly as it does against a
## ship — a poor pilot still sprays at range — so the AI's ground kill rate
## naturally carries the same skill spread as its air combat.
func _try_fire_ground(c: Combatant, my_index: int, sq: Squad) -> void:
	if _tank_objective == null or sq.strike_target < 0:
		return
	var aim: Vector3 = _tank_objective.get_tank_aim_point(sq.strike_target)
	var to_aim := aim - c.position
	var range_to_target := to_aim.length()
	if range_to_target > GROUND_ATTACK_FIRE_RANGE or range_to_target < 0.01:
		return
	if c.heading.angle_to(to_aim / range_to_target) > GROUND_ATTACK_FIRE_CONE:
		return

	c.aim_jitter = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
	var shot := aim + c.aim_jitter * ((1.0 - c.accuracy) * range_to_target * AIM_ERROR_SCALE)
	c.fire_cooldown = randf_range(0.35, 0.9)
	_spawn_ambient_bolt(c, my_index, c.faction, shot)


## True intercept solution, displaced by this pilot's own inaccuracy. The
## error grows with range, so a distant AI sprays and a close one is
## genuinely dangerous — the standard way to make combat AI feel skilled
## without being impossible.
func _aim_point(c: Combatant, target_pos: Vector3, target_vel: Vector3, range_to_target: float) -> Vector3:
	var solution := _lead_point(c.position, target_pos, target_vel, BOLT_SPEED)
	c.aim_jitter = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
	return solution + c.aim_jitter * ((1.0 - c.accuracy) * range_to_target * AIM_ERROR_SCALE)


## Where to shoot so a bolt at `bolt_speed` meets a target moving at
## `target_vel`. Thin wrapper around the single shared solver now —
## Gunnery.solve_intercept() (gunnery.gd) — which replaced what used to be
## THREE separately-maintained copies of the identical quadratic (this one,
## target_lock.gd's PIP, and a fourth ad hoc calculation in
## weapon_system.gd). Kept as a wrapper rather than replacing both call
## sites directly, so nothing about the AI's own gunnery call sites had to
## change — only the maths underneath got de-duplicated.
func _lead_point(shooter_pos: Vector3, target_pos: Vector3, target_vel: Vector3, bolt_speed: float) -> Vector3:
	return Gunnery.solve_intercept(shooter_pos, target_pos, target_vel, bolt_speed)


func _fire_at_player(c: Combatant, aim_point: Vector3) -> void:
	var dir := (aim_point - c.position).normalized()
	var up_ref := Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP

	var bolt := LASER_BOLT.instantiate()
	# MUST be set before add_child(): add_child() runs laser_bolt.gd's
	# _ready(), which only resolves its Player/PlayerDamage references when
	# this is already false. Setting it afterwards (as this originally did)
	# left those references null, so alien fire could never damage the player.
	bolt.fired_by_player = false
	get_tree().current_scene.add_child(bolt)
	bolt.global_transform = Transform3D(Basis.looking_at(dir, up_ref), c.position)

	_play_battle_sound(BATTLE_LASER_SOUND, c.position, laser_sound_range, 2400.0, -18.0)


## Rare, longer-range shot — see the missile_cooldown gate in
## _update_combatant(). Reuses missile.gd's target_is_player mode exactly as
## the player's own missile_system.gd uses it for aliens, just aimed the
## other way.
func _fire_missile_at_player(c: Combatant, target_pos: Vector3) -> void:
	if not _player:
		return
	var dir := (target_pos - c.position).normalized()
	var up_ref := Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP

	var missile := MISSILE.instantiate()
	# Same before-add_child rule as _fire_at_player above — missile.gd's
	# _ready() joins the "player_seeking_missiles" group and resolves
	# PlayerDamage/FlareSystem only when target_is_player is already true.
	# Setting these afterwards meant alien missiles did no damage and never
	# triggered missile_alert.gd.
	missile.target_is_player = true
	missile.player = _player
	missile.battle = self
	get_tree().current_scene.add_child(missile)
	missile.global_transform = Transform3D(Basis.looking_at(dir, up_ref), c.position)


func _spawn_ambient_bolt(c: Combatant, shooter_index: int, faction: int, aim_point: Vector3) -> void:
	if _ambient_bolts.size() >= max_ambient_bolts:
		return
	var dir := (aim_point - c.position).normalized()
	_ambient_bolts.append({
		"position": c.position,
		"velocity": dir * BOLT_SPEED,
		"faction": faction,
		"shooter_index": shooter_index,
		"life": BOLT_LIFETIME,
	})

	if randf() < laser_sound_chance:
		_play_battle_sound(BATTLE_LASER_SOUND, c.position, laser_sound_range, 2400.0, -18.0)


# ---------------------------------------------------------------------------
# Bolts
# ---------------------------------------------------------------------------

func _update_ambient_bolts(delta: float) -> void:
	var i := 0
	while i < _ambient_bolts.size():
		var b: Dictionary = _ambient_bolts[i]
		var prev_pos: Vector3 = b["position"]
		var new_pos: Vector3 = prev_pos + (b["velocity"] as Vector3) * delta
		b["position"] = new_pos
		b["life"] = (b["life"] as float) - delta

		var hit := _check_ambient_bolt_hit(b, prev_pos, new_pos)
		var expired: bool = (b["life"] as float) <= 0.0
		var hit_environment := false
		if not hit and not expired:
			hit_environment = _check_bolt_environment(new_pos)

		if hit or expired or hit_environment:
			var last := _ambient_bolts.size() - 1
			_ambient_bolts[i] = _ambient_bolts[last]
			_ambient_bolts.remove_at(last)
		else:
			i += 1


## Ambient bolt misses (terrain/building) despawn silently — no impact
## effect. At hundreds of concurrent bolts, spawning
## CrashEffects.spawn_laser_impact()'s full Node3D+GPUParticles3D tree per
## miss would recreate the exact "hundreds of piling-up effects" problem
## that function was built to avoid, just at far greater scale. The
## travelling bolts themselves are the "lasers everywhere" visual; only
## kills (bounded by population, not bolt volume, and budgeted further in
## _spawn_kill_effect) get an effect.
func _check_bolt_environment(pos: Vector3) -> bool:
	var ground_height := 0.0
	if _terrain:
		ground_height = _terrain.get_height_at(pos.x, pos.z)
		if pos.y <= ground_height:
			return true
	# Same altitude gate as the ships use — see MAX_BUILDING_HEIGHT. Most
	# bolts fly well above the city, so this removes the large majority of
	# the per-bolt physics queries.
	if (pos.y - ground_height) > MAX_BUILDING_HEIGHT:
		return false
	return CrashEffects.check_building_collision(get_world_3d().direct_space_state, pos)


## Iterates the 3x3 grid neighbourhood inline rather than building a
## candidate Array per bolt per frame — at hundreds of bolts that allocation
## was pure garbage churn in the hottest loop in the system.
func _check_ambient_bolt_hit(b: Dictionary, prev_pos: Vector3, new_pos: Vector3) -> bool:
	var owner_faction: int = b["faction"]

	# Ground objective first, matching the ordering laser_bolt.gd/missile.gd
	# already use: a fuel tank is a far larger body than a fighter and sits
	# underneath the fight, so a bolt inside one should detonate there rather
	# than carry on to whatever was flying overhead.
	#
	# The altitude test is an EXACT rejection, not an approximation — tanks
	# grow upward from the terrain and max_tank_top_y is the top of the
	# tallest one's collision volume, so nothing above it can be intersecting.
	# Combat happens thousands of metres up, so this rejects the overwhelming
	# majority of bolts for the price of one float compare, and
	# can_be_damaged_by() then drops every bolt the DEFENDING side fired
	# before the swept test ever runs.
	if _tank_objective and _tank_objective.active \
			and minf(prev_pos.y, new_pos.y) <= _tank_objective.max_tank_top_y \
			and _tank_objective.can_be_damaged_by(owner_faction):
		var tank_idx: int = _tank_objective.check_hit(prev_pos, new_pos)
		if tank_idx >= 0:
			_tank_objective.apply_damage(tank_idx, ai_tank_damage,
					"destroyed by %s" % _combatant_label(owner_faction, b["shooter_index"]))
			return true

	var opposing: Array = _enemies if owner_faction == Combatant.Faction.FRIENDLY else _friendlies
	var grid: Dictionary = _enemy_grid if owner_faction == Combatant.Faction.FRIENDLY else _friendly_grid

	var cx := int(floor(new_pos.x / GRID_CELL_SIZE))
	var cz := int(floor(new_pos.z / GRID_CELL_SIZE))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var key := Vector2i(cx + dx, cz + dz)
			if not grid.has(key):
				continue
			for idx in (grid[key] as Array):
				var o: Combatant = opposing[idx]
				if not o.alive:
					continue
				var closest := _closest_point_on_segment(o.position, prev_pos, new_pos)
				if closest.distance_to(o.position) <= BOLT_HIT_RADIUS:
					var shooter_label := _combatant_label(owner_faction, b["shooter_index"])
					_apply_damage_internal(opposing, idx, BOLT_DAMAGE, "shot down by %s" % shooter_label)
					# Only for hits the target SURVIVED — a kill already spawns
					# the far bigger ShipExplosion at the same spot.
					if o.alive:
						spawn_hit_spark(closest)
					return true
	return false


## Budgeted the same way kill effects are: capped concurrently and only
## spawned near the player. At full battle intensity ships are being hit
## many times a second across the whole map, and an unbudgeted particle
## burst per hit is exactly the kind of thing that quietly eats a VR frame
## budget.
##
## PUBLIC (was `_spawn_hit_spark`) — laser_bolt.gd's own player-fired hits
## now call this directly for a hit the target SURVIVES, matching the exact
## convention already used above for AI-vs-AI ambient-bolt hits. This closed
## a real gap: the player's own gun previously called apply_damage() and
## nothing else, so a hit that didn't kill was visually identical to a miss.
func spawn_hit_spark(at_position: Vector3) -> void:
	if not _player or _player.global_position.distance_to(at_position) > spark_range:
		return
	_purge_freed(_live_sparks)
	if _live_sparks.size() >= max_concurrent_sparks:
		return
	var spark := HIT_SPARK.instantiate()
	get_tree().current_scene.add_child(spark)
	spark.global_position = at_position
	_live_sparks.append(spark)


func _closest_point_on_segment(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return a
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t


func _rebuild_spatial_grids() -> void:
	_friendly_grid.clear()
	_enemy_grid.clear()
	_bucket_faction(_friendlies, _friendly_grid)
	_bucket_faction(_enemies, _enemy_grid)


func _bucket_faction(units: Array, grid: Dictionary) -> void:
	for i in units.size():
		var c: Combatant = units[i]
		if not c.alive:
			continue
		var key := Vector2i(int(floor(c.position.x / GRID_CELL_SIZE)), int(floor(c.position.z / GRID_CELL_SIZE)))
		if not grid.has(key):
			grid[key] = []
		(grid[key] as Array).append(i)


func _apply_damage_internal(units: Array, index: int, amount: float, cause: String) -> void:
	var c: Combatant = units[index]
	if not c.alive:
		return
	c.health -= amount
	if c.health <= 0.0:
		var squads: Array[Squad] = _friendly_squads if c.faction == Combatant.Faction.FRIENDLY else _enemy_squads
		var sq: Squad = squads[c.squad_id] if c.squad_id >= 0 and c.squad_id < squads.size() else null
		_kill_combatant(c, index, sq, cause)
		# This is combat damage specifically (this function is only ever
		# reached through apply_damage()/ambient bolts, never the terrain/
		# building crash path — see _update_combatant()'s own separate
		# _kill_combatant() call for that), so it's always a real kill by
		# the OPPOSING faction. Covers player-fired kills too: the player's
		# own weapons call apply_damage() on the ENEMY array, so the victim
		# being enemy correctly credits FRIENDLY, the same side the
		# player's own presence has always counted toward.
		if not game_over:
			if c.faction == Combatant.Faction.FRIENDLY:
				enemy_score += kill_score_value
			else:
				friendly_score += kill_score_value


# ---------------------------------------------------------------------------
# Battle ambience
# ---------------------------------------------------------------------------

## A short-lived positional sound for something happening out in the battle,
## budgeted against max_battle_sounds and distance-gated so a fight on the
## other side of the city doesn't spend a voice. `cutoff`/`filter_db` drive
## Godot's built-in distance low-pass, which is what makes far-off fighting
## read as muffled rather than merely quiet.
func _play_battle_sound(stream: AudioStream, at_position: Vector3, max_range: float,
		cutoff: float, filter_db: float) -> void:
	if not _player:
		return
	if _player.global_position.distance_to(at_position) > max_range:
		return
	_purge_freed(_live_sounds)
	if _live_sounds.size() >= max_battle_sounds:
		return

	var sound := AudioStreamPlayer3D.new()
	get_tree().current_scene.add_child(sound)
	sound.global_position = at_position
	sound.stream = stream
	sound.max_distance = max_range
	sound.attenuation_filter_cutoff_hz = cutoff
	sound.attenuation_filter_db = filter_db
	sound.play()
	sound.finished.connect(sound.queue_free)
	_live_sounds.append(sound)


func _purge_freed(list: Array) -> void:
	var i := 0
	while i < list.size():
		if is_instance_valid(list[i]):
			i += 1
		else:
			list.remove_at(i)


# ---------------------------------------------------------------------------
# Air Superiority / match state
# ---------------------------------------------------------------------------

func _update_match_timer(delta: float) -> void:
	match_time_remaining = maxf(0.0, match_time_remaining - delta)
	if match_time_remaining <= 0.0 and not game_over:
		_end_game()


## Staggered — see AS_UPDATE_INTERVAL. The accumulated delta is integrated
## on the frames it does run, so the scoring rate is exactly what it would
## have been running every frame.
func _update_air_superiority(delta: float) -> void:
	_as_accumulated_delta += delta
	if (_frame_counter % AS_UPDATE_INTERVAL) != 0:
		return
	var scoring_delta := _as_accumulated_delta
	_as_accumulated_delta = 0.0

	var friendly_in_dome := _count_in_dome(_friendlies)
	if _player and _is_in_dome(_player.global_position):
		friendly_in_dome += 1
	var enemy_in_dome := _count_in_dome(_enemies)

	var net_rate := float(friendly_in_dome - enemy_in_dome) * as_generation_multiplier
	air_superiority = clampf(air_superiority + net_rate * scoring_delta, -100.0, 100.0)

	if absf(air_superiority) >= 100.0 and not game_over:
		_end_game()


## ---------------------------------------------------------------------------
## Conquest — the live scoring system (see the class header's own note)
## ---------------------------------------------------------------------------

## One CaptureZone per tower, letters assigned A-F in the SAME order
## CityGenerator places them (index 0 = world origin = "A", then the ring
## in the order get_mega_tower_positions() itself builds it) — see that
## function's own note on why the ordering has to stay deterministic for
## this to hold.
const ZONE_LETTERS := ["A", "B", "C", "D", "E", "F"]

func _build_capture_zones() -> void:
	capture_zones.clear()
	if not _city or not _city.has_method("get_mega_tower_positions"):
		return
	var positions: Array = _city.get_mega_tower_positions()
	for i in positions.size():
		var zone := CaptureZone.new()
		zone.letter = ZONE_LETTERS[i] if i < ZONE_LETTERS.size() else "?"
		var p: Vector2 = positions[i]
		# Real ground height, not a placeholder — _update_capture_zones()'s
		# presence check is horizontal-only (X/Z) so Y was never load-bearing
		# there, but _build_zone_letters() needs the tower's true base to
		# place the letters correctly up its actual structure.
		var ground: float = _terrain.get_height_at(p.x, p.y) if _terrain else 0.0
		zone.position = Vector3(p.x, ground, p.y)
		capture_zones.append(zone)
	_build_zone_letters()


## Four HUGE, world-scale letter markers per tower — one per cardinal
## side, each rotated to face outward so it reads correctly from an
## aircraft approaching from that direction. Direct instruction: "The
## alphabet letters have to be huge and are visible above the clouds on
## every side of the building. Huge letters." Deliberately real
## world-scale text (NOT the fixed-apparent-size `fixed_size=true`
## technique this project's other far-legible text — friendly_tags.gd,
## target_lock.gd — already uses) since the request is specifically for a
## huge PHYSICAL marker on the tower, not a HUD readout; letters genuinely
## get bigger as you approach, matching a real marking on a real
## structure the size of everything else in this "hellscape."
## TWO rings per tower now — direct follow-up request: "every tower to
## have two sets of letters down, one below the cloud line and one above
## the cloud line, but six thousand meters higher than what it is now."
## The "above" ring is the ORIGINAL single set's own placement formula,
## simply raised another 6000m; the "below" ring is new. Both get the
## full letter+hand treatment via `_build_letter_ring()`, so a tower now
## carries 8 letter faces (2 rings * 4 sides) and 8 clock hands — flying
## either above or below the weather still shows a readable, animated
## capture status, not just the one that happened to clear the clouds.
func _build_zone_letters() -> void:
	var cloud_base_y := 3200.0
	var cloud_top_y := 3800.0
	var world_env := get_node_or_null("../Atmosphere")
	if world_env and "cloud_base_y" in world_env and "cloud_thickness" in world_env:
		cloud_base_y = world_env.cloud_base_y
		cloud_top_y = world_env.cloud_base_y + world_env.cloud_thickness

	for zone in capture_zones:
		zone.letter_labels.clear()
		zone.hand_pivots.clear()
		zone.hand_materials.clear()
		zone.pulse_phase = randf() * TAU  # don't let all six towers pulse in lockstep

		# BELOW the cloud line. Never lower than a sane height up the
		# tower's own base (same reasoning the original set already used)
		# even if that means poking into/above the cloud band on a tower
		# whose base already sits unusually high — this terrain is
		# genuinely mountainous, measured base_y ranged 1162-5291m across
		# the ring, so a handful of towers simply don't have room for a
		# true "below the clouds" position and this is the accepted
		# edge case, same tolerance this project already extends to every
		# other measured placement edge case.
		var letter_y_below: float = minf(zone.position.y + 1500.0, cloud_base_y - 300.0)
		letter_y_below = maxf(letter_y_below, zone.position.y + 300.0)
		_build_letter_ring(zone, letter_y_below)

		# ABOVE the cloud line — the original formula (comfortably above
		# the absolute-altitude cloud band, or a sane height up the
		# tower's own structure, whichever is higher), now raised an
		# additional 6000m per the direct follow-up request.
		var letter_y_above: float = maxf(zone.position.y + 500.0, cloud_top_y + 200.0) + 6000.0
		_build_letter_ring(zone, letter_y_above)


## Builds one full ring of 4 letter faces + 4 clock hands at a given
## world-Y and appends onto whatever's already in the zone's arrays — see
## `_build_zone_letters()`'s own header for why a tower now gets two of
## these instead of one.
func _build_letter_ring(zone: CaptureZone, letter_y: float) -> void:
	var ring_radius := 700.0  # just outside the tower's own 600m base radius
	for side in 4:
		var angle := float(side) * PI * 0.5
		var offset := Vector3(sin(angle), 0.0, cos(angle)) * ring_radius
		var label := Label3D.new()
		label.text = zone.letter
		label.font = ZONE_LETTER_FONT
		label.font_size = 300
		label.pixel_size = 2.0  # real world scale — see _build_zone_letters()'s own header
		label.modulate = ZONE_NEUTRAL_COLOR
		label.outline_size = 24
		label.outline_modulate = Color(0.0, 0.0, 0.0, 0.6)
		label.position = zone.position + offset + Vector3(0.0, letter_y - zone.position.y, 0.0)
		# Face OUTWARD (away from the tower centre) — a Label3D's
		# readable front is its own local +Z by default (same
		# convention flight_hud.gd's non-billboarded labels already
		# documented), so rotate to point +Z along `offset`.
		label.rotation.y = angle
		add_child(label)
		zone.letter_labels.append(label)

		# CLOCK HAND — a small needle on each letter face, direct
		# request: "there needs to be a small hand on the letter that
		# you could see it goes around and slowly starts to capture,
		# like, a clock." Two-node split is required, not cosmetic:
		# the PIVOT is what rotates (around its OWN origin, i.e. the
		# letter's centre), while the visible mesh is a fixed child
		# offset half its length away — rotating the mesh directly
		# would spin it in place around its own midpoint instead of
		# sweeping around the letter like an actual clock hand.
		var hand_pivot := Node3D.new()
		hand_pivot.position = label.position + offset.normalized() * ZONE_HAND_FORWARD_OFFSET
		hand_pivot.rotation.y = angle  # matches the label's own outward facing, set once, never touched again
		add_child(hand_pivot)

		var hand_mesh := MeshInstance3D.new()
		var hand_box := BoxMesh.new()
		hand_box.size = Vector3(ZONE_HAND_WIDTH, ZONE_HAND_LENGTH, ZONE_HAND_THICKNESS)
		hand_mesh.mesh = hand_box
		hand_mesh.position = Vector3(0.0, ZONE_HAND_LENGTH * 0.5, 0.0)
		var hand_mat := StandardMaterial3D.new()
		# Unshaded + emission, same lesson just relearned on the main
		# menu screen: a glowing indicator that has to read clearly
		# regardless of scene lighting (including under the overcast
		# cloud band, or at night) can't be a lit/shaded material.
		hand_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		hand_mat.emission_enabled = true
		hand_mesh.material_override = hand_mat
		hand_pivot.add_child(hand_mesh)

		zone.hand_pivots.append(hand_pivot)
		zone.hand_materials.append(hand_mat)


## Presence-COUNT driven clock-sweep capture — replaced the old flat-rate
## boolean-presence version. Direct follow-up request: "it just instantly
## captures when somebody gets in that field... [instead] the letter needs
## to pulsate and glow with the color that's about to capture, and there
## needs to be a small hand on the letter... like a clock. And then once
## it gets to twelve o'clock, that group is captured, and they hold it."
##
## Whichever faction has MORE ships within `capture_radius` is "dominant"
## and pushes `capture_value` toward its own extreme (+100 friendly, -100
## enemy) via `move_toward()` at a rate from `_capture_sweep_duration()` —
## more of that faction present sweeps faster, down to the
## `capture_min_time` floor. Equal counts (including 0-0) freeze the value
## exactly where it is — the same CONTESTED rule real Conquest uses, now
## driven by a majority count instead of a boolean "is anyone here."
##
## Flipping an enemy-owned zone to friendly (or vice versa) still drains
## back through neutral first, and REVERSING an in-progress capture isn't
## special-cased anywhere: "if the enemy comes in and there's a majority,
## that clears in the opposite direction... back to neutral and then
## clockwise again in the other color" is just what `move_toward()` does
## on its own once the dominant sign flips — see `_update_zone_visual()`
## for how that single scalar becomes the swinging hand and pulsing glow.
func _update_capture_zones(delta: float) -> void:
	for zone in capture_zones:
		var friendly_count := _faction_count_near(_friendlies, zone.position)
		if _player and Vector2(_player.global_position.x - zone.position.x, _player.global_position.z - zone.position.z).length_squared() <= capture_radius * capture_radius:
			friendly_count += 1  # the player counts as one friendly, same convention the retired dome-presence system used
		var enemy_count := _faction_count_near(_enemies, zone.position)

		var dominant_sign := 0
		var dominant_count := 0
		if friendly_count > enemy_count:
			dominant_sign = 1
			dominant_count = friendly_count
		elif enemy_count > friendly_count:
			dominant_sign = -1
			dominant_count = enemy_count
		# else: tied (including 0-0) — frozen, same as real Conquest's CONTESTED rule

		if dominant_sign != 0:
			var rate := 100.0 / _capture_sweep_duration(dominant_count)
			zone.capture_value = move_toward(zone.capture_value, float(dominant_sign) * 100.0, rate * delta)

		_update_zone_visual(zone, dominant_sign, delta)
		_maybe_play_capture_sound(zone)


## `capture_base_time` seconds at n=1, exponentially shorter as n grows,
## asymptoting toward — but never reaching below — `capture_min_time`.
## Direct request: "a capture takes about thirty seconds for one person
## and then exponentially gets faster the more people are in it... for a
## minimum of five seconds. It can never be faster than a five second
## capture." Verified against the formula itself: n=1 -> exactly
## capture_base_time, monotonically decreasing, and the floor is a true
## asymptote (never crossed) rather than a clamp that could read as a
## sudden speed cap.
func _capture_sweep_duration(n: int) -> float:
	var count: float = maxf(1.0, float(n))
	return capture_min_time + (capture_base_time - capture_min_time) * exp(-capture_decay_rate * (count - 1.0))


func _faction_count_near(units: Array, pos: Vector3) -> int:
	var radius_sq := capture_radius * capture_radius
	var count := 0
	for c in units:
		var combatant: Combatant = c
		if combatant.alive and Vector2(combatant.position.x - pos.x, combatant.position.z - pos.z).length_squared() <= radius_sq:
			count += 1
	return count


## Fires the low, droning capture-confirmed cue the instant a zone
## genuinely FLIPS to a new owner — gated on `CaptureZone.last_captured_owner`
## rather than `_update_zone_visual()`'s per-frame `pulsing` flag, so it's a
## true one-shot event rather than something that could re-trigger on
## every frame a zone happens to sit at an extreme. Fires again if the
## same zone is lost and recaptured later in the match — each new arrival
## at an extreme is a genuinely new capture event.
func _maybe_play_capture_sound(zone: CaptureZone) -> void:
	var new_owner := zone.owner_faction()
	if new_owner == CaptureZone.NEUTRAL or new_owner == zone.last_captured_owner:
		return
	zone.last_captured_owner = new_owner

	# Deliberately NOT range-gated like _play_battle_sound()'s budgeted
	# ambience — "everybody on the map can hear it" means this always
	# spawns, positioned at the tower, and leans on unit_size/max_distance
	# (see the export group's own header) to stay audible however far away
	# the listener actually is.
	var sound := AudioStreamPlayer3D.new()
	get_tree().current_scene.add_child(sound)
	sound.global_position = zone.position
	sound.stream = CAPTURE_CONFIRMED_SOUND
	sound.volume_db = capture_sound_volume_db
	sound.unit_size = capture_sound_unit_size
	sound.max_distance = capture_sound_max_distance
	sound.attenuation_filter_cutoff_hz = capture_sound_cutoff_hz
	sound.attenuation_filter_db = -24.0
	sound.play()
	sound.finished.connect(sound.queue_free)


## Drives BOTH the clock hand (angle = abs(capture_value)/100 swept
## clockwise — a full 360 degree turn IS "twelve o'clock," i.e. fully
## captured) and the letter/hand glow. Runs every frame rather than only
## on an ownership change like the old flat-rate version, since the hand
## has to keep sweeping and the pulse has to keep animating even while
## ownership itself hasn't flipped yet.
##
## Pulsing uses the DOMINANT faction's colour — whoever currently has more
## ships present — not necessarily the faction that currently owns the
## zone, so contesting a friendly-owned zone immediately glows the
## enemy's colour before `capture_value` has moved at all: "the letter
## needs to pulsate and glow with the color that's about to capture."
func _update_zone_visual(zone: CaptureZone, dominant_sign: int, delta: float) -> void:
	var sweep_fraction: float = clampf(absf(zone.capture_value) / 100.0, 0.0, 1.0)
	var hand_angle := sweep_fraction * TAU

	# Actively contested/capturing: the dominant push hasn't yet reached
	# its own extreme. Sitting on an extreme with that SAME faction still
	# dominant (or nobody around at all) is false here, and the zone just
	# holds its settled colour — "once it gets to twelve o'clock, that
	# group is captured, and they hold it."
	var pulsing: bool = dominant_sign != 0 and float(dominant_sign) * zone.capture_value < 100.0

	var base_color: Color = ZONE_NEUTRAL_COLOR
	if pulsing:
		base_color = FRIENDLY_COLOR if dominant_sign > 0 else ENEMY_COLOR
	elif zone.capture_value > 0.0:
		base_color = FRIENDLY_COLOR
	elif zone.capture_value < 0.0:
		base_color = ENEMY_COLOR

	var glow_color := base_color
	if pulsing:
		zone.pulse_phase += delta * ZONE_PULSE_SPEED
		var pulse_mul: float = lerpf(ZONE_PULSE_MIN, ZONE_PULSE_MAX, 0.5 + 0.5 * sin(zone.pulse_phase))
		glow_color = Color(base_color.r * pulse_mul, base_color.g * pulse_mul, base_color.b * pulse_mul, 1.0)

	for i in zone.letter_labels.size():
		zone.letter_labels[i].modulate = glow_color
		zone.hand_materials[i].albedo_color = base_color
		zone.hand_materials[i].emission = glow_color
		zone.hand_pivots[i].rotation.z = -hand_angle  # negative = clockwise as viewed facing the letter


## The ticket-bleed half of Conquest, translated to a score race instead of
## a countdown: each zone currently owned by a faction adds
## `zone_score_rate` points/second to that faction's score — the more
## towers you hold, the faster your score climbs, same snowball dynamic
## real Conquest has via ticket bleed. Kill-scoring (kill_score_value per
## kill) is added separately, at the moment of the kill — see
## _apply_damage_internal()'s own note.
func _update_score(delta: float) -> void:
	if game_over:
		return
	for zone in capture_zones:
		match zone.owner_faction():
			CaptureZone.FRIENDLY:
				friendly_score += zone_score_rate * delta
			CaptureZone.ENEMY:
				enemy_score += zone_score_rate * delta

	if friendly_score >= score_target or enemy_score >= score_target:
		_end_game()


## Lump-sum contribution to `air_superiority`, for OBJECTIVES rather than
## dome presence. `_update_air_superiority()` above is a RATE — a continuous
## per-second trickle from who is holding the dome — which had no way to
## express "this thing just happened and it was worth N points". Ground
## objectives (tank_objective.gd) need exactly that.
##
## `amount` is signed the same way the scalar itself is: positive is toward
## FRIENDLY, negative toward ENEMY. `reason` is threaded into the kill feed
## using the same mechanism kill attribution already uses, so a scoring event
## the player didn't personally cause is still visible to them.
func grant_air_superiority(amount: float, reason: String) -> void:
	if game_over:
		return
	air_superiority = clampf(air_superiority + amount, -100.0, 100.0)
	if reason != "":
		_add_kill_feed_entry(reason)
	if absf(air_superiority) >= 100.0:
		_end_game()


## Ends the match immediately with an explicit winner, bypassing both the
## +/-100 threshold and the timer. Used by objectives that are themselves a
## win condition — destroying every fuel tank wins outright rather than
## merely scoring (see tank_objective.gd).
func declare_winner(faction: int, reason: String) -> void:
	if game_over:
		return
	winning_faction = faction
	game_over = true
	simulation_active = false
	if reason != "":
		_add_kill_feed_entry(reason)


func _count_in_dome(units: Array) -> int:
	var count := 0
	for c in units:
		if (c as Combatant).alive and _is_in_dome((c as Combatant).position):
			count += 1
	return count


func _is_in_dome(pos: Vector3) -> bool:
	var horiz := Vector2(pos.x - dome_center.x, pos.z - dome_center.z).length()
	if horiz > dome_radius:
		return false
	# Unbounded column (the default) — see dome_ceiling. This also skips a
	# terrain sample per check, and _count_in_dome() runs this over every
	# living ship on the AS tick, so removing the lid is a small performance
	# win as well as the intended gameplay change.
	if dome_ceiling <= 0.0:
		return true
	var ground: float = _terrain.get_height_at(pos.x, pos.z) if _terrain else 0.0
	return (pos.y - ground) <= dome_ceiling


func _end_game() -> void:
	game_over = true
	if friendly_score > enemy_score:
		winning_faction = Combatant.Faction.FRIENDLY
	elif enemy_score > friendly_score:
		winning_faction = Combatant.Faction.ENEMY
	else:
		winning_faction = -1


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _write_multimesh_transforms() -> void:
	for i in _friendlies.size():
		_friendly_mmi.multimesh.set_instance_transform(i, _combatant_transform(_friendlies[i]))
	for i in _enemies.size():
		_enemy_mmi.multimesh.set_instance_transform(i, _combatant_transform(_enemies[i]))

	_bolt_mmi.multimesh.visible_instance_count = _ambient_bolts.size()
	for i in _ambient_bolts.size():
		var b: Dictionary = _ambient_bolts[i]
		_bolt_mmi.multimesh.set_instance_transform(i, _bolt_transform(b))
		_bolt_mmi.multimesh.set_instance_color(i,
				FRIENDLY_BOLT_COLOR if b["faction"] == Combatant.Faction.FRIENDLY else ENEMY_BOLT_COLOR)


## Dead combatants are scaled to zero rather than removed from the array
## (their slot is reused on respawn) — MultiMesh has no per-instance
## visibility flag other than trimming the buffer's tail via
## visible_instance_count, which can't hide an arbitrary middle index.
func _combatant_transform(c: Combatant) -> Transform3D:
	if not c.alive:
		return Transform3D(Basis().scaled(Vector3.ZERO), c.position)
	var up_ref := Vector3.FORWARD if absf(c.heading.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var basis := Basis.looking_at(c.heading, up_ref).scaled(Vector3(SHIP_SCALE, SHIP_SCALE, SHIP_SCALE))
	return Transform3D(basis, c.position)


## LaserBolt.tscn's own mesh child carries a fixed -90 deg X rotation (its
## CylinderMesh's long axis is Y by default; the bolt travels along -Z),
## baked in here too so the pooled ambient bolts match the player's bolt
## visually.
## Bolt sizes are DISTANCE-COMPENSATED so a tracer never falls below a
## readable size on screen. This is the fix for "with VR, it's hard to see the
## lasers off in the distance", and the problem is arithmetic rather than
## taste.
##
## The bolt mesh is 26m long and 1.1m across. At 3km that subtends 0.021
## degrees of width — against roughly 20.6 pixels per degree per eye at this
## headset's resolution, **0.43 of a pixel**. Sub-pixel geometry cannot render
## reliably: it aliases away, flickers between frames, and mostly just is not
## there. At 6km it is 0.22 of a pixel. So the great majority of a battle
## fought across an 8km dome was firing tracers that physically could not
## appear, which is exactly what was reported.
##
## Rather than inflate every bolt (which would look absurd up close, where
## they are already correct), each bolt is scaled only as much as it needs to
## hold a MINIMUM ANGULAR SIZE — normal below that range, clamped above it.
## This is the same "fixed apparent size" reasoning `target_lock.gd`'s
## visor-anchored readouts and `friendly_tags.gd`'s callsigns already use, and
## for the same reason: past a certain distance, world-space size stops being
## what the player perceives and screen-space size is all that is left.
##
## Length gets its own floor as well as width. With width alone, a distant
## bolt clamps to a few pixels wide while its length keeps shrinking, and it
## degenerates into a square dot rather than a tracer — the streak is what
## reads as gunfire.
func _bolt_transform(b: Dictionary) -> Transform3D:
	var dir: Vector3 = (b["velocity"] as Vector3).normalized()
	var up_ref := Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var mesh_correction := Basis(Vector3.RIGHT, deg_to_rad(-90.0))
	var pos: Vector3 = b["position"]

	var scale_w := 1.0
	var scale_l := 1.0
	if _view_point:
		var d: float = _view_point.global_position.distance_to(pos)
		# Small-angle approximation: at these distances the error is far below
		# a pixel, and it saves a tan() per bolt per frame on up to 320 bolts.
		scale_w = maxf(1.0, (d * _bolt_min_width_rad) / BOLT_MESH_WIDTH)
		scale_l = maxf(1.0, (d * _bolt_min_length_rad) / BOLT_MESH_LENGTH)

	# Muzzle flash: a brief flare in the first fraction of a second of flight,
	# so the moment of firing reads as an event rather than a bolt simply
	# existing. Costs one compare per bolt and no extra draw.
	var age: float = BOLT_LIFETIME - float(b["life"])
	if age < BOLT_FLASH_TIME:
		scale_w *= lerpf(BOLT_FLASH_SCALE, 1.0, age / BOLT_FLASH_TIME)

	# Scale in MESH space (the cylinder's height runs along local Y), so it
	# applies after the orientation rather than skewing it.
	var basis := Basis.looking_at(dir, up_ref) * mesh_correction \
			* Basis().scaled(Vector3(scale_w, scale_l, scale_w))
	return Transform3D(basis, pos)


# ---------------------------------------------------------------------------
# Public API — laser_bolt.gd (player shooting aliens) / target_lock.gd /
# missile_system.gd / missile.gd
# ---------------------------------------------------------------------------

# --- Ship audio keys ------------------------------------------------------
#
# ship_engine_audio.gd holds a stable reference to one specific ship while a
# pooled emitter is attached to it. Combatants live in two separate arrays,
# so a plain index is ambiguous — these pack faction and index into a single
# int so a voice can keep tracking "that ship over there" across frames.

const SHIP_KEY_ENEMY_OFFSET := 100000


func _ship_key(faction: int, index: int) -> int:
	return index + (SHIP_KEY_ENEMY_OFFSET if faction == Combatant.Faction.ENEMY else 0)


func _ship_for_key(key: int) -> Combatant:
	if key < 0:
		return null
	if key >= SHIP_KEY_ENEMY_OFFSET:
		var ei := key - SHIP_KEY_ENEMY_OFFSET
		return _enemies[ei] if ei < _enemies.size() else null
	return _friendlies[key] if key < _friendlies.size() else null


## Keys of the living ships nearest to `from` within `radius`, nearest
## first, capped at `max_count`. Called on a slow timer by
## ship_engine_audio.gd (a few times a second, not per frame) — a linear
## scan of both factions at that rate is nothing.
func get_ships_near(from: Vector3, radius: float, max_count: int) -> Array:
	var radius_sq := radius * radius
	var candidates: Array = []
	for i in _friendlies.size():
		var c: Combatant = _friendlies[i]
		if not c.alive:
			continue
		var d := from.distance_squared_to(c.position)
		if d <= radius_sq:
			candidates.append([d, i])
	for i in _enemies.size():
		var c: Combatant = _enemies[i]
		if not c.alive:
			continue
		var d := from.distance_squared_to(c.position)
		if d <= radius_sq:
			candidates.append([d, i + SHIP_KEY_ENEMY_OFFSET])

	candidates.sort_custom(func(a, b): return a[0] < b[0])

	var out: Array = []
	for entry in candidates:
		if out.size() >= max_count:
			break
		out.append(entry[1])
	return out


func is_ship_alive_by_key(key: int) -> bool:
	var c := _ship_for_key(key)
	return c != null and c.alive


func get_ship_position_by_key(key: int) -> Vector3:
	var c := _ship_for_key(key)
	return c.position if c else Vector3.ZERO


## Display name for a ship key ("FRIENDLY-042" / "HOSTILE-007"), using the
## same `_combatant_label()` the kill feed and target_lock.gd already use —
## exposed rather than reformatted at the call site so callsigns can never
## drift between the kill feed and friendly_tags.gd's in-world name tags.
func get_ship_label_by_key(key: int) -> String:
	if key >= SHIP_KEY_ENEMY_OFFSET:
		return _combatant_label(Combatant.Faction.ENEMY, key - SHIP_KEY_ENEMY_OFFSET)
	return _combatant_label(Combatant.Faction.FRIENDLY, key)


## True if `key` belongs to the friendly fleet. The packing is an
## implementation detail (see SHIP_KEY_ENEMY_OFFSET), so callers that only
## care about one faction shouldn't be comparing against it themselves.
func is_friendly_key(key: int) -> bool:
	return key < SHIP_KEY_ENEMY_OFFSET


func get_ship_velocity_by_key(key: int) -> Vector3:
	var c := _ship_for_key(key)
	return c.heading * c.speed if c else Vector3.ZERO


## Whether this ship's afterburner is currently lit — read by
## thruster_trails.gd to decide who gets a smoke plume, matching the
## player's own afterburner-only trail.
func is_ship_afterburning_by_key(key: int) -> bool:
	var c := _ship_for_key(key)
	return c != null and c.alive and c.afterburner_active


## Fraction of max health remaining for EITHER faction's ship, by key — read
## by damage_smoke.gd to decide who is hurt enough to trail smoke. Defaults
## to 1.0 (i.e. "not damaged") for a dead or nonexistent key, so a bad key
## can never be mistaken for a heavily damaged ship and claim an emitter.
func get_ship_health_fraction_by_key(key: int) -> float:
	var c := _ship_for_key(key)
	return clampf(c.health / MAX_HEALTH, 0.0, 1.0) if c and c.alive else 1.0


## Where the player starts the match and respawns: parked on the friendly
## mothership's deck with the rest of the fleet. Returned as a world
## position so game_flow.gd / crash_handler.gd don't have to re-derive the
## mothership's altitude or deck height themselves — this is the single
## source of truth, replacing the hand-synced (-4000, 0) coordinate that
## previously lived in three separate exported values.
func get_player_spawn_position() -> Vector3:
	if duel_mode:
		# The mothership deck now sits at a corner of the whole map, far
		# further from the other mothership than the small-arena request is
		# asking for. Spawn directly at dome_center instead, matching where
		# _start_duel() places the one active opponent relative to.
		var ground: float = _terrain.get_height_at(dome_center.x, dome_center.z) if _terrain else 0.0
		return Vector3(dome_center.x, ground + 900.0, dome_center.z)
	if _friendly_mothership:
		var deck: Vector3 = _friendly_mothership.random_deck_point()
		return deck + Vector3(0.0, 12.0, 0.0)  # sat on the deck, not embedded in it
	var ground: float = _terrain.get_height_at(_friendly_spawn_center.x, _friendly_spawn_center.z) if _terrain else 0.0
	return Vector3(_friendly_spawn_center.x, ground + 102.0, _friendly_spawn_center.z)


func get_nearest_alive_alien(from_position: Vector3) -> int:
	var best_index := -1
	var best_dist := INF
	for i in _enemies.size():
		var c: Combatant = _enemies[i]
		if not c.alive:
			continue
		var d := from_position.distance_squared_to(c.position)
		if d < best_dist:
			best_dist = d
			best_index = i
	return best_index


## All living aliens' indices, nearest-to-farthest from `from_position` —
## used by target_lock.gd's Y-button cycling (each press steps to the next
## entry in this order, wrapping around).
func get_alive_aliens_sorted_by_distance(from_position: Vector3) -> Array:
	var alive_indices: Array = []
	for i in _enemies.size():
		if _enemies[i].alive:
			alive_indices.append(i)
	alive_indices.sort_custom(func(a, b):
		return from_position.distance_squared_to(_enemies[a].position) < from_position.distance_squared_to(_enemies[b].position))
	return alive_indices


## Nearest living alien within `max_angle` (radians) of `direction` from
## `origin`, and within `max_range` — used by missile_system.gd's
## hold-trigger lock to pick what the player is actually pointing at, as
## opposed to get_nearest_alive_alien()'s pure nearest-by-distance (used for
## gun hits and target_lock.gd's Y-button cycling).
func get_nearest_alive_alien_in_cone(origin: Vector3, direction: Vector3, max_angle: float, max_range: float) -> int:
	var dir := direction.normalized()
	var max_range_sq := max_range * max_range
	var best_index := -1
	var best_dist := INF
	for i in _enemies.size():
		var c: Combatant = _enemies[i]
		if not c.alive:
			continue
		var to_target := c.position - origin
		var dist_sq := to_target.length_squared()
		if dist_sq < 0.0001 or dist_sq > max_range_sq:
			continue
		if to_target.normalized().angle_to(dir) > max_angle:
			continue
		if dist_sq < best_dist:
			best_dist = dist_sq
			best_index = i
	return best_index


func is_alive(index: int) -> bool:
	return index >= 0 and index < _enemies.size() and _enemies[index].alive


func get_alien_position(index: int) -> Vector3:
	if index < 0 or index >= _enemies.size():
		return Vector3.ZERO
	return _enemies[index].position


## Fraction of MAX_HEALTH remaining, 0..1 — read by target_lock.gd's info
## readout so a landed hit shows real progress instead of the player having
## to guess how many more shots a target needs. Out-of-range or dead reads as
## 0.0 rather than erroring, matching this file's other index-guarded getters.
func get_health_fraction(index: int) -> float:
	if index < 0 or index >= _enemies.size():
		return 0.0
	return clampf(_enemies[index].health / MAX_HEALTH, 0.0, 1.0)


func get_velocity(index: int) -> Vector3:
	if index < 0 or index >= _enemies.size():
		return Vector3.ZERO
	var c: Combatant = _enemies[index]
	return c.heading * c.speed


func apply_damage(index: int, amount: float, cause: String = "destroyed by PLAYER") -> void:
	if index < 0 or index >= _enemies.size():
		return
	_apply_damage_internal(_enemies, index, amount, cause)


## Spawns a flare at the given alien's current position — called by
## missile.gd the first time an incoming player missile enters the flare
## countermeasure window, since aliens have no button to press themselves
## (flare_system.gd is the equivalent player-side control). Always spawns
## (no limited flare supply was specified) — the missile itself owns the
## redirect-chance roll.
func try_deploy_alien_flare(index: int) -> Node3D:
	if index < 0 or index >= _enemies.size() or not _enemies[index].alive:
		return null
	var flare := FLARE.instantiate()
	get_tree().current_scene.add_child(flare)
	flare.global_position = _enemies[index].position
	return flare
