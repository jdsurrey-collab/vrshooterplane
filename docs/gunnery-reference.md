# Gunnery Reference: Gun Convergence & Harmonization

Real reference data backing the crosshair/convergence system in
`scripts/weapon_system.gd`, in the same spirit as
`docs/flight-physics-reference.md`.

## The problem

`GunMountLeft` and `GunMountRight` sit on either side of the cockpit
centerline (±0.4 m). If both guns simply fired straight ahead, their two
lines of fire would run parallel forever and never meet — split fire,
neither stream landing a concentrated hit. Real fixed-gun fighters don't do
this: the guns are angled slightly inward ("toed in") so the two lines of
fire cross at a chosen distance ahead of the aircraft. This is called **gun
harmonization**, and the crossing point is the **convergence point**.

## Real convergence distances (WWII fighters)

Sourced from historical gunnery doctrine (see links below):

| Aircraft / doctrine | Convergence distance |
|---|---|
| RAF fighters, standard by the Battle of Britain | 250 yards (≈229 m) |
| General WWII fighter range | 200–600 yards, tuned to armament and doctrine |
| P-47 Thunderbolt (one scheme) | ~1,100 ft (≈340 m) |
| Erich Hartmann's Bf 109 (close-range preference) | 50 m |

Two harmonization philosophies existed: **pattern harmonization** (spread
fire to raise hit probability) vs. **point harmonization** (concentrate fire
for maximum damage per hit). Point harmonization is generally judged to have
given better results, and it's the model this implementation follows — both
guns aimed at a single point, not spread into a pattern.

Fire stays reasonably effective past the convergence point too: since the
lines of fire cross and then diverge again, a target flying through the
convergence distance ±roughly the same distance again still catches fire
from both guns (e.g. RAF 250-yard convergence stayed effective out to ~500
yards).

`convergence_distance` in `weapon_system.gd` defaults to **229 m** (250
yards) — the RAF standard.

## Implementation

`_setup_convergence()` in `weapon_system.gd`, called once from `_ready()`:

1. Computes a single world-space target point straight ahead of the ship's
   centerline, `convergence_distance` meters out, at the midpoint height of
   the two gun mounts.
2. Calls `look_at()` on both `GunMountLeft` and `GunMountRight`, aiming each
   at that same point. `look_at()` works from actual global positions, so it
   correctly derives the toe-in angle regardless of the mounts' starting
   orientation or any parent-chain rotation quirks (the ship's own 180°
   flip, etc.) — no manual trigonometry needed.
3. Moves the `Crosshair` node (a small green sphere on `Ship`) to that exact
   point.

Because gun toe-in and crosshair placement both derive from the same
`convergence_distance` value and the same computed target point, they can
never drift out of sync with each other — change the one export, both
update together next time `_ready()` runs.

The crosshair itself is a plain 3D object fixed in the ship's local space
(not a camera-billboarded HUD element) — like a real gunsight reticle
etched onto the canopy glass, it will show correct parallax as you move
your head within the cockpit, rather than always snapping to face you.

## Lead / PIP (implemented — `scripts/target_lock.gd`)

A **PIP (predicted impact point)** — sometimes called a "pipper" — is the
reticle a lead-computing gunsight shows for a *moving* target: instead of a
fixed point at convergence distance, it's computed each frame from target
position, target velocity, your own gun position, and bolt travel speed, so
it shows where to aim to actually hit something that's maneuvering.

Built as part of the Y-button target-lock system: `_solve_intercept()`
solves the real firing-solution quadratic, not a visual approximation —
given a bolt fired *now* travels at a fixed speed, find the smallest
positive time `t` where the bolt's position would coincide with the
target's projected position:

```
|target_pos + target_vel*t - shooter_pos| = bullet_speed * t
```

Expanding and collecting terms gives a standard quadratic `a*t² + b*t + c = 0`
in `t`, solved directly (falling back to the target's current position if
there's no valid positive-time root — e.g. the target is outrunning the
bolt). `target_vel` comes from `enemy_ai.gd`'s `get_velocity()`, which is
exact rather than estimated: that AI is purely kinematic (always moving at
`cruise_speed` along its current facing, no separate velocity state to
drift out of sync), so there's no smoothing/estimation error in the input
to begin with.

The PIP is a small billboarded ring (`TorusMesh`) placed at the computed
world-space point — billboarded (unlike the static convergence crosshair)
because a flat ring needs to face the camera to read as a clean circle
rather than an ellipse or a line depending on viewing angle.

## Sources

- [Gun harmonisation — Wikipedia](https://en.wikipedia.org/wiki/Gun_harmonisation)
- [R.A.F. main fighters gun convergence — WW2Aircraft.net forum discussion citing squadron doctrine](https://ww2aircraft.net/forum/threads/r-a-f-main-fighters-gun-convergence.33987/)
- [Convergence of fighter guns — WW2Aircraft.net forum discussion](https://ww2aircraft.net/forum/threads/convergence-of-fighter-guns.2858/)
