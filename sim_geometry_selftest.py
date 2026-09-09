from __future__ import annotations
import numpy as np
import neural_lockpick_smart as smart

class DummyRuntime:
    def __init__(self):
        self.cfg = smart.SmartConfig.load()
        self.profile = smart.SimProfile.load()


def main() -> None:
    rt = DummyRuntime()
    print('SIM GEOMETRY SELFTEST v0.16.3')
    print('geometry version:', smart.SIM_GEOMETRY_VERSION)
    print('profile geometry mode:', rt.profile.geometry_mode)
    print('Human-fitted hidden geometry is disabled.')
    print()
    ok = True
    for level, name in enumerate(smart.SAFE_SIM_LEVEL_NAMES):
        probs = np.zeros(15, dtype=np.float64)
        probs[level*3:(level+1)*3] = 1.0 / 3.0
        env = smart.VectorLockSim(rt, 8192, curriculum_level=4, seed_offset=9100+level, skill_probs=probs)
        limit = smart.SAFE_SIM_RUSTED_LIMIT if level == 0 else smart.SAFE_SIM_PLAYER_LIMIT
        vals = {
            'ramp_min': min(float(env.ramp_l.min()), float(env.ramp_r.min())),
            'ramp_max': max(float(env.ramp_l.max()), float(env.ramp_r.max())),
            'target_min': float(env.target_w.min()),
            'target_max': float(env.target_w.max()),
            'center_max': float(env.center.max()),
        }
        good = (
            vals['ramp_min'] >= float(smart.SAFE_SIM_RAMP_LOW[level]) - 1e-6 and
            vals['ramp_max'] <= float(smart.SAFE_SIM_RAMP_HIGH[level]) + 1e-6 and
            vals['target_min'] >= float(smart.SAFE_SIM_TARGET_LOW[level]) - 1e-6 and
            vals['target_max'] <= float(smart.SAFE_SIM_TARGET_HIGH[level]) + 1e-6 and
            vals['center_max'] <= limit + 1e-6
        )
        lo, hi, _ = env.bounds()
        good = good and float(hi.max()) <= limit + 1e-6
        ok = ok and good
        print(
            f'L{level} {name:13s} | ramp HW {vals["ramp_min"]:.4f}..{vals["ramp_max"]:.4f} '
            f'| target HW {vals["target_min"]:.4f}..{vals["target_max"]:.4f} '
            f'| center<= {vals["center_max"]:.4f} | action<= {float(hi.max()):.4f} '
            f'| {"PASS" if good else "FAIL"}'
        )
    print()
    print('OVERALL:', 'PASS' if ok else 'FAIL')
    if not ok:
        raise SystemExit(2)

if __name__ == '__main__':
    main()
