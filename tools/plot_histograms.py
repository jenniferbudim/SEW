"""RGB histogram figure, original vs encrypted, from the metrics JSON the app exports.

Layout (same as the reference figure): left block = original face, right block = encrypted face;
each block has Gray, Red, Green, Blue. (JSON from an older build has no gray; the R+G+B sum is used instead.)

  python plot_histograms.py fdae_metrics_xxx.json                  # trial 1
  python plot_histograms.py fdae_metrics_xxx.json --trial 7        # a specific trial (1-based)
  python plot_histograms.py fdae_metrics_xxx.json --trial all      # sum over every trial
  python plot_histograms.py fdae_metrics_xxx.json --out my_hist    # output name (.png and .pdf)
Needs: pip install matplotlib
Nothing in the app has to change: the JSON already holds a 256-bin histogram per channel.
"""
import argparse, json, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ap = argparse.ArgumentParser()
ap.add_argument("json_file")
ap.add_argument("--trial", default="1", help="1-based trial number, or 'all'")
ap.add_argument("--out", default="histograms")
a = ap.parse_args()

d = json.load(open(a.json_file, encoding="utf-8"))
hs = d.get("histograms")
if not hs:
    sys.exit("No 'histograms' in this JSON. Export it from the metrics screen (Download JSON).")
rows = d.get("rows", [])

def get(kind):
    """Return [R, G, B] counts for one trial, or summed over all trials."""
    if a.trial == "all":
        return [[sum(h[kind][c][b] for h in hs) for b in range(256)] for c in range(3)]
    return hs[int(a.trial) - 1][kind]

def chi2_text():
    if a.trial == "all" or not rows:
        return ""
    r = rows[int(a.trial) - 1]
    if "chi2_cipher" not in r:
        return ""
    return (f"  |  chi-square plain {r['chi2_plain']:.0f}, cipher {r['chi2_cipher']:.1f} "
            f"(critical 293.25), entropy cipher {r['entropy_cipher']:.4f}")

GRAY, COLS, NAMES = "#808080", ["#e8242a", "#0b8043", "#3a54a4"], ["Red (R)", "Green (G)", "Blue (B)"]
fig = plt.figure(figsize=(14, 5.2), constrained_layout=True)
blocks = fig.subfigures(1, 2, wspace=0.05)
for blk, (kind, title) in zip(blocks, [("plain", "Original image"), ("cipher", "Encrypted image")]):
    ch = get(kind)
    gk = kind + "_gray"
    if a.trial == "all":
        gray = [sum(h[gk][b] for h in hs) for b in range(256)] if gk in hs[0] else None
    else:
        gray = hs[int(a.trial) - 1].get(gk)
    if gray is None:   # old JSON without gray: fall back to the R+G+B sum
        gray, gname = [sum(ch[c][b] for c in range(3)) for b in range(256)], " (R+G+B)"
    else:
        gname = ""
    panels = [(gray, GRAY, title + gname), (ch[0], COLS[0], NAMES[0]),
              (ch[1], COLS[1], NAMES[1]), (ch[2], COLS[2], NAMES[2])]
    ax = blk.subplots(2, 2)
    for a_, (counts, colr, ttl) in zip(ax.flat, panels):
        a_.bar(range(256), counts, width=1.0, color=colr)
        if kind == "cipher":
            a_.axhline(sum(counts) / 256, color="k", ls="--", lw=0.8)
        a_.set_title(ttl, fontsize=10)
        a_.set_xlim(0, 255)
        a_.set_ylim(bottom=0)
        a_.tick_params(labelsize=8)
        for s in ("top", "right"):
            a_.spines[s].set_visible(False)
    for a_ in ax[1]:
        a_.set_xlabel("pixel value", fontsize=9)
    for a_ in ax[:, 0]:
        a_.set_ylabel("pixel count", fontsize=9)
which = "all trials summed" if a.trial == "all" else f"trial {a.trial}"
fig.suptitle(f"Histogram of RGB channels before and after encryption ({which}){chi2_text()}"
             "   [dashed = ideal uniform]", fontsize=10)
fig.savefig(a.out + ".png", dpi=200)
fig.savefig(a.out + ".pdf")
print("saved", a.out + ".png and", a.out + ".pdf")
