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
## (crash_effects.gd) — nothing here ever calls queue_free().
