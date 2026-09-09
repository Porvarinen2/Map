LOCKPICK v0.17.1 FREELEARN – GRADIENT + PLAYER F-EFFICIENCY COMMAND CENTER
================================================================================

WHAT CHANGED
------------
This update keeps the FREELEARN idea but fixes two important things:

1) RAMP DEPTH IS CONTINUOUS
   The simulator ramp was already physically continuous, but the old dashboard drew it
   as one flat orange block. v0.17.1 makes the physics/visualization explicit:
   dead zone = red, ramp = red -> yellow as depth increases, target = green.

   The neural does NOT receive hidden ramp depth directly. It receives the observable
   lock turn and the new observable frame-to-frame turn delta. This is equivalent to
   seeing whether the lock movement became stronger or weaker between frames.

2) PLAYER LOCK F-EFFICIENCY
   Basic / Medium / Enforced now have a soft goal of fewer than 8 OFF-TARGET F presses.
   There is no hard "8 presses and stop" script. The policy can still invent any search,
   tap, hold, move-while-holding, or recovery strategy.

   On a successful open, fewer wasted F presses = larger reward.
   Off-target taps also wear the simulated pick. The wear budget is randomized between
   configurable min/max values (default 6..8), and long off-target holds add extra wear.

WHY THIS IS STILL FREELEARN
---------------------------
The policy sees only:
- own horizontal X position
- observable lock turn
- observable lock turn delta (visual response getting stronger/weaker)
- current F DOWN / UP
- its own horizontal mouse delta
- remaining time
- visible lock type

It does NOT see:
- target center or target width
- ramp boundaries
- hidden ramp depth/cap value
- template ID
- best_pos
- Bayesian belief
- ramp/near-target/target flags
- scripted SEARCH / RECOVER / FINISH
- predefined F hold-duration menu

Actions are still only:
- horizontal mouse movement
- F DOWN / F UP every 25 ms

PLAYER PICK ECONOMY
-------------------
Default soft goal: <= 8 off-target F presses on player locks.

The Command Center now lets you hot-reload:
- soft off-target press goal
- success efficiency bonus
- pick-break wear min/max
- dead-zone tap wear
- ramp tap wear
- dead-zone hold wear / second
- ramp hold wear / second

The pick-break model is deliberately domain-randomized because the exact SCUM wear
formula is not known. It should teach "do not waste dozens of presses" without teaching
one fake exact durability constant.

CONTINUOUS RAMP PHYSICS
-----------------------
For every position x, the simulator calculates a hidden physical depth:
- 0.0 = dead zone
- 0.0..1.0 = ramp
- 1.0 = target

The curve exponent in each template controls how steeply the ramp rises toward target.
The neural never receives this depth number. F causes the visible lock turn to chase
that depth over time, so the neural must infer direction from visible response.

COMMAND CENTER VISUALIZATION
----------------------------
The four lock panels are smaller and cleaner.

Each panel now shows:
- SCUM lock reference image
- circular geometry ring around the lock
- red dead-zone arc
- red -> yellow ramp gradient
- green target arc
- cyan current neural X marker
- purple marker while F is held
- animated lock-rotation rotor
- visible lock-turn gauge
- visible turn delta
- F press trace
- press count: total / off-target
- simulated pick wear / break budget
- OPEN / FAIL / PICK BREAK

The lower 2D F trace uses:
- X position = where F was pressed
- vertical length = hold duration
- line color = hidden ramp depth shown ONLY to the human dashboard

GEOMETRY EDITOR
---------------
The ring and 2D preview update immediately when you change:
- target half-width
- left ramp width
- right ramp width
- curve exponent
- turn tau
- return tau

SAVE + HOT RELOAD changes new simulator episodes without restarting training.

LOCK SHOW
---------
You can choose the Lock Show interval from the EXE:
100k / 500k / 1M / 5M / 10M, or type any value.

1,000,000 attempts remains a good default because it makes behavioral changes easier
to see. LOCK SHOW NOW requests an immediate four-lock deterministic replay.

TIME / SEARCH RANGE
-------------------
Rusted: 10 seconds, full normalized X range 0.0..1.0.
Basic / Medium / Enforced: 3 seconds, left-side normalized X range 0.0..0.5.

CHECKPOINT COMPATIBILITY
------------------------
v0.17.1 adds observable turn-delta to the neural input, so an older v0.17 FREELEARN
checkpoint has a different input shape. The trainer includes an automatic v0.17 ->
v0.17.1 migration: old X/turn/F/mouse weights are copied into the matching new input
channels and the new turn-delta weights start at zero. Adam optimizer momentum is reset,
but the learned policy, attempts, steps and best score are preserved.

Unknown/incompatible checkpoint shapes still fall back to a fresh FREELEARN model.
Old v0.16.x data/champions remain separate.

IMPORTANT
---------
The exact real SCUM ramp widths and pick durability formula are not publicly known.
This simulator therefore uses visible editable geometry templates and randomized player
pick wear. A high simulator success rate is not proof of equal in-game success.
