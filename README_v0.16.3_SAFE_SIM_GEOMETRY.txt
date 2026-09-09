LOCKPICK LEARNER v0.16.3 - SAFE SIM GEOMETRY / ANTI-BAD-FIT HOTFIX
===================================================================

WHY
---
Human Teach can observe screen response at the positions the player sampled, but it
cannot directly observe the hidden ramp edge or target edge. v0.16.2 tried to infer
hidden width from scattered probe positions. A real demo set therefore produced an
absurd ramp halfwidth around 0.165 and target halfwidth around 0.040.

v0.16.3 separates OBSERVABLE fitting from HIDDEN simulator geometry.

HUMAN DATA MAY FIT
------------------
- vision baseline / low-response statistics
- meaningful response threshold, with sanity clamps
- human probe cadence as telemetry
- Human BC movement/F-hold actions and verified SUCCESS/FAIL labels

HUMAN DATA MAY NOT FIT
----------------------
- ramp width
- target width
- player target search domain
- real game attempt duration

Those hidden values now use conservative simulation priors and hard sanity limits.
An old sim_profile.json containing ramp=0.165 or target=0.040 is sanitized on load,
so it cannot silently enter the simulator again.

SIMULATOR GEOMETRY
------------------
Half-widths are fractions of the full physical pick travel:
- L0 / Rusted: ramp 0.060..0.120, target 0.008..0.020, search 0.00..1.00
- L1 / Basic:  ramp 0.018..0.045, target 0.0035..0.0090, search 0.00..0.50
- L2 / Medium: ramp 0.015..0.036, target 0.0030..0.0075, search 0.00..0.50
- L3 / Enforced: ramp 0.012..0.030, target 0.0025..0.0060, search 0.00..0.50
- L4 / hard Enforced curriculum: ramp 0.010..0.025, target 0.0020..0.0050, search 0.00..0.50

Player ramp response curves are also steeper than Rusted. Player teacher search uses
~0.050 steps and cannot scan beyond 50%. Rusted uses ~0.110 coarse search and can
use the full range.

SKILL / REPLAY SAFETY
---------------------
- persisted replay now carries a simulator geometry version
- replay from pre-v0.16.3 geometry is ignored
- old anonymous legacy elite replay is ignored
- per-skill best-score state carries a geometry version; old scores are ignored

This prevents old wide-ramp simulator trajectories from being rehearsed after the fix.
Existing neural checkpoints remain tensor-compatible and may be evaluated as a seed,
but old simulation percentages are NOT comparable with v0.16.3 percentages.

VERIFY
------
Run SIM_GEOMETRY_SELFTEST.bat. Every level should print PASS.
When training starts, FIT output must contain:
  geometry=LOCKED SAFE PRIORS
  [GEOMETRY GUARD]
It must never print a Human-fitted ramp like 0.165 again.

INSTALL
-------
Extract this UPDATE ONLY package over C:\Lockpick.
It intentionally contains no data/ folder and does not overwrite the active config.

EXTRA CRASH / REVISION SAFETY
-----------------------------
When CONTINUAL MAX has no existing global champion, it now saves
smart_preboot_champion.pt before the first simulator teacher/bootstrap. That keeps a
pre-simulator recovery point for future geometry mistakes or trainer experiments.
