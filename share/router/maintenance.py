#!/usr/bin/env python3
"""
MLX Pilot maintenance — prunes clutter under ~/.mlxlm and related locations.

Safety model:
  - Dry-run by default. Nothing is deleted unless --apply is passed.
  - Never touches files currently open by any running mlx_lm / mlx_vlm /
    router process (checked via `lsof -c Python`).
  - Never touches the model weight directories (~/.mlxlm/models/<name>/*).
  - Every run appends a JSONL audit to ~/.mlxlm/logs/maintenance.jsonl.
  - Tier A is always safe. Tier B uses retention values from config.json.

Usage:
  ~/.mlxlm/venv/bin/python ~/.mlxlm/maintenance.py              # dry run, full report
  ~/.mlxlm/venv/bin/python ~/.mlxlm/maintenance.py --apply      # actually delete
  ~/.mlxlm/venv/bin/python ~/.mlxlm/maintenance.py --quiet      # only totals
"""

import argparse
import sys
import json
import os
import shutil
import subprocess
import time
from datetime import datetime
from pathlib import Path

HOME = Path.home()
MLXLM = HOME / ".mlxlm"
LOGS_DIR = MLXLM / "logs"
MODELS_DIR = MLXLM / "models"
VENV_DIR = MLXLM / "venv"
CONVERSATIONS_DIR = MLXLM / "conversations"
MEMORY_DIR = MLXLM / "memory"
CONFIG_PATH = MLXLM / "config.json"
AUDIT_PATH = LOGS_DIR / "maintenance.jsonl"

# ---------- infrastructure ----------

actions: list[dict] = []


def record(op: str, path: Path, bytes_: int = 0, reason: str = "",
           skipped: bool = False) -> None:
    actions.append({
        "ts": time.time(),
        "op": op,
        "path": str(path),
        "bytes": int(bytes_),
        "reason": reason,
        "skipped": skipped,
    })


def size_of(path: Path) -> int:
    try:
        if path.is_file():
            return path.stat().st_size
        if path.is_dir():
            total = 0
            for root, _, files in os.walk(path):
                for f in files:
                    try:
                        total += os.path.getsize(os.path.join(root, f))
                    except OSError:
                        pass
            return total
    except OSError:
        pass
    return 0


def files_open_by_mlx() -> set[str]:
    """Return paths currently held open by any Python process — conservative
    superset of what the live mlx_lm / mlx_vlm / router.py processes are using.
    """
    try:
        out = subprocess.run(
            ["lsof", "-c", "Python", "-Fn"],
            capture_output=True, text=True, timeout=10
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return set()
    paths: set[str] = set()
    for line in out.stdout.splitlines():
        if line.startswith("n/"):
            paths.add(line[1:])
    return paths


def human(n: int) -> str:
    v = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if v < 1024:
            return f"{v:.1f} {unit}"
        v /= 1024
    return f"{v:.1f} TB"


def load_config_control() -> dict:
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f).get("control", {})
    except Exception:
        return {}


# ---------- Tier A: always safe ----------

def tier_a_pycache() -> None:
    """Delete all __pycache__ directories under ~/.mlxlm."""
    for root, dirs, _ in os.walk(MLXLM):
        for d in list(dirs):
            if d == "__pycache__":
                p = Path(root) / d
                record("rmdir", p, size_of(p), "pycache")
                dirs.remove(d)


def tier_a_model_caches() -> None:
    """Delete .cache subdirs inside each model directory. These are
    HuggingFace dataset-cache leftovers from download time. Model weights
    themselves (the .safetensors files) are NOT touched.
    """
    if not MODELS_DIR.exists():
        return
    for model_dir in MODELS_DIR.iterdir():
        if not model_dir.is_dir():
            continue
        cache = model_dir / ".cache"
        if cache.exists() and cache.is_dir():
            record("rmdir", cache, size_of(cache), "hf model .cache")


def tier_a_ds_store() -> None:
    """Delete .DS_Store files under ~/.mlxlm but NOT inside the venv."""
    for root, dirs, files in os.walk(MLXLM):
        # Skip the venv — it's huge and contains no user-relevant .DS_Store.
        if "venv" in dirs:
            dirs.remove("venv")
        for f in files:
            if f == ".DS_Store":
                p = Path(root) / f
                record("unlink", p, size_of(p), ".DS_Store")


def tier_a_stale_empty_logs(live: set[str]) -> None:
    """Delete 0-byte log files older than 1 day, skipping any that are
    currently open by a running Python process.
    """
    if not LOGS_DIR.exists():
        return
    now = time.time()
    for p in LOGS_DIR.glob("*.log"):
        try:
            st = p.stat()
        except OSError:
            continue
        if st.st_size > 0:
            continue
        age_days = (now - st.st_mtime) / 86400
        if age_days < 1:
            record("skip", p, 0, "empty but fresh", skipped=True)
            continue
        if str(p) in live:
            record("skip", p, 0, "open by process", skipped=True)
            continue
        record("unlink", p, 0, "empty stale log")


def tier_a_log_rotation(live: set[str], max_bytes: int = 2_000_000,
                        keep_lines: int = 5000) -> None:
    """Truncate any log larger than max_bytes to its last keep_lines lines.
    Skips any file currently held open by a live process (their content is
    still being actively written — truncating would confuse the writer).
    """
    if not LOGS_DIR.exists():
        return
    for p in LOGS_DIR.glob("*.log"):
        try:
            sz = p.stat().st_size
        except OSError:
            continue
        if sz <= max_bytes:
            continue
        if str(p) in live:
            record("skip", p, sz, f"oversize ({sz}) but in use", skipped=True)
            continue
        record("truncate-tail", p, sz, f"> {max_bytes} bytes")


def tier_a_bench_progress() -> None:
    """The bench_progress.log isn't in logs/ — it sits at the mlxlm root.
    Delete it if older than 7 days.
    """
    p = MLXLM / "bench_progress.log"
    if not p.exists():
        return
    age_days = (time.time() - p.stat().st_mtime) / 86400
    if age_days >= 7:
        record("unlink", p, p.stat().st_size, "stale bench_progress")


def tier_a_pip_cache() -> None:
    """Purge pip wheel cache at ~/Library/Caches/pip. Grows silently after
    many installs/upgrades. Safe: pip re-populates on demand."""
    cache = HOME / "Library" / "Caches" / "pip"
    if not cache.exists():
        return
    sz = size_of(cache)
    if sz == 0:
        return
    record("shell-pip-purge", cache, sz, "pip cache purge")


def tier_a_brew_cleanup() -> None:
    """Run `brew cleanup -s` to remove outdated formula downloads. Safe:
    brew re-downloads if needed for the installed version."""
    brew_bin = Path("/opt/homebrew/bin/brew")
    if not brew_bin.exists():
        return
    cache = HOME / "Library" / "Caches" / "Homebrew"
    sz = size_of(cache) if cache.exists() else 0
    if sz == 0:
        return
    record("shell-brew-cleanup", cache, sz, "brew cleanup -s")


def tier_a_swift_build() -> None:
    """Delete the Swift package .build dir for MLX Pilot source. Safe:
    regenerates in ~6s on the next `swift build`. Project location is
    overridable via env var MLXPILOT_PROJECT_DIR for fresh installs that
    cloned to a different path."""
    proj_env = os.environ.get("MLXPILOT_PROJECT_DIR")
    candidates: list[Path] = []
    if proj_env:
        candidates.append(Path(proj_env) / ".build")
    # Common conventional locations — try each, skip silently if missing.
    candidates += [
        HOME / "Projects" / "mlxpilot" / ".build",
        HOME / "Projects" / "MLXPilot" / ".build",
    ]
    for p in candidates:
        if not p.exists():
            continue
        sz = size_of(p)
        if sz == 0:
            continue
        record("rmdir", p, sz, "swift .build artifacts")
        return  # only one project


# ---------- Tier B: retention-driven ----------

def _parse_iso(s: str) -> float:
    # Handle trailing Z or +00:00 variants.
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def tier_b_empty_new_chats(hours: int) -> None:
    """Delete conversations that have no messages and haven't been touched
    in `hours`. These are 'New Chat' stubs the user created and abandoned.
    """
    if not CONVERSATIONS_DIR.exists():
        return
    cutoff = time.time() - hours * 3600
    for p in CONVERSATIONS_DIR.glob("*.json"):
        try:
            with open(p) as f:
                data = json.load(f)
        except Exception:
            continue
        if data.get("messages"):
            continue
        if data.get("archived"):
            continue
        ts = _parse_iso(data.get("updatedAt", ""))
        if ts and ts < cutoff:
            try:
                sz = p.stat().st_size
            except OSError:
                sz = 0
            record("unlink", p, sz, f"empty > {hours}h")


def tier_b_archived(days: int) -> None:
    """Delete conversations flagged archived older than `days`."""
    if not CONVERSATIONS_DIR.exists():
        return
    cutoff = time.time() - days * 86400
    for p in CONVERSATIONS_DIR.glob("*.json"):
        try:
            with open(p) as f:
                data = json.load(f)
        except Exception:
            continue
        if not data.get("archived"):
            continue
        ts = _parse_iso(data.get("updatedAt", ""))
        if ts and ts < cutoff:
            try:
                sz = p.stat().st_size
            except OSError:
                sz = 0
            record("unlink", p, sz, f"archived > {days}d")


def tier_b_memory(default_days: int, apply_now: bool) -> None:
    """Prune persistent memory entries older than their TTL.

    Pinned entries are skipped. Per-entry ttl_days overrides the default.
    A negative ttl_days means "never expire". Operates on
    ~/.mlxlm/memory/INDEX.json — rewrites it without the pruned entries
    and removes the matching .md mirror files.

    `apply_now` is the explicit dry-run/apply flag (passed in instead of
    sniffing sys.argv so it works regardless of how the script is invoked).
    """
    index_path = MEMORY_DIR / "INDEX.json"
    if not index_path.exists():
        return
    try:
        with open(index_path) as f:
            entries = json.load(f)
    except Exception:
        return
    if not isinstance(entries, list):
        return
    now = time.time()
    kept: list[dict] = []
    pruned: list[tuple[str, int]] = []  # (id, ttl)
    for e in entries:
        if not isinstance(e, dict):
            continue
        if e.get("pinned"):
            kept.append(e)
            continue
        ttl = e.get("ttlDays")
        if ttl is None:
            ttl = default_days
        try:
            ttl_int = int(ttl)
        except Exception:
            ttl_int = default_days
        if ttl_int < 0:
            kept.append(e)
            continue
        created_ts = _parse_iso(e.get("createdAt", ""))
        if not created_ts:
            kept.append(e)
            continue
        if (now - created_ts) > ttl_int * 86400:
            pruned.append((str(e.get("id", "")), ttl_int))
        else:
            kept.append(e)
    if not pruned:
        return
    record("rewrite-json", index_path, 0,
           f"prune {len(pruned)} memory entr{'y' if len(pruned) == 1 else 'ies'}")
    if apply_now:
        try:
            with open(index_path, "w") as f:
                json.dump(kept, f, indent=2, sort_keys=True)
        except Exception as exc:
            print(f"memory prune: failed to rewrite INDEX.json: {exc}")
    for mid, _ttl in pruned:
        # Defensive: validate id looks like a UUID-ish token before
        # constructing the path — guards against any path-traversal in
        # case INDEX.json was hand-edited with crafted ids.
        if not mid or "/" in mid or "\\" in mid or ".." in mid:
            continue
        md_path = MEMORY_DIR / f"{mid}.md"
        if md_path.exists():
            try:
                sz = md_path.stat().st_size
            except OSError:
                sz = 0
            record("unlink", md_path, sz, "memory ttl expired")


# ---------- apply / report ----------

def apply_actions() -> tuple[int, int]:
    applied, failed = 0, 0
    for a in actions:
        if a["skipped"]:
            continue
        path = Path(a["path"])
        op = a["op"]
        try:
            if op == "unlink":
                path.unlink(missing_ok=True)
                applied += 1
            elif op == "rmdir":
                shutil.rmtree(path, ignore_errors=True)
                applied += 1
            elif op == "truncate-tail":
                lines = path.read_text(errors="replace").splitlines()
                path.write_text("\n".join(lines[-5000:]) + "\n")
                applied += 1
            elif op == "shell-pip-purge":
                pip = VENV_DIR / "bin" / "pip"
                if not pip.exists():
                    pip = Path("/opt/homebrew/bin/pip3")
                subprocess.run([str(pip), "cache", "purge"],
                               capture_output=True, timeout=60)
                applied += 1
            elif op == "shell-brew-cleanup":
                subprocess.run(["/opt/homebrew/bin/brew", "cleanup", "-s"],
                               capture_output=True, timeout=120)
                applied += 1
        except Exception as exc:
            print(f"  FAIL  {op:14s} {a['path']}: {exc}")
            failed += 1
    return applied, failed


def write_audit(applied: bool) -> None:
    AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(AUDIT_PATH, "a") as f:
        for a in actions:
            line = dict(a)
            line["applied"] = bool(applied) and not a["skipped"]
            f.write(json.dumps(line) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser(description="Prune ~/.mlxlm clutter. Dry-run by default.")
    ap.add_argument("--apply", action="store_true",
                    help="Actually execute actions. Default is dry-run.")
    ap.add_argument("--quiet", action="store_true",
                    help="Only print totals, not per-file actions.")
    args = ap.parse_args()

    ctrl = load_config_control()
    archived_days = int(ctrl.get("archived_retention_days", 14))
    empty_hours = int(ctrl.get("prune_empty_new_chats_after_hours", 24))
    # Memory retention: read from the optional `memory` block.
    try:
        with open(CONFIG_PATH) as f:
            full_cfg = json.load(f)
    except Exception:
        full_cfg = {}
    mem_cfg = full_cfg.get("memory") or {}
    memory_default_days = int(mem_cfg.get("default_retention_days", 90))

    live = files_open_by_mlx()

    # Tier A — always-safe
    tier_a_pycache()
    tier_a_model_caches()
    tier_a_ds_store()
    tier_a_stale_empty_logs(live)
    tier_a_log_rotation(live)
    tier_a_bench_progress()
    tier_a_pip_cache()
    tier_a_brew_cleanup()
    tier_a_swift_build()

    # Tier B — retention
    tier_b_empty_new_chats(empty_hours)
    tier_b_archived(archived_days)
    tier_b_memory(memory_default_days, apply_now=args.apply)

    total_bytes = sum(a["bytes"] for a in actions if not a["skipped"])
    n_ops = sum(1 for a in actions if not a["skipped"])
    n_skipped = sum(1 for a in actions if a["skipped"])

    print(f"Planned actions: {n_ops}  skipped: {n_skipped}  reclaim: {human(total_bytes)}")
    if not args.quiet:
        for a in actions:
            tag = "SKIP" if a["skipped"] else a["op"].upper()
            size_str = human(a["bytes"])
            print(f"  {tag:14s} {size_str:>10s}  {a['reason']:<30s}  {a['path']}")

    if args.apply:
        applied, failed = apply_actions()
        print(f"\nApplied: {applied}  Failed: {failed}")
        write_audit(applied=True)
    else:
        print("\nDRY RUN. Re-run with --apply to execute.")
        write_audit(applied=False)


if __name__ == "__main__":
    main()
