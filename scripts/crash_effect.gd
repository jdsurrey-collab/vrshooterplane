extends Node3D

## Visual crash marker: a black scorched crater plus a thick smoke column
## billowing hundreds of meters into the air. Spawned once per crash by
## crash_handler.gd / enemy_ai.gd.
##
## Intentionally permanent — no emission cutoff, no self-destruct timer.
## The GPUParticles3D loops forever (emitting stays true, particles recycle
## on their own per-particle lifetime), so the column stays continuously
## topped-up rather than dissipating. Every crash adds a new one of these
## and it just stays, same permanence contract as the debris field
## (crash_effects.gd) — nothing here ever calls queue_free() *itself*.
##
## It is NOT unbounded, though, and that distinction cost real frame rate.
## Because this effect never dissipates, its cost is paid on every frame for
## the rest of the session, and it used to be spawned with no cap at all —
## so a player who crashed repeatedly (easy, given a 100m spawn altitude
## over genuinely mountainous terrain) accumulated a permanent, continuously
## re-simulated smoke column per crash, each one 1200 alpha-blended quads
## that never went away. That is a frame rate that gets progressively worse
## the longer you play and never recovers, which matches the "FPS collapsed
## to ~6 during a live playtest" report better than any single static cost
## in the scene does.
##
## Two things changed, neither of which removes the permanent-crash-marker
## idea: the column is now 420 particles instead of 1200 (a smoke column
## reads from its silhouette and motion, not from saturation — the old count
## was overlapping many times over inside the same volume), and
## crash_effects.gd now recycles the OLDEST crash site once
## MAX_CRASH_SITES are live, so the trail of recent crashes stays visible
## but the per-frame cost has a ceiling.
