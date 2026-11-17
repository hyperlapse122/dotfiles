"""Check the installed native interpreter and reviewed loader without weights."""

import importlib.util
import sys


def main():
    backend, loader_path = sys.argv[1:]
    import aiohttp
    import jsonschema

    if backend == "mlx":
        import mlx.core
        import mlx_lm
        import mlx_vlm

        module_name = "clef_mlx"
    elif backend == "cuda":
        import torch
        import torchao.quantization
        import transformers
        import clef_server.engine

        assert torch.cuda._is_compiled(), "The selected Torch build has no CUDA support"
        module_name = "joint_schema_model"
    else:
        raise ValueError("Expected an MLX or CUDA runtime")

    spec = importlib.util.spec_from_file_location(module_name, loader_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    print(f"{backend}: native dependencies and reviewed decision loader imported")


if __name__ == "__main__":
    main()
