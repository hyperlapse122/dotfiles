"""Tests for scripts/serve-html: serve one HTML file on loopback and detach.

Each test runs the script as a subprocess, the way an agent does, reads the
target it prints, and talks to the detached server over 127.0.0.1. Every test
records the server's PID through --pid-file and kills it in cleanup.
"""

import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse

SCRIPT = Path(__file__).resolve().parent.parent / 'scripts' / 'serve-html'


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:
        # A zombie still answers signal 0; its parent (init) reaps it shortly.
        return Path('/proc/{}/stat'.format(pid)).read_text().split(') ')[-1][0] != 'Z'
    except OSError:
        return True


class ServeHtmlTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name).resolve()
        self.pid_file = self.dir / 'server.pid'
        self.pids = []
        self.addCleanup(self.kill_servers)

    def kill_servers(self):
        for pid in self.pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def run_script(self, *args, cwd=None):
        pid_file = self.dir / 'pid-{}'.format(len(self.pids))
        started = time.monotonic()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--pid-file', str(pid_file), *args],
            cwd=cwd or self.dir, capture_output=True, text=True, timeout=10)
        self.elapsed = time.monotonic() - started
        if pid_file.exists():
            self.pids.append(int(pid_file.read_text()))
        return result

    def serve(self, *args, cwd=None):
        result = self.run_script(*args, cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('\n'), 1, result.stdout)
        target = json.loads(result.stdout)
        self.assertEqual(target['kind'], 'environment-port')
        self.assertEqual(sorted(target), ['kind', 'path', 'port'])
        return target

    def get(self, target, path=None, host='127.0.0.1', headers=None):
        connection = http.client.HTTPConnection(host, target['port'], timeout=5)
        try:
            connection.request('GET', target['path'] if path is None else path,
                               headers=headers or {})
            response = connection.getresponse()
            return response.status, response, response.read()
        finally:
            connection.close()

    def write(self, name, content):
        path = self.dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
        return path

    def test_prints_one_target_line_and_returns_while_serving(self):
        page = self.write('report.html', '<h1>hello</h1>')
        target = self.serve(str(page))
        self.assertEqual(target['path'], '/report.html')
        self.assertLess(self.elapsed, 5)
        status, _, body = self.get(target)
        self.assertEqual(status, 200)
        self.assertEqual(body, b'<h1>hello</h1>')

    def test_response_headers(self):
        target = self.serve(str(self.write('a.html', '<p>a</p>')))
        _, response, _ = self.get(target)
        self.assertEqual(response.getheader('Cache-Control'), 'no-store')
        self.assertEqual(response.getheader('Content-Type'), 'text/html; charset=utf-8')

    def test_page_without_an_html_suffix_is_still_served_as_html(self):
        page = self.write('cov/report', '<p>report</p>')
        for args in ([str(page)], ['--root', str(self.dir / 'cov'), str(page)]):
            target = self.serve(*args)
            _, response, _ = self.get(target)
            self.assertEqual(response.getheader('Content-Type'), 'text/html; charset=utf-8', args)
        _, response, _ = self.get(target, '/./report')
        self.assertEqual(response.getheader('Content-Type'), 'text/html; charset=utf-8')

    def test_only_loopback_host_names_are_answered(self):
        target = self.serve(str(self.write('a.html', 'host')))
        for host in ('localhost:{}'.format(target['port']), '127.0.0.1', '[::1]:1'):
            self.assertEqual(self.get(target, headers={'Host': host})[0], 200, host)
        for host in ('attacker.example', 'attacker.example:{}'.format(target['port'])):
            status, _, body = self.get(target, headers={'Host': host})
            self.assertEqual((status, body), (404, b''), host)

    def test_a_silent_connection_does_not_block_requests(self):
        target = self.serve(str(self.write('a.html', 'busy')))
        silent = socket.create_connection(('127.0.0.1', target['port']), timeout=3)
        self.addCleanup(silent.close)
        self.assertEqual(self.get(target)[2], b'busy')

    def test_reload_shows_current_content(self):
        page = self.write('a.html', 'first')
        target = self.serve(str(page))
        self.assertEqual(self.get(target)[2], b'first')
        page.write_text('second', encoding='utf-8')
        self.assertEqual(self.get(target)[2], b'second')

    def test_other_paths_are_404_by_default(self):
        page = self.write('a.html', 'page')
        self.write('secret.txt', 'secret')
        target = self.serve(str(page))
        for path in ('/', '/secret.txt', '/a.html/', '/../secret.txt', '/a.htm'):
            self.assertEqual(self.get(target, path)[0], 404, path)

    def test_root_serves_siblings_with_their_types(self):
        page = self.write('cov/index.html', '<link rel=stylesheet href=style.css>')
        self.write('cov/style.css', 'body{}')
        self.write('cov/js/app.js', 'let a;')
        target = self.serve('--root', str(self.dir / 'cov'), str(page))
        self.assertEqual(target['path'], '/index.html')
        status, response, body = self.get(target, '/style.css')
        self.assertEqual((status, body), (200, b'body{}'))
        self.assertEqual(response.getheader('Content-Type'), 'text/css; charset=utf-8')
        self.assertEqual(response.getheader('Cache-Control'), 'no-store')
        self.assertEqual(self.get(target, '/js/app.js')[2], b'let a;')

    def test_root_serves_non_html_files_with_their_own_type(self):
        page = self.write('cov/index.html', 'index')
        self.write('cov/data.json', '{}')
        target = self.serve('--root', str(self.dir / 'cov'), str(page))
        _, response, _ = self.get(target, '/data.json')
        self.assertEqual(response.getheader('Content-Type'), 'application/json; charset=utf-8')

    def test_root_does_not_escape(self):
        self.write('outside.txt', 'outside')
        page = self.write('cov/index.html', 'index')
        (self.dir / 'cov' / 'link.txt').symlink_to(self.dir / 'outside.txt')
        target = self.serve('--root', str(self.dir / 'cov'), str(page))
        for path in ('/../outside.txt', '/%2e%2e/outside.txt', '/..%2foutside.txt',
                     '/sub/../../outside.txt', '/sub/../index.html', '/link.txt',
                     '/missing.txt', '/js'):
            self.assertEqual(self.get(target, path)[0], 404, path)

    def test_root_prints_the_root_relative_path(self):
        page = self.write('cov/sub dir/page.html', 'nested')
        target = self.serve('--root', str(self.dir / 'cov'), str(page))
        self.assertEqual(target['path'], '/sub%20dir/page.html')
        status, _, body = self.get(target)
        self.assertEqual((status, body), (200, b'nested'))

    def test_file_outside_root_fails(self):
        page = self.write('page.html', 'page')
        self.write('cov/index.html', 'index')
        result = self.run_script('--root', str(self.dir / 'cov'), str(page))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertNotEqual(result.stderr, '')
        self.assertEqual(self.pids, [])

    def test_root_that_is_not_a_directory_fails(self):
        page = self.write('page.html', 'page')
        result = self.run_script('--root', str(page), str(page))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('not a directory', result.stderr)

    def test_server_start_failure_prints_nothing_and_fails(self):
        page = self.write('page.html', 'page')
        result = self.run_script('--pid-file', str(self.dir / 'missing' / 'x.pid'), str(page))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('did not start', result.stderr)

    def test_missing_file_fails(self):
        result = self.run_script(str(self.dir / 'missing.html'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('missing.html', result.stderr)
        self.assertEqual(self.pids, [])

    def test_unreadable_file_fails(self):
        page = self.write('locked.html', 'x')
        page.chmod(0)
        if os.access(page, os.R_OK):
            self.skipTest('running as a user that ignores file modes')
        result = self.run_script(str(page))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertNotEqual(result.stderr, '')

    def test_directory_argument_fails(self):
        result = self.run_script(str(self.dir))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_special_characters_in_the_name_are_percent_encoded(self):
        name = 'my report 보고서 #1.html'
        page = self.write(name, 'special')
        target = self.serve(str(page))
        self.assertEqual(target['path'], '/' + urllib.parse.quote(name))
        self.assertEqual(urllib.parse.unquote(target['path']), '/' + name)
        status, _, body = self.get(target)
        self.assertEqual((status, body), (200, b'special'))

    def test_relative_path_resolves_from_the_callers_directory(self):
        self.write('sub/rel.html', 'relative')
        target = self.serve('rel.html', cwd=self.dir / 'sub')
        self.assertEqual(self.get(target)[2], b'relative')

    def test_server_exits_after_the_idle_window_and_requests_extend_it(self):
        page = self.write('a.html', 'idle')
        target = self.serve('--idle-seconds', '4', str(page))
        pid = self.pids[-1]
        for _ in range(3):
            time.sleep(1.5)
            self.assertEqual(self.get(target)[0], 200)
            self.assertTrue(alive(pid), 'a request inside the window must keep the server up')
        deadline = time.monotonic() + 10
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertFalse(alive(pid), 'the server must exit after the idle window')

    def test_server_runs_in_its_own_session(self):
        self.serve(str(self.write('a.html', 'session')))
        self.assertNotEqual(os.getsid(self.pids[-1]), os.getsid(0))

    @unittest.skipUnless(sys.platform.startswith('linux'), '127.0.0.2 is loopback only on Linux')
    def test_binds_loopback_only(self):
        target = self.serve(str(self.write('a.html', 'loopback')))
        self.assertEqual(self.get(target)[0], 200)
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(('127.0.0.2', target['port']), timeout=3).close()

    def test_default_idle_window_is_thirty_minutes(self):
        result = subprocess.run([sys.executable, str(SCRIPT), '--help'],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(' '.join(result.stdout.split()),
                         r'--idle-seconds IDLE_SECONDS [^-]*\(default: 1800(\.0)?\)')


if __name__ == '__main__':
    unittest.main()
