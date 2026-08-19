# vLLM Jetson services decommission checklist (operator-run, not automated)

> **Label:** vLLM Jetson services decommission checklist. This document is manual
> operator guidance for hosts that previously applied the managed vLLM inference
> services on Jetson AGX Thor. Chezmoi executes none of it: the removal is
> source-only, apply never stops a live service, deletes runtime state or weights,
> and no teardown script exists or may be added.

Apply the updated source first (or remove `.chezmoidata/vllm.yaml` and the unit
sources). Deleting managed sources stops chezmoi from managing their deployed
targets on the next apply, but leaves running services, model weight caches,
virtual environments, and credentials untouched. Work through this checklist by
hand on each previously provisioned Jetson host.

## 1. Stop and disable the user services

Stop and disable the two inference engines and their mDNS companions:

- `systemctl --user stop vllm-chat-mdns.service vllm-embed-mdns.service vllm-chat.service vllm-embed.service`
- `systemctl --user disable vllm-chat-mdns.service vllm-embed-mdns.service vllm-chat.service vllm-embed.service`

## 2. Verify nothing still listens

Confirm no process owns TCP port `8000` (chat inference endpoint) or TCP port
`8001` (embedding inference endpoint):

- `ss -ltnp | grep -E ':(8000|8001)\b'`

If a listener survives, identify and stop it before continuing; never kill a
process you cannot attribute to this stack.

## 3. Remove deployed definitions and auth environment file

Remove the four deployed systemd user unit definitions and the environment file:

- `rm -f ~/.config/systemd/user/vllm-chat.service ~/.config/systemd/user/vllm-embed.service ~/.config/systemd/user/vllm-chat-mdns.service ~/.config/systemd/user/vllm-embed-mdns.service`
- `rm -f ~/.config/vllm/auth.env`
- `rmdir ~/.config/vllm 2>/dev/null || true`
- `systemctl --user daemon-reload`
- `systemctl --user reset-failed`

## 4. Weight cache, virtual environment, and state reclamation (optional, explicit opt-in)

The vLLM runtime and model weight downloads occupy disk space under
`~/.local/share/vllm/`:

- `~/.local/share/vllm/models/` holds the downloaded Hugging Face model weight
  directories (e.g. `qwen3.8-27b-nvfp4@*` and `qwen3-embedding-4b@*`, typically ~45+ GiB).
- `~/.local/share/vllm/venv/` holds the native uv Python 3.12 virtual environment
  with vLLM and FlashInfer wheels.
- `~/.local/share/vllm/.vllm-state/` holds the provisioner convergence stamp.

To reclaim all runtime state and disk space:

- `rm -rf ~/.local/share/vllm`

Retain the model directory if you plan to reuse the downloaded weights with another
inference server or reinstall later.

## 5. What stays — do not remove (harmless host state)

- `video` and `render` supplementary group memberships: the user was added to
  the `video` and `render` groups to allow CUDA and GPU device node access. These
  memberships stay in place and are harmless.
- `loginctl enable-linger`: user manager lingering ensures background user
  services run across logins. Retaining linger is standard and harmless.

## 6. Credential boundary — never delete operator-owned vault items

- The 1Password item `op://Private/vLLM Jetson/API Key` referenced by
  `.chezmoidata/vllm.yaml` stays in 1Password, operator-owned; delete or rotate
  it in 1Password only as a separate explicit action.
- Chezmoi never stored plaintext credentials in tracked source: source carried
  only the `op://` reference above, and the deployed secret lived exclusively in
  mode-0600 `~/.config/vllm/auth.env` (cleared in step 3).
