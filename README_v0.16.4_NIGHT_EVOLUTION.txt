LOCKPICK LEARNER v0.16.4 - NIGHT EVOLUTION / PLATEAU ESCAPE
============================================================

PURPOSE
-------
v0.16.3 fixed simulator geometry. The first clean narrow-geometry run improved fast,
then plateaued around the mid-20% global score while LR decayed and repeated
consolidation attempts regressed the main model. v0.16.4 is designed specifically
for long 9-hour unattended simulation runs.

WHAT CHANGED
------------
1) NIGHT EVOLUTION MODE
   - Automatically enables for runs >= 180 minutes.
   - NIGHT_9H_TRAIN.bat runs exactly 540 minutes with the mode forced ON.

2) PLATEAU DETECTOR
   - Tracks challengers since the last global improvement independently of normal
     reject/consolidation counters.
   - After 12 challengers without a new global champion, launches a three-branch
     escape tournament instead of allowing LR to decay forever.

3) THREE SAFE CREATIVE ESCAPE BRANCHES
   FRONTIER
   - LR restart, higher entropy, learnable-frontier curriculum.

   BOLD-NOVELTY
   - Higher entropy and a tiny evolutionary mutation of ONLY the movement/F-hold
     actor heads. Body and critic are not randomly destroyed.
   - Hard PPO KL rollback remains active.

   SPECIALIST CROSSOVER
   - If a per-skill specialist has learned something the global champion has not,
     18% of that specialist's actor-head direction is blended into a fresh global
     branch before PPO.
   - This is a crossover candidate only; it cannot overwrite the champion directly.

4) IMMUTABLE GLOBAL SAFETY
   - Every escape branch starts from smart_max_champion.pt.
   - Rejected branches can add specialist/replay knowledge but cannot replace the
     global champion.
   - After a failed escape, global is restored and LR is restarted for a new path.

5) FRESH-SEED HOLDOUT GATE
   - During NIGHT mode, a candidate that passes the normal fixed 15-skill gate is
     also tested on a fresh unseen seed set.
   - A model that only gets better on the fixed evaluation set is rejected.

6) LEARNABLE-FRONTIER CURRICULUM
   - Does not spend the whole night only on the absolute hardest near-zero-success
     buckets.
   - Prioritizes skills around the current learning frontier, weak skills and useful
     specialist gaps, while retaining uniform rehearsal of all 15 skills.

7) GENTLER NIGHT CONSOLIDATION
   - The old replay + targeted-teacher consolidation repeatedly lost several global
     points under the new narrow geometry.
   - NIGHT mode now uses a smaller replay-only rehearsal pass. The big Bayesian
     teacher remains for fresh bootstrap, not repeated plateau forcing.

8) CRASH RESILIENCE
   - Global and per-skill checkpoints are still saved continuously.
   - Balanced elite replay is additionally persisted every 25 normal challengers
     and immediately after every plateau escape tournament.
   - data/audit/night_evolution_v0164.json records current night-run progress.

9) LR RESTARTS
   - Normal learning may anneal as before, but NIGHT mode prevents it from becoming
     permanently trapped at a tiny LR.
   - Plateau escapes restart LR into a useful exploration range while hard trust
     region checks remain intact.

GEOMETRY
--------
This update DOES NOT loosen or refit the safe v0.16.3 hidden geometry.
SIM_GEOMETRY_VERSION remains unchanged. Human Teach still cannot infer hidden
ramp/target widths.

9 HOUR USE
----------
1. Install over C:\Lockpick.
2. Keep your current data/, Human Teach demos and champion checkpoints.
3. Run NIGHT_9H_TRAIN.bat.
4. SCUM does not need to be open for this simulation run.
5. In the console confirm:
      LOCKPICK v0.16.4 NIGHT EVOLUTION
      Night evolution : ON
      geometry=LOCKED SAFE PRIORS
6. During a plateau you should eventually see:
      [NIGHT ESCAPE] plateau detected
      [NIGHT ESCAPE 1/3] FRONTIER
      [NIGHT ESCAPE 2/3] BOLD-NOVELTY
      [NIGHT ESCAPE 3/3] CROSSOVER-...
   followed by either NIGHT ESCAPE ACCEPT or NIGHT ESCAPE MISS.

INSTALL SAFETY
--------------
UPDATE ONLY. The package intentionally contains NO data/ directory and NO active
config_neural_smart.json. It does not wipe Human Teach data or model checkpoints.
