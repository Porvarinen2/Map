LOCKPICK v0.17.6.2 – FIXED PER-LOCK GEOMETRY

WHAT CHANGED
------------
The simulator no longer randomizes ramp length, target width, response curve, or turn/return timing within a lock type.
Only the hidden target CENTER/location changes between attempts. This matches the intended SCUM model: same lock type = same geometry, different position.

FIXED GEOMETRY (editor / legacy neural coordinate values)
-------------------------------------------------------
Rusted   target half-width 0.030 | ramp L/R 0.08 / 0.08 | curve 1.25 | turn 360 ms | return 150 ms
Basic    target half-width 0.008 | ramp L/R 0.04 / 0.04 | curve 1.50 | turn 285 ms | return 125 ms
Medium   target half-width 0.003 | ramp L/R 0.04 / 0.04 | curve 1.75 | turn 275 ms | return 120 ms
Enforced target half-width 0.002 | ramp L/R 0.04 / 0.04 | curve 2.00 | turn 265 ms | return 115 ms

The player-lock coordinate bridge remains unchanged: physical board 0..1, checkpoint-compatible neural coordinate 0..0.5.
F remains STATIC-X. The agent still sees no hidden ramp/target location.

INSTALL
-------
1. STOP training and close Command Center.
2. Copy/replace this update over C:\Lockpick.
3. This update intentionally REPLACES freelearn_config.json because the geometry values are the patch itself.
4. Recommended once after install: WIPE SIMULATION DATA, because older checkpoints were trained on randomized geometry. This does not require wiping Human Teach/reference data.
