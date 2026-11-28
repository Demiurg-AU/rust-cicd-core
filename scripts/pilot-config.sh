#!/usr/bin/env bash
# Literal-only pilot configuration parser; copied with the trusted shell helpers.
python3 - "$@" <<'PY'
"""Read the pilot profile as literal data; never evaluate shell syntax."""
import argparse
import pathlib
import re
import sys

PATTERNS = {
    'CRATE_NAME': r'[A-Za-z0-9][A-Za-z0-9_-]*',
    'CRATE_URL': r'(?:https://[A-Za-z0-9.-]+/|/)[A-Za-z0-9_./ :@+-]+',
    'CRATE_SHA': r'[0-9a-f]{40}',
    'REQUIRE_LEAN': r'[01]',
    'SEMVER_BASELINE': r'(?:[0-9a-f]{40})?',
    'PILOT_3B_REQUIRE': r'(?:fuzz-targets|fuzz-canaries|k5|k4|claims)(?: (?:fuzz-targets|fuzz-canaries|k5|k4|claims))*',
    'PILOT_3B_CLAIMS': r'[A-Za-z][A-Za-z0-9_-]*(?: [A-Za-z][A-Za-z0-9_-]*)*',
    'PILOT_KANI': r'(?:abstain|required)',
}


def read_profile(path):
    values = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if not sep or key not in PATTERNS or key in values:
            raise ValueError(f'line {number}: unknown, duplicate or malformed parameter')
        if value[:1] in ('"', "'") and value[-1:] == value[:1] and len(value) >= 2:
            value = value[1:-1]
        if not re.fullmatch(PATTERNS[key], value, flags=re.ASCII):
            raise ValueError(f'line {number}: invalid value for {key}')
        values[key] = value
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', type=pathlib.Path)
    parser.add_argument('--caller-url')
    parser.add_argument('--caller-sha')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    values = read_profile(args.profile)
    for key, value in [('CRATE_URL', args.caller_url), ('CRATE_SHA', args.caller_sha)]:
        if value is not None:
            if not re.fullmatch(PATTERNS[key], value, flags=re.ASCII):
                raise ValueError(f'invalid caller {key}')
            values[key] = value
    if 'CRATE_NAME' not in values:
        raise ValueError('missing CRATE_NAME')
    if args.output:
        args.output.write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
    else:
        for key, value in values.items():
            print(f'{key}\t{value}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, UnicodeError) as error:
        sys.exit(f'PILOT invalid configuration: {error}')

PY
