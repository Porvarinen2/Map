LOCKPICK LEARNER v0.11 - STABLE CHAMPION + HOLD-TO-90
========================================================

WHY THIS UPDATE EXISTS
----------------------
v0.10 successfully learned a strong policy from HUMAN BC + the feedback-only
Bayesian teacher, but the MAX PPO stage repeatedly destroyed that competence.
The supplied real log showed a 62.9% deterministic champion followed by PPO
challengers collapsing to 30%, 20%, and sometimes about 8-10%, with KL around
0.02-0.03. v0.11 changes the training architecture so bad challengers can no
longer overwrite the best policy.

THE IMPORTANT CHANGE: CHAMPION / CHALLENGER TRAINING
----------------------------------------------------
The current best deterministic policy is an immutable CHAMPION.

Every PPO attempt now:
  1) restores the champion,
  2) creates a fresh challenger from it,
  3) collects a huge new randomized simulator rollout,
  4) performs a deliberately tiny PPO update,
  5) runs the deterministic L0-L4 suite,
  6) ACCEPTS only if suite score improves without materially damaging the
     weakest level / L4,
  7) otherwise REJECTS it and restores the champion immediately.

Therefore a sequence like
  62.9 -> 30 -> 10 -> 20
can no longer become the saved model. Bad attempts are disposable experiments.
Accepted improvements accumulate in the champion.

PPO STABILITY CHANGES
---------------------
* PPO learning rate: capped at 5e-5 in MAX mode (old MAX was up to 2e-4).
* PPO epochs: 2 instead of 5.
* PPO clip: 0.08 instead of 0.20.
* Target KL: 0.004.
* Hard KL: 0.007. Crossing it atomically reverts the entire PPO update.
* Champion KL anchor: PPO is penalized for drifting far from the proven policy.
* Gradient norm cap reduced to 0.45.
* PPO reward scale 0.05 keeps critic targets numerically sane.
* Critic uses Smooth-L1/Huber rather than raw MSE for terminal reward outliers.
* Advantages are normalized and clipped.
* Every rejected challenger gets a fresh Adam optimizer; bad optimizer momentum
  cannot leak into the next challenger.
* Learning rate automatically falls after harmful challengers and may rise only
  very slowly after accepted improvements.

NOTE ABOUT H / ENTROPY
----------------------
The movement policy is a continuous Beta distribution. Beta uses DIFFERENTIAL
entropy, which can legitimately be negative. Therefore a negative H value alone
is not a bug. v0.11 logs call it entropy_diff and focus on KL / deterministic
suite performance for stability decisions.

CRITIC-ONLY WARMUP
------------------
Before PPO challengers begin, v0.11 trains ONLY the value_head on scaled simulator
returns. Actor heads and shared policy representation are not changed in this
phase. This gives PPO a better critic before it is allowed to move the policy.

ELITE MEMORY BANK
-----------------
v0.11 creates data/neural_smart/elite_champion_bank.npz at runtime.
It contains:
* immutable actions from HUMAN SUCCESS demonstrations,
* successful trajectory tails from ACCEPTED champion challengers.

A small elite auxiliary loss is mixed into PPO so useful successful behaviour is
harder to forget. The bank is capped and stored compactly.

GUARDED TEACHER/HUMAN REHEARSAL
--------------------------------
v0.10 periodically modified the live policy with teacher rehearsal whether or not
that improved the deterministic suite. v0.11 treats rehearsal as another
challenger. It is kept only if it beats the champion; otherwise it is discarded.

EXISTING v0.10 DATA
-------------------
If data/neural_smart/smart_max_champion.pt already exists, v0.11 evaluates and
preserves it before attempting a new human/teacher bootstrap. The bootstrap is
also rejected if it is worse than the existing champion.

Old config_neural_smart.json files are automatically migrated to config_version
11 for the stability-critical PPO fields. Unrelated settings are preserved.

HOLD-TO-90 / PDF SIM RULES ARE UNCHANGED
-----------------------------------------
* 3.00 seconds is VIRTUAL game time in offline simulation; no 3-second wall wait.
* Maximum 7 wrong POSITION hits. The seventh ends the attempt.
* Ramp/target are hidden from the agent and randomized each lock.
* Short F in TARGET may under-hold; it does not count as a wrong-position hit.
* A sufficiently long F-hold in TARGET must drive the simulated lock to ~90 deg.
* Neural policy learns BOTH horizontal target position and F-hold duration.
* Hold choices: 60 / 120 / 220 / 400 / 650 / 950 / 1400 ms.

HOW TO RUN
----------
1. Extract this update over the existing Lockpick folder. The distributed ZIP
   intentionally contains no data/ folder and no live config files, so your demos,
   calibration, checkpoints and real-game data are not overwritten.
2. SETUP_NEURAL.bat only if dependencies are not already installed.
3. MAX_OFFLINE_TRAIN.bat for a chosen duration, or MAX_OFFLINE_60MIN.bat.
4. Watch CH lines. ACCEPT means the deterministic champion genuinely improved;
   REJECT means the experiment was discarded; HARD-REJECT means KL safety caught
   it before evaluation.
5. START_SMART.bat -> REAL EVALUATE is still the real-game benchmark.

A HEALTHY v0.11 LOG SHOULD LOOK MORE LIKE
------------------------------------------
CH 1 | REJECT ... KL=0.001...
CH 2 | ACCEPT +0.4pt ...
CH 3 | REJECT ...
CH 4 | ACCEPT +0.2pt ...

rather than v0.10's repeated 20-50 point collapses.

The simulator remains a theory/data-driven training environment. A high simulator
score is not proof that the same percentage transfers to SCUM; REAL EVALUATE is
the final test.
