from .local import Local, MAX_TOKENS, reviewed_module, snapshot

MODEL = 'mlx-community/clef-flash-8bit'
REVISION = '5a195dc147926b63b1d139691ed4480ca9f92c0e'


class MLX(Local):
    model = MODEL

    def _load(self):
        module = reviewed_module(self.loader_path, 'decide_reviewed_clef_mlx')
        return module.load(snapshot(MODEL, REVISION), backend='vlm')

    def _infer(self, record):
        return self._head.systemone(record, max_length=MAX_TOKENS, truncate=False)
