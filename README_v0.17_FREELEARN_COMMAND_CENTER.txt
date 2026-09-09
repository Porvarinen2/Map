LOCKPICK v0.17 FREELEARN COMMAND CENTER
======================================

WHAT THIS UPDATE IS
-------------------
This is a separate FREELEARN training path. It does not overwrite the old v0.16.x
champions or replay bank. The new action/observation space is intentionally different,
so v0.17 creates/resumes only checkpoints/freelearn_latest.pt.

START
-----
1. Copy all files into the Lockpick project folder.
2. Double-click LockpickCommandCenter.exe.
3. It opens a LOCAL browser dashboard (127.0.0.1 only). No internet is required.
4. Choose training minutes, vector env count and Lock Show interval.
5. Press START TRAINING.

LOCK SHOW INTERVAL
------------------
Default = 1,000,000 completed simulated lock attempts.
100,000 is not computationally dangerous: the showcase is only four deterministic
replays, so its overhead is tiny. 1,000,000 is a better default because the behavioral
difference between shows is easier to see and the dashboard is less noisy.
The interval can be changed while training is running. Presets: 100k / 500k / 1M /
5M / 10M. LOCK SHOW NOW requests an immediate four-lock replay.

STRICT FREE-LEARN CONTRACT
--------------------------
The policy does NOT receive:
- hidden target center or width
- hidden ramp boundaries or template ID
- best_pos / remembered sweet spot feature
- Bayesian belief distribution
- ramp / near-target / target flags
- scripted SEARCH / RECOVER / FINISH state
- predefined F hold-duration choices
- a teacher/bootstrap lockpick strategy

The policy receives only raw information available from its own control/sensor stream:
- own horizontal position inside the physical lock range
- observable lock turn amount
- current F DOWN/UP state
- its own previous horizontal mouse delta
- remaining time
- visible lock type: Rusted / Basic / Medium / Enforced

The policy outputs every 25 ms:
- signed horizontal mouse movement
- F DOWN or F UP

Therefore a 75 ms tap, 425 ms hold, 1.2 s hold, repeated tapping, moving while holding,
etc. are sequences the neural policy must discover itself. There is no hold-time table.

TIME / MOVEMENT PHYSICS
-----------------------
Rusted: 10.0 s, full normalized horizontal range 0.0..1.0.
Basic / Medium / Enforced: 3.0 s, normalized left-side range 0.0..0.5.
No artificial "7 probes" or similar live-style attempt cap exists in FREELEARN.

UNKNOWN REAL SCUM GEOMETRY
--------------------------
Because the exact public SCUM ramp/target widths are not known, v0.17 deliberately
uses a small fixed TEMPLATE BANK instead of pretending one guessed width is exact.
Each lock type has five persistent templates. The target CENTER moves to a new position
each episode, while the chosen template shape stays fixed.

This gives the neural policy several nearby physical versions of the same lock type and
reduces the chance of learning a tactic that works only on one slightly wrong guessed
ramp. The templates are intentionally visible and editable in Command Center.

GEOMETRY EDITOR
---------------
Choose lock type + template. Edit:
- target half-width
- left ramp width
- right ramp width
- ramp curve exponent
- turn time constant
- return time constant

SAVE + HOT RELOAD writes freelearn_config.json. A running trainer notices the file and
uses the new geometry on NEW episodes without restarting. Time limits and lock movement
ranges are shown but are not exposed in the normal editor because those are known rules.

VISUAL LOCK SHOW
----------------
Four panels replay Rusted, Basic, Medium and Enforced simultaneously using the current
neural checkpoint/policy.
- SCUM lock-type reference image is used as visual background.
- yellow = ramp, green = target, red = dead area
- cyan marker = current simulated pick X position
- upper gauge = visible lock turn
- lower 2D trace draws every F press at its X coordinate
- vertical trace length = how long F stayed DOWN

Hidden geometry is written into the showcase file ONLY so the human dashboard can draw
it. It is never appended to neural observations.

FILES CREATED WHILE RUNNING
---------------------------
data/freelearn_telemetry.json  current dashboard telemetry
data/freelearn_progress.csv   long-term learning graph
<data>/freelearn_showcase.json latest 4-lock visual replay
data/freelearn_console.log     trainer console log
checkpoints/freelearn_latest.pt resume checkpoint
checkpoints/freelearn_best.pt   best lifetime mean seen so far

RAM
---
v0.17 FREELEARN intentionally does not allocate the old ~30.7 GiB continual replay
bank. PPO rollout memory is bounded by env count x rollout size. This makes a long run
less likely to fill RAM just because it has been running for many hours.

IMPORTANT
---------
A high simulator score is not proof of SCUM success. The whole point of the geometry
editor/template bank is to make the simulator assumptions visible instead of hiding
an unknown guessed ramp inside the trainer.
