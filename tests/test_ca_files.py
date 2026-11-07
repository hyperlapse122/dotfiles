import importlib.util
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import tomllib
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
SPEC = importlib.util.spec_from_file_location('ca_files', REPO / 'scripts/ca-files.py')
OPENSSL = shutil.which('openssl')
if not OPENSSL and os.name == 'nt':
    candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/usr/bin/openssl.exe'
    OPENSSL = str(candidate) if candidate.is_file() else None


@unittest.skipUnless(OPENSSL, 'OpenSSL synthetic certificate fixture required')
class CaFilesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix='ca-files-fixture-')
        cls.root = Path(cls.scratch.name)
        def openssl(*args):
            result = subprocess.run([OPENSSL, *args], capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise RuntimeError('Synthetic certificate fixture failed')
        for name in ('public', 'enterprise', 'unrelated'):
            openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(cls.root/f'{name}.key'),
                    '-out', str(cls.root/f'{name}.pem'), '-days', '2', '-subj', f'/CN={name} fixture CA',
                    '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
        openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(cls.root/'server.key'),
                '-out', str(cls.root/'server.csr'), '-subj', '/CN=localhost')
        (cls.root/'extensions').write_text('basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nauthorityKeyIdentifier=keyid,issuer\n')
        openssl('x509', '-req', '-in', str(cls.root/'server.csr'), '-CA', str(cls.root/'enterprise.pem'),
                '-CAkey', str(cls.root/'enterprise.key'), '-CAcreateserial', '-out', str(cls.root/'server.pem'),
                '-days', '2', '-extfile', str(cls.root/'extensions'))
        cls.public = (cls.root/'public.pem').read_text()
        cls.enterprise = (cls.root/'enterprise.pem').read_text()
        cls.leaf = (cls.root/'server.pem').read_text()

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def setUp(self):
        self.module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(self.module)
        scratch = tempfile.TemporaryDirectory(prefix='ca-files-home-')
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)

    def inventory(self, pem=None):
        return {'certificates': {'enterprise': self.enterprise if pem is None else pem}}

    def test_public_roots_preserved_and_managed_ca_deduplicated(self):
        inventory = {'certificates': {'one': self.enterprise, 'same': self.enterprise, 'public-copy': self.public}}
        self.module.install_bundle(inventory, self.home, self.public)
        bundle = self.home/'.local/share/dotfiles/ca/bundle.pem'
        data = bundle.read_text()
        self.assertTrue(data.startswith(self.public))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(cadata=data)
        self.assertEqual(len(context.get_ca_certs()), 2)
        before = bundle.stat().st_mtime_ns
        self.module.install_bundle(inventory, self.home, self.public)
        self.assertEqual(bundle.stat().st_mtime_ns, before)
        unrelated = bundle.parent/'unrelated'
        unrelated.write_text('preserve')
        self.module.install_bundle({'certificates': {}}, self.home, self.public)
        self.assertEqual(bundle.read_text(), self.public)
        self.assertEqual(unrelated.read_text(), 'preserve')

    def test_invalid_leaf_private_key_or_partial_pem_preserves_prior_bundle(self):
        self.module.install_bundle(self.inventory(), self.home, self.public)
        bundle = self.home/'.local/share/dotfiles/ca/bundle.pem'
        before = bundle.read_bytes()
        for invalid in (self.leaf, (self.root/'enterprise.key').read_text(), self.enterprise+'garbage', 'not a certificate'):
            with self.subTest(kind=invalid[:20]):
                with self.assertRaises(self.module.common.AuthError):
                    self.module.install_bundle(self.inventory(invalid), self.home, self.public)
                self.assertEqual(bundle.read_bytes(), before)

    def test_apply_preserves_public_bundle_utf8_comments(self):
        source = self.home/'source'
        (source/'home/.secrets').mkdir(parents=True)
        (source/'.chezmoiroot').write_text('home\n')
        (source/'home/.secrets/ca-certificates.json.asc').write_text('inert ciphertext')
        public = '# Public CA: TÜRKTRUST\n' + self.public
        public_path = self.home/self.module.PUBLIC_ROOTS
        public_path.parent.mkdir(parents=True)
        public_path.write_text(public, encoding='utf-8')
        with mock.patch.object(self.module, 'read_inventory', return_value=self.inventory()):
            self.module.apply(source, None, self.home, platform='linux')
        bundle = (self.home/self.module.BUNDLE).read_bytes()
        self.assertTrue(bundle.startswith(public.encode('utf-8')))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(cadata='\n'.join(self.module.CERTIFICATE.findall(bundle.decode('utf-8'))))
        self.assertEqual(len(context.get_ca_certs()), 2)

    def test_private_ca_tls_succeeds_only_with_combined_bundle(self):
        self.module.install_bundle(self.inventory(), self.home, self.public)
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                body = b'fixture-ok'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.root/'server.pem', self.root/'server.key')
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        import urllib.request
        url = f'https://localhost:{server.server_port}/'
        public_only = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        public_only.load_verify_locations(cadata=self.public)
        with self.assertRaises(Exception):
            urllib.request.urlopen(url, context=public_only, timeout=5)
        combined = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        combined.load_verify_locations(cafile=str(self.home/'.local/share/dotfiles/ca/bundle.pem'))
        with urllib.request.urlopen(url, context=combined, timeout=5) as response:
            self.assertEqual(response.read(), b'fixture-ok')
        # Native Windows Schannel is outside the supported file-based fallback.
        if os.name != 'nt' and shutil.which('curl'):
            with mock.patch.dict(os.environ, {'NO_PROXY': 'localhost,127.0.0.1',
                                              'HOME': str(self.home), 'CURL_HOME': str(self.home),
                                              'CURL_CA_BUNDLE': str(self.home/'missing-inherited-bundle')}):
                before = dict(os.environ)
                result = self.module.execute('curl', ['--silent', '--show-error', url], self.home,
                                             platform='linux', capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'fixture-ok')
                self.assertEqual(dict(os.environ), before)

    def test_requests_child_environment_is_scoped_and_missing_bundle_fails(self):
        self.module.install_bundle(self.inventory(), self.home, self.public)
        expected = str(self.home/'.local/share/dotfiles/ca/bundle.pem')
        command = [sys.executable, '-c', 'import os; print(os.environ["REQUESTS_CA_BUNDLE"])']
        before = dict(os.environ)
        result = self.module.execute('requests', command, self.home, platform='linux', capture_output=True)
        self.assertEqual(result.stdout.strip(), expected)
        self.assertEqual(dict(os.environ), before)
        with self.assertRaises(self.module.common.AuthError):
            self.module.execute('requests', command, self.home/'missing', platform='linux')
        with self.assertRaises(self.module.common.AuthError):
            self.module.execute('requests', command, self.home, platform='windows')

    def test_optional_absence_does_not_decrypt_and_failure_preserves_bundle(self):
        source = self.home/'source'
        (source/'home/.secrets').mkdir(parents=True)
        (source/'.chezmoiroot').write_text('home\n')
        with mock.patch.object(self.module.common, 'require_encryption_policy', side_effect=AssertionError('unexpected decrypt')):
            self.module.apply(source, None, self.home/'destination', platform='linux')
        self.assertFalse((self.home/'destination').exists())
        self.module.install_bundle(self.inventory(), self.home, self.public)
        bundle = self.home/'.local/share/dotfiles/ca/bundle.pem'
        before = bundle.read_bytes()
        (source/'home/.secrets/ca-certificates.json.asc').write_text('inert ciphertext')
        with mock.patch.object(self.module.common, 'require_encryption_policy', side_effect=self.module.common.AuthError('Fixture decrypt failure')):
            with self.assertRaises(self.module.common.AuthError):
                self.module.apply(source, None, self.home, platform='linux')
        self.assertEqual(bundle.read_bytes(), before)

    def test_real_encrypted_enrollment_rotation_and_failed_publication_rollback(self):
        gpg = shutil.which('gpg')
        if os.name == 'nt':
            native = Path(os.environ.get('ProgramFiles', 'C:/Program Files'))/'GnuPG/bin/gpg.exe'
            if native.is_file():
                gpg = str(native)
        if not gpg:
            self.skipTest('GPG required for isolated encryption fixture')
        keyring = self.home/'keyring'
        keyring.mkdir(mode=0o700)
        arguments = ['--homedir', str(keyring), '--no-options', '--batch']
        def command(*extra):
            result = subprocess.run([gpg, *arguments, *extra], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, 'Isolated CA GPG fixture failed')
            return result.stdout
        gpgconf = Path(gpg).with_name('gpgconf.exe' if os.name == 'nt' else 'gpgconf')
        if gpgconf.is_file():
            self.addCleanup(lambda: subprocess.run([str(gpgconf), '--homedir', str(keyring), '--kill', 'all'],
                                                   capture_output=True, timeout=30))
        command('--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key',
                'CA fixture <ca@example.invalid>', 'rsa2048', 'encr', '1d')
        recipient = next(line.split(':')[9] for line in command('--with-colons', '--list-keys').splitlines()
                         if line.startswith('fpr:'))
        policy = {'command': gpg, 'args': arguments, 'recipient': recipient}
        source = self.home/'source'
        (source/'home/.secrets').mkdir(parents=True)
        (source/'.chezmoiroot').write_text('home\n')
        target = source/'home/.secrets/ca-certificates.json.asc'
        with mock.patch.object(self.module.common, 'require_encryption_policy', return_value=policy):
            self.module.enroll(source, None, 'enterprise', self.enterprise)
            original = target.read_bytes()
            self.assertTrue(original.startswith(b'-----BEGIN PGP MESSAGE-----'))
            self.assertNotIn(b'BEGIN CERTIFICATE', original)
            self.assertEqual(self.module.read_inventory(source, None), self.inventory())
            reader = self.module.read_inventory
            with mock.patch.object(self.module, 'read_inventory', side_effect=self.module.common.AuthError('Fixture readback failure')):
                with self.assertRaises(self.module.common.AuthError):
                    self.module.publish_inventory(source, None, {'certificates': {'replacement': self.public}})
            self.assertEqual(target.read_bytes(), original)
            self.module.enroll(source, None, 'enterprise', self.public)
            self.assertEqual(reader(source, None), {'certificates': {'enterprise': self.public}})
            self.module.remove(source, None, 'enterprise')
            self.assertEqual(reader(source, None), {'certificates': {}})


class CaTemplateTest(unittest.TestCase):
    @unittest.skipUnless(os.name != 'nt' and shutil.which('chezmoi') and shutil.which('mise'),
                         'Native Unix wrapper, chezmoi and mise required')
    def test_rendered_wrapper_preserves_project_directory_and_interpreter(self):
        import json
        import shlex
        with tempfile.TemporaryDirectory(prefix="ca-wrapper ' ") as temporary:
            root = Path(temporary)
            project, tools, home = (root / name for name in ('project', 'tools', 'home'))
            for directory in (project, tools, home):
                directory.mkdir()
            project_link = root / 'project-link'
            project_link.symlink_to(project, target_is_directory=True)
            project = project_link
            bundle = home / '.local/share/dotfiles/ca/bundle.pem'
            bundle.parent.mkdir(parents=True)
            bundle.write_text('inert bundle; this fixture launches no TLS request\n')
            interpreter = tools / 'python'
            interpreter.write_text('#!/bin/sh\nexport PROJECT_INTERPRETER=selected\nexec '
                                   + shlex.quote(sys.executable) + ' "$@"\n')
            interpreter.chmod(0o755)
            (project / 'client.py').write_text('import json,os,pathlib\n'
                'pathlib.Path("relative-output.json").write_text(json.dumps({"cwd":os.getcwd(),'
                '"interpreter":os.environ.get("PROJECT_INTERPRETER"),"path":os.environ["PATH"]}))\n')
            config = root / 'chezmoi.toml'
            config.write_text('workingTree = ' + json.dumps(str(REPO)) + '\n')
            rendered = subprocess.run(['chezmoi', '--source', str(REPO), '--destination', str(home),
                '--config', str(config), 'execute-template'],
                input=(REPO / 'home/dot_local/bin/executable_dotfiles-ca.tmpl').read_text(),
                capture_output=True, text=True, timeout=30)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            wrapper = root / 'dotfiles-ca'
            wrapper.write_text(rendered.stdout)
            environment = {**os.environ, 'PATH': str(tools) + os.pathsep + os.environ['PATH']}
            result = subprocess.run(['/bin/sh', str(wrapper), 'requests', '--', 'python', 'client.py'],
                                    cwd=project, env=environment, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            observed = json.loads((project / 'relative-output.json').read_text())
            self.assertEqual(observed, {'cwd': str(project.resolve()), 'interpreter': 'selected', 'path': environment['PATH']})

    @unittest.skipUnless(shutil.which('chezmoi'), 'chezmoi required')
    def test_public_roots_and_apply_hook_are_optional_and_platform_scoped(self):
        with tempfile.TemporaryDirectory(prefix='ca-render-') as temporary:
            root = Path(temporary)
            source = root/'source'
            (source/'.chezmoidata').mkdir(parents=True)
            (source/'.chezmoitemplates').mkdir()
            (source/'.secrets').mkdir()
            shutil.copy2(REPO/'home/.chezmoidata/ca-files.json', source/'.chezmoidata/ca-files.json')
            for name, path in (('external', 'home/.chezmoitemplates/external-assets/ca-files.toml.tmpl'),
                               ('hook', 'home/.chezmoiscripts/run_after_35-ca-files.sh.tmpl')):
                shutil.copy2(REPO/path, source/'.chezmoitemplates'/name)
            config = root/'chezmoi.toml'
            config.write_text('')
            def render(name, platform):
                template = '{{ $ctx := . | setValueAtPath "chezmoi.os" "'+platform+'" }}{{ includeTemplate "'+name+'" $ctx }}'
                result = subprocess.run([shutil.which('chezmoi'), '--config', str(config), '--source', str(source),
                    '--destination', str(root/'home'), 'execute-template', template],
                    capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()
            self.assertEqual(render('external', 'linux'), '')
            self.assertEqual(render('hook', 'darwin'), '')
            (source/'.secrets/ca-certificates.json.asc').write_text('must not decrypt during rendering')
            pin = json.loads((REPO/'home/.chezmoidata/ca-files.json').read_text())['caFilesPublicRoots']
            for platform in ('linux', 'darwin'):
                asset = tomllib.loads(render('external', platform))['.local/share/dotfiles/ca/public-roots.pem']
                self.assertEqual(asset['type'], 'file')
                self.assertEqual(asset['url'], 'https://curl.se/ca/cacert.pem#sha256=' + pin['sha256'])
                self.assertEqual(asset['checksum']['sha256'], pin['sha256'])
                self.assertNotIn('format', asset)
                self.assertNotIn('path', asset)
            self.assertIn('ca-files.py', render('hook', 'linux'))
            self.assertEqual(render('external', 'windows'), '')
            self.assertEqual(render('hook', 'windows'), '')


if __name__ == '__main__':
    unittest.main()
