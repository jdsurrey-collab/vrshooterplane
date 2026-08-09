# Flight Physics Reference

Real, sourced physical constants and equations backing the tunable values in
`scripts/flight_controller.gd`, so future tuning departs from a known
baseline instead of arbitrary guesses. Where the game intentionally departs
from realism (arcade-scale accelerations, a 100x-scaled world), that's noted
explicitly rather than left ambiguous.

## 1. Gravity

**Standard gravity:** g₀ = 9.80665 m/s² — the internationally defined
constant (CGPM, 1901), used throughout NASA technical references and by
NIST.

`flight_controller.gd` currently uses `gravity_accel = 800.0 m/s²` (only
applied when `gravity_compensator_active = false`, per the gravity
compensator standard — see the header comment in that file). This project's
world is deliberately scaled 100x (`world_size`/`height_scale` in
`Town.tscn`) so it *feels* huge relative to a normal-scale player and ship —
see `CLAUDE.md`. A literal 100x-scaled real gravity would be
`9.80665 * 100 = 980.665 m/s²`. The current `800.0` is in the same order of
magnitude but isn't an exact match — worth revisiting if/when the "ship
shutdown → falls" path actually gets exercised and the fall rate needs to
feel physically grounded rather than just "roughly right."

## 2. Atmosphere & the drag equation

**ISA sea-level air density:** ρ₀ = 1.225 kg/m³ — International Standard
Atmosphere, sourced from NASA Glenn Research Center's Earth Atmosphere
Model. `air_density` in `flight_controller.gd` is set to exactly this value.

**Equation of state** (NASA Glenn Earth Atmosphere Model): density is
derived from pressure and temperature via the ideal gas law,
`ρ = p / (R × T)`; NASA Glenn's model splits the atmosphere into three
curve-fit zones (troposphere: 0–11 km / 0–36,152 ft, where temperature
decreases linearly and pressure decreases exponentially; lower and upper
stratosphere above that).

**The drag equation** (NASA Glenn Beginner's Guide to Aerodynamics):

```
D = Cd * 0.5 * ρ * V² * A
```

where `Cd` is a dimensionless, experimentally-derived shape coefficient
(usually measured in a wind tunnel), `ρ` is air density, `V` is airspeed,
and `A` is a reference area (frontal area for a body like a fighter
cockpit).

**Reference Cd values** (NASA Glenn, same source):

| Shape | Cd |
|---|---|
| Flat plate | 1.28 |
| Wedge (blunt face forward) | 1.14 |
| Sphere | 0.07 – 0.5 (depends on Reynolds number) |
| Bullet | 0.295 |
| Typical airfoil | 0.045 |

`flight_controller.gd` doesn't expose `Cd`, mass, and frontal area
separately — it folds them into one tunable, `drag_coefficient`, equal to
`Cd * A / (2 * mass)`. Current default: `0.00015`.

## 3. Worked example: what `drag_coefficient` implies

Assume a small single-seat fighter cross-section, `A ≈ 6 m²`, and a mass
`m ≈ 8,000 kg` (roughly F-16-class):

- **Slick/streamlined** (`Cd ≈ 0.045`, NASA's "typical airfoil" figure):
  `drag_coefficient = 0.045 * 6 / 16000 ≈ 1.69e-5`. At 300 m/s that's
  `1.225 * 1.69e-5 * 300² ≈ 1.9 m/s²` of deceleration — realistically,
  minutes to coast down from top speed. Real aircraft genuinely are this
  slippery at altitude.
- **Bluffer** (`Cd ≈ 0.3`): `drag_coefficient = 0.3 * 6 / 16000 ≈ 1.13e-4`.
  At 300 m/s: `1.225 * 1.13e-4 * 300² ≈ 12.4 m/s²`.
- **Current default** (`drag_coefficient = 0.00015`) sits close to the
  bluffer end — implies `Cd ≈ 0.4` for the same area/mass assumptions, and
  gives ≈16.6 m/s² of drag at 300 m/s. That's a deliberate gameplay-pacing
  choice (a real streamlined fighter would coast for minutes, which doesn't
  read well in a dogfight), not an attempt at a literal slick-fighter Cd.

## 4. Thrust / acceleration reference points

**F-16** (real aircraft, for scale): empty mass ≈ 8,570 kg, max afterburner
thrust ≈ 131 kN → max acceleration ≈ `131,000 / 8,570 ≈ 15.3 m/s²`
(≈1.5 g).

`flight_controller.gd`'s `forward_acceleration = 500 m/s²` (≈51 g) is far
beyond any real aircraft or rocket engine's thrust-to-mass ratio. That's
intentional — a physically "correct" 1.5g throttle response would feel
unresponsive in VR — but it's called out here so it reads as a deliberate,
informed departure from realism rather than an unexamined number.

## 5. Newtonian flip-and-thrust behavior

This one isn't a tunable constant, it's a design property worth documenting
explicitly: `flight_controller.gd` stores `_linear_velocity` in **world
space**, not local ship space. Every physics frame, it's re-projected into
the ship's *current* local frame only to apply thrust/drag/clamping, then
converted back to world space. Rotating the ship — including a full 180°
flip — does not change this stored world-space vector.

Consequence: if you're drifting forward at speed and flip the ship around,
then pull the trigger (which always thrusts along the ship's *current* nose
direction, exactly like a real rocket engine), the existing drift is
decelerated first — velocity passes through zero — before speed builds in
the new direction. This matches real Newtonian/RCS-thruster behavior and
required no special-casing; it falls directly out of keeping velocity
integrated in world space rather than in the ship's local frame.

## Sources

- [NASA Glenn Research Center — Beginner's Guide to Aerodynamics: Drag Equation](https://www.grc.nasa.gov/WWW/K-12/BGP/Sue/Drag_equation_int.htm)
- [NASA Glenn Research Center — Effects of Shape on Drag (Cd table)](https://www1.grc.nasa.gov/beginners-guide-to-aeronautics/effects-of-shape-on-drag/)
- [NASA Glenn Research Center — Earth Atmosphere Model](https://www.grc.nasa.gov/www/k-12/airplane/atmosmet.html)
- [NASA Glenn Research Center — Earth Atmosphere Model (metric)](https://www1.grc.nasa.gov/beginners-guide-to-aeronautics/earth-atmosphere-equation-metric/)
- Standard gravity g₀ = 9.80665 m/s²: internationally defined constant (CGPM, 1901), used throughout NASA technical references.
