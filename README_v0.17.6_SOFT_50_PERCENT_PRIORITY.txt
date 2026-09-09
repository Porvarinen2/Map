LOCKPICK v0.17.6 FREELEARN – SOFT 50% PLAYER-LOCK PRIORITY

WHAT CHANGED

- Basic / Medium / Enforced now use the FULL physical horizontal search range X=0..1.
- The first 50% from the left is a SOFT preferred first-pass region, NOT a hard movement limit.
- A player-lock success while neural X is inside that preferred region gets an extra terminal reward.
- Success outside the preferred region still receives the full normal success reward + F-efficiency reward.
- No penalty is added merely for crossing 50%. If the target/ramp is not found in the first half, the neural is free to continue across the rest of the lock.
- Target positions remain sampled across the full 0..1 range, so the simulator does not cheat by placing player-lock targets only in the preferred half.
- Existing v0.17.5 FREELEARN checkpoints are compatible and resume normally. No wipe is required for this update.

DEFAULT SOFT PRIORITY

Preferred first-pass X: 50%
Preferred-zone success bonus: +2.0

The Command Center exposes both values under PLAYER LOCK F ECONOMY. The 50% boundary is also drawn as a cyan dashed marker in player-lock visualizations.

WHY THIS IS SOFT

The neural still receives only the physical X bounds, visible turn/turn-delta, its own F state/history, its own X movement, remaining time, and visible lock type. It is NOT told where the target or ramp is. The extra reward simply makes a successful first-half search more valuable, encouraging finer early probing while preserving the ability to search the second half when needed.

UNCHANGED PHYSICS

- F TAP and F HOLD are separate neural choices.
- While F is active, X is static; no scan-while-holding-F is possible.
- Player-lock off-target F wear / cumulative F-time rules remain enabled.
- F-efficiency reward still favors fewer off-target presses on successful attempts.
- Rusted does not use the soft 50% player-lock success bonus.

INSTALL

1. STOP training.
2. Close LockpickCommandCenter.exe so Windows releases the files.
3. Copy this update into the Lockpick project root and replace the included files.
4. Start Command Center again.

No simulation-data wipe is needed.
