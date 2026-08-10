# Objectives Roadmap — beyond pure dogfighting

**Status: brainstorm, not a spec.** Nothing here is implemented. This
document exists to collect and organize the vision described in one
conversation so it isn't lost, and to sketch how each idea could hook into
the systems that already exist, before any of it becomes a real plan. Treat
every number in here as a placeholder, not a decision.

## The stated vision (source material)

Preserved close to verbatim, since the exact framing matters:

- Eventually, a **ground target system** — two or three destructible
  "batteries" that spawn in the city, worth extra points to destroy.
- The goal is **not everyone wants pure dogfighting** — the match should
  support multiple different kinds of things happening at once, not just
  ship-vs-ship combat.
- **Different ship types that do different things** — e.g. a bomber-style
  ship that has to fly through the city to hit something, rather than just
  another dogfighter.
- Possibly an **escort system up in the atmosphere** — protecting
  something or someone through contested airspace.
- **All of this lives on the same map**, inside the same 10-minute match.
- **Everything still rolls up into one score**: first team to 100% [Air
  Superiority] wins. New objective types don't create a second currency —
  they contribute to the *same* percentage, credited to whichever team (or
  player) actually landed the hit.
- Possibly **faction-colored batteries** (e.g. a purple one and a red one)
  — destroying the *enemy's* battery is what pays out, at a meaningful
  lump sum (the example given was "ten points, ten percent additional").

## Why `ground_flak.gd` is a plausible seed, not a coincidence

The cosmetic anti-aircraft system just added (`scripts/ground_flak.gd`,
see `CLAUDE.md`'s "Ground flak" section) already establishes real
launch-point infrastructure: `city_generator.gd`'s `landmark_rooftops`
array is a genuine list of real tower positions across the city, not
arbitrary points. A real destructible battery objective could plausibly
**reuse those exact same rooftop positions** as spawn points — the flak
system already firing cosmetically from a tower is a very small step from
"that tower has a real, damageable structure at its base, and the flak
stops when it dies." Worth remembering when this becomes a real plan: the
visual language (blue/purple tracer fire, SAM launches) is already built
and could double as "this specific battery is alive and shooting."

## Brainstormed objective concepts

Five distinct ideas, each fleshed out enough to evaluate, not to build.

### 1. Destructible AA batteries (the one explicitly described)

Two or three per side (or per city — see the "neutral vs. faction-owned"
open question below), each a real object with HP, sitting at a fixed
landmark-rooftop-style location. Destroying an enemy-owned battery pays a
lump percentage into `air_superiority` for the credited team, per the
"ten percent additional" framing. Likely needs:

- A visible, aimable target model (distinct from the cosmetic flak
  towers, or literally *the same* towers upgraded with a health pool).
  and a kill effect (`CrashEffects`/`ShipExplosion`-style — both already
  exist and are reusable).
- Attribution — whoever's laser/missile/bomb lands the kill needs to be
  known, the same "who gets credit" plumbing the kill feed's `cause`
  string already threads through `apply_damage()`.
- A decision on whether **AI can also target/destroy batteries**, or
  whether this is player-only content (see open questions).

### 2. Bombing runs (a new ship role)

A slower, tougher, bomber-class ship (or a role the player's existing ship
can switch into?) that has to survive flying low through contested city
airspace — weaving between buildings, under fire — to drop ordnance on a
specific ground target (an enemy battery, or a separate "supply depot"
structure). Bigger one-time payout than routine combat, and inherently
risky/vulnerable, which is what makes it a distinct playstyle from
dogfighting rather than combat with extra steps. Likely needs:

- A new `ShipFlightProfile` variant (this project's existing shared-
  profile pattern already supports this cleanly — see
  `Assets/ShipProfiles/standard_fighter.tres` and
  `docs/omega-flight-model.md`): lower top speed, higher HP/mass, maybe
  reduced maneuverability, matching a bomber's real-world tradeoffs.
- A new weapon type (a straight-down or lead-computed bomb-drop, distinct
  from the existing gun/missile pair) — real gravity-drop ballistics would
  be a genuinely new mechanic in this project (current weapons are all
  flat-trajectory or self-propelled).
- City geometry is already dense enough (`city_generator.gd`'s ~1400
  buildings) that "flying low through the city" is already a real
  navigational challenge, not something that needs new level design.

### 3. Escort missions (the atmosphere idea)

A large, slow, high-value AI-controlled asset (cargo hauler, VIP dropship,
recon platform) flies a set path through contested airspace on a timer.
The escorting side earns a slow ongoing score trickle while it survives;
the opposing side earns a bigger lump-sum payout for shooting it down —
mirroring the battery's "big payout for a hard kill" shape, but moving and
defended instead of static and undefended. Likely needs:

- A simple scripted-waypoint mover rather than full `Combatant`/`Squad`
  AI (it's not a combatant, it doesn't fight back) — much lighter weight
  than the existing 200-ship battle simulation.
- A HUD callout (this project already has strong precedent for "tell the
  player when something with a countdown/timer matters" — `missile_alert.gd`,
  the kill feed, the AS/timer readout on `battle_hud.gd`).
- A decision on cadence: one escort convoy at a time, on a timer, or
  several simultaneously? Simpler to start with one at a time.

### 4. Recon / contested zones (a lighter-weight variant)

Smaller sub-zones scattered around the dome (not the whole city, the way
the existing dome-presence scoring already works) that trickle score to
whichever team currently holds them — the existing `air_superiority`
dome-presence math already does almost exactly this at the scale of the
*entire* dome; this would be the same idea at 3-5x the granularity.
Cheapest of these five ideas to prototype, since it's mostly re-parameterizing
logic that already exists in `faction_battle.gd` rather than building
anything structurally new.

### 5. "Hunt the ace" (a flavor objective, no new assets needed)

One AI squadron leader per side is quietly flagged as a named "ace,"
worth a bonus percentage if killed — no new models, no new systems, just
a `Combatant` flag and a kill-feed line that reads differently
("HOSTILE ACE 'callsign' shot down by..."). Cheapest possible way to add
texture to a match without new art or mechanics; worth keeping in the back
pocket even if the bigger ideas above take priority.

## How this could fit the existing scoring model

Today, `air_superiority` (`faction_battle.gd`) is a single continuous
scalar driven purely by dome presence: `(friendly_in_dome -
enemy_in_dome) * delta * as_generation_multiplier`, clamped to [-100, 100].
The stated vision is explicit that new objectives should feed the *same*
scalar, not a second currency. Two kinds of contribution would need to
coexist:

- **Rate contributions** (existing) — dome presence, and possibly the
  escort-mission "ongoing trickle while it survives" idea, both apply a
  continuous per-second delta.
- **Lump-sum contributions** (new) — a battery or bomber-target kill, an
  escort-asset kill, an ace kill, all apply a one-time jump the instant
  the kill lands, the way `as_generation_multiplier`'s continuous math
  doesn't currently have a mechanism for at all.

Both are compatible with the same scalar, but the *lump-sum* path is new
plumbing: something like `FactionBattle.grant_air_superiority(faction,
amount, reason)`, called from wherever a battery/bomber-target/escort-asset
death is detected, mirroring the kill feed's existing `cause`-string
attribution pattern rather than inventing a new one.

## Open questions (for a real design pass, not answered here)

- **Battery ownership** — neutral (either side can destroy either battery
  for credit) or faction-owned (only the *enemy's* battery pays out,
  matching the "purple battery and red battery" framing)? The stated
  vision leans toward faction-owned, but this needs an explicit decision
  before any implementation.
- **Can the AI fleet damage/destroy objectives too**, or are these
  player-only targets? If AI can, the existing `Combatant` targeting
  system would need a new target type beyond "opposing ship" and "the
  player" (its only two today).
- **Bomber class: player-flyable, AI-only, or both?** A player-flyable
  bomber changes VR ergonomics (different cockpit? same cockpit, different
  flight profile?) in a way an AI-only bomber wouldn't need to solve at
  all.
- **Escort asset: does it need a genuine third "neutral" faction**, or
  does one side spawn it and the other tries to kill it (two-faction, just
  a new kind of "unit")? The latter is much less new architecture.
- **Pacing** — how many of these run concurrently in one 10-minute match?
  Running all five at once risks the same "too much happening, unreadable"
  problem the original 200v200 mass-battle AI had before the squad rebuild
  (see `CLAUDE.md`'s Faction Battle section) — that rebuild's core lesson
  (separation, focus fire, readable states) likely generalizes here too:
  fewer, clearer concurrent objectives beat many overlapping ones.

## Suggested next step, when this becomes real work

Pick **one** of the five ideas — the destructible-battery concept is the
most natural first pick, both because it was the most concretely described
and because `ground_flak.gd`'s rooftop infrastructure already exists to
build on — and take it through a real plan-mode design pass (the same way
the original Faction Battle feature did, per `CLAUDE.md`) before writing
any code. Trying to design all five at once is very likely to produce the
same "too much happening" problem described above, just at the design
stage instead of the gameplay stage.
