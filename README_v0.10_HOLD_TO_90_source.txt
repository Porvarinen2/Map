LOCKPICK LEARNER v0.10 - HOLD-TO-90 SIM + SMART MEMORY
==========================================================

WHAT CHANGED
------------
v0.10 adds F-hold as a real learned control. A quick tap can reveal a wobble/ramp,
but it cannot magically open TARGET. In the simulator, horizontal position sets
the maximum turn angle the lock is capable of reaching, while F-hold duration
controls how deeply the lock actually turns toward that angle.

Core physical abstraction:
  dead zone -> turn cap ~0 deg
  ramp      -> partial turn cap; holding longer reaches the jam angle but NEVER 90 deg
  target    -> full 90 deg cap; a sufficiently long hold reaches 90 and opens

Therefore:
  short F at TARGET = correct position but UNDER-HOLD, no success yet
  long F at TARGET  = reaches ~90 deg -> SUCCESS
  F at wrong position = consumes one of the 7 wrong-position hits

The exact real-game millisecond curve is not claimed as known. The simulator
domain-randomizes turn speed so the neural policy learns the general skill
"tap to probe, hold to finish" instead of memorizing one magic duration.

RULES
-----
* Virtual/in-game attempt budget: 3.00 seconds minimum.
* Headless simulator does NOT sleep for 3 real seconds. Hold/movement consume a
  virtual 3-second budget while thousands of environments run in parallel.
* Maximum wrong POSITION hits: 7. The 7th wrong-position F ends the attempt.
* TARGET + too-short hold is an under-hold, not a wrong-position miss; it costs time.
* Ramp and target location/width are hidden from the agent and randomized.
* Debug rendering may reveal them to the human, but they are never included in obs().

NEURAL F-HOLD ACTIONS
---------------------
The neural policy currently chooses one of these hold durations:
  60, 120, 220, 400, 650, 950, 1400 ms

SEARCH should naturally learn short taps because long holds waste the 3-second
budget. Near TARGET it can escalate to a long hold to drive the lock to 90 degrees.
The PPO action space learns BOTH position and hold duration.

MEMORY
------
The observation has 112 features and includes:
* current + previous response
* best response + exact best position
* last-good position
* recover state when response falls after a good point
* furthest searched position
* previous movement/reward/hold
* 8-probe position history
* 8-probe response history
* 8-probe F-hold-depth history
* 64-bin Bayesian belief map of likely target location

SIMULATOR HOLD MODEL
--------------------
Each hidden lock randomizes a turn-speed constant. Visible turn is approximately:
  spatial turn cap x hold-depth fraction

Hold-depth approaches 1 as F is held longer. TARGET has cap=1.0, ramps have a
cap below 1.0. Thus a ramp can jam strongly but cannot be held all the way to 90.
Success is based on the underlying physical turn reaching ~95.5% of the 90-degree
travel, not on noisy rendered/vision response.

The turn-speed domain is deliberately randomized rather than pretending we know
SCUM's exact millisecond formula. SMART HUMAN TEACH records real F down/up timing,
so future profile fitting can narrow these ranges from real data.

2D SIMULATOR
------------
SIM_PLAY_2D.bat
  Move the mouse horizontally. PRESS AND HOLD F; releasing F executes the probe.
  A tap should only turn shallowly. Hold longer near TARGET to reach 90 degrees.

SIM_DEBUG_2D.bat
  Same simulator but reveals hidden ramp/target for developer inspection only.

SIM_AGENT_WATCH.bat
  Watch the deterministic neural policy choose position + F hold.

SIM_AGENT_WATCH_DEBUG.bat
  Same, with hidden geometry visible to you. The agent still does not receive it.

SIM_HEADLESS_BENCH.bat
  Fast non-rendered benchmark.

OFFLINE TRAINING
----------------
MAX_OFFLINE_TRAIN.bat
  Aggressive CPU/RAM training with no game required.

MAX_OFFLINE_60MIN.bat
  Same idea, configured for a long unattended run.

The training teacher itself does not read hidden target coordinates. It performs a
coarse left-to-right probe search, remembers feedback, recovers toward best-position,
and progressively increases F-hold when the visible turn gets stronger. In a sanity
check of the HOLD-TO-90 simulator this feedback-only teacher solved ~90% of level-1
random locks, proving the synthetic task is learnable without target leakage.

REAL GAME
---------
START_SMART.bat
  SMART HUMAN TEACH can record your exact F press/release durations.
  REAL TRAIN lets the neural agent adapt on-policy in-game.
  REAL EVALUATE is the actual benchmark and disables learning.

IMPORTANT
---------
Offline simulator success is NOT proof of real-game skill. The simulator implements
the PDF theory plus the user's clarification that a tap does not turn deeply enough
and a sustained F-hold is required to reach 90 degrees in TARGET. Exact timing and
response curves must still be validated against real-game recordings.

Existing human demo CSVs remain useful. Because v0.10 changes the hold action space
and observation dimension, older v0.9 neural checkpoints are intentionally treated
as incompatible and moved aside on first run; demos/classic data are not deleted.
