#!/usr/bin/env python3
import argparse
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "fixtures"
IGNORED = {".git", ".lake", "evidence", "target"}


def fixture_roots():
    projects = {}
    for lakefile in FIXTURES.rglob("lakefile.toml"):
        if IGNORED.intersection(lakefile.relative_to(FIXTURES).parts):
            continue
        parent = lakefile.parent
        while parent != FIXTURES and parent != ROOT:
            if (parent / "Cargo.toml").is_file():
                projects.setdefault(parent, []).append(lakefile)
                break
            parent = parent.parent
        else:
            raise ValueError(f"FIXTURE project root missing Cargo.toml: {lakefile.parent.relative_to(ROOT)}")
    for project, lakefiles in projects.items():
        if len(lakefiles) != 1:
            raise ValueError(f"FIXTURE project must contain exactly one lakefile.toml: {project.relative_to(ROOT)}")
    return sorted(projects)


def check_coverage(projects, scheduled):
    covered = set(scheduled)
    uncovered = sorted(set(projects) - covered)
    if uncovered:
        for project in uncovered:
            print(f"FIXTURE not covered: {project.relative_to(ROOT)}", file=sys.stderr)
        return False
    return True


def self_test():
    baseline = fixture_roots()
    with tempfile.TemporaryDirectory(prefix="coverage-canary-", dir=FIXTURES) as temporary:
        project = Path(temporary)
        (project / "Cargo.toml").write_text("[package]\nname = \"coverage-canary\"\n")
        lean = project / "lean"
        lean.mkdir()
        (lean / "lakefile.toml").write_text('name = "coverage_canary"\n')
        discovered = fixture_roots()
        if project not in discovered:
            raise ValueError("fixture coverage canary did not discover temporary project")
        if check_coverage(discovered, baseline):
            raise ValueError("fixture coverage canary did not detect uncovered project")
        print(f"coverage canary passed: FIXTURE not covered: {project.relative_to(ROOT)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return

    projects = fixture_roots()
    if not projects:
        raise ValueError("FIXTURE projects missing")
    matrix = {"include": [
        {
            "id": f"fixture-{index}",
            "dir": project.relative_to(ROOT).as_posix(),
            "name": project.name,
        }
        for index, project in enumerate(projects)
    ]}
    print(json.dumps(matrix, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(str(error))
