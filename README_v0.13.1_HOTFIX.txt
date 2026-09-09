LOCKPICK LEARNER v0.13.1 - LIVE INPUT SAFETY HOTFIX
====================================================

THIS IS UPDATE-ONLY. Extract over the existing Lockpick folder.
It does NOT include or replace data/, checkpoints, configs or training memory.

FIXED CRITICAL BUG #1: F12 spam
--------------------------------
v0.13 accidentally defined two different functions with the same Python name
"key_down". The later SendInput version overwrote the GetAsyncKeyState polling
version. Therefore every emergency/pause check actually PRESSED the key being
checked. Checking F12 caused F12 to be injected repeatedly.

v0.13.1 separates them:
  is_key_down(vk)     = READ physical key state only
  press_key_down(vk)  = SEND a key-down event intentionally
  key_up(vk)          = SEND key-up

Emergency checks are now read-only. F12 is never emitted by the emergency check.

FIXED CRITICAL BUG #2: wrong focused window
--------------------------------------------
The supplied log showed:
  Focused game window: Lukonavausagentin suunnittelu — Mozilla Firefox

The monitor detector correctly found the visual monitor, but the old focus code
used whatever window happened to be under the monitor centre. This could be a
browser, Discord, etc.

v0.13.1 now searches visible top-level windows for SCUM and refuses ALL live input
unless the foreground target is actually a window whose title contains "SCUM".
If SCUM cannot be found/focused, REAL TRAIN/EVALUATE abort safely instead of
sending Space/F/mouse input to another application.

The v0.12/v0.13 neural checkpoints are unchanged and remain compatible.
No offline retraining is required for this hotfix.
