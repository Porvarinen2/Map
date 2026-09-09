LOCKPICK v0.17.2 FREELEARN – STATIC-F PHYSICS COMMAND CENTER
====================================================================

CRITICAL PHYSICS FIX
--------------------
SCUM's F interaction is now modeled as a STATIC probe.

The simulator enforces this as a hard physical rule:
- F UP for the whole 25 ms frame -> horizontal X movement is allowed.
- F press frame -> X is locked.
- F held DOWN -> X is locked.
- F release frame -> X is locked.
- Only the next full F-UP frame may move X again.

Therefore the neural cannot hold F and slide along the ramp to read its gradient.
It must learn the real sequence itself:
MOVE -> stop -> F probe/hold at one fixed X -> observe visible turn -> release F -> move -> next probe.

WHY A FRESH v0.17.2 POLICY IS REQUIRED
---------------------------------------
A v0.17/v0.17.1 FREELEARN checkpoint may have learned an impossible exploit because
older simulator physics allowed horizontal motion while F was active. v0.17.2 refuses
to resume a checkpoint that does not contain the new physics contract
"static-f-x-v1". The old file is not deleted; the new run starts clean and the next
checkpoint becomes a valid v0.17.2 static-F checkpoint.

The observation/action dimensions are otherwise unchanged, but reusing the old weights
would contaminate learning with behavior that cannot occur in the game.

FREE-LEARN CONTRACT
-------------------
The neural receives only:
- own horizontal X position
- visible lock turn
- visible frame-to-frame turn delta
- F DOWN / UP state
- its own ACTUAL horizontal movement (blocked movement during F is reported as 0)
- remaining time
- visible lock type

It does NOT receive:
- target location or target width
- ramp boundaries
- hidden ramp depth
- template ID
- best position
- scripted SEARCH / RECOVER / FINISH states
- predefined hold-duration choices

Actions remain:
- horizontal mouse request
- F DOWN / F UP every 25 ms

The requested mouse action is physically ignored whenever F is involved. PPO also
masks the ignored mouse action out of the policy log-probability and entropy term, so
the optimizer does not waste learning capacity on impossible movement during F.

RAMP RESPONSE
-------------
Ramp depth remains continuous. Hidden physical depth is 0 in dead space, rises through
the ramp and reaches 1 at target. The neural never sees that hidden value directly.
It only sees the resulting visible lock movement and turn delta while testing a STATIC
X position with F.

PLAYER LOCK F ECONOMY
---------------------
Basic / Medium / Enforced keep the soft goal of <= 8 off-target F presses.
This is not a hard action cap. Successful opens receive more reward when they use fewer
wasted probes, while off-target presses/holds add randomized simulated pick wear.

COMMAND CENTER
--------------
Lock Show now makes the static-probe rule obvious:
- cyan marker = current X while movement is available
- purple marker + "F DOWN · X STATIC" = F is active and X is locked
- lock rotor shows visible lock turn
- red -> yellow ramp gradient and green target are shown ONLY to you
- 2D trace uses actual X movement, so the X trace must be perfectly vertical/static
  during every F hold
- lock footer shows X MOVE / LOCKED

If the X marker moves while F says DOWN in a v0.17.2 replay, that is a bug.

OTHER EXISTING v0.17.1 FEATURES RETAINED
----------------------------------------
- Rusted 10 s, full X range
- Basic / Medium / Enforced 3 s, left 50% X range
- editable geometry templates
- red -> yellow -> green geometry visualization
- turn / turn-delta telemetry
- pick wear + 6..8-ish randomized player pick budget
- success efficiency reward
- hot reload geometry and F-economy settings
- configurable 100k / 500k / 1M / 5M / 10M Lock Show interval

IMPORTANT
---------
The exact SCUM ramp geometry and pick durability formula are still not publicly known.
The simulator is intentionally domain-randomized and editable. Simulator success is a
training metric, not a guarantee of the same in-game success rate.
