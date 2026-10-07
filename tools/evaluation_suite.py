"""
Evaluation suite for the face-detect -> selective FDAE pipeline.

Two ways to use it
------------------
1) Unit tests (no model / dataset needed):
       pytest evaluation_suite.py -v
   Checks every metric against a literal transcription of the formula used in
   the paper (entropy, pixel correlation R_pq, NPCR, UACI, MSE, PSNR, SSIM, AP)
   and sanity-checks the timing / FPS maths with a fake detector.

2) Full measurement on real data:
       python evaluation_suite.py --images-dir WIDER_val/images \
           --annotations wider_face_split/wider_face_val_bbx_gt.txt \
           --detector yolo26 --model yolo26n-face.onnx --limit 200
   Measures, per image and per face:
     - face-detection inference time   (detector.detect(): letterbox + model + decode)
     - encryption time / decryption time (3 channels, per face)
     - FPS: detection-only, detect+encrypt ("protect"), detect+encrypt+decrypt
     - information entropy (plain vs cipher, vs a random-bytes reference)
     - adjacent-pixel correlation (horizontal / vertical / diagonal, plain vs cipher)
     - Average Precision (AP) at IoU 0.5 if --annotations is given
   and writes evaluation_report.json.

Metric definitions (as in the paper figures)
--------------------------------------------
  H(m)   = sum_i p(m_i) * log2(1/p(m_i)),  i = 0..2^N-1           (N = 8)
  R_pq   = sum_j (p_j-pbar)(q_j-qbar) /
           ( sqrt(sum_j (p_j-pbar)^2) * sqrt(sum_j (q_j-qbar)^2) ), j = 1..T pairs
  NPCR   = (sum_ij D(i,j) / (M*N)) * 100%,   D=0 if C1==C2 else 1
           (NOTE: the figure typesets "M x N x 100%" in the denominator; the
            correct form multiplies the ratio by 100%.)
  UACI   = (1/(M*N)) * sum_ij |C1-C2| / 255 * 100%
  MSE    = 1/(M*N) * sum (OG - EG)^2
  PSNR   = 10 log10( MAX^2 / MSE ),  MAX = 255 for 8-bit images
  SSIM   = (2 mu_x mu_y + C1)(2 sigma_xy + C2) /
           ((mu_x^2 + mu_y^2 + C1)(sigma_x^2 + sigma_y^2 + C2)), averaged over
           local 7x7 windows
  AP     = 1/n * sum_{r in recall levels} max_{r* >= r} P(r*)
           (n-point interpolated AP; default n = 11 as in PASCAL VOC07.
            The all-point area under the interpolated PR curve is reported too.)

FPS definitions (compute only; image file read time is excluded)
  detection FPS   = 1 / mean(t_detect)
  protect FPS     = images / sum(t_detect + t_encrypt_all_faces)
  round-trip FPS  = images / sum(t_detect + t_encrypt + t_decrypt)
Numbers measured here are for THIS machine and the Python implementation; they
do not predict phone performance -- measure on-device with the Dart timings.
"""
from __future__ import annotations

import argparse
import ast
import json
import math
import sys
import tempfile
import time
import unittest
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from fdae_encryption import (FdaeKeys, adjacent_pixel_correlation,  # noqa: E402
                             decrypt_grayscale, encrypt_grayscale, entropy,
                             npcr_uaci)

DIRECTIONS = ("horizontal", "vertical", "diagonal")


# ===========================================================================
# 1. Literal transcriptions of the paper formulas (slow loops on purpose:
#    they exist to be compared against the fast project code)
# ===========================================================================

def spec_entropy(img: np.ndarray) -> float:
    p = np.bincount(img.ravel(), minlength=256) / img.size
    return float(sum(pi * math.log2(1.0 / pi) for pi in p if pi > 0))


def spec_pearson(p: np.ndarray, q: np.ndarray) -> float:
    p, q = p.astype(np.float64), q.astype(np.float64)
    pm, qm = p.mean(), q.mean()
    num = sum((pj - pm) * (qj - qm) for pj, qj in zip(p, q))
    den = math.sqrt(sum((pj - pm) ** 2 for pj in p)) * math.sqrt(sum((qj - qm) ** 2 for qj in q))
    return num / den


def spec_npcr(c1: np.ndarray, c2: np.ndarray) -> float:
    m, n = c1.shape
    d = sum(0 if c1[i, j] == c2[i, j] else 1 for i in range(m) for j in range(n))
    return d / (m * n) * 100.0


def spec_uaci(c1: np.ndarray, c2: np.ndarray) -> float:
    m, n = c1.shape
    s = sum(abs(int(c1[i, j]) - int(c2[i, j])) / 255.0 for i in range(m) for j in range(n))
    return s / (m * n) * 100.0


def spec_mse(og: np.ndarray, eg: np.ndarray) -> float:
    m, n = og.shape[:2]
    return float(np.sum((og.astype(np.float64) - eg.astype(np.float64)) ** 2) / (m * n * (og.size // (m * n))))


def spec_psnr(og: np.ndarray, eg: np.ndarray, max_val: float = 255.0) -> float:
    mse = spec_mse(og, eg)
    return float("inf") if mse == 0 else 10.0 * math.log10(max_val ** 2 / mse)


def spec_ssim(x: np.ndarray, y: np.ndarray, win: int = 7, L: float = 255.0) -> float:
    """SSIM formula over local win x win windows (unbiased covariance), mean-pooled."""
    from scipy.ndimage import uniform_filter
    x, y = x.astype(np.float64), y.astype(np.float64)
    c1, c2 = (0.01 * L) ** 2, (0.03 * L) ** 2
    cn = win * win / (win * win - 1)
    mx, my = uniform_filter(x, win), uniform_filter(y, win)
    sxx = cn * (uniform_filter(x * x, win) - mx * mx)
    syy = cn * (uniform_filter(y * y, win) - my * my)
    sxy = cn * (uniform_filter(x * y, win) - mx * my)
    s = ((2 * mx * my + c1) * (2 * sxy + c2)) / ((mx ** 2 + my ** 2 + c1) * (sxx + syy + c2))
    pad = (win - 1) // 2
    return float(s[pad:-pad, pad:-pad].mean())


def sample_adjacent_pairs(img: np.ndarray, n_pairs: int, direction: str, seed: int = 0):
    """Same sampling stream as fdae_encryption.adjacent_pixel_correlation."""
    rng = np.random.default_rng(seed)
    h, w = img.shape
    if direction == "horizontal":
        ys, xs = rng.integers(0, h, n_pairs), rng.integers(0, w - 1, n_pairs)
        return img[ys, xs], img[ys, xs + 1]
    if direction == "vertical":
        ys, xs = rng.integers(0, h - 1, n_pairs), rng.integers(0, w, n_pairs)
        return img[ys, xs], img[ys + 1, xs]
    ys, xs = rng.integers(0, h - 1, n_pairs), rng.integers(0, w - 1, n_pairs)
    return img[ys, xs], img[ys + 1, xs + 1]


# ===========================================================================
# 2. Average Precision (the metric that was missing)
# ===========================================================================

def iou_xyxy(a, b) -> float:
    ix1, iy1 = max(a[0], b[0]), max(a[1], b[1])
    ix2, iy2 = min(a[2], b[2]), min(a[3], b[3])
    inter = max(0, ix2 - ix1) * max(0, iy2 - iy1)
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def match_detections(gt: dict[str, list], dets: dict[str, list], iou_thr: float = 0.5,
                     min_gt_size: int = 0):
    """
    PASCAL-VOC style matching.
      gt   {image: [(x1,y1,x2,y2), ...]}
      dets {image: [(x1,y1,x2,y2,score), ...]}
    GT faces with min(w,h) < min_gt_size are 'ignored': not counted as GT, and
    detections that best-match one are neither TP nor FP.
    Returns (records [(score, is_tp)], n_gt).
    """
    records: list[tuple[float, bool]] = []
    n_gt = 0
    for key, gboxes in gt.items():
        ignore = [min(b[2] - b[0], b[3] - b[1]) < min_gt_size for b in gboxes]
        n_gt += sum(1 for ig in ignore if not ig)
        used = [False] * len(gboxes)
        for d in sorted(dets.get(key, []), key=lambda t: -t[4]):
            best_j, best = -1, 0.0
            for j, g in enumerate(gboxes):
                v = iou_xyxy(g, d)
                if v > best:
                    best, best_j = v, j
            if best_j >= 0 and best >= iou_thr:
                if ignore[best_j]:
                    continue
                if not used[best_j]:
                    used[best_j] = True
                    records.append((d[4], True))
                else:
                    records.append((d[4], False))      # duplicate detection
            else:
                records.append((d[4], False))
    return records, n_gt


def pr_curve(records, n_gt: int):
    if n_gt == 0 or not records:
        return np.array([]), np.array([])
    order = sorted(range(len(records)), key=lambda i: -records[i][0])
    tp = np.cumsum([1 if records[i][1] else 0 for i in order], dtype=np.float64)
    fp = np.cumsum([0 if records[i][1] else 1 for i in order], dtype=np.float64)
    return tp / n_gt, tp / (tp + fp)


def ap_interpolated_n(recall: np.ndarray, precision: np.ndarray, n: int = 11) -> float:
    """AP = 1/n * sum_{r in n recall levels} max_{r* >= r} P(r*)  (0 if r unreachable)."""
    if recall.size == 0:
        return 0.0
    total = 0.0
    for r in np.linspace(0.0, 1.0, n):
        mask = recall >= r - 1e-9
        total += float(precision[mask].max()) if mask.any() else 0.0
    return total / n


def ap_all_points(recall: np.ndarray, precision: np.ndarray) -> float:
    """Area under the monotone (interpolated) PR curve (VOC2010+ / COCO-style)."""
    if recall.size == 0:
        return 0.0
    mrec = np.concatenate(([0.0], recall, [1.0]))
    mpre = np.concatenate(([0.0], precision, [0.0]))
    for i in range(len(mpre) - 2, -1, -1):
        mpre[i] = max(mpre[i], mpre[i + 1])
    idx = np.where(mrec[1:] != mrec[:-1])[0] + 1
    return float(np.sum((mrec[idx] - mrec[idx - 1]) * mpre[idx]))


def evaluate_ap(gt, dets, iou_thr: float = 0.5, min_gt_size: int = 0, n_points: int = 11) -> dict:
    records, n_gt = match_detections(gt, dets, iou_thr, min_gt_size)
    rec, prec = pr_curve(records, n_gt)
    return {
        "iou_threshold": iou_thr,
        "min_gt_size_px": min_gt_size,
        "n_gt": n_gt,
        "n_detections_scored": len(records),
        f"ap_{n_points}pt": round(ap_interpolated_n(rec, prec, n_points), 4),
        "ap_all_points": round(ap_all_points(rec, prec), 4),
        "max_recall": round(float(rec.max()), 4) if rec.size else 0.0,
    }


# ===========================================================================
# 3. Measurement harness
# ===========================================================================

def summarize_ms(values_s: list[float]) -> dict:
    if not values_s:
        return {"n": 0}
    a = np.asarray(values_s) * 1000.0
    return {"n": int(a.size), "mean_ms": round(float(a.mean()), 3),
            "median_ms": round(float(np.median(a)), 3),
            "p95_ms": round(float(np.percentile(a, 95)), 3),
            "std_ms": round(float(a.std()), 3),
            "min_ms": round(float(a.min()), 3), "max_ms": round(float(a.max()), 3)}


def summarize_val(values: list[float]) -> dict:
    v = [x for x in values if not (isinstance(x, float) and math.isnan(x))]
    if not v:
        return {"n": 0}
    a = np.asarray(v)
    return {"n": int(a.size), "mean": round(float(a.mean()), 4), "std": round(float(a.std()), 4),
            "min": round(float(a.min()), 4), "max": round(float(a.max()), 4)}


def _import_pipeline():
    import cv2
    from pipeline_test import (FaceBox, decrypt_face_region_color,
                               encrypt_face_region_color, random_keys)
    return cv2, FaceBox, random_keys, encrypt_face_region_color, decrypt_face_region_color


def run_evaluation(detector, image_paths: list[Path], gt_by_stem: dict | None = None, *,
                   warmup: int = 3, max_faces: int = 10, min_face_size: int = 8,
                   n0: int = 1000, iou_thr: float = 0.5,
                   ap_min_gt_sizes=(0, 32), ap_conf_floor: float = 0.01) -> dict:
    cv2, _FaceBox, random_keys, enc_color, dec_color = _import_pipeline()
    rng = np.random.default_rng(0)

    imgs_ok = [p for p in image_paths if cv2.imread(str(p)) is not None]
    if not imgs_ok:
        raise SystemExit("no readable images")

    # ---- warm-up (first call pays graph/JIT/allocator costs) ----
    first = cv2.imread(str(imgs_ok[0]))
    if hasattr(detector, "set_current"):
        detector.set_current(imgs_ok[0].stem)
    for _ in range(warmup):
        detector.detect(first)

    op_thr = getattr(detector, "conf_threshold", 0.0)
    t_det, t_enc_img, t_dec_img, t_enc_face, t_dec_face = [], [], [], [], []
    frame_protect, frame_roundtrip = [], []
    ent_p, ent_c, ent_r, ent_gray_c = [], [], [], []
    corr = {d: {"plain": [], "cipher": []} for d in DIRECTIONS}
    n_faces = n_rt_ok = n_rt_bad = n_nan = 0
    face_px, megapixels = [], []
    wall0 = time.perf_counter()

    for path in imgs_ok:
        img = cv2.imread(str(path))
        megapixels.append(img.shape[0] * img.shape[1] / 1e6)
        if hasattr(detector, "set_current"):
            detector.set_current(path.stem)
        t0 = time.perf_counter()
        faces = detector.detect(img)
        td = time.perf_counter() - t0
        t_det.append(td)

        faces = sorted((f for f in faces if f.confidence >= op_thr),
                       key=lambda f: -f.confidence)
        faces = [f for f in faces if min(f.x2 - f.x1, f.y2 - f.y1) >= min_face_size][:max_faces]

        te_img = tdc_img = 0.0
        for f in faces:
            crop = img[f.y1:f.y2, f.x1:f.x2]
            keys = random_keys(n0=n0, seed=int(rng.integers(0, 2 ** 31)))
            t0 = time.perf_counter()
            enc, iv = enc_color(crop, keys)
            te = time.perf_counter() - t0
            t0 = time.perf_counter()
            dec = dec_color(enc, keys, iv)
            tdc = time.perf_counter() - t0
            te_img += te
            tdc_img += tdc
            t_enc_face.append(te)
            t_dec_face.append(tdc)
            face_px.append(crop.shape[0] * crop.shape[1])
            n_faces += 1
            if np.array_equal(crop, dec):
                n_rt_ok += 1
            else:
                n_rt_bad += 1

            # Quality metrics are computed PER CHANNEL (the cipher is per channel).
            # Converting the cipher to gray first would understate entropy: a
            # weighted sum of 3 independent uniform channels is not uniform
            # (~7.55 bits for perfect randomness at 48x48 instead of ~7.9).
            pc = [crop[..., c] for c in range(3)]
            ec = [enc[..., c] for c in range(3)]
            ent_p.append(float(np.mean([entropy(c) for c in pc])))
            ent_c.append(float(np.mean([entropy(c) for c in ec])))
            ent_r.append(float(np.mean([entropy(rng.integers(0, 256, pc[0].shape, dtype=np.uint8))
                                        for _ in range(3)])))
            ent_gray_c.append(entropy(cv2.cvtColor(enc, cv2.COLOR_BGR2GRAY)))
            if crop.shape[0] > 2 and crop.shape[1] > 2:
                n_pairs = min(2000, crop.shape[0] * crop.shape[1] // 2)
                for d in DIRECTIONS:
                    rps, rcs = [], []
                    for a_, b_ in zip(pc, ec):
                        with np.errstate(all="ignore"):
                            rp = adjacent_pixel_correlation(a_, n_pairs, d)
                            rc = adjacent_pixel_correlation(b_, n_pairs, d)
                        if math.isnan(rp) or math.isnan(rc):
                            n_nan += 1
                        else:
                            rps.append(rp)
                            rcs.append(rc)
                    if rps:
                        corr[d]["plain"].append(float(np.mean(rps)))
                        corr[d]["cipher"].append(float(np.mean(rcs)))
        t_enc_img.append(te_img)
        t_dec_img.append(tdc_img)
        frame_protect.append(td + te_img)
        frame_roundtrip.append(td + te_img + tdc_img)

    wall = time.perf_counter() - wall0
    n_img = len(imgs_ok)
    mean_det = float(np.mean(t_det))

    report = {
        "environment": {
            "n_images": n_img,
            "mean_megapixels": round(float(np.mean(megapixels)), 3),
            "n_faces_encrypted": n_faces,
            "mean_face_pixels": round(float(np.mean(face_px)), 1) if face_px else None,
            "n0_burn_in": n0,
            "onnx_providers": (detector._sess.get_providers() if hasattr(detector, "_sess") else None),
            "operating_conf_threshold": op_thr,
        },
        "detection_inference_time": summarize_ms(t_det),
        "encryption_time_per_face": summarize_ms(t_enc_face),
        "decryption_time_per_face": summarize_ms(t_dec_face),
        "encryption_time_per_image": summarize_ms(t_enc_img),
        "ms_per_megapixel_of_face_encrypted": (
            round(1000 * float(np.sum(t_enc_face)) / (sum(face_px) / 1e6), 1) if face_px else None),
        "fps": {
            "detection_only": round(1.0 / mean_det, 3),
            "protect_detect_plus_encrypt": round(n_img / float(np.sum(frame_protect)), 3),
            "round_trip_detect_encrypt_decrypt": round(n_img / float(np.sum(frame_roundtrip)), 3),
            "wall_clock_loop_incl_metrics": round(n_img / wall, 3),
        },
        "round_trip_exact": {"ok": n_rt_ok, "mismatch": n_rt_bad},
        "information_entropy": {
            "plain": summarize_val(ent_p), "cipher": summarize_val(ent_c),
            "random_bytes_same_size_reference": summarize_val(ent_r),
            "ideal_8bit": 8.0,
            "method": "mean of the 3 per-channel entropies",
            "cipher_if_converted_to_gray_NOT_RECOMMENDED": summarize_val(ent_gray_c),
        },
        "adjacent_pixel_correlation": {
            d: {"plain": summarize_val(corr[d]["plain"]), "cipher": summarize_val(corr[d]["cipher"])}
            for d in DIRECTIONS},
        "correlation_channels_skipped_nan_constant": n_nan,
        "correlation_method": "per-channel Pearson on random adjacent pairs, averaged over B,G,R",
    }

    # ---- AP (separate, untimed pass at a low confidence floor) ----
    if gt_by_stem:
        gt = {p.stem: gt_by_stem[p.stem] for p in imgs_ok if p.stem in gt_by_stem}
        if gt:
            saved = getattr(detector, "conf_threshold", None)
            if saved is not None:
                detector.conf_threshold = ap_conf_floor
            try:
                dets: dict[str, list] = {}
                for p in imgs_ok:
                    if p.stem not in gt:
                        continue
                    if hasattr(detector, "set_current"):
                        detector.set_current(p.stem)
                    im = cv2.imread(str(p))
                    dets[p.stem] = [(f.x1, f.y1, f.x2, f.y2, f.confidence) for f in detector.detect(im)]
            finally:
                if saved is not None:
                    detector.conf_threshold = saved
            report["average_precision"] = [
                evaluate_ap(gt, dets, iou_thr, mg) for mg in ap_min_gt_sizes]
            report["average_precision_note"] = (
                "Single-IoU AP over the evaluated images with a "
                f"{ap_conf_floor} score floor. Not the official WIDER FACE "
                "Easy/Medium/Hard protocol; min_gt_size_px>0 ignores tiny GT faces.")
    return report


def run_crypto_scaling(sizes=(32, 64, 128), repeats: int = 3, n0: int = 1000) -> list[dict]:
    """Encrypt/decrypt time vs square crop size (colour, 3 channels)."""
    _, _, random_keys, enc_color, dec_color = _import_pipeline()
    rng = np.random.default_rng(1)
    rows = []
    for s in sizes:
        te, td = [], []
        for r in range(repeats):
            crop = rng.integers(0, 256, (s, s, 3), dtype=np.uint8)
            keys = random_keys(n0=n0, seed=r)
            t0 = time.perf_counter()
            enc, iv = enc_color(crop, keys)
            te.append(time.perf_counter() - t0)
            t0 = time.perf_counter()
            dec = dec_color(enc, keys, iv)
            td.append(time.perf_counter() - t0)
            assert np.array_equal(crop, dec)
        rows.append({"crop": f"{s}x{s}", "encrypt": summarize_ms(te), "decrypt": summarize_ms(td),
                     "encrypt_ms_per_1000px": round(1000 * float(np.mean(te)) / (s * s / 1000), 2)})
    return rows


# ===========================================================================
# 4. Unit tests  (pytest evaluation_suite.py)
# ===========================================================================

def _benchmark_metrics():
    path = HERE / "benchmark_fdae.py"
    if not path.exists():
        raise unittest.SkipTest("benchmark_fdae.py not next to this file")
    from scipy import stats as sps
    from skimage.metrics import structural_similarity
    tree = ast.parse(path.read_text())
    body = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in {"mse", "psnr", "ssim"}]
    ns = {"np": np, "math": math, "sps": sps, "structural_similarity": structural_similarity}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(path), "exec"), ns)
    return ns["mse"], ns["psnr"], ns["ssim"]


def _rand(shape, seed):
    return np.random.default_rng(seed).integers(0, 256, shape, dtype=np.uint8)


def test_entropy_matches_formula_and_ideals():
    for seed, shape in enumerate([(30, 40), (64, 64), (17, 91)]):
        img = _rand(shape, seed)
        assert abs(entropy(img) - spec_entropy(img)) < 1e-9
    assert entropy(np.full((9, 9), 5, np.uint8)) == 0.0
    assert abs(entropy(np.arange(256, dtype=np.uint8).reshape(16, 16)) - 8.0) < 1e-12


def test_entropy_cipher_close_to_random_reference():
    from pipeline_test import encrypt_face_region_color, random_keys
    yy, xx = np.mgrid[0:48, 0:48]
    # narrow tonal range like a real face crop (a full-range modular ramp would
    # have an almost flat histogram, i.e. ~8 bits of entropy already)
    crop = np.stack([80 + (xx * 2 + yy) % 48, 90 + (xx + yy * 2) % 40, 70 + (xx + yy) % 56], -1).astype(np.uint8)
    enc, _ = encrypt_face_region_color(crop, random_keys(n0=100, seed=3))
    ref = np.mean([entropy(_rand((48, 48), s)) for s in range(100)])
    for c in range(3):                                   # per channel, as encrypted
        assert entropy(enc[..., c]) > ref - 0.15
        assert entropy(enc[..., c]) > entropy(crop[..., c])


def test_gray_conversion_understates_cipher_entropy():
    """Regression guard: do NOT measure cipher entropy after BGR->gray."""
    import cv2
    x = _rand((48, 48, 3), 0)                            # ideal ciphertext stand-in
    per_channel = np.mean([entropy(x[..., c]) for c in range(3)])
    gray = entropy(cv2.cvtColor(x, cv2.COLOR_BGR2GRAY))
    assert per_channel - gray > 0.2


def test_pixel_correlation_matches_formula():
    img = _rand((50, 60), 7)
    for d in DIRECTIONS:
        p, q = sample_adjacent_pairs(img, 400, d)
        assert abs(adjacent_pixel_correlation(img, 400, d) - spec_pearson(p, q)) < 1e-9


def test_pixel_correlation_plain_high_cipher_low():
    from pipeline_test import encrypt_face_region_color, random_keys
    yy, xx = np.mgrid[0:64, 0:64]
    crop = np.stack([(xx * 3 + yy) % 256] * 3, -1).astype(np.uint8)
    enc, _ = encrypt_face_region_color(crop, random_keys(n0=100, seed=5))
    for c in range(3):
        for d in DIRECTIONS:
            assert adjacent_pixel_correlation(crop[..., c], 1500, d) > 0.8
            assert abs(adjacent_pixel_correlation(enc[..., c], 1500, d)) < 0.12   # ~4 sigma at T=1500


def test_npcr_uaci_match_formulas():
    a, b = _rand((20, 25), 1), _rand((20, 25), 2)
    n, u = npcr_uaci(a, b)
    assert abs(n - spec_npcr(a, b)) < 1e-9 and abs(u - spec_uaci(a, b)) < 1e-9
    assert npcr_uaci(a, a) == (0.0, 0.0)


def test_mse_psnr_ssim_match_formulas():
    mse, psnr, ssim = _benchmark_metrics()
    x = _rand((40, 40, 3), 3) // 2
    y = np.clip(x.astype(int) + _rand((40, 40, 3), 4).astype(int) // 8 - 16, 0, 255).astype(np.uint8)
    assert abs(mse(x, y) - spec_mse(x, y)) < 1e-9
    assert abs(psnr(x, y) - spec_psnr(x, y)) < 1e-9
    g1, g2 = x[..., 0], y[..., 0]
    assert abs(ssim(g1, g2) - spec_ssim(g1, g2)) < 1e-6


def test_ap_hand_computed_cases():
    gt = {"a": [(0, 0, 10, 10)], "b": [(0, 0, 10, 10)]}
    perfect = {"a": [(0, 0, 10, 10, 0.9)], "b": [(0, 0, 10, 10, 0.8)]}
    r = evaluate_ap(gt, perfect)
    assert r["ap_11pt"] == 1.0 and r["ap_all_points"] == 1.0
    assert evaluate_ap(gt, {})["ap_11pt"] == 0.0
    # one of two GT found: recall max 0.5 -> 6/11 (11-pt), 0.5 (all-pt)
    half = {"a": [(0, 0, 10, 10, 0.9)]}
    r = evaluate_ap(gt, half)
    assert abs(r["ap_11pt"] - 6 / 11) < 1e-3 and abs(r["ap_all_points"] - 0.5) < 1e-9
    # ranking TP, FP, TP with 2 GT: precision 1 up to r=.5, 2/3 after
    gt2 = {"a": [(0, 0, 10, 10)], "b": [(0, 0, 10, 10)]}
    d2 = {"a": [(0, 0, 10, 10, 0.9)], "b": [(50, 50, 60, 60, 0.8), (0, 0, 10, 10, 0.7)]}
    r = evaluate_ap(gt2, d2)
    assert abs(r["ap_11pt"] - (6 + 5 * 2 / 3) / 11) < 1e-3
    assert abs(r["ap_all_points"] - (0.5 + 0.5 * 2 / 3)) < 1e-3


def test_ap_duplicates_and_ignored_gt():
    gt = {"a": [(0, 0, 10, 10), (30, 30, 34, 34)]}          # second GT is tiny
    dets = {"a": [(0, 0, 10, 10, 0.9), (0, 0, 10, 10, 0.8),   # duplicate -> FP
                  (30, 30, 34, 34, 0.7)]}                       # ignored when min_gt_size=8
    full = evaluate_ap(gt, dets, min_gt_size=0)
    ign = evaluate_ap(gt, dets, min_gt_size=8)
    assert full["n_gt"] == 2 and ign["n_gt"] == 1
    assert ign["n_detections_scored"] == 2                      # tiny-GT match skipped


class _SleepDetector:
    conf_threshold = 0.3

    def __init__(self, delay: float):
        from pipeline_test import FaceBox
        self.delay, self._FaceBox = delay, FaceBox

    def detect(self, img):
        time.sleep(self.delay)
        return [self._FaceBox(10, 10, 50, 50, 0.9), self._FaceBox(60, 5, 90, 40, 0.1)]


def test_timing_and_fps_math_with_fake_detector():
    import cv2
    with tempfile.TemporaryDirectory() as td:
        paths = []
        for i in range(3):
            p = Path(td) / f"img{i}.png"
            cv2.imwrite(str(p), _rand((120, 160, 3), i))
            paths.append(p)
        gt = {p.stem: [(10, 10, 50, 50)] for p in paths}
        rep = run_evaluation(_SleepDetector(0.02), paths, gt, warmup=1, n0=50)
    d = rep["detection_inference_time"]["mean_ms"]
    assert 19.0 < d < 80.0
    assert abs(rep["fps"]["detection_only"] * d / 1000.0 - 1.0) < 0.02
    assert rep["fps"]["protect_detect_plus_encrypt"] < rep["fps"]["detection_only"]
    assert rep["fps"]["round_trip_detect_encrypt_decrypt"] <= rep["fps"]["protect_detect_plus_encrypt"]
    assert rep["environment"]["n_faces_encrypted"] == 3          # 0.1-conf box filtered out
    assert rep["round_trip_exact"] == {"ok": 3, "mismatch": 0}
    assert rep["average_precision"][0]["ap_11pt"] == 1.0         # low-conf FP ranks last


# ===========================================================================
# 5. CLI
# ===========================================================================

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--images-dir", type=Path, default=None)
    ap.add_argument("--annotations", type=Path, default=None, help="official wider_face_*_bbx_gt.txt (enables AP)")
    ap.add_argument("--detector", choices=["yolov7", "yolo26"], default="yolo26")
    ap.add_argument("--model", default=None, help="path to the exported .onnx")
    ap.add_argument("--limit", type=int, default=100)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--n0", type=int, default=1000)
    ap.add_argument("--max-faces", type=int, default=10)
    ap.add_argument("--min-face-size", type=int, default=8)
    ap.add_argument("--ap-min-gt-sizes", type=int, nargs="+", default=[0, 32])
    ap.add_argument("--scaling-sizes", type=int, nargs="*", default=[32, 64, 128],
                    help="square crop sizes for the enc/dec scaling table ([] to skip)")
    ap.add_argument("--report", type=Path, default=Path("evaluation_report.json"))
    args = ap.parse_args()

    out: dict = {}
    if args.scaling_sizes:
        print("Encrypt/decrypt scaling (synthetic colour crops)...")
        out["crypto_scaling"] = run_crypto_scaling(tuple(args.scaling_sizes), n0=args.n0)

    if args.images_dir:
        from batch_test_widerface import load_wider_annotations
        from pipeline_test import get_detector
        paths = sorted(p for p in args.images_dir.rglob("*") if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
        paths = paths[:args.limit]
        gt = load_wider_annotations(args.annotations) if args.annotations else None
        det = get_detector(args.detector, args.model)
        print(f"Evaluating {len(paths)} images with {args.detector}...")
        out["pipeline"] = run_evaluation(det, paths, gt, warmup=args.warmup, max_faces=args.max_faces,
                                         min_face_size=args.min_face_size, n0=args.n0,
                                         ap_min_gt_sizes=tuple(args.ap_min_gt_sizes))
    else:
        print("No --images-dir: skipped detection time / FPS / AP (they need a model and images).")

    args.report.write_text(json.dumps(out, indent=2))
    print(json.dumps(out, indent=2))
    print(f"\nWrote {args.report}")


if __name__ == "__main__":
    main()
