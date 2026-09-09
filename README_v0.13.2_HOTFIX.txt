LOCKPICK LEARNER v0.13.2 - STUCK F12/F10 RELEASE HOTFIX

WHY THIS EXISTS
---------------
v0.13 had a function-name collision: the function that was supposed to READ
F12/F10 state was overwritten by a function that SENT a key-down event.
That build could therefore leave F12 and/or F10 logically held down in Windows.

v0.13.1 fixed the collision, but an already-stuck F12 state from the previous
build could still be detected immediately, causing REAL EVALUATE to exit with:
[F12] Emergency stop.

v0.13.2 FIX
-----------
- Sends safe KEYUP events for F12 and F10 once at startup.
- Debounces/arms F12 only after an UP state has been observed.
- F12 emergency stop now requires a NEW press after live mode starts.
- F10 uses the same stale-state protection.
- Does not change the neural architecture, action space, checkpoints or training.
- Existing v0.12/v0.13 champion/data files remain compatible.

INSTALL
-------
Extract this UPDATE ONLY zip over the existing C:\Lockpick folder and replace
files. Do NOT delete data/. Start START_SMART.bat again.

On startup you should see something like:
[HOTKEY] stale F12/F10 state cleared | F12=up F10=up

Then REAL EVALUATE should continue into SMART attempt 1 instead of stopping.
