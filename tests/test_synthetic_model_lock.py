import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from urllib.error import HTTPError


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('synthetic_model_lock', REPO / 'scripts/update-synthetic-model-lock.py')


class SyntheticModelLockTest(unittest.TestCase):
    def setUp(self):
        self.updater = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(self.updater)

    def model(self, name='syn:small:text'):
        return {'id': name, 'display_name': 'Small model', 'context_length': 196608,
                'max_output_length': 32768, 'input_modalities': ['text', 'image'],
                'output_modalities': ['text'], 'supported_features': ['tools', 'reasoning'],
                'pricing': {'prompt': '$0.0000001', 'completion': '$0.0000005',
                            'input_cache_reads': '$0.00000002', 'input_cache_writes': '0'}}

    def test_metadata_is_normalized_for_pi_and_sorted_without_inference(self):
        other = {**self.model('syn:large:vision'), 'input_modalities': ['text'],
                 'supported_features': []}
        result = self.updater.resolve_models({'data': [self.model(), other]})['syntheticModelLocks']
        self.assertEqual(result['baseUrl'], 'https://api.synthetic.new/openai/v1')
        self.assertEqual(result['provider'], 'synthetic')
        self.assertEqual([model['id'] for model in result['models']], ['syn:large:vision', 'syn:small:text'])
        first, second = result['models']
        self.assertEqual(first['input'], ['text'])
        self.assertFalse(first['reasoning'])
        self.assertEqual(second['input'], ['text', 'image'])
        self.assertEqual(second['cost'], {'input': 0.1, 'output': 0.5, 'cacheRead': 0.02, 'cacheWrite': 0.0})
        self.assertEqual(second['contextWindow'], 196608)
        self.assertEqual(second['maxTokens'], 32768)

    def test_invalid_catalogs_fail_before_replacing_existing_lock(self):
        bad_models = [{**self.model(), 'id': ''}, {**self.model(), 'id': 'bad\nmodel'},
                      {**self.model(), 'context_length': True},
                      {**self.model(), 'max_output_length': 999999},
                      {**self.model(), 'pricing': {'prompt': 'NaN'}},
                      {**self.model(), 'pricing': {}},
                      {**self.model(), 'input_modalities': [{}]},
                      {**self.model(), 'input_modalities': ['shell']},
                      {**self.model(), 'supported_features': 'reasoning'}]
        documents = [{'data': []}, {'data': [self.model(), self.model()]}]
        documents += [{'data': [model]} for model in bad_models]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lock.json'
            path.write_text('previous complete lock')
            for document in documents:
                with self.subTest(document=document):
                    with self.assertRaises(self.updater.ModelLockError):
                        self.updater.update_lock(path, document)
                    self.assertEqual(path.read_text(), 'previous complete lock')

    def test_repeat_update_is_unchanged_and_removed_models_are_drained(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lock.json'
            document = {'data': [self.model('syn:z'), self.model('syn:a')]}
            self.assertTrue(self.updater.update_lock(path, document))
            original = path.read_bytes(), path.stat().st_mtime_ns
            self.assertFalse(self.updater.update_lock(path, {'data': list(reversed(document['data']))}))
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), original)
            self.assertTrue(self.updater.update_lock(path, {'data': [self.model('syn:a')]}))
            self.assertEqual(len(json.loads(path.read_text())['syntheticModelLocks']['models']), 1)

    def test_request_uses_fixed_origin_and_private_bearer_transport(self):
        observed = []
        def opener(request, timeout):
            observed.append((request.full_url, request.get_header('Authorization'), timeout))
            return io.BytesIO(json.dumps({'data': [self.model()]}).encode())
        result = self.updater.fetch_models('inert-fixture-secret', opener=opener)
        self.assertEqual(result['data'][0]['id'], 'syn:small:text')
        self.assertEqual(observed, [('https://api.synthetic.new/openai/v1/models',
                                     'Bearer inert-fixture-secret', 30)])
        def denied(request, timeout):
            raise HTTPError(request.full_url, 401, 'private response inert-fixture-secret', {}, None)
        with self.assertRaises(self.updater.ModelLockError) as error:
            self.updater.fetch_models('inert-fixture-secret', opener=denied)
        self.assertNotIn('inert-fixture-secret', str(error.exception))

    def test_redirect_handler_never_forwards_credentials(self):
        handler = self.updater.NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, 'move', {}, 'https://other.invalid'))

    def test_candidate_validation_has_no_credential_or_dynamic_provider_fields(self):
        lock = self.updater.resolve_models({'data': [self.model()]})
        self.updater.validate_lock(lock)
        for key, value in [('baseUrl', 'https://foreign.invalid'), ('provider', 'foreign')]:
            changed = json.loads(json.dumps(lock))
            changed['syntheticModelLocks'][key] = value
            with self.assertRaises(self.updater.ModelLockError):
                self.updater.validate_lock(changed)
        lock['syntheticModelLocks']['models'][0]['apiKey'] = '!not-an-allowed-model-property'
        with self.assertRaises(self.updater.ModelLockError):
            self.updater.validate_lock(lock)

    def test_repository_or_overlaid_candidate_catalog_is_valid_without_credentials(self):
        path = REPO / 'home/.chezmoidata/synthetic-model-lock.json'
        self.updater.validate_lock(json.loads(path.read_text(encoding='utf-8')))


class SyntheticPublicationWorkflowTest(unittest.TestCase):
    def test_catalog_and_application_candidates_share_publication(self):
        refresh = (REPO / '.github/workflows/update-personal-app-lock.yml').read_text()
        self.assertLess(refresh.index('scripts/update-synthetic-model-lock.py'),
                        refresh.index('actions/upload-artifact@'))
        self.assertIn('SYNTHETIC_API_KEY: ${{ secrets.SYNTHETIC_API_KEY }}', refresh)
        staged, publish = refresh.split('  publish:', 1)
        self.assertIn('synthetic-model-lock.json', staged)
        self.assertIn('synthetic-model-lock.json', publish)
        self.assertIn('"$apps" "$models"', publish)
        suite = (REPO / '.github/workflows/test.yml').read_text()
        selection = suite.split('- &select-lock', 1)[1].split('- &download-harness-lock', 1)[0]
        self.assertIn('test -f "$RUNNER_TEMP/locked-apps/synthetic-model-lock.json"', selection)
        self.assertIn('cp -- "$RUNNER_TEMP/locked-apps/synthetic-model-lock.json"', selection)


if __name__ == '__main__':
    unittest.main()
