"""Plots for the thesis test suite (test/thesis/thesis_tests.dart).

  python tools/plot_thesis_tests.py thesis_results/thesis_results.json --out thesis_results/fig
Writes fig_A.png/.pdf, fig_B.png/.pdf, fig_C.png/.pdf, fig_G.png/.pdf and prints a short text summary.
Needs: pip install matplotlib numpy
"""
import argparse, json, math
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SF, INK, MUT, B, OR, GR = "#fcfcfb", "#1f2328", "#6b7280", "#2a78d6", "#eb6834", "#2f9e6b"
plt.rcParams.update({"figure.facecolor": SF, "axes.facecolor": SF, "savefig.facecolor": SF, "font.size": 10,
                     "axes.edgecolor": MUT, "axes.labelcolor": INK, "xtick.color": INK, "ytick.color": INK,
                     "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True, "grid.color": "#e6e6e3"})

def save(f, stem):
    f.savefig(stem + ".png", dpi=200); f.savefig(stem + ".pdf"); plt.close(f)

def tag(ax, t): ax.set_title(t, loc="left", fontsize=10.5, color=INK, fontweight="bold")

def fig_A(R, out):
    f, ax = plt.subplots(1, 2, figsize=(12.5, 4.4), constrained_layout=True, gridspec_kw=dict(width_ratios=[1.5, 1]))
    rows = R["A1_differential"]["rows"]
    pix = sorted({r["pixels"] for r in rows})
    lo_all = [r["npcr_min"] for r in rows]
    for kind, c, ls in (("lsb", B, "-"), ("invert", OR, "--")):
        y = [np.mean([r["npcr"] for r in rows if r["pixels"] == p and r["change"] == kind]) for p in pix]
        lo = [min(r["npcr_min"] for r in rows if r["pixels"] == p and r["change"] == kind) for p in pix]
        ax[0].plot(range(len(pix)), y, ls, marker="o", color=c, label=f"change = {kind} (mean of 4 positions)")
        ax[0].scatter(range(len(pix)), lo, marker="v", s=28, color=c, alpha=.6)
    ax[0].axhline(99.6094, color=INK, ls=":", lw=1); ax[0].text(0.02, 99.62, "ideal 99.6094 %", fontsize=8, color=MUT)
    ax[0].set_xticks(range(len(pix))); ax[0].set_xticklabels([str(p) for p in pix])
    ax[0].set_xlabel("Number of changed pixels"); ax[0].set_ylabel("NPCR between the two ciphertexts (%)")
    ax[0].set_ylim(max(0, min(lo_all) - 3), 100.2); ax[0].legend(loc="lower right", frameon=False, fontsize=8)
    tag(ax[0], "(a) Differential attack (triangles = lowest single case)")
    a2 = R["A2_equivalent_keystream_attack"]
    names = [("chosen_plaintext_all_zero", "FDAE, chosen plaintext\n(all-zero image)", B),
             ("known_plaintext_pair", "FDAE, known\nplaintext pair", B),
             ("xor_stream_cipher_baseline", "Plain XOR cipher\n(baseline)", OR)]
    x = np.arange(3)
    ax[1].bar(x, [a2[k]["npcr"] for k, _, _ in names], color=[c for _, _, c in names], width=.55)
    for i, (k, _, _) in enumerate(names):
        ax[1].text(i, a2[k]["npcr"] + 2, f"{a2[k]['npcr']:.1f} %\n|corr| {abs(a2[k]['corr'] or 0):.3f}", ha="center", fontsize=8.5)
    ax[1].set_xticks(x); ax[1].set_xticklabels([n for _, n, _ in names], fontsize=8.5); ax[1].set_ylim(0, 125)
    ax[1].set_ylabel("NPCR: recovered vs real image (%)\n100 = nothing recovered")
    tag(ax[1], "(b) Equivalent-keystream attack")
    f.suptitle("Figure A. Attack simulations", x=0.01, ha="left", fontsize=10, color=MUT)
    save(f, out + "_A")

def fig_B(R, out):
    B_ = R["B_wrong_key"]
    f, ax = plt.subplots(1, 2, figsize=(12.5, 4.4), constrained_layout=True, gridspec_kw=dict(width_ratios=[1.6, 1]))
    cols = dict(x0="#2a78d6", mu1="#eb6834", z0="#2f9e6b", r="#8b5cf6", y0="#d4a017", mu2="#6b7280")
    for p, d in B_["near_key"].items():
        t = d["table"]
        ax[0].plot([r["exponent"] for r in t], [r["npcr"] for r in t], "-o", ms=4, color=cols[p], label=f"{p}  (kmax={d['kmax']})")
    ax[0].axhline(99.6094, color=INK, ls=":", lw=1)
    ax[0].set_xlabel("Key error = 10^-k added to ONE parameter (k)"); ax[0].set_ylabel("NPCR: original vs decrypted (%)")
    ax[0].set_ylim(-3, 104); ax[0].legend(ncol=2, frameon=False, fontsize=8, loc="center right")
    tag(ax[0], "(a) Decrypting with a slightly wrong key")
    items = [("Correct key", B_["correct_key"]), ("Random wrong key", B_["random_wrong_keys"]),
             ("Wrong IV bit", R["B4_wrong_iv_and_n0"]["wrong_iv_bit"]), ("Wrong n0 (+1)", R["B4_wrong_iv_and_n0"]["wrong_n0_plus_1"])]
    x = np.arange(len(items))
    ax[1].bar(x, [d["npcr"] for _, d in items], color=[GR, B, OR, B], width=.55)
    for i, (_, d) in enumerate(items):
        ax[1].text(i, d["npcr"] + 2, f"{d['npcr']:.1f} %\nSSIM {d['ssim']:.2f}", ha="center", fontsize=8.5)
    ax[1].set_xticks(x); ax[1].set_xticklabels([n for n, _ in items], fontsize=8.5, rotation=10); ax[1].set_ylim(0, 125)
    ax[1].set_ylabel("NPCR: original vs decrypted (%)")
    tag(ax[1], "(b) When the decrypted image differs")
    f.suptitle(f"Figure B. Decryption mismatch. Key bits from measured sensitivity: {B_['effective_key_bits_from_sensitivity']:.1f}", x=0.01, ha="left", fontsize=10, color=MUT)
    save(f, out + "_B")

def fig_C(R, out):
    C = R["C_ciphertext_damage"]["results"]; units = R["C_ciphertext_damage"]["units"]
    f, ax = plt.subplots(2, 3, figsize=(13, 7), constrained_layout=True)
    order = [("flip", "(a) Flipped bits in the ciphertext"), ("loss", "(b) One lost block"), ("saltpepper", "(c) Salt-and-pepper noise"),
             ("gauss", "(d) Gaussian noise"), ("jpeg", "(e) JPEG recompression")]
    for a, (k, ttl) in zip(ax.ravel()[:5], order):
        rows = C.get(k, [])
        xs = [r["level"] for r in rows]
        a.plot(range(len(xs)), [r["ssim"] for r in rows], "-o", color=B, label="SSIM of restored image")
        a.plot(range(len(xs)), [r["exact_rate"] for r in rows], "--s", color=OR, ms=4, label="share restored exactly")
        a.set_xticks(range(len(xs))); a.set_xticklabels([f"{v:g}" for v in xs]); a.set_ylim(-0.05, 1.05)
        a.set_xlabel(units[k]); tag(a, ttl)
    ax.ravel()[0].legend(frameon=False, fontsize=8, loc="center right")
    a = ax.ravel()[5]
    P = R["C5_png_file_damage"]["outcomes"]; keys = list(P.keys()); cats = ["exact", "wrong_image", "manifest_lost", "decode_failed"]
    cc = [GR, OR, "#d4a017", MUT]; bottom = np.zeros(len(keys))
    for c, col in zip(cats, cc):
        v = np.array([P[k][c] for k in keys], float); tot = np.array([sum(P[k].values()) for k in keys], float)
        a.barh(range(len(keys)), v / tot, left=bottom, color=col, label=c.replace("_", " ")); bottom += v / tot
    a.set_yticks(range(len(keys))); a.set_yticklabels([k.replace("|", " = ") for k in keys], fontsize=8); a.set_xlim(0, 1)
    a.legend(frameon=False, fontsize=7.5, loc="lower right"); tag(a, "(f) Damaged PNG file (byte errors / truncation)")
    f.suptitle("Figure C. Corruption in transmission or storage (SSIM 1 = identical to the original)", x=0.01, ha="left", fontsize=10, color=MUT)
    save(f, out + "_C")

def fig_G(R, out):
    G = R["G1_bruteforce_scaling"]
    f, ax = plt.subplots(1, 2, figsize=(12.5, 4.4), constrained_layout=True)
    b = np.array([r["key_bits"] for r in G["rows"]]); t = np.array([r["mean_trials"] for r in G["rows"]])
    ax[0].plot(b, np.log2(t), "o", color=B, label="measured (mean of repeated searches)")
    ax[0].plot(b, b - 1, "--", color=INK, lw=1, label="expected 2^(bits - 1)")
    ax[0].set_xlabel("Key size searched (bits)"); ax[0].set_ylabel("log2(number of keys tried)")
    ax[0].legend(frameon=False, fontsize=8); tag(ax[0], "(a) Brute-force work doubles with every key bit")
    E = G["extrapolation"]; eb = [e["key_bits"] for e in E]; ly = [e["log10_years_one_machine"] for e in E]
    ax[1].plot(eb, ly, "-o", color=OR, ms=4)
    ax[1].axhline(math.log10(1.38e10), color=INK, ls=":", lw=1); ax[1].text(eb[0], math.log10(1.38e10) + .8, "age of the universe (1.4e10 years)", fontsize=8, color=MUT)
    ax[1].set_xlabel("Key size (bits)"); ax[1].set_ylabel("log10(years), one core of this computer")
    tag(ax[1], "(b) Extrapolated time to search the whole key space")
    g2 = R["G2_key_sizes"]
    f.suptitle(f"Figure G. Key size vs security. Parameter space {g2['parameter_space_bits_resolution_1e-15']:.0f} bits, derived key 256 bits, "
               f"effective at most {g2['effective_bits_upper_bound']:.0f} bits", x=0.01, ha="left", fontsize=10, color=MUT)
    save(f, out + "_G")

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("json"); ap.add_argument("--out", default="fig")
    a = ap.parse_args(); R = json.load(open(a.json))
    for fn, key in ((fig_A, "A1_differential"), (fig_B, "B_wrong_key"), (fig_C, "C_ciphertext_damage"), (fig_G, "G1_bruteforce_scaling")):
        if key in R: fn(R, a.out)
        else: print("missing", key, "- run the whole suite")
    print("A4 same image/different keys NPCR:", R.get("A4_key_dependence", {}).get("npcr"))
    print("A3 all-black entropy:", R.get("A3_special_plaintexts", {}).get("all_black", {}).get("entropy"))
    print("B5 chip:", R.get("B5_chip_integrity")); print("C6 tamper:", R.get("C6_chip_tamper"))

if __name__ == "__main__":
    main()