#!/usr/bin/env python3
"""Require a completed pilot and a report inside this invocation's fresh work directory."""
import csv
import pathlib
import re
import sys


def verify(work, log, rc):
    text = log.read_text()
    matches = re.findall(r'^  evidence: (.+) \(ci-local\),.*$', text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError('missing or ambiguous evidence report')
    evidence = pathlib.Path(matches[0]).resolve()
    work = work.resolve()
    relative = evidence.relative_to(work)
    if len(relative.parts) != 3 or relative.parts[1] != 'evidence':
        raise ValueError('evidence is outside this run')
    with (evidence / 'results.tsv').open() as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        if reader.fieldnames != ['id', 'step', 'expect', 'exit', 'reason_check', 'verdict']:
            raise ValueError('invalid results header')
        rows = list(reader)
    if not rows or any(None in row or any(v is None for v in row.values()) for row in rows):
        raise ValueError('empty or malformed results')
    if any(row['verdict'] != 'PASS' for row in rows) and rc == 0:
        raise ValueError('non-PASS results with zero pilot exit')
    passed = sum(row['verdict'] == 'PASS' for row in rows)
    summary = (evidence / 'summary.txt').read_text().splitlines()
    if f'PROGRESS={passed}/{len(rows)}' not in summary or f'evidence={evidence}' not in summary:
        raise ValueError('missing or inconsistent summary')
    verdict = 'PASS' if rc == 0 else 'FAIL'
    if f'PILOT 3a core (ci-local): {verdict}' not in text.splitlines():
        raise ValueError('pilot did not finish')
    print(evidence)


if __name__ == '__main__':
    try:
        verify(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3]))
    except (ValueError, OSError, UnicodeError) as error:
        sys.exit(f'PILOT mandatory current-run report invalid: {error}')
