# Decisions with decide

`decide judge` submits typed questions to a private user service. The service uses the official [Decisions operation](https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-request) through an MLX, CUDA or OpenRouter backend. The CLI serves people; programmatic clients send HTTP over the Unix socket.

## Submit a judgment

Save a request as `request.json`:

```json
{
  "state": "The service is accepting requests.",
  "questions": {
    "available": {
      "type": "noul",
      "instructions": "Is the service available?"
    },
    "status": {
      "type": "choice",
      "criteria": {"up": "Accepting requests", "down": "Unavailable"}
    },
    "urgency": {
      "type": "score",
      "criteria": ["No action", "Investigate", "Act now"]
    }
  }
}
```

```sh
decide judge request.json
decide judge --json request.json
cat request.json | decide judge -
```

The CLI fills in the configured model when the document omits it. `--model` overrides the document's model. A `noul` answer is a numeric probability; a score uses the ordered levels in its criteria. `--json` prints the complete response, including optional fields. API errors go to stderr, with their full JSON body when `--json` is set; failures have a nonzero exit status.

The managed user environment installs and starts the service. To try the package before applying a host configuration, run `nix run .#decide -- serve` in a separate terminal. `decide serve` runs in the foreground and refuses to replace an existing live service.

## Inspect a model

```sh
decide info
decide info --json
decide info --model typesafe/jev-1.14
```

`info` shows the backend and model that `judge` would use for a request without a model field. It accepts the same `--config`, `--socket`, `--timeout` and `--model` flags. `--json` reports the same facts as the plain-text output. Each decision type has a `supported`, `unsupported` or `unknown` value.

For MLX and CUDA, the report includes the bundled model and its pinned revision. A running service can report whether it has finished loading the model. If the socket cannot provide status, `info` shows the package's model information with an unknown load state. When the selected model differs from the bundled model, the local backend cannot serve that selection.

For OpenRouter, `info` looks up the selected model in the live [Decisions model catalog](https://openrouter.ai/docs/guides/overview/models#endpoints). If a model is missing from the response or the lookup fails, the report marks its decision types unknown. The catalog confirms API routing and does not list question types. The command uses the [documented adapter capabilities](https://openrouter.ai/docs/guides/community/multimodal-decisions#what-each-endpoint-accepts) for types it can confirm. `info` does not submit a judgment or load model weights, and it can return partial information with a successful exit status.

## Backends and models

| Environment | Backend | Initial model |
| --- | --- | --- |
| Apple silicon macOS | MLX with Metal | `mlx-community/clef-flash-8bit` |
| NixOS with `my.cuda.enable` | CUDA, INT8 weight-only quantization and CPU offload | `Cloudflare/clef-flash` |
| Other supported environments | OpenRouter | `typesafe/jev-1.14` |

The CUDA trait defaults from the NixOS NVIDIA driver declaration. Backend selection belongs to the package and host configuration. Selecting another model does not change the backend. The local adapters serve only their packaged model; an unsupported model or feature returns a capability error. There is no automatic model substitution or local-to-remote fallback.

Local Clef supports `noul`, `choice` and `score`, with text and static images placed directly in the top-level state array. Image asset references can appear as whole state items. Images retain their order and numbered associations. Nested image positions, animated images, video, audio, files, `box` questions and provider preferences are unsupported on the current local adapter. Unsupported requests fail before model loading.

OpenRouter receives the complete request, including structured instructions and criteria, assets, provider preferences and metadata. Its selected model and endpoint determine the available primitives and media forms. [Jev 1.14](https://openrouter.ai/typesafe/jev-1.14) accepts text and images and supports `box`. [Gemini Decision 1](https://openrouter.ai/google/gemini-decision-1) accepts audio, video and supported documents as well as images. See the [multimodal Decisions guide](https://openrouter.ai/docs/guides/community/multimodal-decisions) for each endpoint's forms and limits.

The local code and dependencies are fixed Nix sources. Weights load lazily from the user's Hugging Face cache at these immutable revisions:

- MLX: `5a195dc147926b63b1d139691ed4480ca9f92c0e`.
- CUDA: `22b75507981345858dd152fbd9a6f8c0c4068b0a`.

The first supported local request may download weights and take longer. Use `decide judge --timeout 1800 request.json` when allowing time for that first load. Login does not download or load the model. The reviewed Nix package supplies model Python code. Requests that exceed the native context limit return an error without truncating their state.

## Configure the client and service

Optional settings live in `$XDG_CONFIG_HOME/decide/config.toml`, or `~/.config/decide/config.toml` when that variable is unset:

For an OpenRouter package:

```toml
model = "typesafe/jev-1.14"
timeout = 120
openrouter_key_file = "/path/to/openrouter_api_key"
# socket = "/private/user/directory/decide.sock"
```

Use a model supported by the active backend. The key setting names a file containing the key; it does not contain the key itself. Managed hosts reuse `/run/secrets/cli-auth/openrouter_api_key` on NixOS and `~/.local/state/cli-auth/openrouter_api_key` on macOS. Local inference needs no OpenRouter key. The remote adapter reads the file for each request, so key rotation does not require restarting the service.

`DECIDE_MODEL`, `DECIDE_SOCKET` and `DECIDE_TIMEOUT` override the corresponding TOML settings. Command flags override those values for that process. `--config` selects another TOML file. Restart the supervised service after changing its settings; client-only flags do not reconfigure the running service. Explicit inherited CA bundle variables remain in effect.

On NixOS, use `systemctl --user restart decide.service` to restart the service and `journalctl --user -u decide.service` to read its log. On macOS, use `launchctl kickstart -k "gui/$(id -u)/org.nix-community.home.decide"` to restart it.

## Use IPC

Both interfaces use `POST /api/alpha/decisions`. IPC requires the full official body, including `model`; the CLI's default-model convenience does not change that contract. The server validates requests and results against the OpenAPI snapshot dated 2026-11-18, preserves remote errors and per-question refusals, and does not invent absent optional metadata.

The default socket is `$XDG_RUNTIME_DIR/decide/decide.sock` when `XDG_RUNTIME_DIR` is set, otherwise `$XDG_CACHE_HOME/decide/decide.sock` or `~/.cache/decide/decide.sock`. Its directory must be owned by the user and private. Clients can discover this path directly; they do not invoke the CLI.

With a full request document and the socket path from the same configuration:

```sh
curl --unix-socket /private/user/directory/decide.sock \
  --header 'Content-Type: application/json' \
  --data-binary @request-with-model.json \
  http://localhost/api/alpha/decisions
```

The documented `HTTP-Referer`, `X-OpenRouter-Title`, `X-OpenRouter-Categories` and `x-session-id` headers pass through IPC to OpenRouter. CLI users can repeat `--header 'NAME: VALUE'` on `decide judge`. Native backends accept this attribution metadata without using it for inference.

Inference is serialized in the service. Queued requests whose connections have closed are dropped before execution. Once execution starts, a client disconnect or timeout does not establish that inference, a model download or remote billing stopped. Requests are not automatically retried. Remote image downloads on native backends have a 30-second total deadline and stream into temporary storage.

## Evidence and follow-up

The initial M5 Pro run used 64 GiB of unified memory and the real MLX decision head. A Korean text example returned `rain=0.9767` and selected Seoul; a red image returned `red=0.985` and selected red. The text request took 13.277 seconds including model loading, and the image request took 1.395 seconds. Observed MLX peak memory was 11,072,467,604 bytes, about 10.31 GiB. These examples demonstrate that path, not general Korean accuracy, calibration or performance.

Native CUDA build and target GPU results are reported separately from deterministic adapter tests. The initial Mac evidence does not establish RTX 3060 memory fit or image inference. Hardware evidence and the current-head repository checks belong in the pull request's validation record.

The full operation remains available through `judge`. Focused primitive entry points are tracked in [#219](https://github.com/hyperlapse122/dotfiles/issues/219). Harness plugins and execution policies such as task delegation, worker model/effort choice and task splitting are separate consumers; [#217](https://github.com/hyperlapse122/dotfiles/issues/217) tracks one proposed router.
