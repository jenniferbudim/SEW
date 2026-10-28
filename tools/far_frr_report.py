"""
Face-verification error rates from the app's `faceLogs` export.

Input : CSV from fetch_facelogs.py (or a JSON list with the same field names).
Output: far_frr_table.csv, face_report.json, face_roc.png / face_roc.pdf and a text summary on screen.

How attempts are classified (the `label` field set on the calibration sign-in screen):
    me              genuine   : the account owner on their own account
    impostor[:id]   impostor  : another person on someone else's account (the cross-test)
    spoof-print / spoof-screen[:id]  presentation attack (photo of the owner)
Only rows with event == "verify" are used. Attempts without a score ("no face found", "several faces", "face too
small") are failures to acquire; they are counted and reported, not mixed into FAR/FRR.

Definitions (ISO/IEC 19795-1; a score is ACCEPTED when score >= threshold)
    FRR(t) = share of genuine attempts with score <  t
    FAR(t) = share of impostor attempts with score >= t
    EER    = the point where FAR == FRR (taken at the threshold with the smallest |FAR-FRR|, value = their mean)
Liveness (ISO/IEC 30107-3). liveScore is a SPOOF score, so lower = more live: an attempt is called live if
liveScore < threshold.
    BPCER(t) = share of genuine attempts called spoof   (liveScore >= t)
    APCER(t) = share of attack attempts called live     (liveScore <  t)       ACER = (APCER + BPCER) / 2

Usage
    python far_frr_report.py facelogs.csv
    python far_frr_report.py facelogs.csv --far-targets 0.1 0.01 0.001 --live-threshold 0.4 --out-prefix run1
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from collections import defaultdict
from pathlib import Path

import numpy as np


# ----------------------------------------------------------------------------------------------- loading
def _num(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return None if (isinstance(v, float) and math.isnan(v)) else float(v)
    s = str(v).strip()
    if s == "" or s.lower() in ("none", "null", "nan"):
        return None
    try:
        return float(s)
    except ValueError:
        return None


def load_rows(path: Path) -> list[dict]:
    if path.suffix.lower() == ".json":
        data = json.loads(path.read_text(encoding="utf-8"))
        rows = data["rows"] if isinstance(data, dict) and "rows" in data else data
    else:
        with open(path, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
    return rows


def classify(label: str) -> tuple[str, str]:
    """-> (class, tester id). class in genuine / impostor / spoof / other."""
    label = (label or "").strip()
    base, _, who = label.partition(":")
    base = base.strip().lower()
    if base in ("me", ""):
        return "genuine", ""
    if base.startswith("impostor"):
        return "impostor", who.strip() or "?"
    if base.startswith("spoof"):
        return "spoof", base + (":" + who.strip() if who.strip() else "")
    return "other", label


# ----------------------------------------------------------------------------------------------- statistics
def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """95 % Wilson score interval for a proportion k/n."""
    if n == 0:
        return (float("nan"), float("nan"))
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, (c - h) / d), min(1.0, (c + h) / d))


def rates_at(gen: np.ndarray, imp: np.ndarray, t: float) -> dict:
    frr_k = int((gen < t).sum())
    far_k = int((imp >= t).sum())
    flo, fhi = wilson(frr_k, len(gen))
    alo, ahi = wilson(far_k, len(imp))
    return {
        "threshold": t,
        "FAR": far_k / len(imp) if len(imp) else float("nan"),
        "FAR_ci95": [alo, ahi],
        "FRR": frr_k / len(gen) if len(gen) else float("nan"),
        "FRR_ci95": [flo, fhi],
        "TAR": 1 - frr_k / len(gen) if len(gen) else float("nan"),
    }


def sweep(gen: np.ndarray, imp: np.ndarray) -> list[dict]:
    """Rates at every distinct score (plus one above the maximum, where nothing is accepted)."""
    pts = sorted(set(gen.tolist()) | set(imp.tolist()))
    pts.append(pts[-1] + 1e-6)
    return [rates_at(gen, imp, t) for t in pts]


def dprime(gen: np.ndarray, imp: np.ndarray) -> float:
    if len(gen) < 2 or len(imp) < 2:
        return float("nan")
    s = math.sqrt((gen.var(ddof=1) + imp.var(ddof=1)) / 2)
    return float((gen.mean() - imp.mean()) / s) if s > 0 else float("inf")


def eer_of(curve: list[dict]) -> dict:
    best = min(curve, key=lambda r: (abs(r["FAR"] - r["FRR"]), r["threshold"]))
    return {"threshold": best["threshold"], "EER": (best["FAR"] + best["FRR"]) / 2, "FAR": best["FAR"], "FRR": best["FRR"]}


def threshold_for_far(curve: list[dict], target: float) -> dict:
    """Lowest threshold whose FAR <= target (lowest threshold = fewest genuine rejections)."""
    ok = [r for r in curve if r["FAR"] <= target]
    return min(ok, key=lambda r: r["threshold"]) if ok else curve[-1]


# ----------------------------------------------------------------------------------------------- main
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", type=Path)
    ap.add_argument("--far-targets", type=float, nargs="+", default=[0.1, 0.01, 0.001])
    ap.add_argument("--grid", type=float, nargs=3, metavar=("LO", "HI", "STEP"), default=[0.0, 1.0, 0.05],
                    help="threshold grid for the printed table")
    ap.add_argument("--live-threshold", type=float, default=0.4, help="kLiveThreshold currently in the app")
    ap.add_argument("--out-prefix", default="face", help="prefix of the files that are written")
    ap.add_argument("--no-plot", action="store_true")
    a = ap.parse_args()

    rows = [r for r in load_rows(a.logs) if str(r.get("event", "")).strip() == "verify"]
    if not rows:
        raise SystemExit("No rows with event == 'verify' in that file.")

    gen, imp, spf = [], [], []
    fta = defaultdict(int)  # failures to acquire per class
    per_uid = defaultdict(lambda: defaultdict(int))
    per_tester = defaultdict(list)
    live_gen, live_att = [], []  # (liveScore, attack-type)
    sharp_gen = []
    other = 0
    for r in rows:
        cls, who = classify(str(r.get("label", "")))
        if cls == "other":
            other += 1
            continue
        s = _num(r.get("score"))
        per_uid[str(r.get("uid", ""))[:8]][cls] += 1
        if s is None:
            fta[cls] += 1
        elif cls == "genuine":
            gen.append(s)
        elif cls == "impostor":
            imp.append(s)
            per_tester[who].append(s)
        elif cls == "spoof":
            spf.append((s, who))
        ls = _num(r.get("liveScore"))
        if ls is not None:
            if cls == "genuine":
                live_gen.append(ls)
            elif cls == "spoof":
                live_att.append((ls, who))
        sh = _num(r.get("sharpness"))
        if sh is not None and cls == "genuine":
            sharp_gen.append(sh)

    gen_a, imp_a = np.array(gen), np.array(imp)
    out: dict = {"counts": {"genuine": len(gen), "impostor": len(imp), "spoof_with_score": len(spf),
                            "failure_to_acquire": dict(fta), "ignored_other_labels": other},
                 "per_account": {k: dict(v) for k, v in per_uid.items()}}
    lines: list[str] = []
    P = lines.append

    P("=" * 78)
    P("FACE VERIFICATION ERROR RATES")
    P("=" * 78)
    P(f"genuine attempts with a score : {len(gen)}   (failures to acquire: {fta.get('genuine', 0)})")
    P(f"impostor attempts with a score: {len(imp)}   (failures to acquire: {fta.get('impostor', 0)})")
    if spf:
        P(f"attack attempts with a score  : {len(spf)}   (failures to acquire: {fta.get('spoof', 0)})")
    P("accounts (first 8 chars of uid): " + ", ".join(f"{k}: {dict(v)}" for k, v in per_uid.items()))
    warn = []
    if len(gen) < 50:
        warn.append(f"only {len(gen)} genuine attempts (aim for >= 50, in varied light / angle / distance)")
    if len(imp) < 100:
        warn.append(f"only {len(imp)} impostor attempts (aim for >= 100 from >= 10 different people)")
    if len(per_tester) < 10 and imp:
        warn.append(f"only {len(per_tester)} different impostor tester(s) (aim for >= 10)")
    for w in warn:
        P("WARNING: " + w)

    if len(gen) and len(imp):
        curve = sweep(gen_a, imp_a)
        eer = eer_of(curve)
        out["scores"] = {
            "genuine": {"mean": float(gen_a.mean()), "std": float(gen_a.std(ddof=1)) if len(gen) > 1 else None,
                        "min": float(gen_a.min()), "max": float(gen_a.max())},
            "impostor": {"mean": float(imp_a.mean()), "std": float(imp_a.std(ddof=1)) if len(imp) > 1 else None,
                         "min": float(imp_a.min()), "max": float(imp_a.max())},
            "d_prime": dprime(gen_a, imp_a),
        }
        out["EER"] = eer
        P("")
        P(f"genuine  scores: mean {gen_a.mean():.3f}  min {gen_a.min():.3f}  max {gen_a.max():.3f}")
        P(f"impostor scores: mean {imp_a.mean():.3f}  min {imp_a.min():.3f}  max {imp_a.max():.3f}")
        P(f"d-prime (separation of the two groups): {out['scores']['d_prime']:.2f}")
        overlap = gen_a.min() <= imp_a.max()
        P("the two score groups " + ("OVERLAP" if overlap else "do NOT overlap (a threshold between them gives 0 errors on this data)"))
        P("")
        P(f"EER = {eer['EER'] * 100:.2f} %  at threshold {eer['threshold']:.3f}   (FAR {eer['FAR'] * 100:.2f} %, FRR {eer['FRR'] * 100:.2f} %)")

        # table on a regular grid
        lo, hi, st = a.grid
        grid = [round(x, 6) for x in np.arange(lo, hi + st / 2, st)]
        table = [rates_at(gen_a, imp_a, t) for t in grid]
        with open(f"{a.out_prefix}_far_frr_table.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["threshold", "FAR", "FAR_ci95_lo", "FAR_ci95_hi", "FRR", "FRR_ci95_lo", "FRR_ci95_hi", "TAR"])
            for r in table:
                w.writerow([r["threshold"], r["FAR"], *r["FAR_ci95"], r["FRR"], *r["FRR_ci95"], r["TAR"]])
        P("")
        P(f"{'threshold':>9} | {'FAR %':>7} {'(95% CI)':>16} | {'FRR %':>7} {'(95% CI)':>16}")
        P("-" * 66)
        for r in table:
            P(f"{r['threshold']:9.2f} | {r['FAR'] * 100:7.2f} ({r['FAR_ci95'][0] * 100:5.1f}-{r['FAR_ci95'][1] * 100:5.1f}) | "
              f"{r['FRR'] * 100:7.2f} ({r['FRR_ci95'][0] * 100:5.1f}-{r['FRR_ci95'][1] * 100:5.1f})")
        out["table"] = table

        # thresholds for FAR targets
        P("")
        P("Threshold for a target FAR (lowest threshold that meets it):")
        P(f"{'target FAR':>10} | {'threshold':>9} | {'FAR %':>7} | {'FRR %':>7} | resolvable with this many impostor attempts?")
        P("-" * 78)
        out["far_targets"] = []
        for tgt in a.far_targets:
            r = threshold_for_far(curve, tgt)
            need = math.ceil(3 / tgt)  # "rule of three": 0 errors in N trials -> FAR < 3/N with 95 % confidence
            ok = len(imp) >= need
            P(f"{tgt * 100:9.2f}% | {r['threshold']:9.3f} | {r['FAR'] * 100:7.2f} | {r['FRR'] * 100:7.2f} | "
              f"{'yes' if ok else f'NO, needs >= {need} impostor attempts'}")
            out["far_targets"].append({"target": tgt, **r, "resolvable": ok, "attempts_needed": need})

        # per impostor tester
        if per_tester:
            P("")
            P("Impostor scores per tester (a person who scores high is the one who fools the system):")
            for who, v in sorted(per_tester.items(), key=lambda kv: -np.max(kv[1])):
                P(f"  {who:>12}: n={len(v):3d}  mean {np.mean(v):.3f}  max {np.max(v):.3f}")

        # attacks that reach the matcher
        if spf:
            P("")
            P("Presentation attacks that got a match score (liveness off or in log-only mode):")
            by = defaultdict(list)
            for s, who in spf:
                by[who.split(":")[0]].append(s)
            for k, v in by.items():
                P(f"  {k:>12}: n={len(v):3d}  mean {np.mean(v):.3f}  max {np.max(v):.3f}")
            e_t = eer["threshold"]
            P(f"  accepted at the EER threshold {e_t:.3f}: {sum(1 for s, _ in spf if s >= e_t)} of {len(spf)}")
    else:
        curve = []
        P("")
        P("Need at least one genuine AND one impostor attempt with a score to compute FAR/FRR.")

    # ---------------------------------------------------------------- liveness
    if live_gen or live_att:
        P("")
        P("=" * 78)
        P("LIVENESS (lower liveScore = more live; live if liveScore < threshold)")
        P("=" * 78)
        lg = np.array(live_gen)
        la = np.array([s for s, _ in live_att])
        P(f"genuine attempts with liveScore: {len(lg)}   attack attempts: {len(la)}")
        out["liveness"] = {"genuine_n": len(lg), "attack_n": len(la)}

        def lrates(t: float) -> dict:
            bp = float((lg >= t).mean()) if len(lg) else float("nan")
            ap_ = float((la < t).mean()) if len(la) else float("nan")
            return {"threshold": t, "BPCER": bp, "APCER": ap_, "ACER": (bp + ap_) / 2}

        cur = lrates(a.live_threshold)
        P(f"at the app's current threshold {a.live_threshold}: BPCER {cur['BPCER'] * 100:.1f} % (real faces rejected), "
          f"APCER {cur['APCER'] * 100:.1f} % (attacks accepted), ACER {cur['ACER'] * 100:.1f} %")
        out["liveness"]["at_current_threshold"] = cur
        if len(lg) and len(la):
            cand = sorted(set(lg.tolist()) | set(la.tolist()))
            cand.append(cand[-1] + 1e-6)
            sw = [lrates(t) for t in cand]
            best = min(sw, key=lambda r: (r["ACER"], r["threshold"]))
            P(f"lowest ACER {best['ACER'] * 100:.1f} % at threshold {best['threshold']:.3f} "
              f"(BPCER {best['BPCER'] * 100:.1f} %, APCER {best['APCER'] * 100:.1f} %)")
            out["liveness"]["best_acer"] = best
            for b in (0.05, 0.10):
                ok = [r for r in sw if r["BPCER"] <= b]
                if ok:
                    r = min(ok, key=lambda r: r["threshold"])  # lowest threshold = fewest attacks accepted
                    P(f"threshold with BPCER <= {b * 100:.0f} % (reject at most that share of real faces): {r['threshold']:.3f} -> APCER {r['APCER'] * 100:.1f} %")
            kinds = defaultdict(list)
            for s, who in live_att:
                kinds[who.split(":")[0]].append(s)
            for k, v in kinds.items():
                P(f"  attack type {k:>12}: n={len(v)}  APCER at {a.live_threshold}: {np.mean(np.array(v) < a.live_threshold) * 100:.1f} %")
        if sharp_gen:
            sg = np.array(sharp_gen)
            P(f"sharpness of genuine captures: min {sg.min():.0f}  5th pct {np.percentile(sg, 5):.0f}  median {np.median(sg):.0f}"
              "  (kMinSharpness should sit below the 5th percentile)")
            out["liveness"]["sharpness_genuine"] = {"min": float(sg.min()), "p5": float(np.percentile(sg, 5)), "median": float(np.median(sg))}

    P("")
    P("NOTE: error rates measured on a handful of people describe THIS test, not the population. Report the sample sizes and the")
    P("confidence intervals above, and do not quote a FAR below ~3/N (N = impostor attempts).")

    text = "\n".join(lines)
    print(text)
    Path(f"{a.out_prefix}_report.txt").write_text(text, encoding="utf-8")
    Path(f"{a.out_prefix}_report.json").write_text(json.dumps(out, indent=2, default=float), encoding="utf-8")

    # ---------------------------------------------------------------- figure
    if a.no_plot or not (len(gen) and len(imp)):
        return
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    has_live = len(live_gen) and len(live_att)
    fig, ax = plt.subplots(1, 3 if has_live else 2, figsize=(16 if has_live else 11, 4.3))
    bins = np.linspace(min(gen_a.min(), imp_a.min(), 0.0), max(gen_a.max(), imp_a.max(), 1.0), 41)
    ax[0].hist(imp_a, bins, alpha=0.65, label=f"impostor (n={len(imp)})", color="#c0392b")
    ax[0].hist(gen_a, bins, alpha=0.65, label=f"genuine (n={len(gen)})", color="#1e7b4b")
    if spf:
        ax[0].hist([s for s, _ in spf], bins, histtype="step", lw=1.6, label=f"attack (n={len(spf)})", color="#555")
    ax[0].axvline(eer["threshold"], color="k", ls="--", lw=1, label=f"EER threshold {eer['threshold']:.2f}")
    t1 = threshold_for_far(curve, 0.01)
    ax[0].axvline(t1["threshold"], color="#2c3e50", ls=":", lw=1.2, label=f"FAR<=1% threshold {t1['threshold']:.2f}")
    ax[0].set(xlabel="cosine similarity", ylabel="attempts", title="Score distributions")
    ax[0].legend(fontsize=8)

    far = np.array([r["FAR"] for r in curve])
    tar = np.array([r["TAR"] for r in curve])
    ax[1].step(np.maximum(far, 1e-4), tar, where="post", color="#34495e")
    ax[1].scatter([max(eer["FAR"], 1e-4)], [1 - eer["FRR"]], color="#c0392b", zorder=3, label=f"EER {eer['EER'] * 100:.1f}%")
    ax[1].set_xscale("log")
    ax[1].set(xlabel="FAR (log scale)", ylabel="TAR = 1 - FRR", title="ROC", ylim=(0, 1.02))
    ax[1].grid(alpha=0.3, which="both")
    ax[1].legend(fontsize=8)

    if has_live:
        lg_, la_ = np.array(live_gen), np.array([s for s, _ in live_att])
        lb = np.linspace(min(lg_.min(), la_.min(), 0), max(lg_.max(), la_.max(), 1), 31)
        ax[2].hist(lg_, lb, alpha=0.65, label=f"real (n={len(lg_)})", color="#1e7b4b")
        ax[2].hist(la_, lb, alpha=0.65, label=f"attack (n={len(la_)})", color="#c0392b")
        ax[2].axvline(a.live_threshold, color="k", ls="--", lw=1, label=f"current threshold {a.live_threshold}")
        ax[2].set(xlabel="liveScore (lower = more live)", ylabel="attempts", title="Liveness")
        ax[2].legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(f"{a.out_prefix}_roc.png", dpi=200)
    fig.savefig(f"{a.out_prefix}_roc.pdf")
    print(f"\nwrote {a.out_prefix}_far_frr_table.csv, {a.out_prefix}_report.json/.txt, {a.out_prefix}_roc.png/.pdf")


if __name__ == "__main__":
    main()
