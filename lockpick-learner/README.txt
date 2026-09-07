LOCKPICK LEARNER v0.8 - THE PICK COULD NOT MOVE
=================================================

Every version up to here, mine included, tuned the algorithm. The algorithm
was never the binding constraint: move_to() clipped every mouse step to +/-140
counts and allowed 8 of them, so with the recorded 6000 counts across the lock
the pick could never move more than 0.187 of the lock in one go, whatever was
asked for - and that cost 440 ms of a 3100 ms attempt. The rotation detector
was separately the source of its own noise floor.

Read UPDATE_NOTES_v0.8.txt first. v0.7's notes cover the search and the 4%
coverage bug, v0.6's cover the state key, reward and SUCCESS detection.

IMPORTANT UPDATE RULE
---------------------
Copy the v0.6 program files over your existing C:\Lockpick\ installation.
DO NOT delete or replace C:\Lockpick\data\. Your recorded human demos and
self-play episodes stay there and are still used.

One thing does NOT carry over: the learned Q values and demo priors from
v0.5 and earlier. Their state keys meant "absolute pick position", which is
meaningless now that the state is measured from the ramp. The program
notices this on startup, drops those values and tells you so. Your recorded
episodes are untouched - run 2) TRAIN and 5) SELF TRAIN once and the policy
is rebuilt from them in seconds.

NEW IN v0.6
-----------
1) SUCCESS IS ACTUALLY DETECTED
The v0.4/v0.5 template matcher scored 0.199 and 0.197 on the two real SUCCESS
screens against its own 0.62 threshold, so it never fired: no attempt was ever
credited as a success and nothing was ever learned from one. It is replaced by
two measurements that separate cleanly on real frames - a bright text band
across the middle (running 938-1216 px, SUCCESS 5126-5366 px) and the timer arc
being gone (running 4640-6373 px, SUCCESS 1 px). 8/8 correct on the reference
frames in kuvat\, with no template, no OCR and no cv2 matching.

2) THE STATE IS MEASURED FROM THE RAMP
The target is redrawn on every attempt, so "position 0.62 was good" teaches
nothing about the next lock. The distance from the ramp to the opening point
is a property of the lock type, so that is what the state now encodes. Two
identical attempts whose ramps sit at 0.22 and 0.71 used to land in disjoint
state bins (3/4 versus 11/12) and share no learning at all; they now produce
exactly the same states.

3) EACH PROBE PAYS FOR ITS OWN TIME
v0.5 charged every probe the elapsed time of the whole attempt, so the same
action looked worse purely for happening later. Each probe is now charged only
for its own duration.

4) EVERYTHING FROM A SUCCESSFUL ATTEMPT IS KEPT
Every confirmed success - yours in OBSERVE and the agent's own - writes its
full probe-by-probe trace to data\successes\ and a summary row to
data\successes.csv: where the ramp was, how far past it the lock opened, how
long it took, how many probes. After three successes the median ramp-to-opening
distance is used: when the agent finds a ramp it jumps straight to where locks
have opened before instead of creeping there one microstep at a time.

5) OFFLINE TESTS
  python testit.py    (or Testit.bat)
Runs without Windows, without the game and without cv2/mss. It checks SUCCESS
detection against the real frames, that the state key is ramp-relative, that
the time penalty is per-probe, the learned distance, the saving, and that two
human attempts with the same shape teach the same states.

NEW IN v0.5 (still here)
------------------------
1) DECISION AUDIT
Every model-driven AGENT decision can be written to:
  data\audit\decisions.csv

For each decision it records, among other things:
- detected model state
- Q value of the chosen action
- human-demo prior value
- combined learned score
- top candidate actions
- whether the choice came from learned argmax or epsilon exploration
- whether the built-in search/ramp constraint overrode the model recommendation
- chosen action + mouse delta
- reward observed after the action
- Q value before and after the online update
- next state
- policy hash

This is the direct trace:
  screen state -> learned values -> chosen action -> game response -> reward -> Q change

2) MODEL HASH + TRAIN SNAPSHOTS
TRAIN and SELF TRAIN calculate a SHA-256 policy hash before and after training.
They also count exactly how many learned states and individual values changed.
Snapshots are saved under:
  data\audit\snapshots\

Training run summaries are appended to:
  data\audit\training_runs.csv

If new training data changes the policy, the before/after hashes should differ.
Repeated TRAIN on identical already-learned data may correctly show zero changes.

3) VERIFY LEARNING
Menu option:
  6) VERIFY

VERIFY is offline; it does not touch the game. It checks:
- model save/reload produces the same policy hash
- deterministic epsilon=0 lookup always returns the actual argmax of Q + demo prior
- repeated calls for the same state return the same action
- ablation sensitivity: how many decisions change versus a blank model
- agreement with clean successful human demonstration transitions
- agreement with the final 40% of successful human trajectories
- whether failed terminal human actions are now avoided
- whether audited TRAIN / SELF TRAIN runs actually changed policy values

A text + JSON report is saved under:
  data\audit\verify\

VERIFY proves the software is loading and using learned values. It cannot prove
that every unseen future lock will open; use EVALUATE for real game performance.

4) DETERMINISTIC EVALUATION
Menu option:
  7) EVALUATE

EVALUATE runs the autonomous player with:
- epsilon = 0
- deterministic policy
- Q learning OFF
- replay OFF
- model mutation OFF

The model's policy hash, Q update count and epsilon are checked before/after the
run. A clean evaluation should print PASS and leave all three unchanged.

Evaluation episodes are stored separately under:
  data\evaluation\successful\
  data\evaluation\failed\

They are NOT used for training automatically. This keeps the benchmark clean.

5) LEARNING CURVES IN STATS
Menu option:
  9) STATS

STATS now shows recent 25 / 50 / 100 episode windows when enough history exists:
- success rate
- average best lock response
- average episode reward
- average stored transitions
- average successful unlock time

It reports self-play learning runs and deterministic evaluation runs separately.
That distinction matters: self-play can improve while it is exploring/training;
EVALUATE shows what the already-learned deterministic policy can actually do.

6) HUMAN + SELF TRAINING REMAIN ACTIVE
OBSERVE still stores successful AND failed human attempts.
TRAIN strongly emphasizes clean successful episodes while retaining useful and
negative evidence from failures.

AGENT still learns online after its actions and stores autonomous successes and
failures for replay. SELF TRAIN can replay the stored autonomous history later.

RECOMMENDED WORKFLOW
--------------------
1. Keep your old C:\Lockpick\data\ folder.
2. Copy the v0.6 update files into C:\Lockpick\.
3. Start START.bat. It will tell you it dropped the old learned values.
4. Run 2) TRAIN and then 5) SELF TRAIN once to rebuild the policy from the
   demos and self-play episodes you already have, then 6) VERIFY to inspect it.
5. Run 1) OBSERVE and play more attempts yourself if you want more human data.
6. Run 2) TRAIN.
   Check the before/after policy hash and changed values.
7. Run 4) AGENT to let it learn by self-play.
8. Run 5) SELF TRAIN after you have accumulated autonomous history.
9. Run 7) EVALUATE for e.g. 25-100 attempts.
10. Run 9) STATS and compare deterministic evaluation over time.

HOW TO READ AGENT OUTPUT
------------------------
AGENT now prints a source tag for model decisions:
  src=LEARNED   -> deterministic/greedy learned preference was used
  src=EXPLORE   -> epsilon exploration intentionally picked a trial action
  src=OVERRIDE  -> the model recommended something outside the current phase
                   constraint and the search/ramp safety rule adjusted it

The complete evidence is in data\audit\decisions.csv.

HOTKEYS
-------
F12 = emergency stop
F10 = hold to pause

NOTES
-----
- Existing config.json files migrate automatically; new settings get their
  defaults without deleting your custom settings. The old success_template_*
  keys are simply ignored.
- Existing demos and self-play episodes remain compatible and are re-used.
  Learned Q values from v0.5 and earlier are dropped once, on first startup.
- refs\success_text_template.png is gone; nothing matches a template any more.

TUNING SUCCESS DETECTION
------------------------
Run 8) VISION DEBUG with the lock open. It prints the two raw numbers live:
  band=  1122/2500  arc= 5717/800  success=0.000
band is the bright text, arc is the countdown ring. On the SUCCESS screen band
jumps above 5000 and arc drops to nearly zero. If your resolution or UI scale
shifts those numbers, change success_band_pixels and success_arc_max in
config.json to sit between what you see running and what you see on SUCCESS.
Nothing else needs touching.
