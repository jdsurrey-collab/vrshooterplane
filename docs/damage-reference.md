# Damage Reference: Hit Zones & Component Health

Design backing the enemy ship's damage system (`scripts/enemy_ai.gd`'s health
pools + `scripts/laser_bolt.gd`'s hit-zone detection), grounded in how
modern flight/space sims actually model combat damage — not an arbitrary
"hull HP bar."

## What real sims do

**DCS World** models damage per internal system, not one shared pool: hits
are calculated against specific components — oil/air/hydraulic/cooling
systems, the engine and propeller installation, flight controls, and
airframe structure — as the projectile passes through the aircraft.
Critically, failure is a *process*, not a switch: "a burning fuel leak gives
off dense white/grey smoke, and depending on the size and type of leak, it
can eventually result in a fire." Damage escalates visually and functionally
over time rather than jumping straight to destroyed.

**Star Citizen** (this project's own reference point for the flight model —
see `docs/flight-physics-reference.md`) gives every major component — power
plant, engines, shields, coolers — its **own independent health pool**,
not a shared hull bar. Systems "degrade, overload, or fail under stress" as
they take damage rather than working at 100% until they hit zero. A power
plant reaching 0% can trigger a destruct countdown. Ballistic weapons
penetrate the hull to damage internal components directly — hitting the
outside of the ship doesn't just deplete one generic pool, *where* you hit
determines *what* breaks.

## Design that follows from this

Three independent health pools, matching the three zones asked for, instead
of one hull bar with hit-location flavor text:

| Zone | Represents | Max HP | Failure at 0 |
|---|---|---|---|
| Cockpit | Pilot/avionics | 40 | Immediate destruction (pilot killed) |
| Engine | Powerplant/thrust | 60 | Engine cuts out — no instant kill, see below |
| Hull | Structure | 100 | Immediate destruction (structural failure) |

Cockpit and hull both fail *instantly* at 0 — a real pilot hit or a
structural failure doesn't give you a grace period, and this gives point
defense/precision fire (aim for the small cockpit) a real payoff versus
just spraying the hull, the same tradeoff DCS's fuel-tank/cockpit
"golden BB" hits represent.

**Engine failure is the one built to be a process, not a switch** —
matching DCS's smoke-then-fire escalation and Star Citizen's "degrade,
overload, or fail" language:

- Above 30% engine health: cruise speed and turn rate scale down linearly
  with remaining health (down to a 35%/40% floor) — a wounded engine flies
  worse, it doesn't fly at full power until it doesn't.
- Below 30%: ground-avoidance (`enemy_ai.gd`'s reactive pull-up, built
  earlier this session) turns off — a badly damaged aircraft struggling to
  make power can't reliably out-climb terrain either. This is the exact
  hook that system was built with: "a damaged/failing ship should fly with
  `ground_avoidance_enabled = false` so it can actually crash from bad
  flying."
- At 0%: the engine cuts out entirely. No instant-death code path — instead
  the ship glides forward at a fixed low speed while losing altitude, a
  dead-stick descent, until it meets the terrain through the **existing**
  ground-collision check. Engine death doesn't need its own destruction
  logic; it naturally resolves through the crash system already built.

Visual damage is per-zone and progressive, not a single "now it's on fire"
flag: light smoke begins under ~66% zone health, heavy smoke under ~33%,
sourced from a position on the ship approximating that zone, escalating as
that specific system keeps taking hits — the DCS "smoke now, maybe fire
later" idea, simplified to what's buildable with this project's existing
particle-effect approach (see `docs/flight-physics-reference.md`'s and
`crash_effects.gd`'s established patterns) rather than true fluid/fire
simulation.

## Hit zones on the ship

`ship1.obj`'s measured local bounds (see `scripts/city_generator.gd`-era
AABB-measurement technique, applied the same way here): roughly 7.15m long
along local Z at the enemy's actual (2x) scale. `enemy_ai.gd` moves along
its local **-Z** (`Basis.looking_at` aligns -Z with the wander target), so
the nose is the more-negative-Z end. Zones are the thirds of that length:

- **Cockpit**: front third (most negative Z)
- **Hull**: middle third
- **Engine**: rear third (most positive Z)

Flagged the same way the ship's actual forward orientation was flagged
earlier this session: derived from the movement code's convention, not
confirmed by eye in the headset — the boundary constants are simple enough
to flip/adjust live if it turns out backwards.

## Scope

Explicitly enemy-only for now, per how this was asked for — the player's
own ship has no equivalent health pool, and the enemy doesn't shoot back
yet either, so there's nothing to damage the player's ship *with* even if
it had one. A natural next step once the enemy can return fire.
