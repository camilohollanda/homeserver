# Native Ollama

Reproducible native inference service for the existing RTX 3090 machine at
`camilo@192.168.0.107`. This is separate from the Docker-based AI VM configured
by `bootstrap/ai/`.

The scripts install official Linux x86_64 binaries into `/opt/ollama-native`,
create `ollama.service`, and store models on the mounted data disk. They do not
install GPU drivers, configure Docker, modify LM Studio, create DNS records or
provision VMs.

## Preview and install

Run on your development machine from the repository root:

```bash
# Offline: validate inputs and show the configuration. Does not use SSH.
./external/cawser/ollama/setup.sh --dry-run

# Apply explicitly when ready: installs, starts the service, downloads the
# model and performs a one-token GPU check.
./external/cawser/ollama/setup.sh
```

The default target is `camilo@192.168.0.107`. Override with `OLLAMA_SSH`.
The local machine needs Bash and SSH; the target needs passwordless sudo,
Debian/Ubuntu with systemd, Linux x86_64, a working NVIDIA driver, and `/dados`
already mounted. SSH host-key verification follows your SSH configuration.

For direct execution on the host, run `sudo bash install.sh`. Alternatively,
`REMOTE_HOST=camilo@192.168.0.107 bash install.sh` forwards the settings over SSH
using the repository's quoted-environment convention.

## Defaults

| Setting | Default |
| --- | --- |
| `OLLAMA_VERSION` | `0.34.0`, with a pinned official archive SHA256 |
| `OLLAMA_MODEL` | `qwen3-coder:30b`, with a pinned manifest SHA256 |
| `OLLAMA_DATA_MOUNT` | `/dados` — must be a mount point |
| `OLLAMA_MODELS` | `/dados/ollama/models` |
| `OLLAMA_PORT` | `11434` — binds only to `127.0.0.1` |
| `OLLAMA_CONTEXT_LENGTH` | `16384` |
| `OLLAMA_NUM_PARALLEL` | `1`; other values are rejected for this shared GPU |
| `OLLAMA_VERIFY_GPU` | `1`; use `0` to skip inference during installation |

The service also sets one loaded model, a queue of 16 requests, a five-minute
keep-alive, Flash Attention, `q8_0` KV cache and `OLLAMA_NO_CLOUD=1`.
It runs as the dedicated `ollama` user, with state in `/var/lib/ollama`.
Configuration is managed in `/etc/ollama-native.env` and the systemd unit.

The default model file is approximately 19 GB. Context and runtime allocations
require additional VRAM. The GPU smoke check loads the model and fails if
Ollama reports CPU offload. That failure leaves the service and downloaded model
in place for diagnosis; it does not alter drivers or switch models automatically.

The scripts reject an unrelated existing Ollama unit or port listener. They also
reject symlinked data paths and nonempty model directories without the
`.ollama-native-managed` marker. Do not add that marker to adopt another app's
directory blindly: inspect and migrate existing data deliberately.

## Re-runs and upgrades

A re-run reuses the downloaded Ollama release and matching model, preserves model
data, and restarts the service only if its managed binary/configuration changes.
With the default GPU check enabled, a re-run still performs the one-token check.
Old release directories remain available for explicit rollback. No model is
deleted automatically.

Changing `OLLAMA_VERSION` requires `OLLAMA_ARCHIVE_SHA256`. Changing
`OLLAMA_MODEL` requires `OLLAMA_MODEL_SHA256` (64 lowercase hex digits, without
`sha256:`). A changed upstream model tag causes a digest mismatch and a failure;
the installer never silently accepts different weights.

Review the official release and its asset digest before updating the pin:

```bash
gh api repos/ollama/ollama/releases/tags/v0.34.0 \
  --jq '.assets[] | select(.name == "ollama-linux-amd64.tar.zst") | {name, digest}'

# SHA256 of the exact registry manifest bytes (do not parse/reformat the JSON).
curl -fsS https://registry.ollama.ai/v2/library/qwen3-coder/manifests/30b \
  | shasum -a 256
```

OS packages come from the host's configured apt repositories; this reproduces
the service and pinned application/model versions, not an entire OS image.

## Operations

On the host:

```bash
systemctl status ollama
journalctl -u ollama -f
curl -fsS http://127.0.0.1:11434/api/version
curl -fsS http://127.0.0.1:11434/api/tags
curl -fsS http://127.0.0.1:11434/api/ps
nvidia-smi
```

The executable is `/opt/ollama-native/current/bin/ollama`; the installer does not
replace a binary in the host's PATH. The API is intentionally local and needs no
DNS/TLS configuration for a runner on the same machine. Runners on the homeserver
VM cannot use it until a separate private connectivity design is implemented.

Next: [dedicated review runner](../code-review-runner/README.md).

## Offline verification

The tests require Bash, `jq`, and GNU `realpath` (`grealpath` from GNU coreutils
is also detected on macOS), in addition to Python 3 and ShellCheck.

```bash
python3 -B external/cawser/ollama/install_test.py
shellcheck external/cawser/ollama/{install,setup}.sh
bash -n external/cawser/ollama/install.sh
bash -n external/cawser/ollama/setup.sh
```

These checks do not deploy the service or measure inference performance.

References: [Ollama Linux installation](https://docs.ollama.com/linux),
[runtime configuration](https://docs.ollama.com/faq),
[Qwen3-Coder model](https://ollama.com/library/qwen3-coder:30b).
