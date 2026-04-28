#!/usr/bin/env python3
"""
MLX Pilot Router — single-endpoint proxy in front of the per-model mlx servers.

Listens on 0.0.0.0:8000 and forwards OpenAI-format /v1/chat/completions requests
to the correct backend port based on the "model" field.

Clients can use friendly aliases ("coder", "vision", "chat") instead of full
model names or port numbers. If a model has `default_system_prompt` in config
and the client didn't send a system message, the router prepends one.
"""

import asyncio
import json
import os
import subprocess
import sys
import time
from collections import OrderedDict
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
import httpx
import uvicorn

CONFIG_PATH = Path.home() / ".mlxlm" / "config.json"
LOGS_DIR = Path.home() / ".mlxlm" / "logs"
VENV_PY = Path.home() / ".mlxlm" / "venv" / "bin" / "python"

# Maximum number of router-owned models held resident at once.
# Two-resident mode (2026-04-26): 35B on :8001 and 27B on :8003 stay up
# simultaneously. The router never SIGTERMs another backend during routing.
# It only lazy-launches a model whose configured port isn't already listening.
MAX_ROUTER_MODELS = 2

# Maximum input tokens the router forwards to backends. Enforced by the
# trimmer in chat_completions and exposed on /health so clients (MLX Pilot
# GUI, agents) display the real cap instead of a stale hardcoded value.
MAX_INPUT_TOKENS = 96000

# Friendly aliases → model keys in config.json.
# Daily driver: Qwen3.6-35B-A3B-4bit (chat/default/coder/vision/qwen35/thinker).
# Deep coder/thinker: Qwen3.6-27B-8bit (deep/qwen27/thinker27).
ALIASES = {
    "chat":       "Qwen3.6-35B-A3B-4bit",
    "default":    "Qwen3.6-35B-A3B-4bit",
    "qwen35":     "Qwen3.6-35B-A3B-4bit",
    "thinker":    "Qwen3.6-35B-A3B-4bit",
    "coder":      "Qwen3.6-35B-A3B-4bit",
    "code":       "Qwen3.6-35B-A3B-4bit",
    "vision":     "Qwen3.6-35B-A3B-4bit",
    "vl":         "Qwen3.6-35B-A3B-4bit",
    "deep":       "Qwen3.6-27B-8bit",
    "thinker27":  "Qwen3.6-27B-8bit",
    "qwen27":     "Qwen3.6-27B-8bit",
}

# Per-alias overrides injected into the outgoing payload BEFORE forwarding.
# qwen35  → fast, thinking off.
# thinker → slow, deep reasoning (thinking on).
ALIAS_OVERRIDES = {
    "qwen35":     {"chat_template_kwargs": {"enable_thinking": False}},
    "thinker":    {"chat_template_kwargs": {"enable_thinking": True}},
    "deep":       {"chat_template_kwargs": {"enable_thinking": True}},
    "thinker27":  {"chat_template_kwargs": {"enable_thinking": True}},
}

# Tool calls are handled natively by mlx_vlm.server (and mlx_lm.server) via
# their built-in tool parser dispatched off the chat template. Qwen3.6
# responses already arrive with shaped message.tool_calls[] in both streaming
# and non-streaming modes, so the router does not translate them.


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


CONFIG = load_config()
MODELS_DIR = CONFIG["control"]["models_dir"]
try:
    _CONFIG_MTIME = CONFIG_PATH.stat().st_mtime
except Exception:
    _CONFIG_MTIME = 0.0
_CONFIG_RELOAD_LOCK = asyncio.Lock()


async def _maybe_reload_config() -> None:
    """Re-read config.json if its mtime changed since last load. Called
    from chat_completions and the watchdog loop so the router picks up
    model/alias/port edits without needing a restart. Aliases defined in
    this file (ALIASES dict) are NOT affected — those live in code."""
    global CONFIG, MODELS_DIR, _CONFIG_MTIME
    try:
        mtime = CONFIG_PATH.stat().st_mtime
    except Exception:
        return
    if mtime == _CONFIG_MTIME:
        return
    async with _CONFIG_RELOAD_LOCK:
        if mtime == _CONFIG_MTIME:
            return
        try:
            new_cfg = load_config()
            CONFIG = new_cfg
            MODELS_DIR = CONFIG["control"]["models_dir"]
            _CONFIG_MTIME = mtime
            print(f"[router] config.json hot-reloaded", flush=True)
        except Exception as e:
            print(f"[router] config reload failed: {e}", flush=True)


def resolve_model(requested: str):
    """Resolve an alias, short name, or full path to (name, port, default_sysprompt).

    Accepts any of:
      - bare alias          e.g. "chat", "deep"
      - provider/alias      e.g. "mlx-pilot/chat", "omlx/chat", "openai/chat"
      - bare full name      e.g. "Qwen3.6-35B-A3B-4bit"
      - provider/full name  e.g. "mlx-pilot/Qwen3.6-35B-A3B-4bit"
      - on-disk path tail   e.g. ".../.mlxlm/models/Qwen3.6-35B-A3B-4bit"

    Strips any provider prefix before lookup so the ALIASES table is the
    single resolution path for short names.
    """
    if not requested:
        requested = "default"
    key = requested.strip()

    # Strip any provider prefix (everything before the last slash) so the
    # rest of the resolver sees a clean name. Applies to both aliases and
    # full names.
    if "/" in key:
        key = key.rsplit("/", 1)[-1]

    lower = key.lower()

    if lower in ALIASES:
        name = ALIASES[lower]
    else:
        name = key

    if name not in CONFIG["models"]:
        raise HTTPException(404, f"model not found: {requested!r}")
    m = CONFIG["models"][name]
    port = m.get("port")
    if not port:
        raise HTTPException(500, f"model {name!r} has no port configured")
    return name, port, m.get("default_system_prompt")


# ---- Lifecycle management (auto-swap, one-model-at-a-time) --------------
#
# Policy: when a request arrives for a model that isn't currently listening
# on its port, kill anything else on any model port and launch the requested
# model. This guarantees we never hold two big models in memory at once.
#
# Consequence: switching models costs a 10-30s load, but the machine never
# slams the RAM wall. If you want two models hot at once, start them
# manually via MLX Pilot and keep hitting the same one — the router won't
# touch what's already up *as long as the port you ask for is already live*.

_LOAD_LOCK = asyncio.Lock()

# Active-forward refcount per model. A request increments this before
# sending bytes to the backend and decrements after the full response
# (non-stream) or the stream closes. ensure_loaded's eviction phase waits
# until each target model's refcount hits zero before killing it — that
# prevents the race where request A loads model A, releases _LOAD_LOCK,
# starts forwarding, and request B for a different model immediately
# evicts model A mid-forward (which was the 503 / RemoteProtocolError
# storm the VM agents were hitting on streaming calls).
_ACTIVE_FORWARDS: dict[str, int] = {}
_FORWARD_COND = asyncio.Condition()


async def _begin_forward(name: str):
    async with _FORWARD_COND:
        _ACTIVE_FORWARDS[name] = _ACTIVE_FORWARDS.get(name, 0) + 1


async def _end_forward(name: str):
    async with _FORWARD_COND:
        if _ACTIVE_FORWARDS.get(name, 0) > 0:
            _ACTIVE_FORWARDS[name] -= 1
        if _ACTIVE_FORWARDS.get(name, 0) == 0:
            _FORWARD_COND.notify_all()


async def _wait_until_idle(name: str, timeout: float = 30.0):
    """Wait (up to `timeout` seconds) until no in-flight forwards remain
    for `name`. Returns True on idle, False on timeout."""
    deadline = asyncio.get_event_loop().time() + timeout
    async with _FORWARD_COND:
        while _ACTIVE_FORWARDS.get(name, 0) > 0:
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                return False
            try:
                await asyncio.wait_for(_FORWARD_COND.wait(), timeout=remaining)
            except asyncio.TimeoutError:
                return False
    return True


def _launch_args(model_name: str):
    m = CONFIG["models"][model_name]
    engine = m.get("engine", "mlx_vlm")
    port = m["port"]
    path = f"{MODELS_DIR}/{model_name}"
    if engine == "mlx_vlm":
        args = [str(VENV_PY), "-m", "mlx_vlm.server",
                "--model", path, "--host", "0.0.0.0", "--port", str(port),
                "--kv-bits", "4", "--kv-quant-scheme", "turboquant"]
    elif engine == "mlx_lm":
        rd = m.get("request_defaults", {})
        args = [str(VENV_PY), "-m", "mlx_lm.server",
                "--model", path, "--host", "0.0.0.0", "--port", str(port),
                "--temp", str(rd.get("temperature", 0.7)),
                "--top-p", str(rd.get("top_p", 0.8)),
                "--top-k", str(rd.get("top_k", 20)),
                "--max-tokens", str(rd.get("max_tokens", 4096))]
    else:
        raise HTTPException(500, f"unknown engine: {engine}")
    return args


def _port_listening(port: int, timeout: float = 2.0) -> bool:
    try:
        r = httpx.get(f"http://127.0.0.1:{port}/health", timeout=timeout)
        return r.status_code == 200
    except Exception:
        return False


def _kill_port(port: int):
    """Find any process listening on `port` and send SIGTERM, then SIGKILL."""
    try:
        out = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True, text=True, timeout=3
        )
        pids = [p for p in out.stdout.split() if p.strip()]
    except Exception:
        pids = []
    for pid in pids:
        try:
            subprocess.run(["kill", "-TERM", pid], capture_output=True, timeout=2)
            print(f"[router] killed pid {pid} on :{port}", flush=True)
        except Exception:
            pass
    if pids:
        time.sleep(1.5)
        # Escalate any survivors.
        for pid in pids:
            try:
                subprocess.run(["kill", "-9", pid], capture_output=True, timeout=2)
            except Exception:
                pass


async def _wait_for_health(port: int, timeout: float = 120.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        if _port_listening(port, timeout=1.0):
            return True
        await asyncio.sleep(1.0)
    return False


async def ensure_loaded(model_name: str):
    """Ensure `model_name` is listening on its configured port.

    Polite eviction (2026-04-27): never both resident. When a different
    model is requested and another is currently up, drain its in-flight
    refcount to zero (preserving the "never kill mid-stream" guarantee
    that motivated the 2026-04-26 two-resident change), then evict it
    before launching the new one. If the other backend doesn't drain
    within the window, evict anyway — a hung backend would otherwise
    deadlock the swap-cliff fix this whole change exists for.
    """
    port = CONFIG["models"][model_name]["port"]

    # Fast path: already up.
    if _port_listening(port, timeout=2.0):
        return

    async with _LOAD_LOCK:
        # Re-check after lock acquisition.
        if _port_listening(port, timeout=2.0):
            return

        # Polite eviction of any other resident backend.
        for other_name, other_cfg in CONFIG["models"].items():
            if other_name == model_name:
                continue
            other_port = other_cfg["port"]
            if not _port_listening(other_port, timeout=1.0):
                continue
            print(
                f"[router] evicting {other_name} (:{other_port}) to make room for {model_name}",
                flush=True,
            )
            drained = await _wait_until_idle(other_name, timeout=600.0)
            if not drained:
                print(
                    f"[router] WARN: {other_name} did not drain within 600s — evicting anyway",
                    flush=True,
                )
            _kill_port(other_port)

        # Launch requested model.
        args = _launch_args(model_name)
        log_path = LOGS_DIR / f"server.{model_name}.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_f = open(log_path, "a")
        log_f.write(f"\n=== {datetime.now().isoformat()} — router autoload {model_name} ===\n")
        log_f.flush()
        print(f"[router] launching {model_name} on :{port}", flush=True)
        # Environment: disable tqdm progress bars (they were writing
        # hundreds of KB of ANSI garbage to the server logs per
        # request), and silence Python warnings.
        env = os.environ.copy()
        env["TQDM_DISABLE"] = "1"
        env["PYTHONWARNINGS"] = "ignore"
        env["PYTHONUNBUFFERED"] = "1"
        subprocess.Popen(args, stdout=log_f, stderr=subprocess.STDOUT,
                         start_new_session=True, env=env)

        ready = await _wait_for_health(port, timeout=120.0)
        if not ready:
            raise HTTPException(
                504,
                f"model {model_name} failed to load within 120s — check ~/.mlxlm/logs/server.{model_name}.log"
            )
        print(f"[router] {model_name} ready on :{port}", flush=True)


app = FastAPI(title="MLX Pilot Router")


# ---- Usage tracking -----------------------------------------------------
#
# Every successful /v1/chat/completions response is inspected for a `usage`
# block and the token counts are:
#   1. Appended to ~/.mlxlm/logs/usage.jsonl as a single JSON line
#   2. Added to in-memory running totals (overall + per-model + today)
#
# GET /usage returns the totals. The MLX Pilot GUI polls this to display
# token spend in the sidebar. Zero RAM pressure — the counters are ints
# and a jsonl append is a few bytes per request.

USAGE_LOG = LOGS_DIR / "usage.jsonl"
USAGE_TOTALS: dict = {
    "requests": 0,
    "input_tokens": 0,
    "output_tokens": 0,
    "total_tokens": 0,
    "per_model": {},  # model_name -> {requests, input, output, total}
    "today": {
        "date": datetime.now().date().isoformat(),
        "requests": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "total_tokens": 0,
    },
}


def _record_usage(model_name: str, usage: dict) -> None:
    """Update in-memory counters + append one jsonl line."""
    try:
        inp = int(usage.get("input_tokens") or usage.get("prompt_tokens") or 0)
        out = int(usage.get("output_tokens") or usage.get("completion_tokens") or 0)
        tot = int(usage.get("total_tokens") or (inp + out))
    except Exception:
        return
    if inp == 0 and out == 0:
        return
    USAGE_TOTALS["requests"] += 1
    USAGE_TOTALS["input_tokens"] += inp
    USAGE_TOTALS["output_tokens"] += out
    USAGE_TOTALS["total_tokens"] += tot
    pm = USAGE_TOTALS["per_model"].setdefault(
        model_name, {"requests": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
    )
    pm["requests"] += 1
    pm["input_tokens"] += inp
    pm["output_tokens"] += out
    pm["total_tokens"] += tot
    today = datetime.now().date().isoformat()
    if USAGE_TOTALS["today"]["date"] != today:
        USAGE_TOTALS["today"] = {
            "date": today, "requests": 0, "input_tokens": 0,
            "output_tokens": 0, "total_tokens": 0,
        }
    USAGE_TOTALS["today"]["requests"] += 1
    USAGE_TOTALS["today"]["input_tokens"] += inp
    USAGE_TOTALS["today"]["output_tokens"] += out
    USAGE_TOTALS["today"]["total_tokens"] += tot
    try:
        USAGE_LOG.parent.mkdir(parents=True, exist_ok=True)
        line = {
            "ts": datetime.now().isoformat(),
            "model": model_name,
            "input": inp, "output": out, "total": tot,
        }
        with open(USAGE_LOG, "a") as f:
            f.write(json.dumps(line) + "\n")
    except Exception:
        pass


@app.get("/usage")
async def get_usage():
    return USAGE_TOTALS


def _rehydrate_usage() -> None:
    """Sum all historical lines in usage.jsonl back into USAGE_TOTALS so
    the lifetime counters survive router restarts. Today counter only
    accumulates entries matching today's date."""
    if not USAGE_LOG.exists():
        return
    today = datetime.now().date().isoformat()
    try:
        with open(USAGE_LOG) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                inp = int(r.get("input") or 0)
                out = int(r.get("output") or 0)
                tot = int(r.get("total") or (inp + out))
                model_name = r.get("model", "unknown")
                USAGE_TOTALS["requests"] += 1
                USAGE_TOTALS["input_tokens"] += inp
                USAGE_TOTALS["output_tokens"] += out
                USAGE_TOTALS["total_tokens"] += tot
                pm = USAGE_TOTALS["per_model"].setdefault(
                    model_name, {"requests": 0, "input_tokens": 0,
                                 "output_tokens": 0, "total_tokens": 0}
                )
                pm["requests"] += 1
                pm["input_tokens"] += inp
                pm["output_tokens"] += out
                pm["total_tokens"] += tot
                ts = r.get("ts", "")
                if isinstance(ts, str) and ts.startswith(today):
                    USAGE_TOTALS["today"]["requests"] += 1
                    USAGE_TOTALS["today"]["input_tokens"] += inp
                    USAGE_TOTALS["today"]["output_tokens"] += out
                    USAGE_TOTALS["today"]["total_tokens"] += tot
    except Exception as e:
        print(f"[router] usage rehydrate failed: {e}", flush=True)


@app.on_event("startup")
async def _startup():
    _rehydrate_usage()


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "router": "mlx-pilot-router",
        "max_input_tokens": MAX_INPUT_TOKENS,
        "backends": [
            {"model": n, "port": m.get("port")}
            for n, m in CONFIG["models"].items() if m.get("port")
        ],
        "aliases": ALIASES,
    }


@app.get("/v1/models")
async def list_models():
    data = []
    for name in CONFIG["models"]:
        data.append({"id": name, "object": "model", "owned_by": "local"})
    for alias in ALIASES:
        data.append({"id": alias, "object": "model", "owned_by": "local-alias"})
    return {"object": "list", "data": data}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    await _maybe_reload_config()
    try:
        body = await request.json()
    except Exception as e:
        raise HTTPException(400, f"bad json: {e}")

    requested = body.get("model", "default")
    # Normalize: strip any prefix like "mlx-pilot/" that some clients send.
    raw = (requested or "default").strip()
    alias_key = raw.split("/")[-1].lower() if "/" in raw else raw.lower()
    name, port, default_sys = resolve_model(requested)

    # Auto-load: if the backend isn't listening, evict LRU and launch it.
    # This is the auto-swap behavior — clients just ask for a model and it
    # appears, possibly after a 10-30s wait on first hit.
    await ensure_loaded(name)

    # Rewrite the model field to the on-disk path the backend expects.
    body["model"] = f"{MODELS_DIR}/{name}"

    # Apply per-alias overrides (e.g. thinking on/off for qwen35 vs thinker).
    # Only inject fields the client didn't explicitly set — client always wins.
    overrides = ALIAS_OVERRIDES.get(alias_key, {})
    for k, v in overrides.items():
        if k not in body:
            body[k] = v

    # Safety net: if a client sends an enormous conversation history and would
    # blow the model's context, drop oldest user/assistant pairs until it fits.
    # Preserves the system message. Rough 4-chars-per-token heuristic.
    msgs = body.get("messages", [])
    if isinstance(msgs, list) and msgs:
        def est_tokens(m):
            # 3 chars/token (was 4) — code/JSON traffic averages closer
            # to 3. With 4, MAX_INPUT_TOKENS=16000 was more permissive
            # than intended because the estimator under-counted real
            # tokens on agent/tool payloads.
            c = m.get("content", "") if isinstance(m, dict) else ""
            if isinstance(c, str):
                return max(1, len(c) // 3)
            total = 0
            if isinstance(c, list):
                for part in c:
                    if isinstance(part, dict) and isinstance(part.get("text"), str):
                        total += len(part["text"]) // 3
            return max(1, total)

        total = sum(est_tokens(m) for m in msgs)
        if total > MAX_INPUT_TOKENS:
            sys_msgs = [m for m in msgs if isinstance(m, dict) and m.get("role") == "system"]
            convo    = [m for m in msgs if isinstance(m, dict) and m.get("role") != "system"]
            while convo and sum(est_tokens(m) for m in sys_msgs + convo) > MAX_INPUT_TOKENS:
                convo.pop(0)  # drop oldest

            # Guard: if the trimmer drained convo completely, the original had
            # a single oversized turn (e.g. Hermes context-compaction prompts,
            # which pack conversation history into one giant user message).
            # Sending messages=[] downstream crashes transformers.apply_chat_template
            # with IndexError at conversation[0]. Keep the last non-system
            # message and middle-truncate its string content to fit the budget.
            if not convo:
                tail_msg = next(
                    (m for m in reversed(msgs)
                     if isinstance(m, dict) and m.get("role") != "system"),
                    None,
                )
                if tail_msg is not None:
                    sys_chars = sum(
                        len(m.get("content", "")) if isinstance(m.get("content"), str) else 0
                        for m in sys_msgs
                    )
                    budget_chars = max(0, MAX_INPUT_TOKENS * 3 - sys_chars - 512)
                    content = tail_msg.get("content")
                    if isinstance(content, str) and len(content) > budget_chars:
                        half = budget_chars // 2
                        dropped = len(content) - budget_chars
                        truncated = (
                            content[:half]
                            + f"\n\n…[router trimmer: dropped {dropped} chars from middle]…\n\n"
                            + content[-half:]
                        )
                        tail_msg = {**tail_msg, "content": truncated}
                        print(
                            f"router: single-turn overflow truncated "
                            f"{len(content)}→{len(truncated)} chars",
                            flush=True,
                        )
                    convo = [tail_msg]
                else:
                    # Pathological: only system messages, all trimmed. Inject a
                    # minimal user stub so the backend never sees messages=[].
                    convo = [{"role": "user", "content": "[context compacted]"}]

            body["messages"] = sys_msgs + convo

    # Inject default system prompt if the caller didn't send one.
    if default_sys:
        msgs = body.get("messages", [])
        has_sys = any(m.get("role") == "system" for m in msgs if isinstance(m, dict))
        if not has_sys:
            body["messages"] = [{"role": "system", "content": default_sys}] + msgs

    target = f"http://127.0.0.1:{port}/v1/chat/completions"
    stream = bool(body.get("stream", False))
    timeout = httpx.Timeout(600.0, connect=10.0)

    client = httpx.AsyncClient(timeout=timeout)
    await _begin_forward(name)
    try:
        if stream:
            req = client.build_request("POST", target, json=body)
            resp = await client.send(req, stream=True)

            async def forward():
                # Pure passthrough. Backend already emits OpenAI-shaped
                # tool_calls[]; we only buffer SSE lines to harvest the
                # final usage block for /usage tracking.
                buf = bytearray()
                try:
                    async for chunk in resp.aiter_raw():
                        buf.extend(chunk)
                        yield chunk
                finally:
                    await resp.aclose()
                    await client.aclose()
                    try:
                        txt = buf.decode("utf-8", errors="replace")
                        last_usage = None
                        for line in reversed(txt.split("\n")):
                            line = line.strip()
                            if not line.startswith("data:"):
                                continue
                            payload_s = line[5:].strip()
                            if payload_s == "[DONE]":
                                continue
                            try:
                                obj = json.loads(payload_s)
                            except Exception:
                                continue
                            if isinstance(obj, dict) and isinstance(obj.get("usage"), dict):
                                last_usage = obj["usage"]
                                break
                        if last_usage is not None:
                            _record_usage(name, last_usage)
                    except Exception as exc:
                        print(f"[router] usage tracking failed: {exc}", flush=True)
                    await _end_forward(name)

            return StreamingResponse(forward(), media_type="text/event-stream",
                                     status_code=resp.status_code)
        else:
            try:
                resp = await client.post(target, json=body)
                try:
                    payload = resp.json()
                except Exception:
                    payload = {"error": "non-json response from backend", "raw": resp.text[:500]}
                if resp.status_code == 200 and isinstance(payload, dict):
                    usage = payload.get("usage")
                    if isinstance(usage, dict):
                        _record_usage(name, usage)
                return JSONResponse(payload, status_code=resp.status_code)
            finally:
                await client.aclose()
                await _end_forward(name)
    except httpx.ConnectError:
        await _end_forward(name)
        await client.aclose()
        raise HTTPException(503, f"backend :{port} ({name}) connect failed after load — check ~/.mlxlm/logs/server.{name}.log")


if __name__ == "__main__":
    host = "0.0.0.0"
    port = 8000
    print(f"[mlx-pilot-router] listening on http://{host}:{port}", flush=True)
    print(f"[mlx-pilot-router] aliases: {', '.join(sorted(ALIASES.keys()))}", flush=True)
    uvicorn.run(app, host=host, port=port, log_level="info")
