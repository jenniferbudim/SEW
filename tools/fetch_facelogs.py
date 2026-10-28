"""
Export the Firestore `faceLogs` collection to a CSV (free: reads with the Admin SDK, no Blaze plan needed).

One-time setup
  1. Firebase console -> Project settings -> Service accounts -> "Generate new private key" -> save the JSON.
     This file is a SECRET (full access to your project). Keep it out of git and delete it when you are done.
  2. pip install firebase-admin

Run
  python fetch_facelogs.py --key serviceAccount.json --out facelogs.csv
"""
import argparse
import csv
import json

import firebase_admin
from firebase_admin import credentials, firestore

COLUMNS = ["createdAt", "uid", "event", "label", "score", "accepted", "threshold", "error",
           "liveScore", "sharpness", "liveVerdict", "liveMode", "failCount", "timingsMs"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True, help="service-account JSON")
    ap.add_argument("--out", default="facelogs.csv")
    ap.add_argument("--collection", default="faceLogs")
    a = ap.parse_args()

    firebase_admin.initialize_app(credentials.Certificate(a.key))
    db = firestore.client()
    n = 0
    with open(a.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        for doc in db.collection(a.collection).stream():
            d = doc.to_dict()
            row = {c: d.get(c) for c in COLUMNS}
            ts = d.get("createdAt")
            row["createdAt"] = ts.isoformat() if ts is not None else ""
            if isinstance(row["timingsMs"], dict):
                row["timingsMs"] = json.dumps(row["timingsMs"])
            w.writerow(row)
            n += 1
    print(f"wrote {n} rows to {a.out}")


if __name__ == "__main__":
    main()
