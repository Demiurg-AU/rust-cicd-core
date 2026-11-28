#!/usr/bin/env python3
"""Small offline regression tests for the caller trust boundary; no Rust/CI run."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rcc-caller-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.crate = self.root / 'crate'
        self.crate.mkdir()
        self.tpl = self.root / 'rcc'
        (self.tpl / 'scripts').mkdir(parents=True)
        (self.tpl / 'pilots').mkdir()
        for name in ('check-crate-run.sh', 'pilot-config.sh', 'pilot-report.py'):
            shutil.copy(ROOT / 'scripts' / name, self.tpl / 'scripts' / name)
        shutil.copytree(ROOT / 'pilots/humantime', self.crate / '.rcc',
                        ignore=shutil.ignore_patterns('work'))
        for repo in (self.crate, self.tpl):
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            subprocess.run(['git', '-C', str(repo), '-c', 'user.name=test', '-c',
                            'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
                            'commit', '-q', '--allow-empty', '-m', 'fixture'], check=True)
        self.env = dict(os.environ, RUNNER_TEMP=str(self.root),
                        GITHUB_OUTPUT=str(self.root / 'output'),
                        GITHUB_STEP_SUMMARY=str(self.root / 'summary'))

    def parse(self, text):
        p = self.crate / '.rcc/pilot.env'
        p.write_text(text)
        return subprocess.run(['bash', str(ROOT / 'scripts/pilot-config.sh'), str(p)],
                              capture_output=True, text=True)

    def run_adapter(self, body):
        (self.tpl / 'scripts/pilot.sh').write_text(body)
        return subprocess.run(['bash', str(self.tpl / 'scripts/check-crate-run.sh'),
                               str(self.crate), '.rcc'], env=self.env,
                              capture_output=True, text=True)

    def test_quickstart_literal_profile(self):
        text = (ROOT / 'pilots/humantime/pilot.env').read_text()
        result = self.parse(text)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PILOT_3B_REQUIRE\tfuzz-targets fuzz-canaries k5 k4 claims', result.stdout)

    def test_reject_shell_unknown_duplicate_and_invalid_values(self):
        for entry in ['exit 0', 'CRATE_NAME=$(touch sentinel)', 'PATH=/tmp',
                      'CRATE_NAME=../escape', 'REQUIRE_LEAN=2', 'SEMVER_BASELINE=main',
                      'CRATE_NAME=again', 'PILOT_KANI=off']:
            with self.subTest(entry=entry):
                self.assertNotEqual(self.parse('CRATE_NAME=humantime\n'+entry+'\n').returncode, 0)
        self.assertFalse((self.root / 'sentinel').exists())

    def test_reject_before_pilot_and_no_shell_execution(self):
        sentinel = self.root / 'executed'
        (self.crate / '.rcc/pilot.env').write_text(f'CRATE_NAME=humantime\ntouch {sentinel}\nexit 0\n')
        result = self.run_adapter(f'touch {sentinel}\nexit 0\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(sentinel.exists())

    def test_success_without_current_report_is_rejected(self):
        for body in ['exit 0\n', 'echo "PILOT 3a core (ci-local): PASS"\nexit 0\n']:
            with self.subTest(body=body):
                result = self.run_adapter(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('mandatory completed report', result.stdout)

    def report_body(self, rc):
        verdict = 'PASS' if rc == 0 else 'FAIL'
        count = 1 if rc == 0 else 0
        return f'''ev="$1/work/humantime/evidence/current"
mkdir -p "$ev"
printf 'id\\tstep\\texpect\\texit\\treason_check\\tverdict\\nS1d\\tmutation\\tpass\\t{rc}\\tn/a\\t{verdict}\\n' > "$ev/results.tsv"
printf 'PROGRESS={count}/1\\nevidence=%s\\n' "$ev" > "$ev/summary.txt"
echo "  evidence: $ev (ci-local), $1/work (spec pack logs, status.tsv)"
echo '    NOT PASS S1d mutation: FAIL - MISSED src/date.rs:43:9'
echo 'PILOT 3a core (ci-local): {verdict}'
exit {rc}
'''

    def test_current_complete_report_passes(self):
        result = self.run_adapter(self.report_body(0))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_nonzero_preserved_with_report_and_without_report(self):
        for body in [self.report_body(7), 'exit 7\n']:
            with self.subTest(body=body):
                result = self.run_adapter(body)
                self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        reports = list((self.tpl / 'pilots').glob('caller.*/work/pilot.log'))
        self.assertTrue(any('MISSED src/date.rs:43:9' in p.read_text() for p in reports))

    def test_missing_summary_or_completion_marker_is_rejected(self):
        body = self.report_body(0)
        variants = [body.replace('exit 0', 'rm "$ev/summary.txt"\nexit 0'),
                    body.replace("echo 'PILOT 3a core (ci-local): PASS'", ':'),
                    self.report_body(7).replace('exit 7', 'exit 0')]
        for variant in variants:
            with self.subTest(body=variant):
                self.assertNotEqual(self.run_adapter(variant).returncode, 0)

    def test_stale_report_from_another_invocation_is_rejected(self):
        self.assertEqual(self.run_adapter(self.report_body(0)).returncode, 0)
        stale = next((self.tpl / 'pilots').glob('caller.*/work/pilot.log')).read_text()
        result = self.run_adapter("cat <<'END'\n"+stale+"END\nexit 0\n")
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
