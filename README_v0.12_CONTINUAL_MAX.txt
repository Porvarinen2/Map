LOCKPICK LEARNER v0.12 - CONTINUAL SKILL BANK MAX
=================================================

WHAT CHANGED FROM v0.11
-----------------------
v0.11 used one immutable global champion. A challenger that learned something useful could still be discarded as a whole if another evaluation bucket became worse.

v0.12 keeps the safe global champion, but adds continual learning around it:

1) 15 separate hidden evaluation skills
   - 5 simulator difficulty levels (L0-L4)
   - target location LEFT / MID / RIGHT
   The target/ramp labels are trainer-only metadata. They are NOT included in the neural observation and therefore cannot leak the hidden target to the agent.

2) Per-skill champion archive
   A challenger can be rejected as the new global model and still become the best known specialist for one or more skills. Those weights are archived under data\neural_smart\skill_champions_v012.

3) Large RAM continual replay bank
   All simulator transitions are stored in compact float16 rings during the training session. On a ~192 GiB machine the automatic capacity is roughly 30 GiB. Successful terminal trajectories are indexed separately and replayed in balanced form across all 15 skills.
   PPO itself stays on-policy; old replay is used only as a supervised behavior-preservation auxiliary loss. This avoids pretending stale experience is valid PPO data.

4) Adaptive skill curriculum
   Training probability is based on current weakness AND the gap to the best specialist ever seen for that skill. 22% of every curriculum remains uniform rehearsal, so mastered skills never disappear completely from training.

5) Less stupid rollback
   One small bucket regression no longer vetoes all progress. Large collapses are still blocked from the global champion, while useful specialist improvements are preserved in the skill archive and replay memory.

6) Continual consolidation
   After repeated global rejects, the trainer starts from the global champion and consolidates balanced successful replay plus targeted Bayesian-teacher data for weak/forgotten skills. The consolidated model must still pass the deterministic suite before replacing the global champion.

7) Faster simulator hot paths
   - Bayesian teacher planner is vectorized (v0.11 had a Python loop over every parallel environment).
   - F-hold lookup is vectorized.
   - CPU parallelism is autotuned at startup: it benchmarks multiple environment counts and chooses the largest configuration within 97% of best measured throughput.
   - HIGH process priority + all logical CPU affinity on Windows (never REALTIME priority).

8) Existing v0.11 learning is compatible
   Neural observation size, action space and network architecture were intentionally kept checkpoint-compatible. smart_max_champion.pt and the old elite bank continue to work.

HOW TO RUN
----------
1. Run SETUP_NEURAL.bat if dependencies are not installed.
2. Run MAX_OFFLINE_TRAIN.bat and choose minutes.
3. Game does not need to be open.
4. Ctrl+C is safe: accepted global/per-skill checkpoints are written immediately.
5. After offline training: START_SMART.bat -> REAL EVALUATE.

LOG FORMAT
----------
Each Lx value is shown as:
  L4: 42.5%[LEFT/MID/RIGHT]

Decision meanings:
  ACCEPT       = candidate became the new global champion.
  SPECIALIST   = global champion unchanged, but candidate set one or more per-skill records.
  REJECT       = no useful new record and global gate failed.
  TRUST-REJECT = PPO itself crossed a hard trust-region limit; update was atomically reverted.

IMPORTANT
---------
Simulator performance is not real-game performance. The simulator is based on the PDF feedback model and domain randomization. Real EVALUATE remains the final benchmark.
