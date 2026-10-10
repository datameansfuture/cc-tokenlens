#!/usr/bin/env python3
"""Session token counter for cc-statusline.sh.

Reads the Claude Code statusline stdin JSON, pulls `transcript_path`, and
returns the session's token consumption as "<new-input>↓ <output>↑".

## Why not context_window.total_*_tokens

Claude Code also exposes `context_window.total_input_tokens` /
`total_output_tokens` on stdin, but those are NOT session counters — they are
snapshots of the CURRENT context window (verified: total_output_tokens read 75
for a 636-record session, and total_input_tokens jumped 193371 -> 113566
between two renders seconds apart). Claude Code rebuilds the context window on
auto-compact, so those fields reset to zero and the statusline briefly shows
"0↓ 0↑". No cumulative token field exists anywhere in the payload.

This script sums the transcript instead, so the number only ever grows and is
unaffected by compaction.

## Formula

For every assistant record in the transcript:

    down += input_tokens + cache_creation_input_tokens
    up   += output_tokens

`cache_read_input_tokens` is deliberately EXCLUDED. It dominates the raw total
(measured 92.7% of all input-side tokens on a long session) because each turn
re-sends the whole cached context; counting it makes the displayed number look
absurd (84.7M for one session). What is counted is the genuinely new input plus
the output — the tokens the session actually consumed rather than re-read.

## Incremental scan

The transcript is append-only JSONL and grows every turn, so re-parsing the
whole file on every statusline tick is wasteful. Cache the running totals plus
the byte offset already consumed, keyed to the transcript. Each call parses
only the bytes appended since last time — O(new bytes), not O(file).

Only complete lines are consumed; a trailing partial line (file mid-write) is
left for the next call. If the file is ever shorter than the recorded offset
(truncated or replaced), the scan resets and re-reads from zero.

The cache write is atomic (temp file + os.replace) so a concurrent statusline
invocation cannot observe a half-written entry.

Exit 0 with the token pair on stdout, or prints nothing (exit 0) when the
transcript has no usage records yet.
"""
import hashlib
import json
import os
import sys
import tempfile

CACHE_VERSION = 3  # bump when the formula or cache shape changes


def fmt(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 10_000:
        return f"{n / 1_000:.0f}k"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def load_cache(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
        if d.get("v") == CACHE_VERSION:
            return d
    except (OSError, json.JSONDecodeError, ValueError):
        pass
    return {}


def save_cache(path: str, data: dict) -> None:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # A predictable name in a shared TMPDIR is a symlink target: another
        # process on the machine can create it first, and the write below would
        # land wherever that link points. mkstemp creates the file exclusively,
        # so the name is ours and the descriptor is already open.
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.replace(tmp, path)
        except BaseException:
            os.unlink(tmp)
            raise
    except OSError:
        pass


def scan(path: str, cache: dict):
    """Parse only the bytes appended since `cache['offset']`.

    Returns (down, up, new_offset). Byte-oriented throughout: multibyte UTF-8
    in message content must not shift the offset.
    """
    down = int(cache.get("down", 0))
    up = int(cache.get("up", 0))
    offset = int(cache.get("offset", 0))

    size = os.path.getsize(path)
    if offset > size:  # truncated or replaced — start over
        down = up = offset = 0
    if offset == size:
        return down, up, offset

    with open(path, "rb") as f:
        f.seek(offset)
        data = f.read()

    # Consume complete lines only; hold back a trailing partial line.
    last_nl = data.rfind(b"\n")
    if last_nl == -1:
        return down, up, offset
    chunk = data[:last_nl]
    new_offset = offset + last_nl + 1

    for raw in chunk.split(b"\n"):
        raw = raw.strip()
        if not raw:
            continue
        try:
            d = json.loads(raw)
        except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
            continue
        if d.get("type") != "assistant":
            continue
        usage = d.get("message", {}).get("usage")
        if not isinstance(usage, dict):
            continue
        down += usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
        up += usage.get("output_tokens", 0)

    return down, up, new_offset


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        path = payload.get("transcript_path") or ""
    except (json.JSONDecodeError, ValueError, OSError):
        return 0
    if not path or not os.path.isfile(path):
        return 0

    cache_dir = os.path.join(os.environ.get("TMPDIR", "/tmp"), "ccsl-token-cache")
    cache_file = os.path.join(
        cache_dir, hashlib.sha1(path.encode()).hexdigest() + ".json"
    )

    cache = load_cache(cache_file)
    try:
        down, up, offset = scan(path, cache)
    except OSError:
        return 0

    if down == 0 and up == 0:
        return 0

    save_cache(cache_file, {"v": CACHE_VERSION, "offset": offset, "down": down, "up": up})
    print(f"{fmt(down)}↓ {fmt(up)}↑", end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
