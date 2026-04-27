# MLX Pilot

> **Low-friction MLX VLM server. MLX Pilot puts you in the driver's seat to control your own locals.**

Apple Silicon native, no Electron, no cloud, no API keys. One Swift file (the GUI), one Python file (the router), one config. Cross-conversation memory built in.

The one network call this app makes is to DuckDuckGo's HTML endpoint when you use `/search` — and even that only fetches text the *user* asks for, so your local model can read it.

## What you get

- **A menu-bar GUI** — three-pane chat (conversation list / chat / right-side controls). Streaming, image/PDF/video drop, persistent cross-conversation memory, system prompt per conversation, slash commands, model hot-swap.
- **A router** — single FastAPI process on `:8000` that loads/evicts MLX backends on demand. One model resident at a time. OpenAI-compatible `/v1/chat/completions` endpoint so any OpenAI-style client works.
- **Maintenance** — nightly launchd job at 03:00 local that prunes logs, model caches, expired conversations, and expired memory entries.

Tested daily on a Mac mini M4 Pro with 64 GB RAM, macOS 26.3, with two Qwen 3.6 model variants (35B-A3B-4bit MoE and 27B-8bit dense). Should run on any Apple Silicon Mac with ≥32 GB RAM if you stick to smaller models.

## Why MLX Pilot

- **No cloud, no keys, no telemetry.** Models run on your Mac. The only outbound network call is DuckDuckGo's HTML endpoint when *you* type `/search`.
- **Native, not Electron.** A single SwiftUI binary, ~5 MB, launches in under a second.
- **Hot-swap models on demand.** One model resident at a time, evicted automatically when you ask for another. No "load at startup" RAM tax for models you're not using.
- **Cross-conversation memory.** The model itself decides what's worth remembering after each turn; new chats inherit relevant context automatically. Pinned, TTL'd, prunable, fully visible in the right panel.
- **Drag anything in.** Screenshot, photo, JPG/PNG/HEIC, PDF, MP4, plain-text file, folder of text — drop anywhere on the chat pane.
- **Two files of source.** The whole GUI is one Swift file. The whole router is one Python file. You can read and modify the entire stack in an afternoon.

## Recommended models

The two that this stack is tuned for. Both are MLX conversions of Qwen 3.6 (Apache 2.0 licensed):

| Local key | Source | Footprint | Role |
|---|---|---|---|
| `Qwen3.6-35B-A3B-4bit` | [`mlx-community/Qwen3.6-35B-A3B-4bit`](https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-4bit) (from [`Qwen/Qwen3.6-35B-A3B`](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)) | ~22 GB weights, ~75–80 tok/s on M4 Pro | **Default.** MoE 256/8. Text + image + video + tool-calling. |
| `Qwen3.6-27B-8bit` | [`mlx-community/Qwen3.6-27B-8bit`](https://huggingface.co/mlx-community/Qwen3.6-27B-8bit) (from [`Qwen/Qwen3.6-27B`](https://huggingface.co/Qwen/Qwen3.6-27B)) | ~30 GB weights, ~9–11 tok/s on M4 Pro | Slow deep reasoning. Dense. Thinking-on by default. |

Download with `huggingface-cli`:

```bash
huggingface-cli download mlx-community/Qwen3.6-35B-A3B-4bit \
    --local-dir ~/.mlxlm/models/Qwen3.6-35B-A3B-4bit

huggingface-cli download mlx-community/Qwen3.6-27B-8bit \
    --local-dir ~/.mlxlm/models/Qwen3.6-27B-8bit
```

The directory name under `~/.mlxlm/models/` must match the key in `~/.mlxlm/config.json`.

If you have less than 64 GB RAM, drop one or both of these and use a smaller MLX build instead — anything that runs under `mlx_vlm.server` will work. Update `config.json` to match the directory name.

## Quick start

Prerequisites:
- macOS 13+ on Apple Silicon
- Python 3.11 (`brew install python@3.11`)
- Swift toolchain (`xcode-select --install`)
- `huggingface-cli` (`pip install -U huggingface_hub`)
- ~22+ GB free disk per model

```bash
# 1. Set up the router stack (creates ~/.mlxlm/, installs deps, registers launchd)
bash share/setup.sh

# 2. Download at least one model — see the "Recommended models" table above
#    for the exact mlx-community URLs. Example for the default model:
huggingface-cli download mlx-community/Qwen3.6-35B-A3B-4bit \
    --local-dir ~/.mlxlm/models/Qwen3.6-35B-A3B-4bit

# 3. The default config.example.json already references the two recommended
#    model keys. If you downloaded different models, edit ~/.mlxlm/config.json
#    so the keys under "models" match the directory names under ~/.mlxlm/models/.

# 4. Build the GUI
bash Scripts/build_app.sh
# Drag dist/MLX\ Pilot.app into /Applications/

# 5. Launch — the menu-bar icon appears. Hit ⌘N to start a chat.
```

## Architecture

```
You ──HTTP──┐
            ▼
   router.py :8000  (launchd, KeepAlive)
        │
        └── per-model backend on its own port (8001, 8003, …)
              loaded on demand by mlx_vlm.server / mlx_lm.server
```

Config lives at `~/.mlxlm/config.json` (v6 schema). The router hot-reloads it whenever the file's mtime changes — add a model, save, and it's available next request.

The Swift app is a single source file: `Sources/MLXPilot/main.swift` (~5300 lines). One SwiftPM target, no external dependencies, builds in ~10s incremental / ~45s clean.

## Slash commands inside chat

| Command | What it does |
|---|---|
| `/fetch <url>` | Download a web page, strip HTML, inline as context for the next reply. |
| `/search <query>` | DuckDuckGo top-5 results inlined as context. No API key. |
| `/remember <text>` | Save a persistent memory (flags: `--pin`, `--ttl <days>`, `--title <t>`). |
| `/forget <pattern>` | Delete memories whose title contains `<pattern>`. |
| `/memory` | Preview what memories would inject on the next send. |
| `/help` | List every command + keyboard shortcut. |

## Memory system

The app maintains a persistent memory store at `~/.mlxlm/memory/INDEX.json` that survives across chats. After every assistant reply, an autonomous extractor runs the recent turn back through your loaded model with a strict JSON-array prompt, asking what's worth remembering. New entries get auto-saved. On every send, the most relevant entries (pinned first, then most-recently-used, under a 5K token budget) are prepended to the system prompt. A `🧠 N memories loaded` chip in the chat header shows you what got injected.

To configure: edit the `memory` block in `~/.mlxlm/config.json`. To disable entirely, set `"enabled": false`.

## Layout of this repo

```
mlxpilot/
  Sources/MLXPilot/main.swift     ← the entire GUI app
  Package.swift                   ← SwiftPM manifest
  Scripts/
    build_app.sh                  ← clean rebuild + bundle into dist/MLX Pilot.app
    quick_build.sh                ← incremental rebuild
  share/
    setup.sh                      ← one-shot installer for the router stack
    router/
      router.py                   ← FastAPI router, hot-swaps MLX backends
      maintenance.py              ← nightly pruner
      requirements.txt            ← pinned Python deps (mlx-vlm==0.4.3)
      config.example.json         ← config template (uses __HOME__ marker)
    launchagents/
      com.mlxpilot.router.plist        ← launchd template
      com.mlxpilot.maintenance.plist   ← launchd template
  README.md
  LICENSE
  .gitignore
```

## Important notes

- **mlx-vlm is pinned at 0.4.3.** Version 0.4.4 has a text-only regression on Qwen3-VL. Don't `pip install -U mlx-vlm` without re-testing.
- **Default input cap is 96K tokens** (`MAX_INPUT_TOKENS` in router.py). KV cache at 4-bit + turboquant takes roughly 15–20 GB of wired RAM at this setting. Drop to 60K if your machine has less than 64 GB total or you're running other heavy apps alongside.
- **Models are not included.** You bring your own from huggingface.co/mlx-community or your own MLX conversions. Two model entries in `config.example.json` show the shape; replace with whatever you actually have.
- **No backwards compatibility for the config schema.** v6 adds the `memory` block. If you find an older config online, look at `config.example.json` for the current shape.

## Contributing

This was built for a friend's local LLM workflow on a single machine. It's not designed for multi-user, multi-tenant, or cloud deployment. PRs that improve the local-only path (better drop handling, better SwiftUI ergonomics, more capable router) are welcome. PRs that add cloud integrations will be politely declined.

## License

MIT. See `LICENSE`.
