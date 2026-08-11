extends Node3D

## Visual crash marker: a black scorched crater plus a thick smoke column
## billowing hundreds of meters into the air. Spawned once per crash by
## crash_handler.gd / enemy_ai.gd.
##
## NOTHING IN THIS PROJECT IS PERMANENT ANY MORE. Standing rule, set after
## this effect specifically was reported as never being seen: *"anything
## that's persistent like the crash sites doesn't need to exist any more."*
## Persistent effects are a cost paid every frame for the rest of the session
## against something the player has usually flown away from, and this one was
## the last of them.
##
## This node still never frees ITSELF — the GPUParticles3D loops and stays
## topped-up rather than dissipating — because the whole crash site (column
## plus its debris field) is owned and freed together by crash_effects.gd
## after CRASH_SITE_LIFETIME. Freeing the column independently would leave
## orphaned wreckage standing around nothing.
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
