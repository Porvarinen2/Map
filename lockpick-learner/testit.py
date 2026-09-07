# -*- coding: utf-8 -*-
"""Offline tests for the parts that decide whether this thing can learn.

Runs without Windows, without a game and without cv2/mss: every test is
measured against the real 1080p gameplay frames in kuvat\\ or against pure
logic. Run it with:  python testit.py
"""
from __future__ import annotations

import shutil
import sys
import tempfile
import types
from pathlib import Path

import numpy as np

# The learner imports cv2/mss for live capture. None of that is needed to
# test the maths, so stub them out before importing.
for name in ("cv2", "mss"):
    if name not in sys.modules:
        sys.modules[name] = types.ModuleType(name)

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import lockpick_learner as LL  # noqa: E402

KUVAT = ROOT / "kuvat"
virheet = []


def vaita(ehto: bool, teksti: str) -> None:
    print(f"  {'OK  ' if ehto else 'FAIL'}  {teksti}")
    if not ehto:
        virheet.append(teksti)


def lataa_rajaus(polku: Path, cfg: LL.Config):
    """Crops a full screenshot exactly the way ScreenVision would."""
    from PIL import Image
    rgb = np.asarray(Image.open(polku).convert("RGB"))
    H, W = rgb.shape[:2]
    bgr = rgb[:, :, ::-1].copy()
    half = max(260, int(min(W, H) * cfg.capture_half_size_ratio))
    half = min(half, max(150, int(min(W, H) * 0.46)))
    cy, cx = H // 2, W // 2
    return bgr[cy - half:cy + half, cx - half:cx + half], H, half


def nakija(cfg: LL.Config, korkeus: int, half: int) -> LL.ScreenVision:
    """A ScreenVision with only the fields detect_success needs."""
    v = LL.ScreenVision.__new__(LL.ScreenVision)
    v.cfg = cfg
    v.height = korkeus
    v.half = half
    v._arc_mask = None
    v.last_success_parts = (0, 0)
    return v


def testi_success(cfg: LL.Config) -> None:
    print("\n1) SUCCESS detection against real gameplay frames")
    kuvat = sorted(KUVAT.glob("*.jpg"))
    if not kuvat:
        vaita(False, "kuvat/ is empty")
        return
    oikein = 0
    for p in kuvat:
        frame, korkeus, half = lataa_rajaus(p, cfg)
        v = nakija(cfg, korkeus, half)
        score, ok = v.detect_success(frame)
        band, arc = v.last_success_parts
        odotus = p.name.startswith("success")
        oikein += int(ok == odotus)
        merkki = "OK  " if ok == odotus else "FAIL"
        print(f"  {merkki}  {p.name:18s} band={band:5d} arc={arc:5d} score={score:.3f} "
              f"-> {'SUCCESS' if ok else 'running':7s} (expected {'SUCCESS' if odotus else 'running'})")
    vaita(oikein == len(kuvat), f"all {len(kuvat)} frames classified correctly ({oikein}/{len(kuvat)})")


def testi_tila_avain(cfg: LL.Config) -> None:
    print("\n2) State key is measured from the ramp, not from the lock's left edge")
    m = LL.QModel.__new__(LL.QModel)
    m.cfg = cfg
    # The same situation - 0.03 past the ramp - at three very different
    # absolute positions has to produce the same state.
    avaimet = {m.state_key(pos + 0.03, 0.30, 0.30, 1, True, pos) for pos in (0.10, 0.50, 0.88)}
    print(f"  keys: {sorted(avaimet)}")
    vaita(len(avaimet) == 1, "same distance past the ramp -> one state, wherever the ramp is")

    # Different distances past the ramp must still separate.
    a = m.state_key(0.50, 0.30, 0.30, 1, True, 0.50)
    b = m.state_key(0.62, 0.30, 0.30, 1, True, 0.50)
    vaita(a != b, f"different distances past the ramp -> different states ({a} vs {b})")

    # Before a ramp is found there is nothing to measure from: one search state.
    haku = {m.state_key(pos, 0.0, 0.0, 0, False, None) for pos in (0.05, 0.40, 0.95)}
    vaita(len(haku) == 1, f"searching is one state, not 16 ({sorted(haku)})")


def testi_palkkio(cfg: LL.Config) -> None:
    print("\n3) Time penalty charges each probe for its own time only")
    r = LL.RewardEngine(cfg)
    # Two identical probes, one early and one late in the attempt, each taking
    # 0.2 s. They must be rewarded the same.
    aikainen = r.step(0.30, 0.20, 0.20, 0.2)
    myohainen = r.step(0.30, 0.20, 0.20, 0.2)
    vaita(abs(aikainen - myohainen) < 1e-9, f"same probe, same reward ({aikainen:.3f} vs {myohainen:.3f})")
    # A slower probe must still cost more than a fast one.
    hidas = r.step(0.30, 0.20, 0.20, 1.0)
    vaita(hidas < aikainen, f"a slower probe costs more ({hidas:.3f} < {aikainen:.3f})")


def testi_etaisyys(cfg: LL.Config) -> None:
    print("\n4) Learned ramp -> opening distance")
    m = LL.QModel.__new__(LL.QModel)
    m.cfg = cfg
    m.success_offsets = []
    vaita(m.learned_offset() is None, "nothing is claimed before enough successes")
    for ramp, avaus in ((0.20, 0.31), (0.55, 0.67), (0.71, 0.83)):
        m.note_success(ramp, avaus)
    off = m.learned_offset()
    print(f"  offsets={[round(x,3) for x in m.success_offsets]} -> median {off:.3f}")
    vaita(off is not None and abs(off - 0.12) < 0.011, f"median of the real distances ({off})")
    m.note_success(None, 0.5)
    m.note_success(0.1, 9.9)
    vaita(len(m.success_offsets) == 3, "junk offsets are rejected")


def testi_tallennus(cfg: LL.Config) -> None:
    print("\n5) Everything from a successful attempt is saved")
    tmp = Path(tempfile.mkdtemp())
    vanha_dir, vanha_idx = LL.SUCCESS_DIR, LL.SUCCESS_INDEX
    LL.SUCCESS_DIR, LL.SUCCESS_INDEX = tmp / "successes", tmp / "successes.csv"
    LL.SUCCESS_DIR.mkdir(parents=True, exist_ok=True)
    try:
        jalki = [{"state": "1:2:3:4:1", "action": 7, "delta": 0.022, "reward": 1.5,
                  "pick": 0.51, "response": 0.30, "best": 0.30}]
        LL.save_success(jalki, {"source": "AGENT", "elapsed": 2.1, "probes": 6, "pick": 0.63,
                                "ramp_pos": 0.51, "offset": 0.12, "best": 0.94,
                                "reward": 120.0, "score": 0.99, "note": "test"})
        tiedostot = list(LL.SUCCESS_DIR.glob("success_*.csv"))
        vaita(len(tiedostot) == 1, "the probe-by-probe trace is written")
        vaita(LL.SUCCESS_INDEX.exists(), "successes.csv summary row is written")
        teksti = LL.SUCCESS_INDEX.read_text(encoding="utf-8")
        vaita("ramp_pos" in teksti and "0.12" in teksti, "the ramp and the distance past it are in the summary")
    finally:
        LL.SUCCESS_DIR, LL.SUCCESS_INDEX = vanha_dir, vanha_idx
        shutil.rmtree(tmp, ignore_errors=True)


def testi_hyppy(cfg: LL.Config) -> None:
    print("\n6) Once a lock has been opened a few times, the ramp is not re-crawled")
    m = LL.QModel.__new__(LL.QModel)
    m.cfg = cfg
    m.success_offsets = [0.11, 0.12, 0.13]
    learned = m.learned_offset()
    ramp_pos, pos = 0.44, 0.44
    delta = float(np.clip((ramp_pos + learned) - pos, -0.20, 0.20))
    action = LL.nearest_action(cfg, delta)
    askel = cfg.action_steps[action]
    print(f"  ramp at {ramp_pos:.2f}, learned distance {learned:+.3f} -> one step of {askel:+.3f}")
    vaita(askel > 0.05, f"the jump is a real move, not a microstep ({askel:+.3f})")
    vaita(abs((pos + askel) - (ramp_pos + learned)) < 0.05, "it lands near where past locks opened")


def testi_demo_opetus(cfg: LL.Config) -> None:
    print("\n7) Two human attempts with the same shape teach the same states")
    tmp = Path(tempfile.mkdtemp())
    vanha = LL.DEMO_DIR
    LL.DEMO_DIR = tmp
    try:
        import csv
        # The same attempt twice: ramp found, then +0.02, +0.02, open.
        # Only the absolute position of the ramp differs.
        for eid, ramp in enumerate((0.22, 0.71)):
            polku = tmp / f"demo_{eid}.csv"
            head = ["pick_pos", "response", "prev_response", "best_before", "episode_id",
                    "episode_success", "episode_elapsed", "elapsed"]
            with polku.open("w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=head)
                w.writeheader()
                vaste = [0.00, 0.08, 0.22, 0.45]
                for i, r in enumerate(vaste):
                    w.writerow({
                        "pick_pos": ramp + 0.02 * i, "response": r,
                        "prev_response": vaste[i - 1] if i else 0.0,
                        "best_before": max(vaste[:i]) if i else 0.0,
                        "episode_id": 0, "episode_success": 1,
                        "episode_elapsed": 2.4, "elapsed": 0.6 * i,
                    })
        rec = LL._demo_transition_records(cfg, _malli(cfg))
        eka = [r["state"] for r in rec if r["state"]][:3]
        toka = [r["state"] for r in rec][3:6]
        print(f"  ramp at 0.22 -> {eka}")
        print(f"  ramp at 0.71 -> {toka}")
        vaita(len(rec) == 6, f"both attempts produced transitions ({len(rec)})")
        vaita(eka == toka, "the same shape at a different place teaches the same states")
    finally:
        LL.DEMO_DIR = vanha
        shutil.rmtree(tmp, ignore_errors=True)


def _malli(cfg: LL.Config) -> LL.QModel:
    m = LL.QModel.__new__(LL.QModel)
    m.cfg = cfg
    m.calibration = {}
    m.success_offsets = []
    return m


def main() -> int:
    print("=== LOCKPICK LEARNER TESTS ===")
    cfg = LL.Config()
    testi_success(cfg)
    testi_tila_avain(cfg)
    testi_palkkio(cfg)
    testi_etaisyys(cfg)
    testi_tallennus(cfg)
    testi_hyppy(cfg)
    testi_demo_opetus(cfg)
    print("\n" + ("ALL TESTS PASSED" if not virheet else f"{len(virheet)} FAILED:"))
    for v in virheet:
        print(f"  - {v}")
    return 1 if virheet else 0


if __name__ == "__main__":
    raise SystemExit(main())
