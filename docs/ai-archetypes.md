# AI Archetypes & Skill Tiers

**Status: design document, not implemented.** Nothing described here exists
in code yet. It defines the trait vocabulary, the 50 archetypes, and the
skill model so they can be built incrementally rather than invented ad hoc.
Every number is a starting point, not a decision.

Grounded against what `combatant.gd` / `squad.gd` / `faction_battle.gd`
actually carry today — see "What exists vs. what this needs" at the bottom,
which is honest about which archetypes are buildable now and which are
waiting on mechanics that don't exist yet.

---

## 1. The core idea: three independent rolls

Every AI ship rolls **three** things at match start, and they are
deliberately orthogonal:

| Roll | What it is | Range |
|---|---|---|
| **Callsign** | Its identity — already exists as `FRIENDLY-042` | index |
| **Archetype** | What it *wants* | 1 of 50 |
| **Skill** | How *well* it does it | 1-10 |

Keeping archetype and skill separate is the whole point. A skill-1 Headhunter
is a nuisance that fixates on you and misses; a skill-10 Headhunter is the
scariest thing in the match. Same intent, completely different threat. That
one split turns 50 archetypes into 500 distinguishable pilots without
writing 500 behaviours.

**Archetype sets the goals. Skill sets the execution.** An archetype must
never make a pilot *better*, only different — otherwise archetypes become a
second difficulty axis and the two fight each other.

---

## 2. The trait vector

An archetype is not bespoke code. It is a **named preset over a shared set
of traits**, exactly the way `Assets/ShipProfiles/standard_fighter.tres`
already presets flight characteristics for every ship in the game. Adding an
archetype should mean adding a row of numbers, not a new branch in
`_update_combatant()`.

Most of these already exist in `faction_battle.gd` as **global constants**.
Promoting them to per-pilot traits is the bulk of the actual work.

### Engagement traits

| Trait | Range | Meaning | Today |
|---|---|---|---|
| `aggression` | 0-1 | How readily it enters PURSUE vs. holding FORMATION | implicit |
| `courage` | 0-1 | Drives `RETREAT_HEALTH_FRACTION` (currently 0.35 for all) | global const |
| `preferred_range` | m | Drives `BREAK_OFF_RANGE` (140m) and `ENGAGE_RANGE` (700m) | global const |
| `patience` | 0-1 | Drives `reaction_timer` (0.35-1.1s) and trigger discipline | per-pilot |
| `persistence` | 0-1 | How long it stays on one target before retargeting | none |
| `retaliation` | 0-1 | Tendency to switch to whoever just hurt it | none |
| `squad_cohesion` | 0-1 | Holds station vs. freelances away from the squad | implicit |

### Target-selection traits

| Trait | Range | Meaning |
|---|---|---|
| `player_fixation` | **-1 to +1** | The key one. **+1** hunts the player above all; **0** genuinely does not care the player exists; **-1** actively flees the player. Generalises today's single global `player_target_bias` (0.55). |
| `objective_focus` | 0-1 | Weight on fuel tanks vs. enemy ships |
| `prey_bias` | 0-1 | Preference for already-damaged targets |
| `threat_bias` | 0-1 | Preference for high-performing targets (needs a per-pilot kill counter) |

### Weapon & energy traits

| Trait | Range | Meaning | Today |
|---|---|---|---|
| `missile_appetite` | 0-1 | Missiles vs. guns | fixed cooldown |
| `afterburner_appetite` | 0-1 | Drives the burn/cooldown state machine thresholds | global consts |
| `fire_discipline` | 0-1 | Won't fire outside a good solution — narrows `FIRE_CONE` (14°) | global const |
| `flare_readiness` | 0-1 | How reliably it defeats an incoming missile | always deploys |

### Movement traits

| Trait | Range | Meaning |
|---|---|---|
| `altitude_preference` | 0-1 | Deck-hugging through the city vs. staying high |
| `separation_appetite` | 0-1 | Scales `SEPARATION_RADIUS` (130m) — tight formations vs. loose |
| `evasion` | 0-1 | Jinking while under fire (no jink behaviour exists yet) |

---

## 3. Skill 1-10

Skill scales **execution quality only**. Each of these interpolates across
the tiers:

| What scales | Skill 1 | Skill 10 |
|---|---|---|
| `accuracy` (exists, 0.55-0.95) | 0.35 | 0.99 |
| `reaction_timer` (exists) | ~1.6s | ~0.15s |
| **Lead quality** | fires at where the target *is* | full intercept solution |
| Aim error growth with range | steep | nearly flat |
| Afterburner discipline | wastes it, burns while coasting | saves it for the merge |
| Missile defeat | ignores incoming | flares reliably, breaks correctly |
| Turn efficiency | overshoots, bleeds speed | clean, minimal energy loss |
| Situational awareness | tunnel vision, no check-six | disengages before being flanked |

**Lead quality is the single most important one.** The AI today always
computes a perfect quadratic intercept (`_lead_point()`, the same solution
the player's PIP ring uses). That is a *skill-10* behaviour being given to
every pilot in the game for free. Degrading it toward "shoot at where they
are right now" is what will make low-skill pilots feel genuinely low-skill,
and it is probably the highest-value single change on this whole page.

### Match distribution

Bottom-heavy, per the intent that level 1 is a heavy majority and aces are
rare. Weights out of 100 per fleet:

| Skill | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| **Ships** | 26 | 19 | 14 | 11 | 8 | 7 | 5 | 4 | 3 | 3 |

- Skill 1-3 = **59%** of the fleet — the mass that makes a 100v100 battle
  feel like a battle rather than 100 aces.
- Skill 8-10 = **10 ships** per side.
- Skill 10 = **3 per side, 6 in the match.** These should be *named* and
  called out in the kill feed — that hooks directly into the
  "Hunt the ace" idea already in `docs/objectives-roadmap.md`.

Exported as a weight table so the curve is a tuning knob, not a rewrite.
A "veteran fleet" or "green fleet" is then just a different weight row.

---

## 4. The 50 archetypes

Grouped into families. Each lists its defining traits and — because it was
an explicit requirement — **how it treats the player**.

### A. Aggressors (1-8)

| # | Name | Identity | Player |
|---|---|---|---|
| 1 | **Berserker** | Max `aggression`, `courage` 1.0 — never retreats at any health | attacks |
| 2 | **Brawler** | Tiny `preferred_range`; closes to knife-fighting distance and stays | attacks |
| 3 | **Duelist** | `persistence` 1.0 — picks one target and will not break off until it or they are dead | attacks if picked |
| 4 | **Headhunter** | `player_fixation` +1.0. Ignores the fleet battle entirely | **hunts you** |
| 5 | **Blitzer** | `afterburner_appetite` 1.0 — fast slashing passes, never loiters | attacks |
| 6 | **Marauder** | `prey_bias` 1.0 — always picks the most damaged target in range | attacks if hurt |
| 7 | **Zealot** | Aggression *rises* as health falls | attacks |
| 8 | **Pack Leader** | Aggression scales with the number of living squadmates nearby | attacks |

### B. Reactive hunters (9-14)

| # | Name | Identity | Player |
|---|---|---|---|
| 9 | **Stalker** | Shadows a target at range; only commits when they're already engaged | **shadows you** |
| 10 | **Opportunist** | Only engages targets below 50% health, disengages otherwise | conditional |
| 11 | **Ambusher** | Loiters off the main furball; dives on anything passing | situational |
| 12 | **Avenger** | Fixates on whoever last killed a squadmate | if you killed one |
| 13 | **Tank Guardian** | Fixates on whoever last damaged a friendly fuel tank | **if you attack tanks** |
| 14 | **Bounty Hunter** | Targets whoever currently has the most kills | if you're winning |

### C. Objective specialists (15-21)

| # | Name | Identity | Player |
|---|---|---|---|
| 15 | **Saboteur** | `objective_focus` 1.0, `aggression` 0.0 — avoids all combat, beelines for tanks | **ignores you** |
| 16 | **Bombardier** | Attacks tanks with missiles from stand-off range | ignores |
| 17 | **Trailblazer** | First to the objective, pulls its squad along | ignores |
| 18 | **Squatter** | Parks over the objective and defends the airspace | if you approach |
| 19 | **Sapper** | Low `altitude_preference` — uses city streets as cover to reach tanks | ignores |
| 20 | **Objective Denier** | Defends tanks exclusively, will not chase anything away from them | if you approach |
| 21 | **Raider** | Only strikes tanks when the airspace above them is clear | avoids |

### D. Team players (22-28)

| # | Name | Identity | Player |
|---|---|---|---|
| 22 | **Wingman** | `squad_cohesion` 1.0 — mirrors its leader's target choice exactly | follows leader |
| 23 | **Shepherd** | Escorts damaged allies out of the fight | attacks pursuers |
| 24 | **Anchor** | Holds formation rigidly; never freelances | rarely |
| 25 | **Screener** | Positions itself between threats and its own squad | intercepts |
| 26 | **Rally Caller** | Retreats early and re-forms broken squads | avoids |
| 27 | **Spotter** | Fires little, but whatever it targets gets focus-fired by the squad | marks you |
| 28 | **Decoy** | Deliberately draws fire; high `evasion`, low damage | **baits you** |

### E. Cautious & evasive (29-35)

| # | Name | Identity | Player |
|---|---|---|---|
| 29 | **Skittish** | `player_fixation` -1.0 — breaks away the moment the player closes | **flees you** |
| 30 | **Survivor** | `courage` 0.15 — retreats at 70% health, returns when repaired | flees |
| 31 | **Kiter** | Maintains range; never lets anything get inside `preferred_range` | keeps away |
| 32 | **Turtle** | `flare_readiness` 1.0, heavy defensive flying | defensive |
| 33 | **Hermit** | Operates alone at the edges of the dome | avoids |
| 34 | **Pacifist Scout** | Never fires. Exists to hold dome presence for Air Superiority | **ignores you** |
| 35 | **Bleeder** | Trades one pass, disengages, returns — attrition by repetition | hit and run |

### F. Marksmen & technicians (36-42)

| # | Name | Identity | Player |
|---|---|---|---|
| 36 | **Sniper** | Long `preferred_range`, `fire_discipline` 1.0 — never closes | at range |
| 37 | **Missileer** | `missile_appetite` 1.0 — guns are a last resort | at range |
| 38 | **Deflection Shooter** | Specialises in high-angle snapshots across the merge | attacks |
| 39 | **Energy Fighter** | Trades altitude for speed; vertical tactics | attacks |
| 40 | **Angles Fighter** | Turn-fights, works for a position behind the target | attacks |
| 41 | **Boom & Zoom** | High-speed passes, refuses to turn-fight | attacks |
| 42 | **Cold Shot** | Fires rarely; `fire_discipline` 1.0 and near-perfect solutions | attacks |

### G. Erratic & flavour (43-50)

| # | Name | Identity | Player |
|---|---|---|---|
| 43 | **Wildcard** | Rerolls its own archetype every ~60s | unpredictable |
| 44 | **Late Bloomer** | Passive until its squad is nearly wiped, then goes Berserker | changes |
| 45 | **Show-off** | Flies aerobatics near the player; poor threat, high presence | **performs at you** |
| 46 | **Grudge Holder** | Permanently fixates on whoever first damaged it | if you shoot it |
| 47 | **Rookie** | Panics under fire; erratic, breaks the wrong way | flees badly |
| 48 | **Veteran** | Calm and efficient; never wastes an afterburner burn | measured |
| 49 | **Ghost** | Deliberately stays outside the player's view cone | **avoids being seen** |
| 50 | **Kamikaze** | Below 20% health, rams the nearest target or tank | terminal threat |

---

## 5. What exists vs. what this needs

Honest accounting, so this can be built in order of what's cheapest.

### Buildable on today's systems

These need only the trait-vector refactor — promoting existing global
constants in `faction_battle.gd` to per-pilot fields:

Berserker, Brawler, Duelist, Headhunter, Blitzer, Marauder, Zealot,
Pack Leader, Opportunist, Ambusher, Wingman, Anchor, Rally Caller, Decoy,
Skittish, Survivor, Kiter, Turtle, Hermit, Pacifist Scout, Bleeder, Sniper,
Missileer, Cold Shot, Wildcard, Late Bloomer, Rookie, Veteran.

**That is 28 of 50 with no new mechanics at all**, which makes the trait
refactor by far the highest-leverage first step.

### Needs mechanics that don't exist yet

| Missing mechanic | Unlocks |
|---|---|
| **AI ground attack** — `Combatant` can only target "an opposing ship" or "the player"; it needs a third target type. *Already the flagged known gap on the tank objective.* | Saboteur, Bombardier, Trailblazer, Squatter, Sapper, Objective Denier, Raider |
| **Damage attribution stored per pilot** — who hurt me, who hurt my tank, who killed my squadmate. Cause strings exist for the kill feed but are never read back. | Avenger, Tank Guardian, Grudge Holder, retaliation trait |
| **Per-pilot kill counter** | Bounty Hunter, threat_bias, named aces |
| **Ship-vs-ship collision** — ships currently pass through each other | Kamikaze |
| **Energy state modelling** — the AI tracks heading and speed, not energy | Energy Fighter, Angles Fighter, Boom & Zoom |
| **Player view-cone test** | Ghost |
| **Jink/evasion under fire** | evasion trait, Rookie's panic |
| **Aerobatic manoeuvre set** | Show-off, Deflection Shooter |
| **Squad target marking** | Spotter |
| **Ally-protection targeting** | Shepherd, Screener |

---

## 6. Suggested build order

1. **Trait vector + skill tiers.** Promote the global constants to per-pilot
   traits, add the 1-10 skill roll and the distribution table. Ship maybe 8
   archetypes across the extremes (Berserker / Headhunter / Skittish /
   Pacifist Scout / Sniper / Wingman / Rookie / Veteran) to prove the system
   reads differently in the headset before authoring 50 rows of numbers.
2. **Degrade lead quality by skill.** Single highest-value change for making
   the fleet feel like it has a range of ability.
3. **AI ground attack.** Unlocks a whole family *and* closes the standing
   tank-objective gap at the same time.
4. **Damage attribution.** Unlocks the reactive-hunter family, including the
   Tank Guardian behaviour that was an explicit request.
5. Everything else, as the underlying mechanics arrive.

## 7. Open questions

- **Does the player see any of this?** A callsign is already shown by
  `friendly_tags.gd`; skill or archetype could surface on `target_lock.gd`'s
  info readout. Showing it makes aces legible and threatening; hiding it
  keeps them mysterious. Probably: show skill for locked targets only.
- **Are both fleets drawn from the same distribution?** Symmetric is
  simplest and fairest. An asymmetric roll is also the obvious place for a
  future overall difficulty setting to live.
- **Do archetypes persist across respawn?** Squad membership is already
  fixed for the match. Keeping archetype fixed too makes callsigns mean
  something across a whole match, which is what makes an ace worth hunting.
- **How much should archetype bias squad composition?** A squad of five
  Saboteurs behaves very differently from a mixed one. Rolling per-squad
  rather than per-pilot for *some* archetypes may read better than pure
  per-pilot randomness.
- **Does skill affect ship performance, or only piloting?** Recommended:
  **only piloting.** Every ship in this game shares one
  `ShipFlightProfile` by explicit design (see `docs/omega-flight-model.md`),
  and giving aces faster ships would quietly break the "the player flies the
  same ship as the AI" property that profile exists to guarantee.
