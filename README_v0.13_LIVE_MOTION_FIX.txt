LOCKPICK LEARNER v0.13 - LIVE MOTION CAPTURE FIX
=================================================

WHY THIS UPDATE EXISTS
----------------------
The v0.12 live log proved the neural controller was not the main failure.
The live observation bridge was dropping the exact signal the player could see.

v0.12 did this:
  1) press F with a blocking send_key()
  2) wait until F was released
  3) only then sample lock rotation

In SCUM the lock can rotate/jolt DURING the F press and snap back quickly.
Therefore visible ramp motion could be missed and the agent stayed in SEARCH.

The uploaded live log also showed real small-turn responses around 0.078-0.101,
while the live phase gate was 0.130 because no real demo profile was loaded.
Those real visible turns were therefore treated as dead-zone noise.

v0.13 FIXES
-----------
1. F is now key-down / vision samples WHILE HELD / key-up / short post-window.
2. Live first-motion threshold is separate from simulator threshold (default 0.050).
3. Response uses actual keyway orientation excursion from the pre-F baseline.
4. Short lock jitter contributes to the motion signal instead of being discarded.
5. Pick visual tracking is removed from normal live movement.
   Each attempt hard-resets against the left stop => internal position starts at 0.000.
   Position is then dead-reckoned from our own mouse commands.
6. A visible ramp/target response no longer consumes the 'wrong position' counter.
7. Live console now prints: resp=..., motion=..., jit=...

CHECKPOINT COMPATIBILITY
------------------------
Network architecture and action space are unchanged.
Your v0.12 trained champion/checkpoints remain compatible and are NOT reset.
This update changes the live sensor/control bridge, not the learned neural weights.

INSTALL OVER EXISTING v0.12
----------------------------
Extract the UPDATE ONLY zip directly over the existing C:\Lockpick folder.
Do NOT delete the data folder.
Run START_SMART.bat -> REAL EVALUATE.

WHAT YOU SHOULD SEE
-------------------
When the lock visibly begins to turn during a short F tap, motion/resp should rise
and the NEXT decision should leave SEARCH for RAMP/NEAR/TARGET instead of blindly
continuing to scan right.

If resp still stays ~0.000 while the lock visibly rotates, use VISION DEBUG and
record a short log; that would isolate the remaining issue to keyway detection ROI.
