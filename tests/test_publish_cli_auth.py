import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/publish-cli-auth'
loader = importlib.machinery.SourceFileLoader('publisher', str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
publisher = importlib.util.module_from_spec(spec)
loader.exec_module(publisher)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'home'
        self.source = Path(self.tmp.name) / 'secrets'
        self.home.mkdir()
        self.source.mkdir()
        for name in ['github', 'gitlab', 'jpi']:
            (self.source / (name + '_token')).write_text('FAKE_' + name)

    def publish(self):
        publisher.publish(self.source, self.home, 'octocat', 'gitlab-user', 'work-user')

    def test_writable_host_specific_configs_and_repair(self):
        self.publish()
        gh = self.home / '.config/gh/hosts.yml'
        glab = self.home / '.config/glab-cli/config.yml'
        data = json.loads(gh.read_text())['github.com']
        self.assertEqual(data['users']['octocat']['oauth_token'], 'FAKE_github')
        self.assertEqual(gh.stat().st_mode & 0o777, 0o600)
        self.assertFalse(gh.is_symlink())
        hosts = json.loads(glab.read_text())['hosts']
        self.assertEqual(hosts['gitlab.com']['token'], 'FAKE_gitlab')
        self.assertEqual(hosts['git.jpi.app']['token'], 'FAKE_jpi')
        inode = gh.stat().st_ino
        self.publish()
        self.assertEqual(inode, gh.stat().st_ino)
        gh.unlink()
        self.publish()
        self.assertTrue(gh.exists())

    def test_invalid_input_preserves_last_good_files(self):
        self.publish()
        gh = self.home / '.config/gh/hosts.yml'
        before = gh.read_bytes()
        (self.source / 'jpi_token').write_text('bad\nTOKEN')
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual(before, gh.read_bytes())

    def test_symlink_directory_rejected(self):
        outside = Path(self.tmp.name) / 'outside'
        outside.mkdir()
        (self.home / '.config').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
