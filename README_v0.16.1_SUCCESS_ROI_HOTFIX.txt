LOCKPICK LEARNER v0.16.1 - SUCCESS ROI REFERENCE HOTFIX
=======================================================

Why this hotfix exists
----------------------
v0.16 could record many real wins as HUMAN FAIL. The SUCCESS reference screenshot's
actual lock radius is about 221 px, while the old detector scaled the text as if the
reference radius were about 191 px. That systematically distorted template size.

v0.16.1 success rule
--------------------
1. Only the centre SUCCESS text area is searched (see refs/success_detection/
   SUCCESS_reference_RED_ROI.png).
2. The bundled SUCCESS word image is the authoritative positive reference.
3. Matching uses both lock-radius scaling and game/window-height scaling.
4. Binary brightness matching + edge matching are combined.
5. Hard score >= 0.48 => SUCCESS immediately.
6. Soft score >= 0.34 on two nearby frames within 220 ms => SUCCESS.
7. Human Teach uses the same soft reference gate before Space, instead of blindly
   writing FAIL when a borderline SUCCESS was already visible.
8. Existing config.json with the old exact default 0.62 is automatically migrated
   to 0.48. Custom thresholds are preserved.

Reference self-test
-------------------
Run SUCCESS_REF_SELFTEST.bat. The bundled positive SUCCESS screenshot should score
very high while ordinary lock reference images should stay far below the gate.

Data safety
-----------
This update contains no data/ directory and does not replace the trained neural
checkpoint. Existing SMART models remain in place.
