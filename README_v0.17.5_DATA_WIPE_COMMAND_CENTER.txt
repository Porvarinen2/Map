LOCKPICK v0.17.5 FREELEARN – BOUNDS + EXPLICIT F TAP/HOLD + 1 SECOND OFF-TARGET CAP
====================================================================================

WHAT CHANGED
------------
1. Neural now has explicit control modes:
   - MOVE / RELEASE
   - F TAP
   - F HOLD

2. F TAP is one simulator frame (default 25 ms) at one STATIC X position.

3. F HOLD has NO predefined duration menu. The neural chooses the duration itself by
   selecting HOLD again every frame. With 25 ms frames, a 200 ms hold is simply eight
   consecutive HOLD decisions. It can release whenever it wants.

4. Static-F physics remains hard:
   - X movement is allowed only on a full MOVE frame when persistent F was already UP.
   - F TAP locks X.
   - F HOLD locks X.
   - the RELEASE frame locks X.
   - movement can resume on the following full MOVE frame.

   Therefore the neural cannot scan sideways while F is active.

5. Basic / Medium / Enforced now have a cumulative off-target F-active time budget.
   Default: 1.00 second.

   Every millisecond of F that is active outside the actual target counts toward this
   budget, whether it came from short TAPs or HOLDs. Example:
     5 x 200 ms off-target HOLD = 1.00 s -> simulated pick breaks.

   Rusted is exempt from this player-lock 1 s cap.

6. Breaking specifically because of the off-target F-time cap receives an additional
   negative reward. Off-target F-active time also has a small per-second penalty, so a
   successful policy is encouraged to use short tests rather than long blind holds.

7. The earlier player-lock efficiency model remains:
   - <=8 off-target presses is a soft goal, not a scripted action cap.
   - fewer wasted presses give a larger success bonus.
   - simulated pick wear is still randomized around the configured 6..8-ish budget.

8. The neural now explicitly knows the physical horizontal board bounds:
   - left X limit
   - right X limit
   - distance to left edge
   - distance to right edge
   - total usable X width

   These are physical limits only. Target/ramp position, ramp width, target width,
   geometry template, hidden depth, best position, or search direction are NOT given.

FREE-LEARN CONTRACT
-------------------
Agent observations:
- own X
- visible lock turn
- visible turn delta
- own F action history / persistent HOLD state
- own actual X movement
- remaining time
- visible lock type
- physical X bounds/distances

Agent does NOT receive:
- target position or target width
- ramp boundaries or hidden ramp depth
- geometry template ID
- best position
- scripted search/recover/finish states
- a list of preset hold durations

The hidden ramp remains a continuous physical gradient. The neural only experiences
that gradient through visible lock motion after a static F test.

COMMAND CENTER
--------------
The Command Center exposes these player-lock parameters for hot reload:
- soft off-target press goal
- success efficiency bonus
- randomized pick wear budget min/max
- dead/ramp tap wear
- dead/ramp hold wear per second
- maximum cumulative off-target F-active seconds (default 1.00)
- off-target F-time penalty per second
- extra penalty for breaking on the F-time cap

Lock Show now labels TAP and HOLD separately. HOLD duration is shown in milliseconds.
The trace remains vertical during F, because X is physically static during TAP/HOLD.
The red->yellow->green geometry is visible only to YOU in Command Center and is never
fed into the policy observation.

CHECKPOINT MIGRATION
--------------------
- v0.17.5 checkpoints resume directly.
- v0.17.3 bounds-aware checkpoints migrate automatically: trunk, mouse and value
  knowledge are preserved; the old F tendency is split neutrally between TAP/HOLD.
- v0.17.2 static-F checkpoints also migrate automatically. The five new X-bound inputs
  start neutral, while old trunk/mouse/value knowledge is retained.
- older pre-static-F checkpoints are not resumed because they may contain the old
  impossible move-while-F behavior.

IMPORTANT
---------
The real SCUM ramp geometry and exact durability formula are not public. The simulator
is still an editable approximation. Simulator success rate is a training metric, not a
guaranteed in-game success rate.


v0.17.5 COMMAND CENTER DATA RESET
--------------------------------
- WIPE SIMULATION DATA: removes only FREELEARN simulation checkpoint/progress/telemetry/showcase/log data. Keeps Human Teach, real-game demos, neural_smart, references and freelearn_config.json.
- WIPE ALL DATA: removes the contents of data\ and checkpoints\. Keeps program files, references and freelearn_config.json.
- Both wipes are blocked while training is running. Stop training first.
- WIPE ALL requires an extra typed confirmation: WIPE ALL.
