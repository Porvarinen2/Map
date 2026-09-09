LOCKPICK LEARNER v0.8 MAX - SMART MEMORY + OFFLINE SIM TRAINING
================================================================

WHAT THIS VERSION CHANGES
-------------------------
v0.8 MAX is a new SMART policy generation. It keeps the robust screen detector,
SUCCESS detector and Windows input layer from the older versions, but replaces
the old discrete +/-0.120 neural movement model with a continuous absolute
search policy and explicit working memory.

The main goal is: train very aggressively WITHOUT the game running, then take
that policy into the real lockpick minigame for deterministic evaluation and
small real-world adaptation.

FASTEST FIRST RUN
-----------------
1. Run SETUP_NEURAL.bat once.
2. Run MAX_OFFLINE_TRAIN.bat.
3. Enter e.g. 30 or 60 minutes.
4. The game does NOT need to be open.
5. After offline training, run START_SMART.bat -> REAL EVALUATE.
6. If real performance is weaker than simulation, use SMART HUMAN TEACH for
   more real examples, then run MAX_OFFLINE_TRAIN.bat again.

MAX_OFFLINE_60MIN.bat is a one-click 60 minute version.
Ctrl+C stops offline training safely and preserves the current/champion model.

SMART MEMORY
------------
The network does not see a single isolated probe only. Observation state now
contains 104 continuous features, including:
- current pick position and current/previous response
- response improvement / gradient
- best response ever seen in the current attempt
- BEST POSITION where that response happened
- distance from current position back to best position
- last-good position and distance to it
- furthest searched position
- previous target/movement/F hold/reward
- elapsed and remaining time
- explicit FOUND and RECOVER state
- response/best ratio
- 8-step position + response history (16 history values)
- a 64-bin Bayesian belief map over the entire lockpick search range
- belief mean, spread, entropy and peak

This directly fixes the v0.7 failure where the agent could see best=0.94, walk
away, then forget where the 0.94 response occurred.

CONTINUOUS MOVEMENT
-------------------
The actor no longer chooses only from 11 fixed deltas ending at +/-0.120.
It outputs a continuous Beta-distributed action inside a phase-specific absolute
search interval.

SEARCH:
- can jump across a large part of the whole 0..1 range
- cannot get trapped walking left from the left endpoint

RAMP/NEAR/TARGET:
- automatically narrows around remembered best_position
- can make tiny corrections when useful

RECOVER:
- if response collapses after a strong best response, the allowed action region
  explicitly moves back around best_position

This makes large human search movements representable instead of clipping them
all to +0.120.

SMART HUMAN TEACH
-----------------
SMART HUMAN TEACH records:
- the previously missing left-endpoint -> FIRST PROBE action
- every F probe position
- exact F key-down/key-up duration
- response/best response
- SUCCESS/FAIL/INCOMPLETE episode labels
- high-rate (~100 Hz target) visual/input trajectory stream for system ID/debug

Successes are strongly positive examples. Helpful parts of failed attempts are
also positive examples. Harmful/final fail actions can be negative examples.
The network uses continuous target positions rather than forcing human motion
into the old 11-action bins.

OFFLINE SIMULATOR
-----------------
The game is not required for simulator training.

The vector simulator randomizes:
- target center across the whole lock range
- left/right ramp width and asymmetry
- target width
- response curve shape
- dead-zone baseline response
- visual/measurement noise
- movement error
- attempt time budget
- F-hold requirement on harder locks
- difficulty/curriculum level

FIT SIM PROFILE reads the real human demo CSVs and estimates the real vision
baseline, meaningful-response threshold, ramp/target scale, attempt time and
probe rhythm. Domain randomization then varies around those estimates instead
of pretending the estimates are exact.

BAYESIAN TEACHER
----------------
Before PPO, MAX OFFLINE runs millions of streamed teacher transitions. The
teacher is NOT allowed to read the simulator's hidden target location. It only
uses visible response history, best_position and the same belief map available
to the neural agent.

This gives the neural network a strong search/recover prior before it starts
reinforcement-learning exploration.

MAX OFFLINE CPU/RAM MODE
------------------------
MAX_OFFLINE_TRAIN.bat sets aggressive CPU thread-pool variables before Python
starts. The trainer then auto-detects logical CPU count and total RAM and sizes:
- PyTorch CPU threads
- vector environment count
- rollout length
- PPO minibatch
- teacher-stream size
- evaluation batch size

On a high-core / high-RAM machine the trainer may use tens of thousands of
parallel simulated locks and hundreds of thousands to millions of transitions
per PPO update. This intentionally keeps large batches resident in RAM so the
CPU is kept fed instead of spending wall-clock time on tiny batches.

Windows process priority is raised to HIGH (not REALTIME).
The resource planner prioritizes training throughput; it does not allocate RAM
just to make the RAM usage number look bigger.

PPO + ANTI-COLLAPSE
-------------------
After teacher/human distillation, offline training uses on-policy PPO with:
- GAE
- clipped PPO objective
- value function
- entropy schedule
- gradient clipping
- target-KL early stopping
- curriculum from easier to harder randomized locks
- periodic human rehearsal so simulator PPO does not forget real examples
- periodic Bayesian-teacher rehearsal

Every few updates the trainer evaluates a deterministic suite across ALL
curriculum difficulty levels. Hard levels get more weight, but a policy must
retain broad competence.

The best suite becomes smart_max_champion.pt.
If PPO suffers a sustained large collapse relative to the champion, the trainer
automatically restores the champion and reduces PPO learning rate. This is
intended to prevent a single bad PPO phase from destroying a good distilled
policy.

REAL GAME MODES
---------------
REAL TRAIN:
- game must be open
- SMART policy plays autonomously
- uses screen feedback, best-position memory and belief updates
- small on-policy real adaptation is enabled

REAL EVALUATE:
- deterministic neural policy
- learning OFF
- optimizer OFF
- policy hash checked for mutation
- this is the actual skill benchmark

A simulator score is NOT treated as proof of real-game skill. The simulator is
the training gym; REAL EVALUATE is the test.

FILES
-----
START.bat / START_SMART.bat
    v0.8 SMART menu

MAX_OFFLINE_TRAIN.bat
    aggressive auto-sized offline trainer; asks duration

MAX_OFFLINE_60MIN.bat
    one-click 60 minute aggressive offline trainer

offline_max_trainer.py
    CPU/RAM auto-tuning, streamed Bayesian distillation, large-batch PPO,
    all-level evaluation, champion/rollback logic

neural_lockpick_smart.py
    SMART policy, memory, belief map, human recorder, vector simulator,
    live agent and real evaluation

data/demos/
    current real human training data is included in this package

data/neural_smart/
    v0.8 checkpoints/statistics created during use

data/neural_smart/smart_max_champion.pt
    best all-level deterministic simulator suite checkpoint

OLDER VERSIONS
--------------
The v0.7 FAST neural and v0.5 classic code remain in the package as fallback
and for comparison. Their old data is not deleted.

RECOMMENDED LOOP
----------------
A) MAX OFFLINE 30-60 min
B) REAL EVALUATE 25-100 attempts
C) SMART HUMAN TEACH if transfer is weak
D) MAX OFFLINE again
E) REAL EVALUATE again

The important metric is whether deterministic REAL EVALUATE improves, not how
many simulator transitions or PPO updates happened.
