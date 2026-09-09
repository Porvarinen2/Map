LOCKPICK LEARNER v0.5 - AUDITABLE LEARNING
============================================

This update is designed to make learning observable instead of just trusting a
counter that says "Q updates".

IMPORTANT UPDATE RULE
---------------------
Copy the v0.5 program files over your existing C:\Lockpick\ installation.
DO NOT delete or replace C:\Lockpick\data\. Your human demos, Q model,
self-play history and counters stay there and v0.5 continues from them.

NEW IN v0.5
-----------
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
2. Copy the v0.5 update files into C:\Lockpick\.
3. Start START.bat.
4. Run 6) VERIFY once to inspect the current saved model.
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
- Existing v0.4 config.json files migrate automatically; new audit settings get
  their defaults without deleting your custom settings.
- Existing model.json and demos remain compatible.
- The bundled SUCCESS detector reference files are unchanged and still used.
