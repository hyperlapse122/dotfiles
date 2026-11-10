"""Drive agent-plugin-release against fixture release feeds.

Every fixture gives each tag train a different version:
if two trains shared one, a correct prefix filter and a broken one would print
the same answer and the round would prove nothing.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/agent-plugin-release'
PREFIX = 'compound-engineering-'

FAKE_GH = '''#!{python}
import os, sys
expected = ['api', f"repos/{{os.environ['EXPECTED_SOURCE']}}/releases?per_page=100"]
if sys.argv[1:] != expected:
    sys.stderr.write(f'unexpected gh args: {{sys.argv[1:]!r}} != {{expected!r}}\\n')
    sys.exit(99)
status = int(os.environ.get('FAKE_FETCH_STATUS', '0'))
sys.stdout.write(os.environ['FAKE_FETCH_BODY'])
if status:
    sys.stderr.write(os.environ['FAKE_FETCH_BODY'])
    sys.exit(status)
'''


def release(tag, draft=False, prerelease=False):
    return {'tag_name': tag, 'draft': draft, 'prerelease': prerelease}


class ReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin_dir = root / 'bin'
        self.bin_dir.mkdir()
        gh = self.bin_dir / 'gh'
        gh.write_text(FAKE_GH.format(python=sys.executable))
        gh.chmod(0o755)

    def run_release(self, body, prefix=PREFIX, source='EveryInc/compound-engineering-plugin',
                    status=0):
        env = dict(os.environ)
        env['PATH'] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env['EXPECTED_SOURCE'] = source
        env['FAKE_FETCH_BODY'] = body if isinstance(body, str) else json.dumps(body)
        env['FAKE_FETCH_STATUS'] = str(status)
        return subprocess.run(
            [sys.executable, str(SCRIPT), '--source', source, '--tag-prefix', prefix],
            capture_output=True,
            text=True,
            env=env,
        )

    def test_every_train_distinct_and_only_the_plugin_train_wins(self):
        result = self.run_release([
            release('v8.1.0'),
            release('cli-v7.2.0'),
            release('marketplace-v6.3.0'),
            release('cursor-marketplace-v5.4.0'),
            release('coding-tutor-v4.5.0'),
            release('compound-engineering-v3.28.0'),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'compound-engineering-v3.28.0')

    def test_comparison_is_numeric_not_lexical(self):
        result = self.run_release([
            release('compound-engineering-v3.9.0'),
            release('compound-engineering-v3.10.0'),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'compound-engineering-v3.10.0')

    def test_draft_and_prerelease_are_excluded(self):
        result = self.run_release([
            release('compound-engineering-v4.0.0', draft=True),
            release('compound-engineering-v3.99.0', prerelease=True),
            release('compound-engineering-v3.28.0'),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'compound-engineering-v3.28.0')

    def test_no_matching_prefix_names_the_prefix(self):
        result = self.run_release([release('cli-v9.9.9')])
        self.assertEqual(result.returncode, 1)
        self.assertIn(PREFIX, result.stderr)
        self.assertEqual(result.stdout.strip(), '')

    def test_prefix_matching_tag_with_shell_metacharacters_is_refused(self):
        result = self.run_release([
            release('compound-engineering-v1.0.0$(touch /tmp/pwned)'),
            release('compound-engineering-v3.28.0'),
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), '')
        self.assertIn('not a plain version', result.stderr)

    def test_prefix_matching_tag_with_a_newline_is_refused(self):
        result = self.run_release([release('compound-engineering-v1.0.0\nrm -rf /')])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), '')

    def test_non_numeric_component_is_refused(self):
        result = self.run_release([release('compound-engineering-vnightly')])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), '')

    def test_malformed_payload_does_not_echo_it(self):
        secret = 'SHOULD-NOT-APPEAR'
        result = self.run_release('not json ' + secret)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(secret, result.stdout)
        self.assertNotIn(secret, result.stderr)

    def test_fetch_failure_does_not_echo_the_payload(self):
        sentinel = 'FAILED-FETCH-PAYLOAD-MUST-STAY-PRIVATE'
        result = self.run_release(sentinel, status=4)
        self.assertEqual(result.returncode, 1)
        self.assertIn('failed with status 4', result.stderr)
        self.assertNotIn(sentinel, result.stdout)
        self.assertNotIn(sentinel, result.stderr)

    def test_feed_that_is_not_a_list_is_refused(self):
        result = self.run_release({'message': 'Not Found'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('did not return a list', result.stderr)

    def test_unsafe_source_is_refused(self):
        result = self.run_release([release('compound-engineering-v3.28.0')],
                                  source='owner/repo; rm -rf /')
        self.assertEqual(result.returncode, 2)
        self.assertIn('unsafe source', result.stderr)


if __name__ == '__main__':
    unittest.main()
