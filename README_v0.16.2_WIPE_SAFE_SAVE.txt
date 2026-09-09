Lockpick Learner v0.16.2 - WIPE-SAFE HUMAN TEACH SAVE

Fixes Human Teach FileNotFoundError after data/ was manually wiped while the program/menu was already running.

Changes:
- Human Teach recreates data/demos + success/failed/incomplete + trajectory directories immediately before recording.
- Directories are recreated again immediately before final save.
- Recovery autosave is written every 10 finalized episodes into data/demos/_autosave/.
- F12 forces a recovery autosave BEFORE calibration, final archive creation, and human pretraining.
- On a normal successful save the temporary recovery file is removed.
- SUCCESS ROI detection from v0.16.1 is unchanged.
- Edge scan / micro-finish behavior from v0.16 is unchanged.

If data/ is wiped while the app is open, the next Human Teach no longer relies on directories created only at process startup.
