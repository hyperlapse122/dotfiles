from .core import error
from .local import Local, MAX_TOKENS, NATIVE_MODELS, reviewed_module, snapshot

MODEL = NATIVE_MODELS['linux']['model']
REVISION = NATIVE_MODELS['linux']['revision']


class CUDA(Local):
    model = MODEL

    def _load(self):
        import torch
        from clef_server.backend import detect
        from clef_server.config import Config
        from clef_server.models.base import ModelSpec
        from clef_server.models.clef_release import ClefReleaseAdapter

        device = detect('cuda')
        module = reviewed_module(self.loader_path, 'decide_reviewed_joint_schema_model')
        path = snapshot(MODEL, REVISION)
        cfg = Config(model_path=path, device='cuda', dtype='bfloat16', quant='int8',
                     quant_backend='torchao', offload='cpu', max_tokens=2**31 - 1,
                     max_device_memory_gb=0, preflight=True, mask_free=False, fast_head=False,
                     api_key=None, api_keys_raw=None)
        spec = ModelSpec('clef-flash', 'clef-release', MODEL, REVISION, 19.0)
        adapter = ClefReleaseAdapter.from_module(module, spec, cfg)
        adapter.resolve()
        adapter.load(device, torch.bfloat16)
        return adapter, device.device

    def _infer(self, record):
        import torch
        adapter, device = self._head
        encoded = adapter.encode(record)
        if encoded.length > MAX_TOKENS:
            raise error(413, 'Maximum context length exceeded')
        batch = adapter.to_device(adapter.collate([encoded], None), device)
        with torch.inference_mode():
            logits = adapter.forward(batch)[0]
            answers = {q.question_id: adapter.answer(q, record['questions'][q.question_id], lg)
                       for q, lg in zip(encoded.questions, logits, strict=True)}
        return {'model': self.model, 'answers': answers,
                'usage': {'input_tokens': encoded.length, 'output_tokens': 0}}
