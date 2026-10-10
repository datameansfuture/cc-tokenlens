# Token Lens

[English](README.md) | [简体中文](README.zh-CN.md)

A two-line statusline for [Claude Code](https://claude.com/claude-code) that
shows what a session has actually cost you in tokens — a number that keeps
climbing, rather than one that snaps back to zero every time the conversation
is compacted.

```
7.5M │ deepseek-flash 6.9M↓ 765k↑
~/projects/my-app ████████░░░░ 43%
```

## Why not the built-in number

Claude Code hands a statusline a `context_window` block with
`total_input_tokens` and `total_output_tokens`. They read like session totals
and are not. They are **snapshots of the current context window**:

- On a 636-record session, `total_output_tokens` read `75`. The session's actual
  output across those records was 530k.
- `total_input_tokens` went from `193371` to `113566` between two renders a few
  seconds apart.
- On auto-compact the window is rebuilt, both fields reset, and the statusline
  shows `0↓ 0↑` until the next turn fills them again.

There is no cumulative token field anywhere in the payload. `cost.total_cost_usd`
is session-wide, but money is not tokens. So this sums the session's transcript
instead, which only ever grows and is unaffected by compaction.

## What it counts

For every assistant record in the transcript:

```
down += input_tokens + cache_creation_input_tokens
up   += output_tokens
```

`cache_read_input_tokens` is **deliberately excluded**. On a long session it was
79.3M of the 84.7M raw input-side total — 92.7% — because every turn re-sends
the whole cached context. Counting it makes the number meaningless. What is
counted is genuinely new input plus output: what the session consumed rather
than re-read.

Change the formula in `cc-statusline-tokens.py` if you want it the other way;
the constant is `CACHE_VERSION`, which forces stale caches to be discarded when
you change the shape of the data.

### Incremental

The transcript is append-only and grows every turn, so re-parsing it on every
statusline tick would be wasteful. `cc-statusline-tokens.py` caches the running
totals plus the byte offset it has consumed, keyed to the transcript, and each
call parses only the bytes appended since. It is byte-oriented throughout, so
multibyte UTF-8 in message content cannot shift the offset, and it consumes only
complete lines — a file caught mid-write is finished next call. A transcript
shorter than the stored offset (truncated or replaced) restarts the scan.

Cost is about 28ms warm and 68ms on a cold full scan of a 5MB transcript.

## What it shows

Line 1 joins three things:

- **caveman's savings figure** — the token saving your setup has produced. Read
  out of the `caveman` plugin's statusline, keeping only the number.
- **the model tag** — from [`@alyibrahim/claude-statusline`](https://github.com/AlyIbrahim1/claude-statusline).
- **the session tokens** — this project's own contribution.

Line 2 is the directory and the context bar, also from claude-statusline.

## Install

`claude-statusline.sh` resolves the two helpers relative to itself, so the two
files sit side by side wherever you clone them. Point Claude Code at it:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/tokenlens_for_claudecode/cc-statusline.sh"
  }
}
```

`/plugin` and `settings.json` both work; put it in whichever your setup owns
permanently, since some subscription-switching tools rewrite `settings.json` on
every switch.

### Requirements

- **Optional.** `caveman` — for the savings figure. Without it the line renders
  without it.
- **Optional.** `@alyibrahim/claude-statusline` — for the model tag and the
  context bar. Found via `npm root -g`, so any npm prefix works; without it the
  line degrades to the tokens alone rather than breaking.
- **Required.** `python3`, for the token counter. The statusline renders nothing
  without it.

Neither dependency is vendored or required. The script degrades to less rather
than to an error, because a statusline that exits non-zero is hidden by Claude
Code and a broken one is worse than a plain one.

## Notes

- claude-statusline is invoked with `COLUMNS=200` on purpose. Its `wrapChunks()`
  pushes the directory onto a second line when the real terminal is narrow, and
  the `│`-split this script does would then capture the model name twice — once
  per line.
- stdin is read with a one-second ceiling. A bare `cat` blocks forever if the
  writer never closes the pipe, which would pin the statusline thread for the
  whole session.
- macOS ships bash 3.2, which rejects fractional `read -t` timeouts.

## License

MIT.
