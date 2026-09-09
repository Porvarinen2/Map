from __future__ import annotations

import argparse
import copy
import ctypes
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

_LOGICAL = os.cpu_count() or 8
os.environ.setdefault("OMP_NUM_THREADS", str(_LOGICAL))
os.environ.setdefault("MKL_NUM_THREADS", str(_LOGICAL))
os.environ.setdefault("NUMEXPR_NUM_THREADS", str(_LOGICAL))
os.environ.setdefault("OMP_WAIT_POLICY", "ACTIVE")

import numpy as np
import torch
import torch.nn.functional as F

import neural_lockpick_smart as smart

ROOT = Path(__file__).resolve().parent
MAX_CHAMPION = smart.SMART_DIR / "smart_max_champion.pt"
PREBOOT_CHAMPION = smart.SMART_DIR / "smart_preboot_champion.pt"
ELITE_BANK = smart.SMART_DIR / "elite_champion_bank.npz"
MAX_LOG = smart.AUDIT_DIR / "max_offline_train_v011.csv"


@dataclass
class ResourcePlan:
    logical_cores: int
    ram_gb: float
    torch_threads: int
    interop_threads: int
    sim_envs: int
    rollout_steps: int
    ppo_minibatch: int
    ppo_epochs: int
    teacher_transitions: int
    warmup_batch: int
    eval_episodes_per_level: int
    estimated_rollout_gb: float


def total_ram_bytes() -> int:
    if os.name == "nt":
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]
        st = MEMORYSTATUSEX(); st.dwLength = ctypes.sizeof(st)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            return int(st.ullTotalPhys)
    try:
        return int(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE"))
    except Exception:
        return 16 * 1024**3


def set_high_priority() -> bool:
    if os.name != "nt":
        return False
    try:
        return bool(ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x80))
    except Exception:
        return False


def build_plan() -> ResourcePlan:
    cores = max(2, os.cpu_count() or 8)
    ram_gb = total_ram_bytes() / 1024**3
    # Keep the huge vector workload from v0.10; stability is fixed by smaller
    # gradient steps, not by starving the CPU of simulator data.
    if ram_gb >= 128 and cores >= 24:
        envs, rollout, mb, teacher_trans = 32768, 56, 32768, 6_000_000
    elif ram_gb >= 64 and cores >= 16:
        envs, rollout, mb, teacher_trans = 16384, 48, 16384, 3_500_000
    elif ram_gb >= 32 and cores >= 12:
        envs, rollout, mb, teacher_trans = 8192, 40, 8192, 1_800_000
    elif ram_gb >= 16 and cores >= 8:
        envs, rollout, mb, teacher_trans = 4096, 32, 4096, 900_000
    else:
        envs, rollout, mb, teacher_trans = 2048, 28, 2048, 400_000
    cpu_cap = max(1024, 1024 * max(1, cores // 4))
    envs = max(512, int(min(envs, cpu_cap * 4)))
    rollout_bytes = rollout * envs * smart.OBS_DIM * 4
    estimated_gb = rollout_bytes * 3.1 / 1024**3
    return ResourcePlan(
        logical_cores=cores, ram_gb=ram_gb, torch_threads=cores,
        interop_threads=max(1, min(4, cores // 8)), sim_envs=envs,
        rollout_steps=rollout, ppo_minibatch=mb, ppo_epochs=2,
        teacher_transitions=teacher_trans, warmup_batch=max(4096, mb),
        eval_episodes_per_level=1024 if envs < 8192 else 2048,
        estimated_rollout_gb=estimated_gb,
    )


def apply_plan(rt: smart.SmartRuntime, plan: ResourcePlan) -> None:
    try: torch.set_num_threads(plan.torch_threads)
    except Exception: pass
    try: torch.set_num_interop_threads(plan.interop_threads)
    except Exception: pass
    try: torch.set_float32_matmul_precision("high")
    except Exception: pass
    try: torch.set_flush_denormal(True)
    except Exception: pass
    try: torch.backends.mkldnn.enabled = True
    except Exception: pass
    c = rt.cfg
    c.sim_envs = plan.sim_envs
    c.sim_rollout_steps = plan.rollout_steps
    c.ppo_minibatch = plan.ppo_minibatch
    c.ppo_epochs = 2
    c.sim_warmup_batch = plan.warmup_batch
    c.sim_eval_episodes = max(c.sim_eval_episodes, plan.eval_episodes_per_level * 2)
    # Hard cap: the old 2e-4 MAX LR was demonstrably too large with 1.8M-step rollouts.
    c.ppo_lr = min(max(c.ppo_min_lr, c.ppo_lr), 5.0e-5)
    c.ppo_clip = min(c.ppo_clip, 0.08)
    c.ppo_value_coef = min(c.ppo_value_coef, 0.35)
    c.ppo_entropy_coef = min(c.ppo_entropy_coef, 0.0030)
    c.ppo_entropy_min = min(c.ppo_entropy_min, 0.0006)
    c.ppo_entropy_decay = max(c.ppo_entropy_decay, 0.992)
    c.ppo_max_grad_norm = min(c.ppo_max_grad_norm, 0.45)
    c.ppo_target_kl = min(c.ppo_target_kl, 0.004)
    c.ppo_hard_kl = min(c.ppo_hard_kl, 0.007)
    c.ppo_reward_scale = 0.05
    c.ppo_adv_clip = min(c.ppo_adv_clip, 6.0)
    c.ppo_champion_anchor_coef = max(c.ppo_champion_anchor_coef, 0.22)
    c.ppo_champion_anchor_hard_kl = min(c.ppo_champion_anchor_hard_kl, 0.040)
    c.ppo_elite_coef = max(c.ppo_elite_coef, 0.055)
    rt.optimizer = torch.optim.Adam(rt.net.parameters(), lr=c.ppo_lr, eps=1e-5)


def checkpoint_load(rt: smart.SmartRuntime, path: Path) -> bool:
    if not path.exists(): return False
    try:
        ck = torch.load(path, map_location=rt.device)
        rt.net.load_state_dict(ck["state_dict"])
        # Fresh Adam for each challenger. Rejected momentum must never leak into
        # the next attempt.
        rt.optimizer = torch.optim.Adam(rt.net.parameters(), lr=rt.cfg.ppo_lr, eps=1e-5)
        rt.net.eval(); rt.save()
        return True
    except Exception as exc:
        print(f"[WARN] checkpoint restore failed: {exc}")
        return False


def set_champion_anchor(rt: smart.SmartRuntime) -> None:
    anchor = copy.deepcopy(rt.net).to(rt.device)
    anchor.eval()
    for p in anchor.parameters(): p.requires_grad_(False)
    rt.ppo_anchor_net = anchor


def eval_suite(rt: smart.SmartRuntime, episodes_each: int) -> Tuple[float, float, List[float]]:
    rates: List[float] = []
    for level in range(rt.cfg.sim_curriculum_max + 1):
        ev = smart.sim_evaluate(rt, level, episodes=episodes_each)
        rates.append(float(ev["success_rate"]))
    weights = np.linspace(1.0, 2.4, len(rates), dtype=np.float64); weights /= weights.sum()
    weighted = float(np.dot(weights, np.asarray(rates)))
    worst = float(min(rates) if rates else 0.0)
    score = 0.78 * weighted + 0.22 * worst
    return score, worst, rates


def make_batch(rt: smart.SmartRuntime, env: smart.VectorLockSim) -> smart.PPOBatch:
    T, N = rt.cfg.sim_rollout_steps, rt.cfg.sim_envs
    b = smart.PPOBatch(T, N)
    for t in range(T):
        obs = env.obs()
        act, hold, logp, value = smart.sim_policy_batch(rt, obs, deterministic=False)
        _next, reward, done, _info = env.step(act, hold)
        b.obs[t] = obs; b.action[t] = act; b.hold[t] = hold
        b.logp[t] = logp; b.value[t] = value; b.reward[t] = reward; b.done[t] = done
    with torch.no_grad():
        _a, _be, _h, v = rt.net(torch.as_tensor(env.obs(), dtype=torch.float32, device=rt.device))
        b.next_value = v.detach().cpu().numpy().astype(np.float32)
    return b


def critic_head_warmup(rt: smart.SmartRuntime, seed_offset: int = 424242) -> Dict[str, float]:
    """Train only value_head; actor/body are immutable during this phase."""
    env = smart.VectorLockSim(rt, rt.cfg.sim_envs, curriculum_level=rt.cfg.sim_curriculum_max, seed_offset=seed_offset)
    b = make_batch(rt, env)
    T, N = b.reward.shape
    ret = np.zeros((T, N), np.float32)
    running = np.zeros(N, np.float32)
    for t in reversed(range(T)):
        running = b.reward[t] * float(rt.cfg.ppo_reward_scale) + rt.cfg.ppo_gamma * running * (1.0 - b.done[t])
        ret[t] = running
    obs_np = b.obs.reshape(-1, smart.OBS_DIM)
    ret_np = ret.reshape(-1)
    # Up to 350k examples is plenty for the tiny value head and avoids spending
    # the whole bootcamp on critic calibration.
    if len(ret_np) > 350_000:
        rng = np.random.default_rng(rt.cfg.seed + 991)
        ix = rng.choice(len(ret_np), 350_000, replace=False)
        obs_np, ret_np = obs_np[ix], ret_np[ix]
    obs = torch.as_tensor(obs_np, dtype=torch.float32, device=rt.device)
    target = torch.as_tensor(ret_np, dtype=torch.float32, device=rt.device)
    params = list(rt.net.value_head.parameters())
    opt = torch.optim.Adam(params, lr=3e-4, eps=1e-5)
    losses=[]; rt.net.train()
    idx=np.arange(len(ret_np)); bs=min(32768, max(2048, rt.cfg.ppo_minibatch))
    for _ in range(3):
        np.random.shuffle(idx)
        for s in range(0,len(idx),bs):
            m=torch.as_tensor(idx[s:s+bs],dtype=torch.long,device=rt.device)
            _a,_b,_h,v=rt.net(obs[m])
            loss=F.smooth_l1_loss(v,target[m],beta=1.0)
            opt.zero_grad(set_to_none=True); loss.backward()
            torch.nn.utils.clip_grad_norm_(params,0.8); opt.step(); losses.append(float(loss.item()))
    rt.net.eval(); rt.optimizer=torch.optim.Adam(rt.net.parameters(),lr=rt.cfg.ppo_lr,eps=1e-5); rt.save()
    return {"loss":float(np.mean(losses) if losses else 0.0),"samples":float(len(ret_np))}


def stream_teacher_distill(rt: smart.SmartRuntime, transitions_target: int, lr: float, label: str="teacher") -> Dict[str,float]:
    transitions_target=max(rt.cfg.sim_envs,int(transitions_target)); opt=torch.optim.Adam(rt.net.parameters(),lr=lr,eps=1e-5)
    rt.net.train(); seen=0; losses=[]; steps=0; start=time.perf_counter(); max_level=rt.cfg.sim_curriculum_max
    env=smart.VectorLockSim(rt,rt.cfg.sim_envs,curriculum_level=0,seed_offset=777)
    current_level=0
    while seen<transitions_target:
        frac=seen/max(1,transitions_target); desired=min(max_level,int(frac*(max_level+1)))
        if desired!=current_level:
            current_level=desired; env=smart.VectorLockSim(rt,rt.cfg.sim_envs,curriculum_level=current_level,seed_offset=777+current_level)
        obs_np=env.obs(); target,hold_np=smart.planner_targets_from_env(env,q=0.18); low,high,_=env.bounds()
        unit_np=np.clip((target-low)/np.maximum(1e-6,high-low),1e-4,1-1e-4).astype(np.float32)
        weight_np=(1.0+3.5*env.best+1.5*(env.response>=env.threshold()).astype(np.float32)).astype(np.float32)
        obs=torch.as_tensor(obs_np,dtype=torch.float32,device=rt.device); act=torch.as_tensor(unit_np,dtype=torch.float32,device=rt.device)
        hold=torch.as_tensor(hold_np,dtype=torch.long,device=rt.device); w=torch.as_tensor(weight_np,dtype=torch.float32,device=rt.device)
        alpha,beta,hold_logits,_=rt.net(obs); bd=torch.distributions.Beta(alpha,beta)
        move_mse=(bd.mean-act)**2; move_nll=-bd.log_prob(act).clamp(-20.0,20.0); hold_ce=F.cross_entropy(hold_logits,hold,reduction="none")
        loss=((7.0*move_mse+0.06*move_nll+0.25*hold_ce)*w).sum()/torch.clamp(w.sum(),min=1.0)
        opt.zero_grad(set_to_none=True); loss.backward(); torch.nn.utils.clip_grad_norm_(rt.net.parameters(),rt.cfg.ppo_max_grad_norm); opt.step()
        losses.append(float(loss.item())); steps+=1; env.step(unit_np,hold_np); seen+=rt.cfg.sim_envs
        if steps==1 or steps%25==0:
            print(f"{label}: {seen:,}/{transitions_target:,} transitions | L{current_level} | loss={losses[-1]:.4f} | {seen/max(1e-6,time.perf_counter()-start):,.0f}/s",end="\r")
    print(); rt.net.eval(); rt.optimizer=torch.optim.Adam(rt.net.parameters(),lr=rt.cfg.ppo_lr,eps=1e-5); rt.save()
    return {"transitions":float(seen),"loss":float(np.mean(losses) if losses else 0.0),"seconds":float(time.perf_counter()-start)}


def load_elite_bank(rt: smart.SmartRuntime, human_samples: Sequence[smart.HumanSample]) -> Tuple[np.ndarray,np.ndarray,np.ndarray]:
    obs=[]; act=[]; hold=[]
    # Human successes are immutable high-value anchors.
    for x in human_samples:
        if getattr(x,"source","")=="human_success" and not x.negative:
            obs.append(x.obs.astype(np.float32)); act.append(float(x.unit_action)); hold.append(int(x.hold_action))
    if ELITE_BANK.exists():
        try:
            z=np.load(ELITE_BANK)
            obs.extend(list(z["obs"].astype(np.float32))); act.extend(list(z["action"].astype(np.float32))); hold.extend(list(z["hold"].astype(np.int64)))
        except Exception as exc: print(f"[WARN] elite bank read: {exc}")
    if not obs:
        return np.zeros((0,smart.OBS_DIM),np.float32),np.zeros(0,np.float32),np.zeros(0,np.int64)
    o=np.asarray(obs,np.float32); a=np.asarray(act,np.float32); h=np.asarray(hold,np.int64)
    if len(o)>200_000:
        rng=np.random.default_rng(rt.cfg.seed+909); ix=rng.choice(len(o),200_000,replace=False); o,a,h=o[ix],a[ix],h[ix]
    return o,a,h


def install_elite(rt: smart.SmartRuntime, bank: Tuple[np.ndarray,np.ndarray,np.ndarray]) -> None:
    rt.ppo_elite_obs,rt.ppo_elite_action,rt.ppo_elite_hold=bank


def add_accepted_successes(rt: smart.SmartRuntime, bank: Tuple[np.ndarray,np.ndarray,np.ndarray], batch: smart.PPOBatch) -> Tuple[np.ndarray,np.ndarray,np.ndarray]:
    old_o,old_a,old_h=bank; add_o=[];add_a=[];add_h=[]
    threshold=float(rt.cfg.reward_success)*0.50
    success=np.argwhere(batch.reward>threshold)
    # Keep terminal action plus up to 3 preceding actions from the same episode.
    for t,i in success:
        lo=max(0,int(t)-3)
        for k in range(int(t),lo-1,-1):
            if k<int(t) and batch.done[k,int(i)]>0.5: break
            add_o.append(batch.obs[k,int(i)].copy()); add_a.append(float(batch.action[k,int(i)])); add_h.append(int(batch.hold[k,int(i)]))
    if not add_o: return bank
    ao=np.asarray(add_o,np.float32); aa=np.asarray(add_a,np.float32); ah=np.asarray(add_h,np.int64)
    if len(ao)>30_000:
        rng=np.random.default_rng(rt.cfg.seed+len(ao)); ix=rng.choice(len(ao),30_000,replace=False); ao,aa,ah=ao[ix],aa[ix],ah[ix]
    o=np.concatenate([old_o,ao],axis=0) if len(old_o) else ao
    a=np.concatenate([old_a,aa],axis=0) if len(old_a) else aa
    h=np.concatenate([old_h,ah],axis=0) if len(old_h) else ah
    if len(o)>200_000:
        # Keep newest half and random older half.
        keep_new=min(100_000,len(ao)); newest=np.arange(max(0,len(o)-keep_new),len(o))
        older=np.arange(0,max(0,len(o)-keep_new)); need=200_000-len(newest)
        if len(older)>need:
            rng=np.random.default_rng(rt.cfg.seed+313); older=rng.choice(older,need,replace=False)
        ix=np.concatenate([older,newest]); o,a,h=o[ix],a[ix],h[ix]
    np.savez_compressed(ELITE_BANK,obs=o,action=a,hold=h)
    return o,a,h


def guarded_maintenance(rt: smart.SmartRuntime, human_success: Sequence[smart.HumanSample], best: Tuple[float,float,List[float]], eval_eps:int, transition_count:int) -> Tuple[bool,Tuple[float,float,List[float]]]:
    """Teacher/human rehearsal is a challenger too; never mutate champion blindly."""
    best_score,best_worst,best_rates=best
    checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt)
    stream_teacher_distill(rt,transition_count,lr=1.8e-5,label="guarded teacher")
    if human_success:
        smart.supervised_update(rt,human_success,epochs=1,lr=1.5e-5,batch_size=max(1024,rt.cfg.ppo_minibatch//2))
    score,worst,rates=eval_suite(rt,eval_eps)
    accept=score>best_score+0.0005 and worst>=best_worst-0.005 and rates[-1]>=best_rates[-1]-0.005
    if accept:
        rt.save(MAX_CHAMPION); set_champion_anchor(rt)
        print(f"[MAINT ACCEPT] {100*best_score:.2f}% -> {100*score:.2f}%")
        return True,(score,worst,rates)
    checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt)
    print(f"[MAINT REJECT] candidate={100*score:.2f}% champion={100*best_score:.2f}%")
    return False,best


def run_bootcamp(rt: smart.SmartRuntime, plan: ResourcePlan, minutes: float, skip_human: bool=False) -> None:
    print("\n===============================================================")
    print(" LOCKPICK v0.11 STABLE CHAMPION MAX OFFLINE - GAME NOT REQUIRED")
    print("===============================================================")
    print(f"CPU logical cores : {plan.logical_cores}")
    print(f"Detected RAM      : {plan.ram_gb:.1f} GiB")
    print(f"Torch CPU threads : {plan.torch_threads} + interop {plan.interop_threads}")
    print(f"Vector envs       : {plan.sim_envs:,}")
    print(f"Rollout/challenger: {plan.rollout_steps} x {plan.sim_envs:,} = {plan.rollout_steps*plan.sim_envs:,} transitions")
    print(f"PPO               : epochs={rt.cfg.ppo_epochs} lr={rt.cfg.ppo_lr:.2e} clip={rt.cfg.ppo_clip:.3f}")
    print(f"Trust region      : target KL={rt.cfg.ppo_target_kl:.4f} hard KL={rt.cfg.ppo_hard_kl:.4f} + champion anchor")
    print(f"Teacher warm-start: {plan.teacher_transitions:,} transitions")
    print(f"Estimated rollout RAM: ~{plan.estimated_rollout_gb:.2f} GiB + runtime")
    print(f"Training target   : {minutes:.1f} minutes")
    print("Rule model         : L0/Rusted 10s | player 3s VIRTUAL clock | NO artificial probe cap | HOLD must reach ~90 deg")
    print("v0.11 rule         : champion is immutable; every PPO policy is a challenger and is accepted only if deterministic suite improves.\n")

    smart.fit_sim_profile(rt,verbose=True)
    human_samples=[]
    if not skip_human:
        human_samples,cnt=smart.load_human_samples(rt)
        print(f"Human data: files={cnt['files']} success={cnt['success']} fail={cnt['fail']} positive={cnt['positive']} negative={cnt['negative']}")
    human_success=[x for x in human_samples if getattr(x,"source","")=="human_success" and not x.negative]

    # If v0.10 already produced a good champion, use it as the pre-boot baseline.
    had_champion=MAX_CHAMPION.exists()
    old_best=None
    if had_champion and checkpoint_load(rt,MAX_CHAMPION):
        old_best=eval_suite(rt,plan.eval_episodes_per_level)
        rt.save(PREBOOT_CHAMPION)
        print("Existing champion: "+" | ".join(f"L{i}={100*r:.1f}%" for i,r in enumerate(old_best[2]))+f" | score={100*old_best[0]:.1f}%")

    # Human + teacher bootstrap candidate. It is guarded if an old champion exists.
    if human_samples:
        m=smart.supervised_update(rt,human_samples,rt.cfg.human_bc_epochs,rt.cfg.human_bc_lr,rt.cfg.human_bc_batch)
        print(f"Human BC: samples={int(m['samples'])} loss={m['loss']:.4f} hash={rt.model_hash()[:12]}")
    print(f"Bayesian teacher stream: {plan.teacher_transitions:,} feedback-only transitions...")
    m=stream_teacher_distill(rt,plan.teacher_transitions,rt.cfg.sim_warmup_lr,label="teacher warm-start")
    print(f"Teacher complete: {int(m['transitions']):,} | loss={m['loss']:.4f} | {m['seconds']:.1f}s")

    bootstrap=eval_suite(rt,plan.eval_episodes_per_level)
    if old_best is not None and not (bootstrap[0]>old_best[0]+0.0005 and bootstrap[1]>=old_best[1]-0.005):
        print(f"[BOOTSTRAP REJECT] candidate={100*bootstrap[0]:.1f}% old champion={100*old_best[0]:.1f}% -> preserving old champion")
        checkpoint_load(rt,PREBOOT_CHAMPION); best_score,best_worst,best_rates=old_best; rt.save(MAX_CHAMPION)
    else:
        best_score,best_worst,best_rates=bootstrap; rt.save(MAX_CHAMPION)
        print("Bootstrap champion: "+" | ".join(f"L{i}={100*r:.1f}%" for i,r in enumerate(best_rates))+f" | score={100*best_score:.1f}%")

    # Critic-only calibration cannot change actor outputs.
    set_champion_anchor(rt)
    cmet=critic_head_warmup(rt)
    rt.save(MAX_CHAMPION); set_champion_anchor(rt)
    print(f"Critic-only warmup: {int(cmet['samples']):,} samples | Huber loss={cmet['loss']:.4f} | actor unchanged")

    bank=load_elite_bank(rt,human_samples); install_elite(rt,bank)
    print(f"Immutable elite bank: {len(bank[0]):,} transitions (human successes + accepted champion successes)")

    deadline=time.perf_counter()+max(1.0,minutes)*60.0; start=time.perf_counter(); total_trans=0; local_updates=0
    accepts=0; rejects=0; hard_rejects=0; consecutive_rejects=0; last_report=start
    try:
        while time.perf_counter()<deadline:
            local_updates+=1
            # Every challenger starts from the last accepted champion.
            checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt); install_elite(rt,bank)
            focus=int(np.argmin(np.asarray(best_rates))) if best_rates else rt.cfg.sim_curriculum_max
            env=smart.VectorLockSim(rt,rt.cfg.sim_envs,curriculum_level=focus,seed_offset=100003*local_updates)
            tc=time.perf_counter(); batch=make_batch(rt,env); collect_s=time.perf_counter()-tc
            tt=time.perf_counter(); metrics=smart.ppo_update(rt,batch,source="sim"); train_s=time.perf_counter()-tt
            trans=rt.cfg.sim_rollout_steps*rt.cfg.sim_envs; total_trans+=trans

            if metrics.get("reverted",0.0)>0.5:
                hard_rejects+=1; rejects+=1; consecutive_rejects+=1
                rt.cfg.ppo_lr=max(rt.cfg.ppo_min_lr,rt.cfg.ppo_lr*0.70)
                checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt)
                score,worst,rates=best_score,best_worst,best_rates
                decision="HARD-REJECT"
            else:
                score,worst,rates=eval_suite(rt,plan.eval_episodes_per_level)
                # Champion score is hard-level weighted. Do not buy an average
                # improvement by sacrificing the weakest/L4 skill.
                accepted=(score>best_score+0.0005 and worst>=best_worst-0.005 and rates[-1]>=best_rates[-1]-0.005)
                if accepted:
                    old=best_score; best_score,best_worst,best_rates=score,worst,rates
                    rt.save(MAX_CHAMPION); set_champion_anchor(rt)
                    bank=add_accepted_successes(rt,bank,batch); install_elite(rt,bank)
                    accepts+=1; consecutive_rejects=0
                    rt.cfg.ppo_lr=min(rt.cfg.ppo_max_lr,rt.cfg.ppo_lr*1.04)
                    decision=f"ACCEPT +{100*(best_score-old):.2f}pt"
                else:
                    rejects+=1; consecutive_rejects+=1
                    drop=best_score-score
                    if drop>0.010 or metrics.get("kl",0)>rt.cfg.ppo_target_kl:
                        rt.cfg.ppo_lr=max(rt.cfg.ppo_min_lr,rt.cfg.ppo_lr*0.82)
                    checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt)
                    decision=f"REJECT {100*drop:+.2f}pt"

            wall=time.perf_counter()-start; sps=total_trans/max(1e-6,wall); eta=max(0.0,deadline-time.perf_counter())/60.0
            rates_txt=" ".join(f"L{i}:{100*r:4.1f}%" for i,r in enumerate(rates))
            print(f"CH {local_updates:4d} | {decision:16s} | {rates_txt} | champ={100*best_score:5.1f}% worst={100*best_worst:4.1f}% "
                  f"| KL={metrics.get('kl',0):.4f} A-KL={metrics.get('anchor_kl',0):.4f} clip={100*metrics.get('clipfrac',0):4.1f}% "
                  f"E={int(metrics.get('epochs_used',0))} LR={rt.cfg.ppo_lr:.1e} | {sps:,.0f} steps/s | left={eta:.1f}m")
            smart.append_csv(MAX_LOG,
                ["wall_time","challenger","decision","suite_score","suite_worst","level_rates","ppo_kl","anchor_kl","clipfrac","entropy_diff","epochs_used","lr","accepts","rejects","hard_rejects","elite_size","steps_per_second","collect_s","train_s","policy_hash"],
                {"wall_time":time.strftime("%Y-%m-%d %H:%M:%S"),"challenger":local_updates,"decision":decision,
                 "suite_score":score,"suite_worst":worst,"level_rates":";".join(f"{x:.6f}" for x in rates),"ppo_kl":metrics.get("kl",0),
                 "anchor_kl":metrics.get("anchor_kl",0),"clipfrac":metrics.get("clipfrac",0),"entropy_diff":metrics.get("entropy",0),
                 "epochs_used":metrics.get("epochs_used",0),"lr":rt.cfg.ppo_lr,"accepts":accepts,"rejects":rejects,"hard_rejects":hard_rejects,
                 "elite_size":len(bank[0]),"steps_per_second":sps,"collect_s":collect_s,"train_s":train_s,"policy_hash":rt.model_hash()})

            # If pure PPO fails repeatedly, try a tiny teacher/human maintenance
            # challenger. It is accepted by the exact same deterministic gate.
            if consecutive_rejects>=10 and time.perf_counter()<deadline-10:
                ok,best=guarded_maintenance(rt,human_success,(best_score,best_worst,best_rates),plan.eval_episodes_per_level,max(rt.cfg.sim_envs*4,plan.teacher_transitions//40))
                if ok:
                    best_score,best_worst,best_rates=best; accepts+=1; consecutive_rejects=0
                else:
                    consecutive_rejects=0
                install_elite(rt,bank)
            last_report=time.perf_counter()
    except KeyboardInterrupt:
        print("\n[STOP] Ctrl+C received. Champion is already safe on disk.")

    checkpoint_load(rt,MAX_CHAMPION); rt.save()
    wall=time.perf_counter()-start
    print("\n===============================================================")
    print(f"v0.11 COMPLETE | challengers={local_updates} accepted={accepts} rejected={rejects} hard={hard_rejects} | transitions={total_trans:,} | wall={wall/60:.1f} min")
    print("Champion: "+" | ".join(f"L{i}={100*r:.1f}%" for i,r in enumerate(best_rates)))
    print(f"Champion score={100*best_score:.2f}% | worst={100*best_worst:.2f}% | elite={len(bank[0]):,}")
    print(f"Checkpoint: {MAX_CHAMPION}")
    print("Next: START_SMART.bat -> REAL EVALUATE. Offline simulator score is not real-game success.")


def main() -> None:
    ap=argparse.ArgumentParser(description="v0.11 stable champion HOLD-TO-90 offline trainer")
    ap.add_argument("--minutes",type=float,default=None); ap.add_argument("--skip-human",action="store_true")
    args=ap.parse_args(); plan=build_plan(); set_high_priority(); cfg=smart.SmartConfig.load(); smart.set_seeds(cfg.seed)
    rt=smart.SmartRuntime(smart.classic.Config.load(),cfg); apply_plan(rt,plan)
    minutes=args.minutes
    if minutes is None:
        raw=input("How many minutes should STABLE MAX training run? [30]: ").strip()
        try: minutes=float(raw) if raw else 30.0
        except Exception: minutes=30.0
    run_bootcamp(rt,plan,max(1.0,min(float(minutes),24*60.0)),skip_human=args.skip_human)


if __name__=="__main__": main()
