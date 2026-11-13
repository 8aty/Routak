#!/usr/bin/env python3
"""Adds a release to the AltStore source (altstore/source.json).

    scripts/update-source.py --version 1.2.0 --build 7 --url <ipa url> --size <bytes> --notes-file notes.txt

The newest version goes first. AltStore compares it with the installed app and offers the update.
Re-running for the same version replaces its entry.
"""
import argparse
import datetime
import json
import pathlib

SOURCE = pathlib.Path(__file__).resolve().parent.parent / "altstore" / "source.json"
BUNDLE_ID = "cc.tomy.Routak"
MIN_OS = "17.0"

parser = argparse.ArgumentParser()
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--url", required=True)
parser.add_argument("--size", required=True, type=int)
parser.add_argument("--notes-file")
args = parser.parse_args()

notes = "Bug fixes and improvements."
if args.notes_file:
    text = pathlib.Path(args.notes_file).read_text(encoding="utf-8").strip()
    if text:
        notes = text

date = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
entry = {
    "version": args.version,
    "buildVersion": str(args.build),
    "date": date,
    "localizedDescription": notes,
    "downloadURL": args.url,
    "size": args.size,
    "minOSVersion": MIN_OS,
}

source = json.loads(SOURCE.read_text(encoding="utf-8"))
app = next(a for a in source["apps"] if a["bundleIdentifier"] == BUNDLE_ID)
app["versions"] = [entry] + [v for v in app.get("versions", []) if v["version"] != args.version]

# Older AltStore versions read these from the app itself.
app["version"] = entry["version"]
app["versionDate"] = date
app["versionDescription"] = notes
app["downloadURL"] = entry["downloadURL"]
app["size"] = entry["size"]

SOURCE.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"AltStore source now offers Routak {args.version} ({args.build})")
