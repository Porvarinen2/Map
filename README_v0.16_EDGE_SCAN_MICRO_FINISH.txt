LOCKPICK LEARNER v0.16 - EDGE-FOCUSED PLAYER SCAN + MICRO-FINISH

Built on v0.15.1, so the SUCCESS/Human Teach hotfix remains included.

LIVE CHANGES
- Basic / Medium / Enforced: hard live search domain 0.00..0.50 (left half only).
- Player-lock scan gaps reduced to ~0.050..0.060 of full mouse range.
- Player ramp confirmation uses a much smaller +0.008 nudge and lower strong-confirm threshold.
- Player local ramp search is bounded tightly around the best response.
- Rusted: full 0.00..1.00 range, coarse ~0.105..0.145 strides, then finer rescans.
- No artificial probe-count limit. Attempt ends on SUCCESS / real time / minigame ending.
- Finish logic: confirmed strong basin -> tiny MICRO bracket -> COMMIT long F hold at best position.
- Player micro offsets are tiny (0.0025) to avoid jumping across a steep/narrow target.
- Rusted gets a slightly wider micro bracket and enough time to sweep the full range.
- Existing v0.12-v0.15 neural checkpoints remain compatible; this package does NOT include data/ or overwrite your active config file.

IMPORTANT
This update changes live control geometry only. The offline simulator target distribution is intentionally not rewritten yet. After you record clean v0.16 Human Teach demonstrations with verified SUCCESS labels, fit the simulator profile from those real examples before doing the next transfer-focused training revision.
