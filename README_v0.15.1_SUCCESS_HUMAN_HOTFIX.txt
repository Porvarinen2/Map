LOCKPICK LEARNER v0.15.1 - SUCCESS + HUMAN DATA HOTFIX
=======================================================

WHY THIS EXISTS
---------------
v0.15 SMART HUMAN TEACH could record real wins as FAIL / success=0.
Two bugs mattered:

1) SUCCESS template scaling used physical monitor height. At 4K SCUM UI scaling
   does not have to be exactly 2x, so the SUCCESS word could be missed.
   v0.15.1 scales the template from the detected lock radius instead and searches
   a wider centre band. Supplied 1920 reference self-test passes at 1.0x/1.5x/2.0x.

2) HUMAN TEACH stored absolute lock-keyway progress as response. That could create
   absurd values like resp=0.978 on a dead F tap. v0.15.1 records motion relative
   to the exact F-down baseline, matching the live agent measurement.

DATA SAFETY
-----------
- Existing SMART demo files with ZERO verified success episodes are NOT deleted.
- They are treated as untrusted and ignored by simulator-profile fitting and BC.
- If no verified human successes exist, HUMAN PRETRAIN refuses to mutate the
  neural policy. This prevents a broken success detector from poisoning a good
  simulator champion.
- Once a new v0.15.1 recording contains at least one verified SUCCESS, that file
  becomes trusted automatically and can train the policy.

IMPORTANT AFTER THE BAD v0.15 RECORDING
---------------------------------------
The shown session ran BC twice after success=0, so smart_latest may have moved away
from the earlier simulator champion. In START_SMART choose:
  11) RESTORE BEST
and restore best SIM (or a known-good best REAL if you have one) before recording
new human examples.

Then:
  1) SMART HUMAN TEACH
Play some successful AND failed attempts normally. On a real win you should now
see a line like:
  HUMAN SUCCESS | ep=... score=...
and the final summary should show success > 0.

Do not delete data/. This ZIP is update-only.
