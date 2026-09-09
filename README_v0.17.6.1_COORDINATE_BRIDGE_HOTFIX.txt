LOCKPICK v0.17.6.1 – PLAYER-LOCK COORDINATE BRIDGE HOTFIX

WHY THIS EXISTS
----------------
v0.17.6 changed Basic/Medium/Enforced from the old internal 0..0.5 board to a literal 0..1 board.
That unintentionally changed THREE things at once:
1) existing checkpoints saw a different coordinate/boundary distribution,
2) the same configured target/ramp widths became visually and physically half as wide relative to the board,
3) old player-lock movement semantics no longer matched the trained policy.
That is why player-lock success could collapse even though Rusted stayed excellent.

FIX
---
- Physical board is still truly 0..1 for every lock. There is NO hard 50% movement limit.
- Player-lock neural coordinates remain checkpoint-compatible with the old 0..0.5 representation.
- Mouse deltas are converted between neural and physical coordinates.
- Player target/ramp widths are converted by the same factor (default x2), restoring their pre-v0.17.6 relative size on the full board.
- The 50% preferred-zone success bonus remains based on PHYSICAL X.
- Target/ramp location is still hidden from the neural.
- F remains static-X: no mouse movement while TAP/HOLD is active.

INSTALL
-------
Stop training and close Command Center before replacing files.
This update intentionally DOES NOT include freelearn_config.json, so your current geometry/economy settings are not overwritten.
No simulation-data wipe is required. Existing compatible checkpoints load normally.
