from .local import Local, MAX_TOKENS, NATIVE_MODELS, reviewed_module, snapshot

MODEL = NATIVE_MODELS['darwin']['model']
REVISION = NATIVE_MODELS['darwin']['revision']


class MLX(Local):
    model = MODEL

    def _load(self):
        module = reviewed_module(self.loader_path, 'decide_reviewed_clef_mlx')
        return module.load(snapshot(MODEL, REVISION), backend='vlm')

    def _infer(self, record):
        return self._head.systemone(record, max_length=MAX_TOKENS, truncate=False)
