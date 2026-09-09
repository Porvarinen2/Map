from __future__ import annotations

import argparse
import math
import time
from pathlib import Path

import numpy as np

import neural_lockpick_smart as smart

ROOT = Path(__file__).resolve().parent


def phase_name(code: int) -> str:
    return {0: "SEARCH", 1: "RAMP", 2: "RECOVER", 3: "NEAR", 4: "TARGET", -1: "HUMAN"}.get(int(code), "?")


class PdfSimWindow:
    def __init__(self, rt: smart.SmartRuntime, mode: str, debug: bool, episodes: int, speed: float, level: int):
        import tkinter as tk

        self.tk = tk
        self.rt = rt
        self.mode = mode
        self.debug = bool(debug)
        self.episodes_limit = max(1, int(episodes))
        self.speed = max(0.25, float(speed))
        self.level = max(0, min(rt.cfg.sim_curriculum_max, int(level)))
        self.env = smart.VectorLockSim(rt, 1, curriculum_level=self.level)
        self.env.budget[:] = max(3.0, rt.cfg.sim_virtual_time_limit_sec)
        self.root = tk.Tk()
        self.root.title("Lockpick Learner v0.11 - HOLD-TO-90 Hidden Ramp/Target Simulator")
        self.root.geometry("1280x760")
        self.root.minsize(1000, 650)
        self.root.configure(bg="#080d13")
        self.canvas = tk.Canvas(self.root, bg="#080d13", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)

        self.left = 90
        self.right = 1190
        self.line_y = 290
        self.cursor = 0.0
        self.response = 0.0
        self.last_reward = 0.0
        self.last_hold_ms = 0.0
        self.finished = False
        self.finish_text = ""
        self.finish_good = False
        self.episode_no = 1
        self.successes = 0
        self.wall_start = time.perf_counter()
        self.flash_until = 0.0
        self.last_phase = "SEARCH"
        self.last_wrong = 0
        self.last_hold_ms = 0.0
        self.f_down_at = None
        self.agent_next_at = 0.0

        self.root.bind("<Motion>", self.on_motion)
        self.root.bind("<KeyPress-f>", self.on_f_down)
        self.root.bind("<KeyPress-F>", self.on_f_down)
        self.root.bind("<KeyRelease-f>", self.on_f_up)
        self.root.bind("<KeyRelease-F>", self.on_f_up)
        self.root.bind("<space>", self.on_space)
        self.root.bind("<Escape>", lambda _e: self.root.destroy())
        if self.debug:
            self.root.bind("<KeyPress-d>", self.toggle_debug)
            self.root.bind("<KeyPress-D>", self.toggle_debug)
        self.root.focus_force()
        self.redraw()
        self.root.after(16, self.tick)

    def hidden_geometry(self):
        c = float(self.env.center[0])
        tl = max(0.0, c - float(self.env.target_w[0]))
        tr = min(1.0, c + float(self.env.target_w[0]))
        rl = max(0.0, c - float(self.env.ramp_l[0]))
        rr = min(1.0, c + float(self.env.ramp_r[0]))
        return rl, tl, tr, rr, c

    def x_for(self, p: float) -> float:
        return self.left + float(np.clip(p, 0.0, 1.0)) * (self.right - self.left)

    def p_for(self, x: float) -> float:
        return float(np.clip((x - self.left) / max(1.0, self.right - self.left), 0.0, 1.0))

    def on_motion(self, event):
        if self.mode != "human" or self.finished:
            return
        self.cursor = self.p_for(event.x)
        self.redraw()

    def toggle_debug(self, _event=None):
        self.debug = not self.debug
        self.redraw()

    def human_timeout(self):
        if self.finished:
            return
        self.finished = True
        self.finish_good = False
        self.finish_text = "FAIL - 3.00 s TIME LIMIT"
        self.flash_until = time.perf_counter() + 0.35
        self.redraw()

    def on_f_down(self, _event=None):
        if self.mode != "human" or self.finished:
            return
        if self.f_down_at is None:
            self.f_down_at = time.perf_counter()

    def on_f_up(self, _event=None):
        if self.mode != "human" or self.finished or self.f_down_at is None:
            return
        now = time.perf_counter()
        held_ms = max(1.0, min(1800.0, (now - self.f_down_at) * 1000.0))
        self.f_down_at = None
        self.last_hold_ms = held_ms
        if now - self.wall_start >= 3.0:
            self.human_timeout()
            return
        # Human 2D mode uses the exact measured F hold, mapped only to the closest
        # neural hold action for the shared simulator core. The visible effect is
        # therefore "tap = shallow turn, hold = deeper turn".
        idx = min(range(len(self.rt.cfg.hold_ms)), key=lambda i: abs(self.rt.cfg.hold_ms[i] - held_ms))
        self.env.budget[0] = 999.0
        _next, reward, done, info = self.env.step(
            np.asarray([self.cursor], np.float32),
            np.asarray([idx], np.int64),
            absolute=True,
            hold_ms_override=np.asarray([held_ms], np.float32),
        )
        self.response = float(info["response"][0])
        self.last_reward = float(reward[0])
        self.last_hold_ms = float(self.rt.cfg.hold_ms[hold_idx])
        self.flash_until = time.perf_counter() + 0.14
        success = bool(info["success"][0] > 0.5)
        wrong = int(info["wrong_hits"][0])
        underhold = bool(info.get("underhold", np.asarray([0.0]))[0] > 0.5)
        self.last_wrong = wrong
        if success:
            self.finished = True
            self.finish_good = True
            self.finish_text = "SUCCESS - HELD TO 90 DEG"
            self.successes += 1
        elif bool(done[0] > 0.5):
            self.finished = True
            self.finish_good = False
            self.finish_text = "FAIL - VIRTUAL TIMER ENDED"
        elif underhold:
            self.finish_text = "TARGET HIT - HOLD F LONGER"
        else:
            self.finish_text = ""
        self.redraw(info)

    def on_space(self, _event=None):
        if self.mode != "human":
            return
        if self.finished:
            # Core auto-resets terminal envs. A pure wall-time timeout does not,
            # so reset explicitly in both cases for a clean new hidden lock.
            self.env._reset_params(np.asarray([0], dtype=np.int64))
            self.episode_no += 1
            self.cursor = 0.0
            self.response = 0.0
            self.last_reward = 0.0
            self.last_hold_ms = 0.0
            self.finished = False
            self.finish_text = ""
            self.finish_good = False
            self.wall_start = time.perf_counter()
            self.redraw()

    def agent_step(self):
        if self.finished:
            return
        obs = self.env.obs()[0]
        unit, hold_idx, _logp, _value, _mean, _hp = smart.policy_action(self.rt, obs, deterministic=True)
        low, high, phase = self.env.bounds()
        target = float(low[0] + unit * max(1e-6, float(high[0] - low[0])))
        self.cursor = target
        _next, reward, done, info = self.env.step(
            np.asarray([unit], np.float32), np.asarray([hold_idx], np.int64), absolute=False
        )
        self.last_phase = phase_name(int(phase[0]))
        self.response = float(info["response"][0])
        self.last_wrong = int(info["wrong_hits"][0])
        self.last_reward = float(reward[0])
        self.last_hold_ms = float(self.rt.cfg.hold_ms[hold_idx])
        self.flash_until = time.perf_counter() + 0.10
        if bool(done[0]):
            ok = bool(info["success"][0] > 0.5)
            self.finished = True
            self.finish_good = ok
            self.finish_text = "SUCCESS" if ok else "FAIL"
            if ok:
                self.successes += 1
        self.redraw(info)

    def advance_agent_episode(self):
        if self.episode_no >= self.episodes_limit:
            self.finish_text = f"DONE - {self.successes}/{self.episodes_limit} SUCCESS"
            self.redraw()
            return
        self.episode_no += 1
        self.cursor = 0.0
        self.response = 0.0
        self.last_reward = 0.0
        self.last_hold_ms = 0.0
        self.finished = False
        self.finish_text = ""
        self.finish_good = False
        self.last_phase = "SEARCH"
        self.last_wrong = 0
        self.redraw()

    def tick(self):
        try:
            now = time.perf_counter()
            if self.mode == "human" and not self.finished:
                if now - self.wall_start >= 3.0:
                    self.human_timeout()
                else:
                    self.redraw()
            elif self.mode == "agent":
                if self.finished:
                    if now >= self.agent_next_at:
                        self.agent_next_at = now + max(0.03, 0.55 / self.speed)
                        self.advance_agent_episode()
                elif now >= self.agent_next_at:
                    self.agent_next_at = now + max(0.018, 0.20 / self.speed)
                    self.agent_step()
            self.root.after(16, self.tick)
        except self.tk.TclError:
            pass

    def redraw(self, terminal_info=None):
        c = self.canvas
        c.delete("all")
        w = max(1000, c.winfo_width())
        h = max(650, c.winfo_height())
        # Recompute horizontal geometry when resized.
        self.left = max(70, int(w * 0.075))
        self.right = min(w - 70, int(w * 0.925))
        self.line_y = int(h * 0.39)

        c.create_text(w/2, 42, text="LOCKPICK - HOLD-TO-90 2D SIMULATOR", fill="white", font=("Segoe UI", 25, "bold"))
        subtitle = "RAMP + TARGET ARE HIDDEN FROM THE AGENT" if not self.debug else "DEBUG VIEW - HIDDEN PHYSICS REVEALED"
        c.create_text(w/2, 78, text=subtitle, fill="#9aa7b8", font=("Segoe UI", 12, "bold"))

        # Lock reaction gauge. Response 0..1 becomes a 0..90 degree needle.
        gx, gy, gr = w/2, 165, 72
        c.create_oval(gx-gr, gy-gr, gx+gr, gy+gr, outline="#66717f", width=4)
        ang = math.radians(-90 + 90 * float(np.clip(self.response, 0, 1)))
        nx, ny = gx + math.cos(ang)*gr*0.78, gy + math.sin(ang)*gr*0.78
        c.create_line(gx, gy, nx, ny, fill="#f1f5f9", width=8, capstyle="round")
        c.create_text(gx, gy+gr+22, text=f"LOCK TURN {self.response*90.0:5.1f} DEG  |  response={self.response:.3f}", fill="#dce6f2", font=("Consolas", 12, "bold"))

        # Horizontal lock area.
        c.create_line(self.left, self.line_y, self.right, self.line_y, fill="#ff1535", width=8)
        c.create_text((self.left+self.right)/2, self.line_y-34, text="LOCK AREA  0.000 ------------------------------------------------ 1.000", fill="#ff526a", font=("Consolas", 13, "bold"))
        c.create_line(self.left, self.line_y-30, self.left, self.line_y+80, fill="#ff2bd6", width=8)
        c.create_text(self.left, self.line_y+105, text="START\nALWAYS LEFT", fill="#ff45df", font=("Segoe UI", 11, "bold"), justify="center")

        # Optional hidden physics overlay; never enabled in agent mode unless the
        # user explicitly launches SIM_DEBUG_2D.bat. It is never part of obs().
        if self.debug:
            rl, tl, tr, rr, center = self.hidden_geometry()
            c.create_line(self.x_for(rl), self.line_y+18, self.x_for(tl), self.line_y+58, fill="#19e6ef", width=7)
            c.create_line(self.x_for(tr), self.line_y+58, self.x_for(rr), self.line_y+18, fill="#19e6ef", width=7)
            c.create_line(self.x_for(tl), self.line_y+58, self.x_for(tr), self.line_y+58, fill="#31ff45", width=10)
            c.create_text(self.x_for(center), self.line_y+88, text="HIDDEN TARGET", fill="#31ff45", font=("Segoe UI", 11, "bold"))
            c.create_text((self.x_for(rl)+self.x_for(rr))/2, self.line_y+25, text="HIDDEN RAMP", fill="#19e6ef", font=("Segoe UI", 10, "bold"))

        # Current pick/test point.
        px = self.x_for(self.cursor)
        c.create_line(px, self.line_y-35, px, self.line_y+38, fill="#ffd92f", width=5)
        c.create_polygon(px, self.line_y-48, px-9, self.line_y-33, px+9, self.line_y-33, fill="#ffd92f", outline="")
        c.create_text(px, self.line_y-68, text=f"{self.cursor:.3f}", fill="#ffe65c", font=("Consolas", 12, "bold"))

        if self.mode == "human":
            elapsed = min(3.0, time.perf_counter() - self.wall_start) if not self.finished else min(3.0, time.perf_counter() - self.wall_start)
            remain = max(0.0, 3.0 - elapsed)
            wrong = int(self.env.wrong_hits[0]) if not self.finished else int(self.last_wrong)
            control = "MOUSE = PICK POSITION     HOLD F = TURN DEEPER     RELEASE = READ LOCK     SPACE = NEW LOCK"
        else:
            elapsed = float(self.env.elapsed[0]) if not self.finished else 0.0
            remain = max(0.0, max(3.0, self.rt.cfg.sim_virtual_time_limit_sec) - elapsed)
            wrong = int(self.env.wrong_hits[0]) if not self.finished else int(self.last_wrong)
            control = f"NEURAL AGENT WATCH  |  deterministic policy  |  visual speed {self.speed:.1f}x"
        c.create_text(w/2, self.line_y+145, text=control, fill="#c3ceda", font=("Segoe UI", 11, "bold"))

        # Rules panel.
        panel_y = self.line_y + 190
        c.create_rectangle(50, panel_y, w-50, min(h-25, panel_y+150), outline="#263747", width=2)
        c.create_text(75, panel_y+28, anchor="w", text=f"TIME-LIMITED ONLY     DEAD PROBES (METRIC): {wrong}     LAST HOLD: {self.last_hold_ms:.0f} ms     LEFT: {remain:.2f}s", fill="#f4f7fb", font=("Consolas", 14, "bold"))
        c.create_text(75, panel_y+63, anchor="w", text=f"Reward: {self.last_reward:+.2f}     Phase: {self.last_phase}     Episode: {self.episode_no}     Successes: {self.successes}", fill="#a9bdd2", font=("Consolas", 12))
        c.create_text(75, panel_y+100, anchor="w", text="Rule v0.15: there is NO artificial wrong-position cap. Keep probing until SUCCESS or virtual time ends.", fill="#f8b84d", font=("Segoe UI", 11, "bold"))
        c.create_text(75, panel_y+127, anchor="w", text="Headless training does NOT wait 3 real seconds; its action costs advance a 3.00 s virtual game clock.", fill="#7cd4ff", font=("Segoe UI", 10, "bold"))

        if self.finished or time.perf_counter() < self.flash_until:
            if self.finished:
                fill = "#32ff62" if self.finish_good else "#ff3c55"
                c.create_rectangle(0, h*0.43, w, h*0.56, fill="#05080c", outline="")
                c.create_text(w/2, h*0.495, text=self.finish_text, fill=fill, font=("Segoe UI", 34, "bold"))
                if self.mode == "human":
                    c.create_text(w/2, h*0.56, text="SPACE = NEXT RANDOM HIDDEN LOCK", fill="white", font=("Segoe UI", 12, "bold"))

    def run(self):
        self.root.mainloop()


def headless_bench(rt: smart.SmartRuntime, episodes: int, level: int) -> None:
    n = min(max(1024, int(rt.cfg.sim_envs)), max(1024, int(episodes)))
    env = smart.VectorLockSim(rt, n, curriculum_level=level)
    target_done = int(episodes)
    done_total = 0
    success_total = 0
    steps = 0
    start = time.perf_counter()
    while done_total < target_done:
        obs = env.obs()
        act, hold, _lp, _v = smart.sim_policy_batch(rt, obs, deterministic=True)
        _next, _r, done, info = env.step(act, hold)
        mask = done > 0.5
        done_total += int(mask.sum())
        success_total += int((info["success"] > 0.5).sum())
        steps += n
    wall = time.perf_counter() - start
    print(f"HOLD-TO-90 SIM BENCH: episodes={done_total:,} successes={success_total:,} ({100*success_total/max(1,done_total):.1f}%)")
    print(f"Virtual rule: L0/Rusted={max(10.0,rt.cfg.sim_rusted_time_limit_sec):.2f}s, player={max(3.0,rt.cfg.sim_virtual_time_limit_sec):.2f}s / no fake probe cap / target requires hold-to-90")
    print(f"Throughput: {steps/max(1e-9,wall):,.0f} simulated interactions/s | wall={wall:.2f}s")


def main() -> None:
    ap = argparse.ArgumentParser(description="HOLD-TO-90 hidden ramp/target lockpick simulator")
    ap.add_argument("--mode", choices=["human", "agent", "bench"], default="human")
    ap.add_argument("--debug", action="store_true", help="developer view only: reveal hidden ramp/target")
    ap.add_argument("--episodes", type=int, default=20)
    ap.add_argument("--speed", type=float, default=6.0, help="agent-watch animation speed only")
    ap.add_argument("--level", type=int, default=2)
    args = ap.parse_args()

    cfg = smart.SmartConfig.load()
    cfg.sim_virtual_time_limit_sec = max(3.0, float(cfg.sim_virtual_time_limit_sec))
    cfg.sim_use_wrong_hit_limit = False
    cc = smart.classic.Config.load()
    rt = smart.SmartRuntime(cc, cfg)

    if args.mode == "bench":
        headless_bench(rt, args.episodes, args.level)
        return
    if args.mode == "agent" and args.debug:
        print("[WARN] DEBUG overlay reveals hidden physics visually to YOU, but it is never included in agent observations.")
    PdfSimWindow(rt, args.mode, args.debug, args.episodes, args.speed, args.level).run()


if __name__ == "__main__":
    main()
