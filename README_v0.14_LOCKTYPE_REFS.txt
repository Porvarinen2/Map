LOCKPICK LEARNER v0.14 - LOCK-TYPE REFERENCES + DYNAMIC LIVE PROFILES
======================================================================

UPDATE-ONLY package. Extract over the existing C:\Lockpick folder.
DO NOT delete data/. Existing v0.12/v0.13 neural checkpoints remain compatible.

WHY v0.14
---------
The live controller previously treated every lock as the same ~3 s / 7-dead-probe
problem. That made the easy Rusted lock quit far too early even though the user
observed ~10 s and well over 30 fast F probes before the pick is exhausted.

v0.14 classifies the visible lock body from the supplied reference images BEFORE
each attempt. The classifier uses only the metal annulus. It deliberately excludes
the central keyway/pick and therefore cannot see the hidden ramp/target.

Bundled lock types:
  refs\lock_types\Rusted.png
  refs\lock_types\Basic.png
  refs\lock_types\Medium.png
  refs\lock_types\Enforced.png

Also bundled for audit/future vision work:
  refs\lock_success_angles\*.png
  refs\rotation_areas\*.png
  refs\minigame\*.png

LIVE PROFILES
-------------
Rusted (easy):
  - 10.0 s live budget
  - 36 dead-position probes before controller gives up
  - up to 48 decision steps
  - lower first-motion threshold 0.030 for the gentler/shallower ramp response

Basic / Medium / Enforced (player locks):
  - max(current configured budget, 3.0 s); existing default is ~3.1 s
  - 7 dead-position probes
  - 14 decision steps
  - first-motion threshold 0.050

Important: 'dead-position probes' are controller search misses. A useful visible
ramp/target response does NOT burn this counter. Time still limits the attempt.

REFERENCE CLASSIFIER
--------------------
The classifier compares robust Lab-colour statistics + a 2D chroma histogram on
the lock's metal annulus. It samples multiple frames and reports confidence and
best/second reference distances. It is designed to tolerate brightness changes
better than raw template matching.

If classification confidence is low, v0.14 fails safe to the short player-lock
profile. On retries of the same visible lock it may carry forward the last strong
classification.

MENU
----
18) LOCK TYPE DEBUG
    Reads the lock type continuously without sending F, Space, or mouse input.
    Use this first if you want to verify the reference classifier. F12 closes it.

Or run LOCK_TYPE_DEBUG.bat directly.

REAL EVALUATE now prints e.g.:
  --- SMART attempt 1 | Rusted (ref, conf=0.82, ...) ---
  [LOCK] budget=10.0s dead-probes=36 max-steps=48 first-motion=0.030

At the end it prints a per-lock-type batch summary.

OTHER FIXES INCLUDED
--------------------
- Keeps the v0.13 motion-during-F capture.
- Keeps pick vision OFF and dead-reckoned position from a hard-left reset.
- Keeps the v0.13.2 stale-F12/F10 startup release + safe hotkey handling.
- Live reward now uses the lock-specific motion threshold and time budget.
- Reference self-test added to VERIFY SMART (4/4 expected).

CHECKPOINT COMPATIBILITY
------------------------
OBS/action/network dimensions are unchanged. No re-training is required just to
install v0.14. Your existing smart_latest.pt / champion data are preserved because
this update ZIP intentionally contains no data/ directory and no live config file.
