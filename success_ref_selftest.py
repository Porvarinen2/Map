from pathlib import Path
import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent
REFS = ROOT / "refs"
TEMPLATE = cv2.imread(str(REFS / "success_text_template.png"), cv2.IMREAD_GRAYSCALE)
POS = REFS / "Success_reference_1920x1080.png"
HARD = 0.48


def score(path: Path) -> float:
    img = cv2.imread(str(path))
    if img is None or TEMPLATE is None:
        return -1.0
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape[:2]
    blur = cv2.GaussianBlur(gray, (7, 7), 1.5)
    exp = min(w, h) * 0.20
    circles = cv2.HoughCircles(
        blur, cv2.HOUGH_GRADIENT, dp=1.2, minDist=100,
        param1=120, param2=42,
        minRadius=max(20, int(exp * 0.68)), maxRadius=max(30, int(exp * 1.25)),
    )
    cx, cy, r = w // 2, h // 2, exp
    if circles is not None:
        arr = circles[0]
        best = min(arr, key=lambda c: float(np.linalg.norm(np.array(c[:2]) - [w/2, h/2])) + 0.5 * abs(float(c[2]) - exp))
        cx, cy, r = int(round(best[0])), int(round(best[1])), float(best[2])
    x0 = max(0, int(round(cx - 1.35 * r)))
    x1 = min(w, int(round(cx + 1.35 * r)))
    y0 = max(0, int(round(cy - 0.48 * r)))
    y1 = min(h, int(round(cy + 0.42 * r)))
    roi = gray[y0:y1, x0:x1]
    if roi.size == 0:
        return -1.0

    _, tb0 = cv2.threshold(TEMPLATE, 127, 255, cv2.THRESH_BINARY)
    roi_edges = cv2.Canny(roi, 50, 150)
    ref_r = 221.3
    scales = []
    rs = r / ref_r
    hs = h / 1079.0
    for m in (0.78, 0.86, 0.94, 1.00, 1.06, 1.14, 1.24):
        scales.append((rs * m))
    for m in (0.82, 0.90, 0.96, 1.00, 1.04, 1.10, 1.18):
        scales.append((hs * m))

    best_score = 0.0
    for sc in scales:
        tw = max(50, int(round(TEMPLATE.shape[1] * sc)))
        th = max(14, int(round(TEMPLATE.shape[0] * sc)))
        if roi.shape[0] <= th or roi.shape[1] <= tw:
            continue
        tb = cv2.resize(tb0, (tw, th), interpolation=cv2.INTER_NEAREST)
        tg = cv2.resize(TEMPLATE, (tw, th), interpolation=cv2.INTER_LINEAR)
        for cut in (125, 145, 165, 185, 205, 225):
            bright = (roi >= cut).astype(np.uint8) * 255
            res = cv2.matchTemplate(bright, tb, cv2.TM_CCOEFF_NORMED)
            if res.size:
                best_score = max(best_score, float(cv2.minMaxLoc(res)[1]))
        te = cv2.Canny(tg, 50, 150)
        if np.count_nonzero(te) > 20:
            res = cv2.matchTemplate(roi_edges, te, cv2.TM_CCOEFF_NORMED)
            if res.size:
                best_score = max(best_score, 0.95 * float(cv2.minMaxLoc(res)[1]))
    return best_score


positive = score(POS)
print(f"SUCCESS positive reference: {positive:.3f}  {'PASS' if positive >= HARD else 'FAIL'}")
negatives = []
for folder in ("minigame", "lock_types", "rotation_areas", "lock_success_angles"):
    for p in sorted((REFS / folder).glob("*.png")):
        negatives.append((score(p), p.name))
negatives.sort(reverse=True)
if negatives:
    print(f"Highest ordinary-lock reference: {negatives[0][0]:.3f} ({negatives[0][1]})")
    print(f"Hard gate: {HARD:.2f}")
    print("NEGATIVE SET:", "PASS" if negatives[0][0] < HARD else "FAIL")
