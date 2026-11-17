#!/usr/bin/env python3
import csv
import hashlib
import json
import sys
from pathlib import Path


def sealed_results(artifact):
    results = list(artifact.rglob("results.tsv"))
    if len(results) != 1:
        return False, "expected exactly one results.tsv"
    result = results[0]
    sums = result.parent / "SHA256SUMS"
    if not sums.is_file():
        return False, "missing SHA256SUMS"
    entries = {}
    for line in sums.read_text().splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) == 2:
            entries[fields[1].lstrip("* ")] = fields[0]
    digest = hashlib.sha256(result.read_bytes()).hexdigest()
    if entries.get("results.tsv") != digest:
        return False, "results.tsv checksum missing or mismatched"
    with result.open(newline="") as stream:
        rows = list(csv.reader(stream, delimiter="\t"))
    if not rows or rows[0] != ["id", "step", "expect", "exit", "reason_check", "verdict"]:
        return False, "invalid results.tsv header"
    if len(rows) < 2 or any(len(row) != 6 or row[5] != "PASS" for row in rows[1:]):
        return False, "results.tsv has missing gates or non-PASS rows"
    ids = [row[0] for row in rows[1:]]
    if any(not gate_id for gate_id in ids) or len(ids) != len(set(ids)):
        return False, "results.tsv has empty or duplicate gate IDs"
    return True, ""


def main():
    matrix = json.loads(sys.argv[1])
    artifact_root = Path(sys.argv[2])
    run_id, attempt = sys.argv[3:5]
    include = matrix.get("include", [])
    if not include:
        raise ValueError("FIXTURE inventory missing")
    failed = False
    for fixture in include:
        directory = fixture["dir"]
        artifact = artifact_root / f"fixture-evidence-{run_id}-{attempt}-{fixture['id']}"
        if not artifact.is_dir():
            print(f"FIXTURE not covered: {directory} (evidence artifact missing)", file=sys.stderr)
            failed = True
            continue
        valid, reason = sealed_results(artifact)
        if not valid:
            print(f"FIXTURE not covered: {directory} ({reason})", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print(f"FIXTURE coverage verified: {len(include)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        sys.exit(str(error))
