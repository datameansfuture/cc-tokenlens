#!/bin/bash
# Combined statusline: caveman savings + claude-statusline, split across
# two lines.
#
# Reads the Claude Code statusline JSON payload from stdin and emits:
#   Line 1: <caveman savings> │ <model tag> <session tokens>↓ <output>↑
#   Line 2: <directory> <context bar>%
#
# The session token pair comes from cc-statusline-tokens.py, which sums the
# transcript: input_tokens + cache_creation_input_tokens down, output_tokens
# up. cache_read is deliberately excluded — it is 92.7% of the raw input-side
# volume, and counting it inflates the number to nonsense.
#
# NOT taken from claude-statusline's own Usage line: that reads Claude Code's
# `context_window.total_*_tokens`, which are current-context snapshots, not
# session counters. They reset to zero on auto-compact, so the statusline
# flashed "0↓ 0↑" after every compaction. The transcript sum only grows.
#
# Drops:
#   - caveman [CAVEMAN] tag and ⛏ icon — keep only the savings token
#   - claude-statusline's whole Usage line (label, cost, rate limits)
#
# Caveat: claude-statusline's internal separator is `<sp>\e[2m│\e[0m<sp>`
# (dim-styled box-drawing char). sed normalizes it to a bare U+2502 so
# bash parameter expansion can split cleanly.

set -u

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Newest match by mtime. Previously this used `find | sort | tail -1`, which is
# lexicographic, not chronological — it picked b4de606fb871 while 367fdb7f0f8f
# was newer. Benign only because the two cached copies happened to be identical.
# `ls -1t` sorts its operands by mtime, newest first. Caveat: it word-splits on
# whitespace, so it breaks on paths containing spaces — none exist under the
# plugin cache.
CAVEMAN_SCRIPT=""
_cav_files="$(find "$HOME/.claude/plugins/cache/caveman/caveman" -name caveman-statusline.sh 2>/dev/null)"
if [ -n "$_cav_files" ]; then
  CAVEMAN_SCRIPT="$(ls -1t $_cav_files 2>/dev/null | head -1)"
fi

# claude-statusline ships as an npm global. The prefix is read without trusting
# PATH: a statusline inherits whatever the shell that launched it had, and a
# `npm` earlier in that PATH is not necessarily the npm that installed the
# package. Common locations first, PATH last.
npm_root() {
  for candidate in \
    "${NPM_BIN:-/nonexistent}" \
    /opt/homebrew/bin/npm \
    /usr/local/bin/npm \
    /usr/bin/npm
  do
    if [ -x "$candidate" ]; then
      "$candidate" root -g 2>/dev/null && return 0
    fi
  done

  # nvm and other version managers install into a versioned prefix that has to
  # be resolved, so PATH is the only way left to find them.
  command -v npm >/dev/null 2>&1 && npm root -g 2>/dev/null
}

NPM_ROOT="$(npm_root)"
if [ -n "$NPM_ROOT" ] && [ -d "$NPM_ROOT/@alyibrahim/claude-statusline" ]; then
  # Never fall back to <prefix>/bin/claude-statusline — that is bin/cli.js, the
  # command-line installer, which prints its help text. A wrong path here paints
  # "claude-statusline <command> / Commands:" into the status bar. Empty is the
  # correct degradation: we render without the model/dir chunk.
  CLAUDE_BIN="$(find "$NPM_ROOT/@alyibrahim/claude-statusline/node_modules" -name statusline -type f 2>/dev/null | head -1)"
else
  CLAUDE_BIN=""
fi
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
  CLAUDE_BIN=""
fi

# The token counter ships beside this script. Resolved relative to it so the mod
# works from wherever it was cloned; a hardcoded $HOME path only works for
# whoever installed it.
TOK_PY="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/cc-statusline-tokens.py"
if [ ! -x "$TOK_PY" ]; then
  TOK_PY=""
fi

# Cache stdin once — both children need the same JSON, and re-reading a pipe
# from two processes can race on small payloads.
#
# `read -t 1` is a hard ceiling: a bare `cat` blocks forever if the writer never
# closes stdin, which would pin the statusline thread for the session. macOS
# ships bash 3.2, which rejects fractional timeouts, so the value is an integer.
# `-d ''` reads to NUL, i.e. the whole payload; it returns nonzero at EOF,
# which is the normal path and not an error. Same guard caveman's own
# statusline uses. A real terminal is never read from at all.
INPUT=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' -t 1 INPUT 2>/dev/null || true
fi

# caveman: pull only the savings number (e.g. "7.5M") and re-color so it
# survives the join with the right ANSI prefix. The original output is
# "<ansi>[CAVEMAN]<reset> <ansi>⛏  <savings><reset>"; splitting on ⛏ loses
# the leading color run since the icon sits between two colored blocks.
CAV_OUT=""
if [ -n "$CAVEMAN_SCRIPT" ] && [ -r "$CAVEMAN_SCRIPT" ]; then
  CAV_OUT="$(printf '%s' "$INPUT" | bash "$CAVEMAN_SCRIPT" 2>/dev/null \
    | grep -oE '[0-9]+(\.[0-9]+)?[KMG]' \
    | head -1 \
    | awk '{printf "\033[38;5;172m%s\033[0m", $1}')"
fi

# Full claude-statusline output (multi-line). We only need:
#   Line 1: model │ dir bar%
#
# Force COLUMNS=200 so statusline.js's wrapChunks() never wraps line 1 — when
# the real terminal is narrow, wrap puts dirDisplay on line 2 alone, and our
# `sed -n '1p'` would see only modelDisplay (no │) and the %%│*/##*│ split
# degenerates to DIR_OUT == MODEL_OUT, painting model name into both rows.
# COLUMNS env is honored by statusline.js:terminalColumns() after stdout.columns.
CLAUDE_RAW=""
if [ -n "$CLAUDE_BIN" ] && [ -r "$CLAUDE_BIN" ]; then
  CLAUDE_RAW="$(printf '%s' "$INPUT" | COLUMNS=200 "$CLAUDE_BIN" 2>/dev/null)"
fi

CLAUDE_LINE1="$(printf '%s\n' "$CLAUDE_RAW" | sed -n '1p')"

# Split claude-statusline line 1 into model + dir/bar.
#
# line 1 may carry MULTIPLE " │ " separators: model_display is chunk 1 and
# dir+bar is ALWAYS the last chunk, with an optional task chunk in between
# (only when an agent task is active). So model = first │, dir+bar = last │.
# First-│ split would leave the task chunk glued to line 2's head.
#
# Replace "<sp><dim><box><reset><sp>" with a bare box char, consuming the
# surrounding spaces so pre/post have no stray whitespace.
CLAUDE_LINE1_CLEAN=""
if [ -n "$CLAUDE_LINE1" ]; then
  CLAUDE_LINE1_CLEAN="$(printf '%s' "$CLAUDE_LINE1" \
    | sed $'s/ \033\\[2m\xe2\x94\x82\033\\[0m /\xe2\x94\x82/g')"
fi

MODEL_OUT=""
DIR_OUT=""
if [ -n "$CLAUDE_LINE1_CLEAN" ]; then
  # First │ marks the end of model_display; last │ marks the start of dir+bar.
  MODEL_OUT="${CLAUDE_LINE1_CLEAN%%│*}"
  DIR_OUT="${CLAUDE_LINE1_CLEAN##*│}"
fi

# Session tokens: locally derived, see the header for why claude-statusline's
# own Usage line is not used. Painted white to match its former color.
TOK_OUT=""
if [ -n "$TOK_PY" ] && [ -x "$TOK_PY" ]; then
  TOK_OUT="$(printf '%s' "$INPUT" | python3 "$TOK_PY" 2>/dev/null)"
  [ -n "$TOK_OUT" ] && TOK_OUT="$(printf '\033[97m%s\033[0m' "$TOK_OUT")"
fi

# Line 1: caveman savings + model tag + session token total.
LINE1=""
if [ -n "$CAV_OUT" ] && [ -n "$MODEL_OUT" ]; then
  LINE1="${CAV_OUT} │ ${MODEL_OUT}"
elif [ -n "$CAV_OUT" ]; then
  LINE1="$CAV_OUT"
elif [ -n "$MODEL_OUT" ]; then
  LINE1="$MODEL_OUT"
fi
# Append session token total to line 1 (e.g. "94k↓") if we got one.
if [ -n "$TOK_OUT" ] && [ -n "$LINE1" ]; then
  LINE1="${LINE1} ${TOK_OUT}"
fi

# Line 2: directory + context bar.
LINE2="$DIR_OUT"

# Emit, preserving the no-trailing-newline rule (Claude Code hides the
# status bar on exit status != 0; trailing \n alone is fine, but stay tidy).
if [ -n "$LINE1" ] && [ -n "$LINE2" ]; then
  printf '%s\n%s' "$LINE1" "$LINE2"
elif [ -n "$LINE1" ]; then
  printf '%s' "$LINE1"
else
  printf '%s' "$LINE2"
fi
