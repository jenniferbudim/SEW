"""Adjacent-pixel correlation (R, G, B; horizontal / vertical / diagonal), original vs encrypted face.

Reads the photo ZIP the Metrics page saves ("Download photos (ZIP)"): it holds trialN_plain_face.png and
trialN_encrypted_face.png for every trial. Nothing in the app has to change.

  python plot_correlation.py fdae_trial_photos_xxx.zip                 # trial 1, horizontal pairs
  python plot_correlation.py fdae_trial_photos_xxx.zip --trial 7 --dir v
  python plot_correlation.py fdae_trial_photos_xxx.zip --pairs 3000 --out corr
Outputs: <out>.png / <out>.pdf (scatter figure for the chosen trial) and <out>_table.csv
(correlation coefficient per channel and direction, mean over ALL trials, computed on every pixel pair).
Needs: pip install numpy pillow matplotlib
"""
import argparse, csv, io, re, sys, zipfile
import numpy as np
from PIL import Image
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ap = argparse.ArgumentParser()
ap.add_argument("zip_file")
ap.add_argument("--trial", type=int, default=1)
ap.add_argument("--dir", choices=["h", "v", "d"], default="h", help="pair direction for the scatter plot")
ap.add_argument("--pairs", type=int, default=3000, help="random pairs drawn in the scatter plot")
ap.add_argument("--out", default="correlation")
a = ap.parse_args()

z = zipfile.ZipFile(a.zip_file)
names = set(z.namelist())
pad = {int(m.group(1)): m.group(1) for n in names if (m := re.match(r"trial(\d+)_plain_face\.png$", n))}  # "01" -> 1
trials = sorted(pad)
if not trials:
    sys.exit("No trialN_plain_face.png in this ZIP. Use the photo ZIP from the Metrics page.")
if a.trial not in trials:
    sys.exit(f"Trial {a.trial} not in the ZIP (has {trials[0]}..{trials[-1]}).")

def load(n):
    return np.asarray(Image.open(io.BytesIO(z.read(n))).convert("RGB"), dtype=np.float64)

def pairs(ch, d):
    if d == "h": return ch[:, :-1], ch[:, 1:]
    if d == "v": return ch[:-1, :], ch[1:, :]
    return ch[:-1, :-1], ch[1:, 1:]

def corr(x, y):
    x, y = x.ravel(), y.ravel()
    if x.std() == 0 or y.std() == 0: return float("nan")
    return float(np.corrcoef(x, y)[0, 1])

# ---- table: mean over all trials, every pixel pair
acc = {(k, c, d): [] for k in ("plain", "cipher") for c in range(3) for d in "hvd"}
for t in trials:
    for k, suf in (("plain", "plain_face"), ("cipher", "encrypted_face")):
        im = load(f"trial{pad[t]}_{suf}.png")
        for c in range(3):
            for d in "hvd":
                acc[(k, c, d)].append(corr(*pairs(im[:, :, c], d)))
CH = ["Red (R)", "Green (G)", "Blue (B)"]
with open(a.out + "_table.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["channel", "direction", "plain", "encrypted"])
    for c in range(3):
        for d, dn in zip("hvd", ["horizontal", "vertical", "diagonal"]):
            w.writerow([CH[c], dn, f"{np.nanmean(acc[('plain', c, d)]):.4f}", f"{np.nanmean(acc[('cipher', c, d)]):.4f}"])
print(open(a.out + "_table.csv").read())

# ---- scatter figure for one trial
rng = np.random.default_rng(1)
GRAYC, COLS = "#808080", ["#e8242a", "#0b8043", "#3a54a4"]
fig = plt.figure(figsize=(14, 5.4), constrained_layout=True)
blocks = fig.subfigures(1, 2, wspace=0.05)
dname = {"h": "horizontal", "v": "vertical", "d": "diagonal"}[a.dir]
for blk, (k, suf, title) in zip(blocks, [("plain", "plain_face", "Original image"), ("cipher", "encrypted_face", "Encrypted image")]):
    im = load(f"trial{pad[a.trial]}_{suf}.png")
    ax = blk.subplots(2, 2)
    ax[0, 0].imshow(im.astype(np.uint8)); ax[0, 0].set_title(title, fontsize=10)
    for a_, c in zip([ax[0, 1], ax[1, 0], ax[1, 1]], range(3)):
        x, y = pairs(im[:, :, c], a.dir)
        x, y = x.ravel(), y.ravel()
        idx = rng.choice(len(x), size=min(a.pairs, len(x)), replace=False)
        a_.scatter(x[idx], y[idx], s=2, color=COLS[c], alpha=.7, linewidths=0)
        a_.set_xlim(-5, 260); a_.set_ylim(-5, 260)
        a_.set_title(f"{CH[c]}   r = {corr(*pairs(im[:, :, c], a.dir)):.4f}", fontsize=10)
        a_.set_xlabel("pixel (x, y)", fontsize=8); a_.set_ylabel("neighbour", fontsize=8)
        a_.tick_params(labelsize=8)
fig.suptitle(f"Adjacent-pixel correlation ({dname} pairs, {a.pairs} random pairs, trial {a.trial}); r = Pearson over all pairs", fontsize=10)
fig.savefig(a.out + ".png", dpi=200); fig.savefig(a.out + ".pdf")
print("saved", a.out + ".png, .pdf and _table.csv")
