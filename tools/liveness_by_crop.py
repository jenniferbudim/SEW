"""
Does a wider liveness crop separate real faces from attacks? Reads the faceLogs export (fetch_facelogs.py).

Each verify attempt logs liveMode as "logOnly|crop1.4" (mode | crop scale). Rows from older builds have no "|crop" part
and are treated as scale 1.0 (the tight crop that was used before).

REAL   = label "me" or "impostor[:id]"  (any live person in front of the camera; family members count as real here)
ATTACK = label "spoof-print" / "spoof-screen" (a photo or a screen of a face)
liveScore is a SPOOF score: lower = more live. A face is called live if liveScore < threshold.

Per crop scale it prints
    n real / n attack, median score of each
    AUC     = chance that a random real face scores LOWER than a random attack (1.0 = perfect, 0.5 = useless)
    ACER-best threshold with BPCER / APCER   (BPCER = real faces called spoof, APCER = attacks called live)
    at the app's current threshold (--threshold, default 0.4)
    the threshold that rejects at most 5 % of real faces and the APCER it gives
    the sharpness of real captures (a wider crop changes it, so kMinSharpness may need to move)

    python liveness_by_crop.py facelogs.csv
    python liveness_by_crop.py facelogs.csv --threshold 0.4 --out live_by_crop.png
Needs numpy and matplotlib. Attempts that never reached the model (too blurry, no face) are listed but not scored.
"""
import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path

import numpy as np


def num(v):
    try:
        x = float(str(v).strip())
        return None if math.isnan(x) else x
    except ValueError:
        return None


def scale_of(mode: str) -> float:
    if "|crop" in (mode or ""):
        try:
            return float(mode.split("|crop", 1)[1])
        except ValueError:
            pass
    return 1.0


def kind_of(label: str):
    base = (label or "").split(":", 1)[0].strip().lower()
    if base in ("me", "") or base.startswith("impostor"):
        return "real"
    if base.startswith("spoof"):
        return "attack"
    return None


def auc_lower_is_real(real: np.ndarray, att: np.ndarray) -> float:
    if not len(real) or not len(att):
        return float("nan")
    lt = (real[:, None] < att[None, :]).sum()
    eq = (real[:, None] == att[None, :]).sum()
    return float((lt + 0.5 * eq) / (len(real) * len(att)))


def rates(real, att, t):
    bp = float((real >= t).mean()) if len(real) else float("nan")
    ap = float((att < t).mean()) if len(att) else float("nan")
    return bp, ap


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", type=Path)
    ap.add_argument("--threshold", type=float, default=0.4)
    ap.add_argument("--out", default="live_by_crop.png")
    ap.add_argument("--min-n", type=int, default=10, help="attempts per group needed before a scale is trusted")
    a = ap.parse_args()

    with open(a.logs, newline="", encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f) if r.get("event") == "verify"]

    real = defaultdict(list)
    att = defaultdict(list)
    sharp = defaultdict(list)
    unscored = defaultdict(int)
    for r in rows:
        k = kind_of(r.get("label", ""))
        if k is None:
            continue
        sc = scale_of(r.get("liveMode", ""))
        ls = num(r.get("liveScore"))
        if ls is None:
            unscored[(sc, k)] += 1
            continue
        (real if k == "real" else att)[sc].append(ls)
        sh = num(r.get("sharpness"))
        if sh is not None and k == "real":
            sharp[sc].append(sh)

    scales = sorted(set(real) | set(att) | {s for s, _ in unscored})
    if not scales:
        raise SystemExit("No verify rows with a label I can use (me / impostor / spoof-*).")

    print("=" * 86)
    print(f"{'crop':>5} | {'n real':>6} {'n att':>5} | {'median real':>11} {'median att':>10} | {'AUC':>5} | "
          f"{'BPCER@%.2f' % a.threshold:>10} {'APCER@%.2f' % a.threshold:>10}")
    print("-" * 86)
    best_auc, best_scale = -1.0, None
    detail = []
    for sc in scales:
        r_, a_ = np.array(real[sc]), np.array(att[sc])
        auc = auc_lower_is_real(r_, a_)
        bp, apc = rates(r_, a_, a.threshold)
        mr = f"{np.median(r_):11.3f}" if len(r_) else f"{'-':>11}"
        ma = f"{np.median(a_):10.3f}" if len(a_) else f"{'-':>10}"
        print(f"x{sc:<4} | {len(r_):6d} {len(a_):5d} | {mr} {ma} | {auc:5.2f} | {bp * 100:9.1f}% {apc * 100:9.1f}%")
        detail.append((sc, r_, a_, auc))
        if len(r_) >= a.min_n and len(a_) >= a.min_n and auc > best_auc:
            best_auc, best_scale = auc, sc
    print("=" * 86)
    for (sc, k), n in sorted(unscored.items()):
        print(f"x{sc}: {n} {k} attempt(s) never reached the model (too blurry / no face) - not scored")

    for sc, r_, a_, auc in detail:
        if not len(r_) or not len(a_):
            continue
        print(f"\n--- crop x{sc} ---")
        cand = sorted(set(r_.tolist()) | set(a_.tolist()))
        cand.append(cand[-1] + 1e-6)
        sw = []
        for t in cand:
            bp, apc = rates(r_, a_, t)
            sw.append((t, bp, apc, (bp + apc) / 2))
        t, bp, apc, acer = min(sw, key=lambda x: (x[3], x[0]))
        print(f"lowest ACER {acer * 100:.1f}% at threshold {t:.3f}   (BPCER {bp * 100:.1f}%, APCER {apc * 100:.1f}%)")
        ok = [x for x in sw if x[1] <= 0.05]
        if ok:
            t5 = min(ok, key=lambda x: x[0])
            print(f"rejecting at most 5% of real faces needs threshold {t5[0]:.3f} -> APCER {t5[2] * 100:.1f}%")
        if sc in sharp and sharp[sc]:
            s = np.array(sharp[sc])
            print(f"sharpness of real captures: min {s.min():.0f}, 5th pct {np.percentile(s, 5):.0f}, median {np.median(s):.0f}")
        if len(r_) < a.min_n or len(a_) < a.min_n:
            print(f"(only {len(r_)} real / {len(a_)} attack attempts: too few to trust, aim for >= {a.min_n} each)")

    print()
    if best_scale is None:
        print(f"No scale has >= {a.min_n} real AND >= {a.min_n} attack attempts yet. Collect more before choosing.")
    else:
        print(f"Best separation so far: x{best_scale} (AUC {best_auc:.2f}). "
              + ("AUC near 0.5 means this model does not tell real faces from attacks on your phone at any crop."
                 if best_auc < 0.75 else "Use its thresholds from above; confirm with a fresh test set."))

    # ---- plot
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(1.6 * max(3, len(scales)) + 3, 4.3))
    rng = np.random.default_rng(0)
    for i, (sc, r_, a_, _) in enumerate(detail):
        ax.scatter(i - 0.18 + rng.uniform(-0.07, 0.07, len(r_)), r_, c="#1e7b4b", s=22, alpha=0.8,
                   label="real" if i == 0 else None)
        ax.scatter(i + 0.18 + rng.uniform(-0.07, 0.07, len(a_)), a_, c="#c0392b", s=22, alpha=0.8,
                   label="attack" if i == 0 else None)
    ax.axhline(a.threshold, color="k", ls="--", lw=1, label=f"threshold {a.threshold}")
    ax.set_xticks(range(len(detail)))
    ax.set_xticklabels([f"x{sc}\nAUC {auc:.2f}" if not math.isnan(auc) else f"x{sc}" for sc, _, _, auc in detail])
    ax.set(ylabel="liveScore (lower = more live)", xlabel="liveness crop scale", title="Liveness score by crop scale")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(a.out, dpi=200)
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
