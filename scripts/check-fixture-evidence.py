#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
import re
import sys
import tempfile
from pathlib import Path

MINIMUM_LEAN_GATES = {
    "S0a", "S0b", "S1a", "S1b", "S1c", "S1d", "S2a", "S2b",
    "C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9", "C10", "C11", "C12", "C13", "T1",
    "L00", "L0", "L0b", "L1", "L2", "L3", "X1", "X2",
}


def sealed_results(artifact):
    results = list(artifact.rglob("results.tsv"))
    if len(results) != 1:
        return False, "expected exactly one results.tsv"
    result = results[0]
    evidence = result.parent
    expected_file = evidence / "expected-gates.txt"
    summary = evidence / "summary.txt"
    sums = evidence / "SHA256SUMS"
    if not sums.is_file():
        return False, "missing SHA256SUMS"
    entries = {}
    for line in sums.read_text().splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) == 2:
            entries[fields[1].lstrip("* ")] = fields[0]
    for path in (result, expected_file, summary):
        if not path.is_file():
            return False, f"missing {path.name}"
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if entries.get(path.name) != digest:
            return False, f"{path.name} checksum missing or mismatched"
    expected = expected_file.read_text().splitlines()
    if not expected or any(not gate_id for gate_id in expected):
        return False, "invalid expected-gates.txt"
    if len(expected) != len(set(expected)):
        return False, "duplicate expected gate IDs"
    if not MINIMUM_LEAN_GATES.issubset(expected):
        missing = sorted(MINIMUM_LEAN_GATES - set(expected))
        return False, f"expected gate inventory missing required Lean gates: {' '.join(missing)}"
    with result.open(newline="") as stream:
        rows = list(csv.reader(stream, delimiter="\t"))
    if not rows or rows[0] != ["id", "step", "expect", "exit", "reason_check", "verdict"]:
        return False, "invalid results.tsv header"
    if len(rows) < 2 or any(len(row) != 6 or row[5] != "PASS" for row in rows[1:]):
        return False, "results.tsv has missing gates or non-PASS rows"
    ids = [row[0] for row in rows[1:]]
    if any(not gate_id for gate_id in ids) or len(ids) != len(set(ids)):
        return False, "results.tsv has empty or duplicate gate IDs"
    if set(ids) != set(expected):
        missing = sorted(set(expected) - set(ids))
        extra = sorted(set(ids) - set(expected))
        return False, f"results.tsv gate inventory mismatch (missing: {missing}; extra: {extra})"
    progress = summary.read_text().splitlines()
    match = re.fullmatch(r"PROGRESS=(\d+)/(\d+)", progress[0]) if progress else None
    if not match or match.group(1) != match.group(2) or int(match.group(2)) != len(expected):
        return False, "summary.txt PROGRESS is not N/N for the expected gates"
    return True, ""


def fixture_result_error(fixture_result, discovery_result):
    if discovery_result != "success":
        return f"fixture discovery job result is {discovery_result}"
    if fixture_result != "success":
        return f"fixture job result is {fixture_result}"
    return ""


def validate_fixture(artifact, fixture_result, discovery_result):
    job_error = fixture_result_error(fixture_result, discovery_result)
    if job_error:
        return False, job_error
    return sealed_results(artifact)


def write_test_evidence(artifact, gate_ids):
    artifact.mkdir(parents=True, exist_ok=True)
    (artifact / "expected-gates.txt").write_text("".join(f"{gate_id}\n" for gate_id in gate_ids))
    with (artifact / "results.tsv").open("w", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(["id", "step", "expect", "exit", "reason_check", "verdict"])
        for gate_id in gate_ids:
            writer.writerow([gate_id, gate_id, "pass", "0", "n/a", "PASS"])
    (artifact / "summary.txt").write_text(f"PROGRESS={len(gate_ids)}/{len(gate_ids)}\n")
    with (artifact / "SHA256SUMS").open("w") as stream:
        for filename in ("expected-gates.txt", "results.tsv", "summary.txt"):
            digest = hashlib.sha256((artifact / filename).read_bytes()).hexdigest()
            stream.write(f"{digest}  {filename}\n")


def self_test():
    with tempfile.TemporaryDirectory(prefix="fixture-evidence-test-") as temporary:
        root = Path(temporary)
        complete = root / "complete"
        gate_ids = sorted(MINIMUM_LEAN_GATES)
        write_test_evidence(complete, gate_ids)
        valid, reason = validate_fixture(complete, "success", "success")
        if not valid:
            raise ValueError(f"checker self-test valid control failed: {reason}")

        incomplete = root / "incomplete"
        write_test_evidence(incomplete, gate_ids)
        results = incomplete / "results.tsv"
        results.write_text("\n".join(results.read_text().splitlines()[:-1]) + "\n")
        with (incomplete / "SHA256SUMS").open("w") as stream:
            for filename in ("expected-gates.txt", "results.tsv", "summary.txt"):
                digest = hashlib.sha256((incomplete / filename).read_bytes()).hexdigest()
                stream.write(f"{digest}  {filename}\n")
        valid, reason = validate_fixture(incomplete, "success", "success")
        if valid or "gate inventory mismatch" not in reason:
            raise ValueError("checker self-test accepted a results table missing a required gate")
        print(f"checker self-test passed: missing result row rejected ({reason})")

        sparse = root / "sparse"
        write_test_evidence(sparse, ["S0a"])
        valid, reason = validate_fixture(sparse, "success", "success")
        if valid or "required Lean gates" not in reason:
            raise ValueError("checker self-test accepted an S0a-only gate table")
        print(f"checker self-test passed: S0a-only evidence rejected ({reason})")

        valid, reason = validate_fixture(complete, "failure", "success")
        if valid or reason != "fixture job result is failure":
            raise ValueError("checker self-test accepted a failed fixture job")
        print("checker self-test passed: failed fixture job result rejected")

        valid, reason = validate_fixture(complete, "success", "failure")
        if valid or reason != "fixture discovery job result is failure":
            raise ValueError("checker self-test accepted a failed discovery job")
        print("checker self-test passed: failed discovery job result rejected")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("matrix", nargs="?")
    parser.add_argument("artifact_root", nargs="?")
    parser.add_argument("run_id", nargs="?")
    parser.add_argument("attempt", nargs="?")
    parser.add_argument("fixture_result", nargs="?")
    parser.add_argument("discovery_result", nargs="?")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if None in (args.matrix, args.artifact_root, args.run_id, args.attempt,
                args.fixture_result, args.discovery_result):
        parser.error("matrix, artifact_root, run_id, attempt, and both job results are required")
    matrix = json.loads(args.matrix)
    artifact_root = Path(args.artifact_root)
    run_id, attempt = args.run_id, args.attempt
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
        valid, reason = validate_fixture(artifact, args.fixture_result, args.discovery_result)
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
