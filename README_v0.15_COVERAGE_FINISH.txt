LOCKPICK LEARNER v0.15 - COVERAGE SCAN + FINISH LATCH + NO FAKE PROBE CAP
=============================================================================

WHY THIS UPDATE EXISTS
----------------------
v0.14 could stop a live attempt because of an internal 7/30/36 probe counter,
and one early/noisy ramp-like response could trap the controller in a tiny local
area. It could also leave a very strong real response and move away before the
final long F hold.

v0.15 fixes those behaviours without changing the neural tensor architecture.
Existing v0.12-v0.14 checkpoints remain loadable.

LIVE RULE CHANGES
-----------------
* NO artificial dead-probe/attempt counter terminates live play.
* Attempt ends on SUCCESS or the lock-type real time budget.
* Rusted: 10 s live budget, lower first-motion threshold, finer systematic scan.
* Basic / Medium / Enforced: short ~3 s player-lock budget.
* Search coverage guard aims to traverse at least 75% of the horizontal range.
* Before ramp confirmation, search is monotonic left -> right and cannot camp.
* Weak first motion is confirmed with a nearby short F probe before local search.
* If local search stops improving, controller escapes back to global rightward scan.
* After a full missed pass, it can rescan from the left while time remains.
* Strong rotation activates FINISH LATCH: return to best remembered position and
  use a long hold; if needed, test only tiny +/- offsets around best position.
* Pick vision is still OFF for position. Position comes from left hard-stop +
  dead-reckoned mouse commands.

OFFLINE SIM RULE CHANGES
------------------------
* Fake 7-wrong-position termination is disabled.
* L0/Rusted virtual budget = 10 s.
* Other player-lock levels virtual budget = 3 s.
* Wrong-position count is diagnostic only; time is the real simulated stop rule.
* Existing continual skill-bank/champion training remains compatible.

REFERENCES INCLUDED
-------------------
refs/lock_types: Rusted, Basic, Medium, Enforced
refs/lock_success_angles: all 4 success-angle references
refs/rotation_areas: all 4 lock rotation masks + screen-area reference
refs/minigame: Lockpicking, Lockpickstart, MaxSideLeft, MaxSideRight
plus success templates.

INSTALL
-------
Extract this UPDATE ONLY package over the existing C:\Lockpick folder.
DO NOT delete the existing data folder. This package intentionally contains no
user data/checkpoints and no active config_neural_smart.json.

FIRST TEST
----------
1. Run LOCK_TYPE_DEBUG.bat and verify the visible lock type.
2. Run START_SMART.bat -> REAL EVALUATE.
3. Watch log fields: scan=%, conf=0/1, phase=SEARCH/CONFIRM/RAMP/FINISH.
4. A no-signal attempt should keep advancing right instead of stopping at 7 probes.
5. A strong response should lead to FINISH at best_pos rather than wandering away.

TRAINING NOTE
-------------
The old champion was trained under the old 3 s / 7-probe simulator assumption.
v0.15 can use it immediately, but future offline continual training now uses the
corrected time-only rule. Test live first; then continue offline training if the
vision/controller is behaving correctly.
