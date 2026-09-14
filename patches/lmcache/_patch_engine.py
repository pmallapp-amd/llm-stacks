#!/usr/bin/env python3
"""_patch_engine.py — the actual source-transformation logic behind
apply-patches.sh. Not meant to be run standalone (no argparse niceties) —
apply-patches.sh writes this file into a tempdir at run time and invokes it
with three positional args: <lmcache_dir> <mode> <diff_out_or_->.

WHY this exists as a separate file rather than inline `python -c` /
"sed": the transformation below has to be robust against not knowing the
EXACT literal syntax of the installed LMCache's NIXL backend allowlists
(flat tuple-of-strings vs. set-of-(backend,device)-tuples — see
patches/lmcache/README.md's "What is ASSUMED" section) and has to prove,
by re-parsing, that whatever it produced is still valid Python before it
is trusted. `sed` can do neither: it has no concept of "this string is
inside a collection literal, not a log message" and no way to validate the
result parses.

Algorithm, in one paragraph: walk every .py file under lmcache_dir whose
path contains "nixl" (case-insensitive — the one confirmed real module,
lmcache.v1.storage_backend.nixl_storage_backend, matches this, and any file
LMCache might rename this logic into in a future version very likely still
would). Tokenize each file. Find every STRING token whose literal value is
exactly "GDS", "POSIX", or "OBJ". For each, walk outward to the smallest
enclosing bracket that looks like a literal collection (not a function
call/subscript — see _is_literal_context). If that bracket's top-level
elements are themselves bare strings, it's a flat allowlist: append
"SPDK_NVMe_KV" and "XNVME_KV". If its top-level elements are themselves
bracketed (tuples/lists), it's a collection-of-combinations (e.g.
(backend, device) pairs, consistent with the "Invalid NIXL backend & device
combination" assertion text this repo has already observed and recorded in
scripts/common/gen-lmcache-config.sh) — clone every matching row, swapping
only the first string in the row for "SPDK_NVMe_KV" or "XNVME_KV" and
appending the clones as new top-level elements of the OUTER bracket. Skip
(don't double-patch) any bracket that already contains the substring
"SPDK_NVMe_KV". If literally zero qualifying brackets exist anywhere in the
scanned tree, that means the allowlist has moved/changed shape since this
was written — refuse to report success (exit 1) rather than silently doing
nothing.
"""
from __future__ import annotations

import ast
import difflib
import io
import keyword
import os
import sys
import tokenize
from dataclasses import dataclass, field

TARGET_NAMES = {"GDS", "POSIX", "OBJ"}
NEW_BACKENDS = ["SPDK_NVMe_KV", "XNVME_KV"]
ALREADY_PATCHED_MARK = "SPDK_NVMe_KV"

# Inserted as the first line of every file this engine actually edits.
# apply-patches.sh's marker-detection (before this engine even runs) greps
# for this exact string to refuse a second run without --force.
FILE_MARKER = (
    "# kvstack-lmcache-patch: added SPDK_NVMe_KV, XNVME_KV to the NIXL "
    "backend allowlist(s) in this file — see patches/lmcache/README.md. "
    "Do not hand-edit this comment; apply-patches.sh --revert removes it."
)


def _find_target_files(lmcache_dir: str) -> list[str]:
    out = []
    for root, _dirs, files in os.walk(lmcache_dir):
        for fn in files:
            if not fn.endswith(".py"):
                continue
            full = os.path.join(root, fn)
            if "nixl" in full.lower():
                out.append(full)
    return sorted(out)


def _prev_significant(tokens: list[tokenize.TokenInfo], idx: int):
    """Nearest token before index idx that isn't whitespace/comment noise."""
    skip = {tokenize.COMMENT, tokenize.NL, tokenize.INDENT, tokenize.DEDENT,
             tokenize.ENCODING}
    i = idx - 1
    while i >= 0:
        if tokens[i].type not in skip:
            return tokens[i]
        i -= 1
    return None


def _is_literal_context(prev) -> bool:
    """True if a bracket immediately preceded by `prev` looks like a bare
    collection literal (allowlist, membership check) rather than a function
    call or subscript on some other expression.

    WHY this matters: without this guard, a call like
    `logger.error("GDS init failed: %s", exc)` would have its `(...)`
    mistaken for an allowlist tuple and get "SPDK_NVMe_KV" spliced into a
    logging call's argument list — syntactically valid, semantically
    nonsense, and exactly the kind of "technically ran without error" bug
    this whole patch family exists to avoid reproducing.
    """
    if prev is None:
        return True
    if prev.type in (tokenize.NEWLINE, tokenize.NL, tokenize.INDENT,
                      tokenize.DEDENT, tokenize.ENCODING):
        return True
    if prev.type == tokenize.OP:
        # `foo()(...)` / `foo[0](...)` chaining off a prior call/subscript
        # result still looks like a call from here — everything else
        # (`=`, `,`, `:`, `(`, `[`, `{`, `return`-as-NAME handled below) is
        # assignment/argument/literal-nesting context.
        return prev.string not in (")", "]")
    if prev.type == tokenize.NAME:
        # `in`/`not in`/`assert`/`if`/`return` etc. are NAME-typed keywords
        # in the tokenizer; a bare identifier immediately before "(" or "["
        # that ISN'T a keyword means "this is a call or subscript".
        return keyword.iskeyword(prev.string)
    return False


@dataclass
class _Bracket:
    open_idx: int
    close_idx: int
    kind: str  # "(" "[" "{"


def _outermost_literal_bracket(tokens, enclosing: list, open_idx: int) -> int:
    """Climb from `open_idx` up through successive enclosing brackets as
    long as each parent ALSO looks like a bare collection literal (not a
    call/subscript). This is what turns "the innermost tuple containing the
    string GDS" into "the outer set/list this tuple is a ROW of", which is
    the actual allowlist we need to add new ROWS to — see this module's
    docstring on the combination pattern. Without this climb, a
    collection-of-(backend,device)-tuples allowlist would get its INNER
    2-tuples mutated into meaningless 4-tuples instead of gaining new rows.
    """
    cur = open_idx
    while True:
        parent = enclosing[cur]
        if parent is None:
            return cur
        prev = _prev_significant(tokens, parent)
        if not _is_literal_context(prev):
            return cur
        cur = parent


def _bracket_pairs(tokens: list[tokenize.TokenInfo]):
    """Returns (enclosing_open_idx_per_token, pair_close_for_open)."""
    stack: list[int] = []
    enclosing: list[int | None] = [None] * len(tokens)
    pair_close: dict[int, int] = {}
    for i, tok in enumerate(tokens):
        if tok.type == tokenize.OP and tok.string in "([{":
            enclosing[i] = stack[-1] if stack else None
            stack.append(i)
        elif tok.type == tokenize.OP and tok.string in ")]}":
            enclosing[i] = stack[-1] if stack else None
            if stack:
                pair_close[stack.pop()] = i
        else:
            enclosing[i] = stack[-1] if stack else None
    return enclosing, pair_close


def _top_level_elements(tokens, open_idx: int, close_idx: int):
    """Split the tokens strictly between open_idx and close_idx on
    top-level (depth-0 relative to this bracket) commas. Returns a list of
    (start_tok_idx, end_tok_idx_inclusive) spans, one per element, skipping
    purely-trailing-comma artifacts (an element span with zero real tokens).
    """
    depth = 0
    elems = []
    cur_start = None
    skip = {tokenize.COMMENT, tokenize.NL}
    for i in range(open_idx + 1, close_idx):
        tok = tokens[i]
        if tok.type in skip:
            continue
        if tok.type == tokenize.OP and tok.string in "([{":
            if cur_start is None:
                cur_start = i
            depth += 1
        elif tok.type == tokenize.OP and tok.string in ")]}":
            depth -= 1
        elif tok.type == tokenize.OP and tok.string == "," and depth == 0:
            if cur_start is not None:
                elems.append((cur_start, i - 1))
            cur_start = None
            continue
        else:
            if cur_start is None:
                cur_start = i
        # keep extending end even for non-open tokens
    if cur_start is not None:
        # find the actual last non-skip token index <= close_idx-1
        end = close_idx - 1
        while end > cur_start and tokens[end].type in skip:
            end -= 1
        elems.append((cur_start, end))
    return elems


def _span_text(source: str, offsets: list[int], tokens, start_idx: int, end_idx: int) -> str:
    s = _tok_offset(offsets, tokens[start_idx].start)
    e = _tok_offset(offsets, tokens[end_idx].end)
    return source[s:e]


def _line_offsets(source: str) -> list[int]:
    """offsets[i] = absolute char offset of the START of line i+1 (1-indexed
    lines, as tokenize uses)."""
    offsets = [0]
    for line in source.splitlines(keepends=True):
        offsets.append(offsets[-1] + len(line))
    return offsets


def _tok_offset(line_offsets: list[int], rowcol: tuple[int, int]) -> int:
    row, col = rowcol
    return line_offsets[row - 1] + col


@dataclass
class _FileResult:
    path: str
    original: str
    patched: str | None = None
    candidates: int = 0
    edits: int = 0
    notes: list[str] = field(default_factory=list)


def _scan_and_patch_file(path: str) -> _FileResult:
    with open(path, encoding="utf-8") as f:
        source = f.read()

    result = _FileResult(path=path, original=source)

    try:
        tokens = list(tokenize.generate_tokens(io.StringIO(source).readline))
    except (tokenize.TokenError, IndentationError, SyntaxError) as exc:
        # pragma: no cover - defensive: a file that doesn't even tokenize
        # cleanly is left completely untouched.
        result.notes.append(f"tokenize failed: {exc}")
        return result

    line_offsets = _line_offsets(source)
    enclosing, pair_close = _bracket_pairs(tokens)

    # Find every qualifying (open_idx -> close_idx) bracket. Dedup via dict.
    qualifying: dict[int, int] = {}
    for i, tok in enumerate(tokens):
        if tok.type != tokenize.STRING:
            continue
        try:
            val = ast.literal_eval(tok.string)
        except (ValueError, SyntaxError):
            continue
        if val not in TARGET_NAMES:
            continue
        open_idx = enclosing[i]
        if open_idx is None:
            continue  # bare scalar string, not inside any collection
        prev = _prev_significant(tokens, open_idx)
        if not _is_literal_context(prev):
            continue  # looks like a call/subscript, not an allowlist
        open_idx = _outermost_literal_bracket(tokens, enclosing, open_idx)
        close_idx = pair_close.get(open_idx)
        if close_idx is None:
            continue  # unbalanced (shouldn't happen on valid source)
        qualifying[open_idx] = close_idx

    result.candidates = len(qualifying)
    if not qualifying:
        return result

    edits: list[tuple[int, str]] = []  # (absolute_offset, insert_text), applied high-to-low

    for open_idx, close_idx in qualifying.items():
        open_tok = tokens[open_idx]
        close_tok = tokens[close_idx]
        between_start = _tok_offset(line_offsets, open_tok.end)
        between_end = _tok_offset(line_offsets, close_tok.start)
        between_text = source[between_start:between_end]

        if ALREADY_PATCHED_MARK in between_text:
            result.notes.append(
                f"line {open_tok.start[0]}: already contains {ALREADY_PATCHED_MARK} — skipped"
            )
            continue

        elems = _top_level_elements(tokens, open_idx, close_idx)
        # trailing comma? — last significant token before close_idx.
        skip = {tokenize.COMMENT, tokenize.NL}
        j = close_idx - 1
        while j > open_idx and tokens[j].type in skip:
            j -= 1
        trailing_comma = tokens[j].type == tokenize.OP and tokens[j].string == ","

        # Decide flat-vs-combination by inspecting the FIRST element's
        # first real token: if it opens its own bracket, this is a
        # collection-of-tuples ("combination") pattern.
        is_combination = False
        if elems:
            first_start, _first_end = elems[0]
            if tokens[first_start].type == tokenize.OP and tokens[first_start].string in "([{":
                is_combination = True

        insert_offset = _tok_offset(line_offsets, close_tok.start)

        if is_combination:
            new_rows = []
            for e_start, e_end in elems:
                row_text = _span_text(source, line_offsets, tokens, e_start, e_end)
                # Only clone rows whose FIRST string literal inside the row
                # matches one of our target names — i.e. this row is a
                # "(GDS, ...)"-shaped combination we care about, not some
                # unrelated tuple that happens to share this outer
                # collection.
                row_first_str = None
                for k in range(e_start, e_end + 1):
                    if tokens[k].type == tokenize.STRING:
                        try:
                            row_first_str = ast.literal_eval(tokens[k].string)
                        except (ValueError, SyntaxError):
                            row_first_str = None
                        break
                if row_first_str not in TARGET_NAMES:
                    continue
                for new_name in NEW_BACKENDS:
                    # Replace only the FIRST quoted-string occurrence in the
                    # row text (the backend-name position), leave everything
                    # else (device type, extra fields) verbatim.
                    cloned = row_text.replace(f'"{row_first_str}"', f'"{new_name}"', 1)
                    if cloned == row_text:
                        cloned = row_text.replace(f"'{row_first_str}'", f"'{new_name}'", 1)
                    new_rows.append(cloned)
            if not new_rows:
                continue
            joined = ", ".join(new_rows)
            insert_text = (f", {joined}" if not trailing_comma else f" {joined},")
            result.notes.append(
                f"line {open_tok.start[0]}: combination-pattern bracket — "
                f"cloned {len(new_rows)} row(s) for {NEW_BACKENDS}"
            )
        else:
            quoted = ", ".join(f'"{n}"' for n in NEW_BACKENDS)
            insert_text = (f", {quoted}" if not trailing_comma else f" {quoted},")
            result.notes.append(
                f"line {open_tok.start[0]}: flat allowlist bracket — appended {NEW_BACKENDS}"
            )

        edits.append((insert_offset, insert_text))

    if not edits:
        result.patched = None
        return result

    edits.sort(key=lambda e: e[0], reverse=True)
    new_source = source
    for offset, text in edits:
        new_source = new_source[:offset] + text + new_source[offset:]

    # Prepend the file-level marker (first line) so a second run without
    # --force can be detected by a simple grep, and so a human opening the
    # file sees immediately why it differs from upstream.
    if FILE_MARKER not in new_source.splitlines()[0:3]:
        new_source = FILE_MARKER + "\n" + new_source

    # Validate: the patched file MUST still be valid Python. This is the
    # safety net that makes the heuristics above trustworthy even though
    # they don't have a real upstream source tree to diff against.
    try:
        ast.parse(new_source, filename=path)
    except SyntaxError as exc:
        result.notes.append(
            f"FAIL: patched output does not parse ({exc}) — this file's "
            "edits are DISCARDED; the allowlist shape here doesn't match "
            "either pattern _patch_engine.py knows how to handle. See "
            "patches/lmcache/README.md's 'What is ASSUMED' section."
        )
        return result

    result.patched = new_source
    result.edits = len(edits)
    return result


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: _patch_engine.py <lmcache_dir> <scan|dry-run|apply> <diff_out|->",
              file=sys.stderr)
        return 2
    lmcache_dir, mode, diff_out = sys.argv[1], sys.argv[2], sys.argv[3]

    files = _find_target_files(lmcache_dir)
    if not files:
        print(f"FAIL: no .py files under a nixl-related path found beneath "
              f"{lmcache_dir} at all. LMCache's directory layout has moved "
              f"since this was written — see patches/lmcache/README.md's "
              f"'What is ASSUMED' section.", file=sys.stderr)
        return 1

    print(f"scanning {len(files)} candidate file(s) under {lmcache_dir}:", file=sys.stderr)
    for f in files:
        print(f"  {os.path.relpath(f, lmcache_dir)}", file=sys.stderr)

    results = [_scan_and_patch_file(f) for f in files]

    total_candidates = sum(r.candidates for r in results)
    total_edits = sum(r.edits for r in results)
    parse_failures = [r for r in results if r.candidates and r.edits == 0 and
                       any(n.startswith("FAIL:") for n in r.notes)]

    print("", file=sys.stderr)
    for r in results:
        if not r.candidates and not r.notes:
            continue
        print(f"--- {os.path.relpath(r.path, lmcache_dir)} ---", file=sys.stderr)
        print(f"  candidate allowlist bracket(s): {r.candidates}", file=sys.stderr)
        for n in r.notes:
            print(f"  {n}", file=sys.stderr)

    if total_candidates == 0:
        print("", file=sys.stderr)
        print(
            "FAIL: zero \"GDS\"/\"POSIX\"/\"OBJ\" allowlist-shaped brackets "
            "found anywhere under a nixl-related path in the installed "
            "LMCache. Either LMCache_VERSION has drifted away from what "
            "this patch was written against (see "
            "patches/lmcache/README.md's ASSUMED section), or the "
            "installed tree genuinely does not gate SPDK_NVMe_KV/XNVME_KV "
            "at all (in which case: good, but verify with "
            "scripts/common/25-validate-lmcache-config.sh before trusting "
            "that). Refusing to report success.",
            file=sys.stderr,
        )
        return 1

    if parse_failures:
        print("", file=sys.stderr)
        print(f"FAIL: {len(parse_failures)} file(s) failed to re-parse after "
              "patching; their edits were discarded. See notes above.",
              file=sys.stderr)
        return 1

    if total_edits == 0:
        print("", file=sys.stderr)
        print(f"OK: {total_candidates} candidate bracket(s) found, all "
              "already contain SPDK_NVMe_KV — nothing new to do (already "
              "applied).", file=sys.stderr)
        return 0

    print("", file=sys.stderr)
    print(f"{'would make' if mode == 'dry-run' else 'made'} "
          f"{total_edits} edit(s) across "
          f"{sum(1 for r in results if r.edits)} file(s) "
          f"(of {total_candidates} candidate bracket(s) total).",
          file=sys.stderr)

    # Unified diffs, always printed (both dry-run and apply) for operator
    # review; only WRITTEN to disk (files + diff_out) in apply mode.
    all_diff_lines: list[str] = []
    for r in results:
        if not r.patched:
            continue
        rel = os.path.relpath(r.path, lmcache_dir)
        diff = difflib.unified_diff(
            r.original.splitlines(keepends=True),
            r.patched.splitlines(keepends=True),
            fromfile=f"a/{rel}",
            tofile=f"b/{rel}",
        )
        all_diff_lines.extend(diff)

    diff_text = "".join(all_diff_lines)
    print("", file=sys.stderr)
    print("=== unified diff of all changes ===", file=sys.stderr)
    sys.stdout.write(diff_text)

    if mode == "apply":
        for r in results:
            if not r.patched:
                continue
            backup = r.path + ".orig-kvstack"
            if os.path.exists(backup):
                print(f"FAIL: backup {backup} already exists — refusing to "
                      f"overwrite it. Run apply-patches.sh --revert first, "
                      f"or investigate why a stale backup is present.",
                      file=sys.stderr)
                return 1
        for r in results:
            if not r.patched:
                continue
            backup = r.path + ".orig-kvstack"
            with open(backup, "w", encoding="utf-8") as f:
                f.write(r.original)
            with open(r.path, "w", encoding="utf-8") as f:
                f.write(r.patched)
            print(f"patched: {os.path.relpath(r.path, lmcache_dir)} "
                  f"(backup: {os.path.basename(backup)})", file=sys.stderr)
        if diff_out != "-":
            with open(diff_out, "w", encoding="utf-8") as f:
                f.write(diff_text)
            print(f"diff written to {diff_out}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
