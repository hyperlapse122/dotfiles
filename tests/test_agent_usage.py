"""Offline command-boundary proofs for provider usage and shared cache behavior."""

import concurrent.futures
import datetime
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/agent-usage"
TOKEN = "fake-private-token-never-publish"


def provider_windows(result):
    """Windows as the provider reported them, without the clock-derived pace fields."""
    return [{key: value for key, value in entry.items()
             if key not in ('elapsedPercent', 'overshootPercent')} for entry in result['windows']]


class UsageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, HOME=str(self.root),
                        XDG_CACHE_HOME=str(self.root / "cache"),
                        CODEX_HOME=str(self.root / ".codex"),
                        GROK_HOME=str(self.root / ".grok"),
                        CLAUDE_CONFIG_DIR=str(self.root / ".claude"),
                        PI_CODING_AGENT_DIR=str(self.root / ".omp/agent"),
                        AGENT_USAGE_ANTIGRAVITY_VERSION="9.9.9",
                        PATH=str(self.root) + os.pathsep + os.environ.get("PATH", ""))
        for key in ("XAI_API_KEY", "XAI_BASE_URL", "GROK_BASE_URL", "ANTHROPIC_API_KEY", "GEMINI_HOME"):
            self.env.pop(key, None)
        self.write(".codex/auth.json", {"tokens": {"account_id": "codex-account"}})
        self.write(".claude.json", {"oauthAccount": {"accountUuid": "claude-account"}})
        self.write(".grok/auth.json", {"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": {
            "key": TOKEN, "email": "example@example.invalid"}})
        reset = int(time.time()) + 7200
        self.write(".gemini/antigravity-acp/acp_token.json", {
            "client_id": "antigravity-client", "client_secret": TOKEN, "refresh_token": TOKEN,
            "token_uri": "https://oauth2.googleapis.com/token", "project_id": "gemini-project"})
        reset_time = datetime.datetime.fromtimestamp(reset, datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
        self.data = {
            "codex": {"accountId": "codex-account", "rateLimits": {
                "primary": {"usedPercent": 50, "windowDurationMins": 300, "resetsAt": reset},
                "secondary": {"usedPercent": 80, "windowDurationMins": 10080, "resetsAt": reset}}},
            "claude": {"rate_limits": {"five_hour": {"utilization": 30, "resets_at": reset},
                "seven_day": {"utilization": 40, "resets_at": reset}},
                "model_scoped": [{"display_name": "Fable", "utilization": 90, "resets_at": reset}]},
            "antigravity": {"groups": [
                {"displayName": "Gemini Models", "buckets": [
                    {"bucketId": "gemini-weekly", "window": "weekly", "resetTime": reset_time, "remainingFraction": .8},
                    {"bucketId": "gemini-5h", "window": "5h", "resetTime": reset_time, "remainingFraction": .9}]},
                {"displayName": "Claude and GPT models", "buckets": [
                    {"bucketId": "3p-weekly", "window": "weekly", "resetTime": reset_time, "remainingFraction": .01}]}]},
            "grok": {"config": {"creditUsagePercent": 10, "currentPeriod": {
                "type": "USAGE_PERIOD_TYPE_WEEKLY", "start": reset - 604800, "end": reset}}},
            "synthetic": {"subscription": {"limit": 100, "requests": 30, "renewsAt": reset},
                "search": {"hourly": {"limit": 10, "requests": 2, "renewsAt": reset}},
                "planWeeklyLimit": {"percentRemaining": 20, "nextRegenAt": reset, "nextRegenPercent": 5}},
        }
        self.save()
        self.stub("codex", '''
import json,sys,time
assert sys.argv[1:] == ['app-server','--listen','stdio://']
for line in sys.stdin:
 r=json.loads(line)
 if r['method']=='initialize':
  assert r['params']=={'clientInfo':{'name':'agent-usage','version':'1'}}
  print(json.dumps({'id':r['id'],'result':{}}),flush=True)
 elif r['method']=='initialized': initialized=True
 elif r['method']=='account/rateLimits/read':
  assert initialized and r['params']=={}
  (root/'codex-reading').touch()
  time.sleep(data.get('delay',0))
  if data.get('fail'): sys.exit(1)
  print(json.dumps({'id':r['id'],'result':data['codex']}),flush=True)
''')
        self.stub("node", "import json,sys\nif data.get('fail_claude'):\n print(" + repr(TOKEN) + ",file=sys.stderr)\n sys.exit(1)\nprint(json.dumps(data['claude']))")
        self.stub("omp", "import sys\nsys.exit(1)")
        self.stub("grok", "import sys\nassert sys.argv[1:]==['models']")
        self.stub("omp-synthetic-key", "print('" + TOKEN + "')")
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.assertEqual(self.headers['Authorization'], 'Bearer ' + TOKEN)
                provider = 'grok' if self.path.startswith('/v1/billing') else 'synthetic'
                statuses = outer.data.get('grok_statuses', []) if provider == 'grok' else []
                status = statuses.pop(0) if statuses else 200
                self.send_response(status)
                self.end_headers()
                self.wfile.write(json.dumps(outer.data[provider]).encode())

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.stub("curl", f'''
import sys,urllib.parse,urllib.request,urllib.error
assert sys.argv[1:3]==['--config','-'] and not any('{TOKEN}' in arg for arg in sys.argv)
config=sys.stdin.read()
url=sys.argv[-1]
body=[json.loads(line[len('data = '):]) for line in config.splitlines() if line.startswith('data = ')]
if url=='https://oauth2.googleapis.com/token':
 assert 'Authorization' not in config
 assert urllib.parse.parse_qs(body[0])=={{'client_id':['antigravity-client'],'client_secret':['{TOKEN}'],
  'refresh_token':['{TOKEN}'],'grant_type':['refresh_token']}}
 print(json.dumps({{'access_token':'{TOKEN}'}})+'\\n200',end='')
 sys.exit()
if url=='https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary':
 assert 'header = "Authorization: Bearer {TOKEN}"' in config
 assert 'header = "User-Agent: antigravity/acp/9.9.9 (aidev_client)"' in config
 assert json.loads(body[0])=={{'project':'gemini-project'}}
 print(json.dumps(data['antigravity'])+'\\n200',end='')
 sys.exit()
assert 'Bearer {TOKEN}' in config
assert url in ['https://cli-chat-proxy.grok.com/v1/billing?format=credits','https://api.synthetic.new/v2/quotas']
req=urllib.request.Request('http://127.0.0.1:{server.server_port}/'+url.split('/',3)[3],headers={{'Authorization':'Bearer {TOKEN}'}})
try: response=urllib.request.urlopen(req)
except urllib.error.HTTPError as exc: response=exc
sys.stdout.buffer.write(response.read()+b'\\n'+str(response.code).encode())
''')

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def save(self):
        self.write('data.json', self.data)

    def stub(self, name, body):
        path = self.root / name
        path.write_text(f'#!{sys.executable}\nimport json,pathlib\nroot=pathlib.Path(__file__).parent\ndata=json.loads((root/"data.json").read_text())\nwith (root/"calls").open("a") as f: f.write({name!r}+"\\n")\n' + body + '\n')
        path.chmod(0o755)

    def invoke(self, *args):
        proc = subprocess.run([sys.executable, str(SCRIPT), '--json', *args],
                              env=self.env, capture_output=True, text=True, timeout=40)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn(TOKEN, proc.stdout + proc.stderr)
        for path in (self.root / 'cache').rglob('*'):
            if path.is_file():
                self.assertNotIn(TOKEN, path.read_text())
        return json.loads(proc.stdout)['providers']

    def calls(self, name):
        return (self.root / 'calls').read_text().splitlines().count(name)

    def test_readers_preserve_provider_and_model_windows(self):
        result = self.invoke()
        self.assertEqual(result['codex']['windows'][1]['remainingPercent'], 20)
        self.assertEqual(result['claude']['windows'][-1]['model'], 'Fable')
        weekly = result['synthetic']['windows'][-1]
        self.assertEqual(weekly['remainingPercent'], 20)
        self.assertEqual(weekly['nextRegenPercent'], 5)
        self.assertNotIn('resetsAt', weekly)
        self.assertEqual(result['grok']['windows'][0]['usedPercent'], 10)

    def test_default_output_is_readable_usage_and_regeneration(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], env=self.env,
                                capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('codex: ok', result.stdout)
        self.assertIn('% used', result.stdout)
        self.assertIn('regenerates 5%', result.stdout)
        self.assertIn('% elapsed, within pace', result.stdout)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_grok_refresh_and_provider_failure_isolation(self):
        self.data['grok_statuses'] = [401, 200]
        self.data['fail_claude'] = True
        self.save()
        result = self.invoke()
        self.assertEqual(result['grok']['status'], 'ok')
        self.assertEqual(self.calls('grok'), 1)
        self.assertEqual(result['claude']['status'], 'unknown')
        self.assertEqual(result['codex']['status'], 'ok')

    def test_grok_second_401_and_402(self):
        for statuses, exhausted in [([401, 401], False), ([402], True)]:
            with self.subTest(statuses=statuses):
                self.data['grok_statuses'] = statuses
                result = self.invoke('--refresh')['grok']
                self.assertEqual(result['status'], 'unknown')
                self.assertEqual(result.get('exhausted', False), exhausted)

    def test_grok_api_key_and_custom_endpoint_are_unknown(self):
        for key in ('XAI_API_KEY', 'XAI_BASE_URL'):
            self.env[key] = 'custom'
            self.assertEqual(self.invoke('--refresh')['grok']['status'], 'unknown')
            del self.env[key]
        (self.root / '.grok/config.toml').write_text('[api]\nbase_url = "https://custom.invalid"\n')
        self.assertEqual(self.invoke('--refresh')['grok']['status'], 'unknown')

    def test_grok_legacy_auth_missing_percentage_and_api_key_mode(self):
        auth = self.root / '.grok/auth.json'
        self.write('.grok/auth.json', {'https://accounts.x.ai/sign-in': {
            'key': TOKEN, 'email': 'legacy@example.invalid'}})
        del self.data['grok']['config']['creditUsagePercent']
        self.save()
        self.assertEqual(self.invoke()['grok']['windows'][0]['remainingPercent'], 100)
        entry = json.loads(auth.read_text())
        entry['https://accounts.x.ai/sign-in']['auth_mode'] = 'api_key'
        auth.write_text(json.dumps(entry))
        self.assertEqual(self.invoke()['grok']['status'], 'unknown')

    def test_claude_nested_model_windows(self):
        self.data['claude']['rate_limits']['model_scoped'] = self.data['claude'].pop('model_scoped')
        self.save()
        result = self.invoke()
        self.assertEqual([w['model'] for w in result['claude']['windows'] if w.get('model')], ['Fable'])

    def test_claude_legacy_model_windows_and_equivalent_scoped_windows(self):
        rates = self.data['claude']['rate_limits']
        del self.data['claude']['model_scoped']
        for model, used in [('opus', 95), ('sonnet', 99)]:
            rates['seven_day_' + model] = dict(rates['seven_day'], utilization=used)
        self.save()
        legacy = self.invoke()['claude']
        self.assertFalse(legacy['skip'])
        self.assertEqual(sorted(legacy['skipModels']), ['Opus', 'Sonnet'])
        self.assertEqual(len(legacy['windows']), 4)
        rates['model_scoped'] = [dict(rates['seven_day_' + model], display_name=model.title())
                                for model in ('opus', 'sonnet')]
        self.save()
        self.assertEqual(provider_windows(self.invoke('--refresh')['claude']),
                         provider_windows(legacy))

    def test_gemini_reads_only_gemini_buckets_from_antigravity(self):
        result = self.invoke()['gemini']
        self.assertEqual(result['status'], 'ok')
        self.assertEqual([(w['label'], w['remainingPercent'], w['durationMins']) for w in result['windows']],
                         [('weekly', 80, 10080), ('5h', 90, 300)])
        self.assertFalse(result['skip'])
        self.assertEqual(result['skipModels'], {})

    def test_gemini_without_antigravity_sign_in_is_unknown_and_skips_nothing(self):
        (self.root / '.gemini/antigravity-acp/acp_token.json').unlink()
        result = self.invoke()['gemini']
        self.assertEqual(result['status'], 'unknown')
        self.assertEqual(result['reason'], 'no Antigravity ACP sign-in')
        self.assertFalse(result['skip'])

    def test_synthetic_search_is_reported_outside_routing_windows(self):
        self.data['synthetic']['subscription']['requests'] = 5
        self.data['synthetic']['planWeeklyLimit']['percentRemaining'] = 95
        self.data['synthetic']['search']['hourly']['requests'] = 9
        self.save()
        result = self.invoke()['synthetic']
        self.assertFalse(result['skip'])
        self.assertEqual(result['skipModels'], {})
        self.assertEqual(min(w['remainingPercent'] for w in result['windows']), 95)
        self.assertEqual(result['resources'][0]['resource'], 'search')
        self.assertEqual(result['resources'][0]['remainingPercent'], 10)

    def test_real_claude_sdk_usage_is_isolated_and_sends_no_prompt(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('real Node and the pinned Claude Agent SDK are required')
        probe = subprocess.run([node, '-e', "require.resolve('@anthropic-ai/claude-agent-sdk')"],
                               capture_output=True, env=self.env, timeout=10)
        if probe.returncode:
            self.skipTest('pinned Claude Agent SDK is not on NODE_PATH')
        self.stub('claude', '''
import json,signal,sys
(root/'claude-argv').write_text(json.dumps(sys.argv[1:]))
def closed(*args):
 (root/'claude-closed').touch()
 sys.exit(0)
signal.signal(signal.SIGTERM, closed)
for line in sys.stdin:
 message=json.loads(line)
 with (root/'claude-messages').open('a') as output:
  output.write(json.dumps(message)+'\\n')
 if message['type']=='control_request':
  kind=message['request']['subtype']
  if kind not in ('initialize','get_usage'): sys.exit(2)
  response=data['claude'] if kind=='get_usage' else {}
  print(json.dumps({'type':'control_response','response':{
   'subtype':'success','request_id':message['request_id'],'response':response}}),flush=True)
closed()
''')
        result = subprocess.run([node, str(SCRIPT.with_name('agent-usage-claude.mjs'))],
                                env=self.env, cwd=self.root, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), self.data['claude'])
        argv = json.loads((self.root / 'claude-argv').read_text())
        def option(name):
            for index, argument in enumerate(argv):
                if argument == name:
                    return argv[index + 1]
                if argument.startswith(name + '='):
                    return argument.split('=', 1)[1]
            return None
        self.assertEqual(option('--setting-sources'), '')
        self.assertIn('--strict-mcp-config', argv)
        if option('--mcp-config') is not None:
            self.assertEqual(json.loads(option('--mcp-config')), {'mcpServers': {}})
        messages = [json.loads(line) for line in (self.root / 'claude-messages').read_text().splitlines()]
        self.assertTrue(messages)
        self.assertTrue(all(m['type'] == 'control_request' for m in messages))
        self.assertEqual([m['request']['subtype'] for m in messages], ['initialize', 'get_usage'])
        self.assertTrue(messages[-1]['request']['skip_behaviors'])
        self.assertTrue((self.root / 'claude-closed').exists())

    def test_fresh_and_concurrent_calls_share_fetch(self):
        self.data['delay'] = .4
        self.save()
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: self.invoke(), range(2)))
        self.assertEqual(provider_windows(results[0]['codex']), provider_windows(results[1]['codex']))
        self.invoke()
        self.assertEqual(self.calls('codex'), 1)

    def test_failure_cache_refresh_and_stale_success(self):
        self.data['fail'] = True
        self.save()
        failed = self.invoke()['codex']
        self.assertEqual(failed['status'], 'unknown')
        self.assertIn('accountHash', failed)
        self.assertEqual(self.invoke()['codex']['status'], 'unknown')
        self.assertEqual(self.calls('codex'), 1)
        self.data['fail'] = False
        self.save()
        success = self.invoke('--refresh')['codex']
        self.assertEqual(success['status'], 'ok')
        self.assertEqual(failed['accountHash'], success['accountHash'])
        self.data['fail'] = True
        self.save()
        result = self.invoke('--refresh')['codex']
        self.assertEqual(result['status'], 'stale')
        self.assertEqual(result['windows'][1]['remainingPercent'], 20)
        self.invoke()
        self.assertEqual(self.calls('codex'), 3)

    def test_stale_expired_windows_do_not_skip_provider(self):
        self.data['codex']['rateLimits']['secondary']['resetsAt'] = time.time() - 1
        self.save()
        self.invoke()
        self.data['fail'] = True
        self.save()
        result = self.invoke('--refresh')['codex']
        self.assertEqual(result['status'], 'stale')
        self.assertFalse(result['skip'])
        self.assertIsNone(result['windows'][1]['remainingPercent'])
        self.assertIsNone(result['windows'][1]['overshootPercent'])

    def codex_weekly(self, used, minutes_left, duration=10080):
        self.data['codex']['rateLimits']['secondary'] = {
            'usedPercent': used, 'windowDurationMins': duration,
            'resetsAt': time.time() + minutes_left * 60}
        self.save()
        result = self.invoke('--refresh')['codex']
        self.assertNotIn('belowThreshold', result)
        return result

    def test_pace_and_floor_decide_provider_skip(self):
        week = 10080
        # (used, minutes left, duration, expected skipReason, expected aheadOfPace)
        cases = [
            (26, week * .864, week, None, False),
            (78, week * 5 / 7, week, None, True),
            (80, 60, week, None, False),
            (35.1, 270, 300, None, True),
            (35, 270, 300, None, False),
            (25, week * 2, week, None, False),
            (25.1, week * 2, week, None, True),
            (90, 60, week, None, False),
            (90.1, 60, week, 'below floor', False),
            (95, week * 2, week, 'below floor', True),
            (95, 60, 0, 'below floor', False),
        ]
        for used, left, duration, reason, ahead in cases:
            with self.subTest(used=used, left=left, duration=duration):
                result = self.codex_weekly(used, left, duration)
                self.assertEqual(result['skipReason'], reason)
                self.assertEqual(result['skip'], reason is not None)
                self.assertEqual(result['aheadOfPace'], ahead)
        weekly = self.codex_weekly(78, week * 5 / 7)['windows'][1]
        self.assertAlmostEqual(weekly['elapsedPercent'], 200 / 7, delta=.1)
        self.assertAlmostEqual(weekly['overshootPercent'], 78 - 200 / 7 - 25, delta=.1)
        self.assertTrue(weekly['aheadOfPace'])
        unpaced = self.codex_weekly(30, 60, 0)
        self.assertIsNone(unpaced['windows'][1]['elapsedPercent'])
        self.assertIsNone(unpaced['windows'][1]['overshootPercent'])
        self.assertFalse(unpaced['skip'])

    def test_provider_values_take_the_worst_provider_window(self):
        result = self.codex_weekly(78, 10080 * 5 / 7)
        self.assertEqual(result['overshootPercent'], max(w['overshootPercent'] for w in result['windows']))
        self.assertEqual(result['remainingPercent'], 22)

    def test_model_windows_skip_only_their_model_with_combined_values(self):
        week_away = time.time() + 2 * 10080 * 60
        self.data['claude']['model_scoped'] = [
            {'display_name': 'Fable', 'utilization': 30, 'resets_at': week_away}]
        self.save()
        result = self.invoke('--refresh')['claude']
        self.assertFalse(result['skip'])
        self.assertFalse(result['aheadOfPace'])
        self.assertEqual(result['skipModels'], {})
        self.assertEqual(result['aheadModels'], {'Fable': {
            'overshootPercent': 5, 'remainingPercent': 60}})
        self.data['claude']['rate_limits']['seven_day']['utilization'] = 95
        self.save()
        result = self.invoke('--refresh')['claude']
        self.assertEqual(result['skipReason'], 'below floor')
        self.assertEqual(result['skipModels'], {'Fable': {
            'overshootPercent': 5, 'remainingPercent': 5, 'skipReason': 'below floor'}})
        self.assertEqual(result['aheadModels'], {})

    def test_rolling_and_unknown_length_windows_use_the_floor_alone(self):
        self.data['synthetic']['planWeeklyLimit']['percentRemaining'] = 8
        self.data['grok']['config']['currentPeriod'].pop('start')
        self.data['grok']['config']['creditUsagePercent'] = 95
        self.save()
        result = self.invoke()
        self.assertEqual(result['synthetic']['skipReason'], 'below floor')
        self.assertEqual(result['grok']['skipReason'], 'below floor')
        for provider in ('synthetic', 'grok'):
            for entry in result[provider]['windows']:
                self.assertIsNone(entry['elapsedPercent'])
        self.data['synthetic']['planWeeklyLimit']['percentRemaining'] = 30
        self.save()
        self.assertFalse(self.invoke('--refresh')['synthetic']['skip'])

    def test_readers_record_known_window_durations(self):
        rates = self.data['claude']['rate_limits']
        rates['seven_day_opus'] = dict(rates['seven_day'], utilization=20)
        self.save()
        result = self.invoke()
        durations = {w['label']: w.get('durationMins') for w in result['claude']['windows']}
        self.assertEqual(durations, {'five_hour': 300, 'seven_day': 10080,
                                     'seven_day_opus': 10080, 'Fable': 10080})
        self.assertEqual(result['grok']['windows'][0]['durationMins'], 10080)
        for entry in result['synthetic']['windows']:
            self.assertNotIn('durationMins', entry)

    def test_account_change_does_not_reuse_previous_windows(self):
        self.invoke()
        self.data['codex']['accountId'] = 'another-account'
        self.data['codex']['rateLimits']['secondary']['usedPercent'] = 5
        self.save()
        self.write('.codex/auth.json', {'tokens': {'account_id': 'another-account'}})
        result = self.invoke()['codex']
        self.assertEqual(result['windows'][1]['remainingPercent'], 95)
        self.assertEqual(self.calls('codex'), 2)

    def age_cache(self, seconds):
        for path in (self.root / 'cache/agent-usage').glob('*.json'):
            record = json.loads(path.read_text())
            record['result']['fetchedAt'] -= seconds
            if record.get('lastSuccess'):
                record['lastSuccess']['fetchedAt'] -= seconds
            path.write_text(json.dumps(record))

    def test_freshness_expiry_and_last_success_retention(self):
        self.invoke()
        self.age_cache(61)
        self.invoke()
        self.assertEqual(self.calls('codex'), 2)
        self.data['fail'] = True
        self.save()
        self.assertEqual(self.invoke('--refresh')['codex']['status'], 'stale')
        self.age_cache(301)
        self.invoke()
        self.assertEqual(self.calls('codex'), 4)
        self.age_cache(86401)
        self.assertEqual(self.invoke()['codex']['status'], 'unknown')

    def test_killed_fetcher_releases_lock(self):
        self.data['delay'] = 10
        self.save()
        proc = subprocess.Popen([sys.executable, str(SCRIPT), '--json'], env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not (self.root / 'codex-reading').exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.01)
            cache = self.root / 'cache/agent-usage'
            self.assertEqual(list(cache.glob('codex-*.json')), [])
            self.assertFalse((cache / 'codex-current').exists())
            proc.kill()
            proc.wait()
            self.data['delay'] = 0
            self.save()
            self.assertEqual(self.invoke()['codex']['status'], 'ok')
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.communicate(timeout=15)


if __name__ == '__main__':
    unittest.main()
