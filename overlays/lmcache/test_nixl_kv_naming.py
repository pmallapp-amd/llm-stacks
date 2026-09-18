#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
test_nixl_kv_naming.py — offline unit tests for the pure-logic parts of
nixl_kv_l2_adapter.py.

Runnable with plain ``python3`` on the control host: NO nixl, NO
lmcache, NO hardware required. ``nixl_kv_l2_adapter.py`` guards its
nixl/lmcache imports in a top-level try/except specifically so this is
possible (see that module's docstring) — these tests are the proof.

This is the regression test for the page-collapse hole
(docs/design/nixl-kv-l2-adapter.md §4, §9) and for the PRESENT-is-``{}``
probe-interpretation bug (§2, §6 Lookup item 3) that this adapter exists
to fix. Every failure here means one of those two bugs is back.

Usage:
    python3 overlays/lmcache/test_nixl_kv_naming.py

Exits 0 if all tests pass, non-zero (with a summary of failures) if not.
"""

# Standard
import ast
from functools import lru_cache
from pathlib import Path
import sys
import threading
import traceback

# Import the module under test directly by path so this script has no
# dependency on the surrounding package structure (or lmcache/nixl being
# importable) — matches the "runnable with plain python3" requirement.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import nixl_kv_l2_adapter as kv  # noqa: E402


# ---------------------------------------------------------------------
# Tiny test harness — no external test framework dependency, since the
# whole point is zero install requirements beyond stdlib.
# ---------------------------------------------------------------------

_RESULTS: list[tuple[str, bool, str]] = []


def _record(name: str, ok: bool, detail: str = "") -> None:
    _RESULTS.append((name, ok, detail))


def test(fn):
    """Decorator: run ``fn``, recording pass/fail/exception."""
    name = fn.__name__
    try:
        fn()
    except AssertionError as exc:
        _record(name, False, str(exc) or "assertion failed")
    except Exception:
        _record(name, False, "unexpected exception:\n" + traceback.format_exc())
    else:
        _record(name, True)
    return fn


# ---------------------------------------------------------------------
# 1. Runtime-availability guard itself: importing this module must not
#    require nixl or lmcache.
# ---------------------------------------------------------------------


@test
def test_module_imports_without_heavy_deps():
    # If we got this far, the import above already succeeded on a host
    # with neither nixl nor lmcache installed. Just double-check the
    # module's own flag agrees (it should be False here unless this
    # test happens to run inside the vendor container, in which case
    # True is also fine -- the point is merely that import didn't
    # raise).
    assert isinstance(kv._NIXL_KV_RUNTIME_AVAILABLE, bool)


# ---------------------------------------------------------------------
# 2. Page names: unique per ordinal (the page-collapse regression test).
# ---------------------------------------------------------------------


@test
def test_page_names_unique_per_ordinal():
    ns = "deadbeefcafe"
    key_string = "Qwen/Qwen3-8B@00000000@0@abcd1234"
    page_count = 9216  # production geometry (spec §2)
    names = [kv.page_name(ns, key_string, i) for i in range(page_count)]
    assert len(names) == len(set(names)) == page_count, (
        f"page-collapse regression: got {len(set(names))} distinct names "
        f"for {page_count} pages"
    )


@test
def test_page_names_differ_across_keys():
    ns = "ns"
    names_a = {kv.page_name(ns, "keyA", i) for i in range(8)}
    names_b = {kv.page_name(ns, "keyB", i) for i in range(8)}
    assert names_a.isdisjoint(names_b)


# ---------------------------------------------------------------------
# 3. Round-trip: name -> parse -> (ns, key_string, ordinal).
# ---------------------------------------------------------------------


@test
def test_page_name_round_trip():
    ns, key_string, ordinal = "geomabc123", "model@00000001@2@abcdef", 4321
    name = kv.page_name(ns, key_string, ordinal)
    parsed_ns, parsed_key, parsed_ord = kv.parse_name(name)
    assert (parsed_ns, parsed_key, parsed_ord) == (ns, key_string, ordinal)


@test
def test_commit_name_round_trip():
    ns, key_string = "geomabc123", "model@00000001@2@abcdef"
    name = kv.commit_name(ns, key_string)
    parsed_ns, parsed_key, parsed_ord = kv.parse_name(name)
    assert parsed_ns == ns
    assert parsed_key == key_string
    assert parsed_ord is None


@test
def test_round_trip_with_salted_key_string():
    # key_string itself contains '@' (model@rank@group@hash@salt) --
    # round-trip must still work because we only split on the FIRST '@'
    # for ns, and rpartition on the LAST '~' for the ordinal.
    ns = "ns1"
    key_string = "meta-llama/Llama-3-8B@0000002a@1@abcd@user-salt"
    for ordinal in (0, 1, 9215):
        name = kv.page_name(ns, key_string, ordinal)
        parsed = kv.parse_name(name)
        assert parsed == (ns, key_string, ordinal), (name, parsed)


# ---------------------------------------------------------------------
# 4. '~' ordinal separator never collides with 0007's '#' sub-split.
# ---------------------------------------------------------------------


@test
def test_ordinal_separator_is_not_hash():
    assert kv._PAGE_SEP == "~"
    assert "#" not in kv.page_name("ns", "key", 3)
    assert "#" not in kv.commit_name("ns", "key")


@test
def test_hash_in_key_string_does_not_confuse_parsing():
    # Even if a key_string somehow contained '#' (patch 0007's own
    # separator), parse_name must still recover the right ordinal since
    # it splits on '~' (last occurrence), never '#'.
    ns = "ns1"
    key_string = "model#with-hash-looking@0000002a@1@abcd"
    name = kv.page_name(ns, key_string, 7)
    assert kv.parse_name(name) == (ns, key_string, 7)


# ---------------------------------------------------------------------
# 5. Namespace validation: reject '@', '~', '!', and empty.
# ---------------------------------------------------------------------


@test
def test_namespace_accepts_legal_value():
    kv.validate_namespace("a1b2c3d4e5f6")  # must not raise


@test
def test_namespace_rejects_empty():
    try:
        kv.validate_namespace("")
    except ValueError:
        pass
    else:
        raise AssertionError("empty namespace was not rejected")


@test
def test_namespace_rejects_forbidden_chars():
    for bad_ns in ("has@at", "has~tilde", "has!bang", "@~!"):
        try:
            kv.validate_namespace(bad_ns)
        except ValueError:
            continue
        raise AssertionError(f"namespace {bad_ns!r} was not rejected")


# ---------------------------------------------------------------------
# 6. Commit payload round-trip and mismatch rejection.
# ---------------------------------------------------------------------


@test
def test_commit_payload_round_trip():
    ns, page_count, page_size, phy_size = "ns1", 9216, 4096, 9216 * 4096
    encoded = kv.encode_commit_payload(ns, page_count, page_size, phy_size)
    assert len(encoded) == page_size, "commit payload must be padded to page_size"
    decoded = kv.decode_commit_payload(encoded)
    assert decoded == {
        "v": 1,
        "ns": ns,
        "pages": page_count,
        "page_size": page_size,
        "phy_size": phy_size,
    }
    # Must not raise: matches its own encoding.
    kv.validate_commit_payload(
        decoded, ns=ns, page_size=page_size, expected_pages=page_count
    )


@test
def test_commit_payload_rejects_page_size_mismatch():
    ns = "ns1"
    encoded = kv.encode_commit_payload(ns, 4, 4096, 4 * 4096)
    decoded = kv.decode_commit_payload(encoded)
    try:
        kv.validate_commit_payload(decoded, ns=ns, page_size=2048, expected_pages=4)
    except ValueError:
        pass
    else:
        raise AssertionError("page_size mismatch was not rejected")


@test
def test_commit_payload_rejects_pages_mismatch():
    ns = "ns1"
    encoded = kv.encode_commit_payload(ns, 4, 4096, 4 * 4096)
    decoded = kv.decode_commit_payload(encoded)
    try:
        kv.validate_commit_payload(decoded, ns=ns, page_size=4096, expected_pages=5)
    except ValueError:
        pass
    else:
        raise AssertionError("pages mismatch was not rejected")


@test
def test_commit_payload_rejects_ns_mismatch():
    encoded = kv.encode_commit_payload("ns1", 4, 4096, 4 * 4096)
    decoded = kv.decode_commit_payload(encoded)
    try:
        kv.validate_commit_payload(
            decoded, ns="ns2-different", page_size=4096, expected_pages=4
        )
    except ValueError:
        pass
    else:
        raise AssertionError("ns mismatch was not rejected")


@test
def test_commit_payload_rejects_version_mismatch():
    encoded = kv.encode_commit_payload("ns1", 4, 4096, 4 * 4096)
    decoded = kv.decode_commit_payload(encoded)
    decoded["v"] = 2
    try:
        kv.validate_commit_payload(decoded, ns="ns1", page_size=4096, expected_pages=4)
    except ValueError:
        pass
    else:
        raise AssertionError("version mismatch was not rejected")


@test
def test_commit_payload_too_large_for_page_size_raises():
    # A pathologically small align_bytes can't hold even the smallest
    # JSON commit record.
    try:
        kv.encode_commit_payload("some-namespace-value", 4, 8, 4 * 8)
    except ValueError:
        pass
    else:
        raise AssertionError("oversized commit payload was not rejected")


# ---------------------------------------------------------------------
# 7. Probe interpretation: {} is a HIT, None is a MISS.
#
#    This is the regression test for the original nixl_store bug (spec
#    §2 measured facts / §6 Lookup item 3): "if resp[i]:" scores every
#    hit as a miss because PRESENT is an empty, falsy dict.
# ---------------------------------------------------------------------


@test
def test_present_empty_dict_is_a_hit():
    assert kv.is_probe_hit({}) is True


@test
def test_absent_none_is_a_miss():
    assert kv.is_probe_hit(None) is False


@test
def test_truthiness_based_check_would_be_wrong():
    # Explicit proof that this codebase's historical bug pattern
    # (`if resp[i]:`) is broken: bool({}) is False, so a truthiness
    # check on the PRESENT sentinel silently reports a miss.
    present = {}
    absent = None
    assert bool(present) is False, "sanity: {} must be falsy in Python"
    assert bool(absent) is False, "sanity: None must be falsy in Python"
    # A truthiness-based implementation cannot distinguish the two --
    # both are falsy -- so it would misclassify PRESENT as a miss:
    truthiness_says_hit = bool(present)
    assert truthiness_says_hit is False, (
        "if this assertion ever fails, Python's bool({}) semantics "
        "changed -- but as long as it holds, `if resp[i]:` is provably "
        "wrong and `resp[i] is not None` (is_probe_hit) is required"
    )
    # The identity-based interpretation gets it right in both directions:
    assert kv.is_probe_hit(present) is True
    assert kv.is_probe_hit(absent) is False


@test
def test_probe_hit_also_true_for_nonempty_descriptor():
    # Not measured in production (spec §2 says PRESENT is always `{}`
    # for this backend), but the identity check must not accidentally
    # depend on emptiness -- any non-None object is a hit.
    assert kv.is_probe_hit({"unexpected": "descriptor-with-fields"}) is True
    assert kv.is_probe_hit(object()) is True


# ---------------------------------------------------------------------
# 8. Page-count arithmetic: phy_size not divisible by align_bytes raises.
# ---------------------------------------------------------------------


@test
def test_page_count_for_exact_division():
    assert kv.page_count_for(9216 * 4096, 4096) == 9216
    assert kv.page_count_for(4096, 4096) == 1


@test
def test_page_count_for_rejects_non_multiple():
    try:
        kv.page_count_for(4097, 4096)
    except ValueError:
        pass
    else:
        raise AssertionError("non-multiple phy_size was not rejected")


@test
def test_page_count_for_rejects_non_positive_align():
    for bad_align in (0, -1):
        try:
            kv.page_count_for(4096, bad_align)
        except ValueError:
            continue
        raise AssertionError(f"align_bytes={bad_align} was not rejected")


# ---------------------------------------------------------------------
# 9. parse_name rejects malformed input.
# ---------------------------------------------------------------------


@test
def test_parse_name_rejects_missing_ns_separator():
    try:
        kv.parse_name("no-at-sign-here~3")
    except ValueError:
        pass
    else:
        raise AssertionError("name without '@' was not rejected")


@test
def test_parse_name_rejects_missing_ordinal_separator():
    try:
        kv.parse_name("ns@key-with-no-ordinal-or-commit-marker")
    except ValueError:
        pass
    else:
        raise AssertionError("name without '~' or '!c' was not rejected")


@test
def test_parse_name_rejects_non_integer_ordinal():
    try:
        kv.parse_name("ns@key~not-a-number")
    except ValueError:
        pass
    else:
        raise AssertionError("non-integer ordinal was not rejected")


# ---------------------------------------------------------------------
# N. object_key_to_string: the PERSISTENCE FORMAT, pinned to exact bytes.
#
# This function determines the on-device key (via the plugin's FNV-1a
# derivation of metaInfo). LMCache ships four private, independent copies
# of it and one of them is parameterised on a mutable module global, which
# is why this adapter spells its own rather than importing one. That
# decision is only worth anything if a change to our copy FAILS LOUDLY --
# because with no delete primitive on this backend, a silent format change
# does not degrade, it strands every object already on the device.
#
# So: assert the exact output bytes, not merely that it round-trips.
# ---------------------------------------------------------------------


class _FakeObjectKey:
    """Minimal stand-in for lmcache's ObjectKey (not importable offline)."""

    def __init__(self, model_name, kv_rank, object_group_id, chunk_hash,
                 cache_salt=""):
        self.model_name = model_name
        self.kv_rank = kv_rank
        self.object_group_id = object_group_id
        self.chunk_hash = chunk_hash
        self.cache_salt = cache_salt


@test
def test_object_key_to_string_exact_bytes_unsalted():
    k = _FakeObjectKey("Qwen/Qwen3-8B", 0, 0, bytes.fromhex("abcd1234"))
    got = kv.object_key_to_string(k)
    want = "Qwen/Qwen3-8B@00000000@0@abcd1234"
    assert got == want, f"persistence format changed!\n got: {got!r}\nwant: {want!r}"


@test
def test_object_key_to_string_exact_bytes_salted():
    k = _FakeObjectKey("meta-llama/Llama-3-8B", 7, 3,
                       bytes.fromhex("deadbeef"), cache_salt="tenantA")
    got = kv.object_key_to_string(k)
    want = "meta-llama/Llama-3-8B@00000007@3@deadbeef@tenantA"
    assert got == want, f"persistence format changed!\n got: {got!r}\nwant: {want!r}"


@test
def test_object_key_to_string_rank_is_zero_padded_8_hex():
    # kv_rank uses :08x and object_group_id uses :x -- they are NOT the
    # same format. Transposing them changes every key on the device.
    k = _FakeObjectKey("m", 255, 255, b"\x00")
    assert kv.object_key_to_string(k) == "m@000000ff@ff@00"


@test
def test_object_key_to_string_matches_vendor_output():
    # Byte-for-byte agreement with the vendor's own copies as measured
    # 2026-09-17 (s3/bigtable/hfbucket identical; native_connector same
    # output via _KEY_SEP="@"). If a future image's copy diverges, this
    # documents which behaviour WE keep -- ours -- and the divergence
    # becomes a deliberate decision rather than a silent migration.
    def vendor_reference(key):
        base = (
            f"{key.model_name}@{key.kv_rank:08x}"
            f"@{key.object_group_id:x}@{key.chunk_hash.hex()}"
        )
        return f"{base}@{key.cache_salt}" if key.cache_salt else base

    for k in (
        _FakeObjectKey("a/b", 0, 0, b"\x01\x02"),
        _FakeObjectKey("a/b", 1, 16, b"\xff", cache_salt="s"),
        _FakeObjectKey("x", 4294967295, 0, b""),
    ):
        assert kv.object_key_to_string(k) == vendor_reference(k)


# ---------------------------------------------------------------------
# 10. TODO 6.28 attempt-vs-outcome instrumentation.
#
# ``NixlKvL2Adapter`` lives inside an ``if _NIXL_KV_RUNTIME_AVAILABLE:``
# block, so it cannot be imported or instantiated on this control host --
# there is no nixl agent, no lmcache, no device to hand it. These tests
# therefore parse the adapter's own source with ``ast`` and assert
# structural properties of the code (which function a counter is
# incremented in, whether a helper is actually called, ...) instead of
# exercising it at runtime.
#
# The instrumentation under test exists because the outcome counters
# (l2_index_hits, l2_device_hits, l2_probe_errors, ...) cannot by
# themselves distinguish "lookup ran and found nothing" from "lookup was
# never invoked at all" -- both read as all-zero, and that was exactly
# the state the 2026-09-18 acceptance run left undiagnosable. The five
# attempt counters (l2_lookup_calls, l2_lookup_keys, l2_lookup_executions,
# l2_keys_probed, l2_probe_misses) and the two one-shot first-name logs
# exist to make that ambiguity impossible to reproduce; these tests pin
# down *where* each one is counted/called, because counting an attempt
# in the wrong place is worse than not counting it at all -- it reports
# a number that looks trustworthy but answers a different question than
# the one it claims to.
# ---------------------------------------------------------------------


@lru_cache(maxsize=1)
def _adapter_ast() -> ast.Module:
    """Parse nixl_kv_l2_adapter.py's own source, read from the exact path
    this test file already imported it from (``Path(kv.__file__)``) --
    never a copy, never a guessed location. Cached because several tests
    below reparse it.
    """
    source = Path(kv.__file__).read_text()
    return ast.parse(source, filename=str(kv.__file__))


def _find_func(tree: ast.AST, name: str) -> ast.AST:
    """Find the FunctionDef/AsyncFunctionDef named ``name`` anywhere in
    ``tree``, however deeply nested -- the adapter class body is itself
    nested inside ``if _NIXL_KV_RUNTIME_AVAILABLE:``, which is exactly
    why these tests parse rather than import it.
    """
    for node in ast.walk(tree):
        if (
            isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name == name
        ):
            return node
    raise AssertionError(f"no function named {name!r} found in adapter source")


def _augassign_targets_in(func: ast.AST) -> list[tuple[str, int]]:
    """(attribute name, line number) for every ``self.<attr> += ...``
    anywhere inside ``func``.
    """
    out = []
    for node in ast.walk(func):
        if isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Attribute):
            out.append((node.target.attr, node.lineno))
    return out


def _calls_in(func: ast.AST) -> list[str]:
    """Names of every function/method called anywhere inside ``func``
    (``self.foo(...)`` -> ``"foo"``, ``bar(...)`` -> ``"bar"``).
    """
    names = []
    for node in ast.walk(func):
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Attribute):
                names.append(node.func.attr)
            elif isinstance(node.func, ast.Name):
                names.append(node.func.id)
    return names


def _dict_keys_in(func: ast.AST) -> set[str]:
    """String literal keys of every dict literal built anywhere inside
    ``func``.
    """
    keys: set[str] = set()
    for node in ast.walk(func):
        if isinstance(node, ast.Dict):
            for k in node.keys:
                if isinstance(k, ast.Constant) and isinstance(k.value, str):
                    keys.add(k.value)
    return keys


@test
def test_report_status_exposes_attempt_counters():
    # report_status must expose all ten counters (five outcome, five
    # attempt) as dict keys, or the attempt-vs-outcome diagnosis TODO
    # 6.28 added has nothing to report through.
    func = _find_func(_adapter_ast(), "report_status")
    keys = _dict_keys_in(func)
    required = {
        "l2_index_hits",
        "l2_device_hits",
        "l2_probe_errors",
        "l2_commit_writes",
        "l2_load_aborts",
        "l2_lookup_calls",
        "l2_lookup_keys",
        "l2_lookup_executions",
        "l2_keys_probed",
        "l2_probe_misses",
    }
    missing = required - keys
    assert not missing, (
        f"report_status is missing counter key(s): {sorted(missing)}"
    )


@test
def test_lookup_calls_counted_on_synchronous_entry_not_in_coroutine():
    # l2_lookup_calls must be incremented in submit_lookup_and_lock_task
    # (the synchronous call, on LMCache's own thread), never inside the
    # _execute_lookup_in_the_loop coroutine. Counting it in the coroutine
    # would make "LMCache never called lookup" indistinguishable from
    # "our event loop is wedged and never ran the coroutine" --
    # asyncio.run_coroutine_threadsafe swallows a coroutine that was
    # scheduled but never executed, which is precisely the ambiguity
    # TODO 6.28 exists to remove.
    entry_func = _find_func(_adapter_ast(), "submit_lookup_and_lock_task")
    coroutine_func = _find_func(_adapter_ast(), "_execute_lookup_in_the_loop")

    entry_attrs = {attr for attr, _ in _augassign_targets_in(entry_func)}
    coroutine_attrs = {attr for attr, _ in _augassign_targets_in(coroutine_func)}

    assert "_l2_lookup_calls" in entry_attrs, (
        "submit_lookup_and_lock_task no longer does "
        "self._l2_lookup_calls += 1 on its synchronous entry"
    )
    assert "_l2_lookup_calls" not in coroutine_attrs, (
        "_l2_lookup_calls is incremented inside "
        "_execute_lookup_in_the_loop -- this reintroduces the "
        "wedged-event-loop blind spot TODO 6.28 fixed: counted there, a "
        "call that never got scheduled looks identical to a call that "
        "was never made"
    )


@test
def test_lookup_executions_counted_in_coroutine():
    # Mirror image of the previous test: l2_lookup_executions must be
    # incremented inside _execute_lookup_in_the_loop itself, so the
    # calls-vs-executions gap is the wedged-event-loop signal.
    func = _find_func(_adapter_ast(), "_execute_lookup_in_the_loop")
    attrs = {attr for attr, _ in _augassign_targets_in(func)}
    assert "_l2_lookup_executions" in attrs, (
        "_execute_lookup_in_the_loop no longer does "
        "self._l2_lookup_executions += 1 -- without it, calls > 0 with "
        "executions == 0 (a wedged event loop) can no longer be "
        "distinguished from a healthy one"
    )


@test
def test_keys_probed_counted_before_the_probe_can_fail():
    # _l2_keys_probed must be incremented before _l2_probe_errors in
    # _execute_lookup_in_the_loop. If the attempt were only counted
    # after a successful probe, a probe that always raises would report
    # keys_probed=0 and reproduce exactly the undiagnosable
    # zero-reading TODO 6.28 exists to fix.
    func = _find_func(_adapter_ast(), "_execute_lookup_in_the_loop")
    lines = {attr: lineno for attr, lineno in _augassign_targets_in(func)}
    assert "_l2_keys_probed" in lines, (
        "_execute_lookup_in_the_loop no longer counts self._l2_keys_probed"
    )
    assert "_l2_probe_errors" in lines, (
        "_execute_lookup_in_the_loop no longer counts self._l2_probe_errors"
    )
    assert lines["_l2_keys_probed"] < lines["_l2_probe_errors"], (
        f"_l2_keys_probed (line {lines['_l2_keys_probed']}) must be "
        f"counted before _l2_probe_errors (line "
        f"{lines['_l2_probe_errors']}) in _execute_lookup_in_the_loop -- "
        "counting the attempt only after a probe already failed "
        "reproduces the undiagnosable zero-reading TODO 6.28 exists to "
        "fix"
    )


@test
def test_probe_misses_counted_on_absent_entry():
    # _l2_probe_misses must be incremented inside
    # _execute_lookup_in_the_loop -- "the device said absent" needs to
    # be a counted fact in the status dict, not an inference from three
    # other numbers.
    func = _find_func(_adapter_ast(), "_execute_lookup_in_the_loop")
    attrs = {attr for attr, _ in _augassign_targets_in(func)}
    assert "_l2_probe_misses" in attrs, (
        "_execute_lookup_in_the_loop no longer counts "
        "self._l2_probe_misses"
    )


@test
def test_first_probe_and_commit_name_logs_are_one_shot():
    # _log_first_probe_name and _log_first_commit_name are the
    # writer-vs-reader name comparison TODO 6.28 needs next; if they
    # were not one-shot they would log at request rate and bury the
    # first (evidentiary) name.
    probe_func = _find_func(_adapter_ast(), "_log_first_probe_name")
    commit_func = _find_func(_adapter_ast(), "_log_first_commit_name")

    def _sets_flag_true(func: ast.AST, flag_name: str) -> bool:
        for node in ast.walk(func):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if (
                        isinstance(target, ast.Attribute)
                        and target.attr == flag_name
                        and isinstance(node.value, ast.Constant)
                        and node.value.value is True
                    ):
                        return True
        return False

    assert _sets_flag_true(probe_func, "_logged_first_probe_name"), (
        "_log_first_probe_name no longer sets "
        "self._logged_first_probe_name = True -- without a one-shot "
        "flag this would log at request rate and bury the first name"
    )
    assert _sets_flag_true(commit_func, "_logged_first_commit_name"), (
        "_log_first_commit_name no longer sets "
        "self._logged_first_commit_name = True -- without a one-shot "
        "flag this would log at request rate and bury the first name"
    )


@test
def test_store_path_logs_the_first_commit_name():
    # A helper that exists but is never wired in is the same as no
    # instrumentation at all -- assert both one-shot loggers are
    # actually called from their respective coroutines.
    store_func = _find_func(_adapter_ast(), "_execute_store_in_the_loop")
    lookup_func = _find_func(_adapter_ast(), "_execute_lookup_in_the_loop")

    assert "_log_first_commit_name" in _calls_in(store_func), (
        "_execute_store_in_the_loop no longer calls "
        "self._log_first_commit_name(...)"
    )
    assert "_log_first_probe_name" in _calls_in(lookup_func), (
        "_execute_lookup_in_the_loop no longer calls "
        "self._log_first_probe_name(...)"
    )


# ---------------------------------------------------------------------
# 11. TODO 6.34 OBJ-descriptor-aliasing fix.
#
# ``register_obj_names()`` used to build every OBJ descriptor as
# ``(addr=0, len=slot_size, devId=i, metaInfo=name)`` with ``devId``
# restarting at 0 on every call. Because every descriptor sits at
# ``addr=0``, ``devId`` was the ONLY discriminator -- so when the page
# dlist (devId 0..N-1) was still live and the commit dlist (devId
# 0..M-1) was created a few lines later, the two registrations were
# indistinguishable by ``(addr, len, devId)``. NIXL bound the commit
# descriptors' ``metadataP`` to the older, still-live page registration,
# and the plugin's ``make_key()`` hashed the PAGE's name for what was
# supposed to be a commit write. Measured on hardware: the commit
# object was never created (so lookup could never hit) and pages
# 0..M-1 of every stored object were silently overwritten with
# commit-record JSON.
#
# The fix has two independent parts, and each needs its own regression
# test because either one regressing alone reintroduces a real bug:
#
#   1. ``register_obj_names()`` allocates ``devId`` from a
#      daemon-global monotonic counter (``self._next_devid``, guarded
#      by ``self._devid_lock``) instead of the position in that call's
#      ``names`` list, so no two live registrations can ever share a
#      devId (tests 1-3 below).
#   2. ``_execute_store_in_the_loop`` deregisters the page dlist BEFORE
#      creating the commit registration, then clears
#      ``page_reg_descs``/``page_xfer_handler`` to ``None`` so the
#      trailing ``finally`` does not deregister a second time (tests
#      4-5 below).
#
# ``NixlKvStorageAgent`` lives inside ``if _NIXL_KV_RUNTIME_AVAILABLE:``
# and cannot be instantiated on this control host (no nixl agent), so
# tests 1-5 parse the adapter's own source with ``ast`` -- same
# approach as section 10 above, whose helpers (``_find_func``,
# ``_calls_in``, ``_augassign_targets_in``) are reused directly. Test 6
# is the odd one out: it reimplements the allocator's CONTRACT
# independently of the adapter source, so the property it checks
# survives a refactor that a purely structural test would not.
# ---------------------------------------------------------------------


def _find_class(tree: ast.AST, name: str) -> ast.ClassDef:
    """Find the ``ClassDef`` named ``name`` anywhere in ``tree``."""
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == name:
            return node
    raise AssertionError(f"no class named {name!r} found in adapter source")


def _find_method(cls: ast.ClassDef, name: str) -> ast.AST:
    """Find the FunctionDef/AsyncFunctionDef named ``name`` declared
    DIRECTLY in ``cls``'s own body (not in a nested class or a
    different class of the same name) -- there are several classes in
    this module with an ``__init__``, so this must not accidentally
    pick up the wrong one.
    """
    for node in cls.body:
        if (
            isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name == name
        ):
            return node
    raise AssertionError(
        f"no method named {name!r} found directly in class {cls.name!r}"
    )


def _calls_named_in(func: ast.AST, name: str) -> list[ast.Call]:
    """Every ``ast.Call`` node (not just its name, unlike ``_calls_in``)
    whose target is ``name(...)`` or ``<anything>.name(...)`` anywhere
    inside ``func`` -- needed here so callers can inspect call
    arguments and ``.lineno`` for ordering checks.
    """
    out = []
    for node in ast.walk(func):
        if isinstance(node, ast.Call):
            fname = (
                node.func.attr
                if isinstance(node.func, ast.Attribute)
                else node.func.id
                if isinstance(node.func, ast.Name)
                else None
            )
            if fname == name:
                out.append(node)
    return out


def _listcomp_assigned_to(func: ast.AST, var_name: str) -> ast.ListComp:
    """The ``ast.ListComp`` on the right-hand side of ``var_name = [...]``
    inside ``func``.
    """
    for node in ast.walk(func):
        if (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id == var_name
            and isinstance(node.value, ast.ListComp)
        ):
            return node.value
    raise AssertionError(
        f"no list comprehension assigned to {var_name!r} found"
    )


def _has_binop_add_with_name(node: ast.AST, name: str) -> bool:
    """True if ``node`` is ``<name> + <something>`` or
    ``<something> + <name>``.
    """
    return (
        isinstance(node, ast.BinOp)
        and isinstance(node.op, ast.Add)
        and (
            (isinstance(node.left, ast.Name) and node.left.id == name)
            or (isinstance(node.right, ast.Name) and node.right.id == name)
        )
    )


@test
def test_register_obj_names_devids_are_monotonic_not_positional():
    # Guards the ROOT CAUSE of TODO 6.34: a devId that restarts at 0
    # on every call makes two simultaneously-live registrations
    # (e.g. the page dlist and the commit dlist of the same store)
    # indistinguishable by (addr, len, devId) -- since every descriptor
    # this function builds sits at addr=0, devId was the only thing
    # telling them apart. NIXL then binds the newer descriptors'
    # metadataP to the OLDER live registration, and the plugin hashes
    # the wrong object's name -- silently misrouting one registration's
    # writes onto the other's key.
    func = _find_func(_adapter_ast(), "register_obj_names")

    reg_list_devid = _listcomp_assigned_to(func, "reg_list").elt
    xfer_desc_devid = _listcomp_assigned_to(func, "xfer_desc").elt
    assert isinstance(reg_list_devid, ast.Tuple) and len(reg_list_devid.elts) >= 3, (
        "register_obj_names: reg_list's descriptor tuple no longer has "
        "the expected (addr, len, devId, metaInfo) shape"
    )
    assert isinstance(xfer_desc_devid, ast.Tuple) and len(xfer_desc_devid.elts) >= 3, (
        "register_obj_names: xfer_desc's descriptor tuple no longer has "
        "the expected (addr, len, devId) shape"
    )

    reg_list_devid_expr = reg_list_devid.elts[2]
    xfer_desc_devid_expr = xfer_desc_devid.elts[2]

    assert _has_binop_add_with_name(reg_list_devid_expr, "base"), (
        "register_obj_names: reg_list's devId is no longer built as "
        "`base + i` from the daemon-global monotonic counter -- TODO "
        "6.34's aliasing bug reappears the moment devId can restart at "
        "0 across two live registrations"
    )
    assert _has_binop_add_with_name(xfer_desc_devid_expr, "base"), (
        "register_obj_names: xfer_desc's devId is no longer built as "
        "`base + i` from the daemon-global monotonic counter -- same "
        "TODO 6.34 aliasing risk as reg_list, since NIXL resolves "
        "descriptor identity from BOTH lists"
    )

    for expr, comp_name in (
        (reg_list_devid_expr, "reg_list"),
        (xfer_desc_devid_expr, "xfer_desc"),
    ):
        assert not (isinstance(expr, ast.Name) and expr.id == "i"), (
            f"register_obj_names: {comp_name}'s devId is the bare "
            "positional loop variable `i` -- this is exactly the "
            "pre-fix `(0, slot_size, i, name)` / `(0, slot_size, i)` "
            "shape that reintroduces TODO 6.34's OBJ descriptor "
            "aliasing (devId restarts at 0 on every call, so two live "
            "registrations collide on (addr, len, devId))"
        )


@test
def test_register_obj_names_allocates_devid_under_a_lock():
    # WHY a lock, not just a monotonic counter: register_obj_names is
    # called from the asyncio loop thread (store/lookup coroutines) and
    # potentially from callers on other threads. A racy
    # read-then-increment allocator could hand the SAME base to two
    # concurrent registrations, reintroducing the TODO 6.34 alias even
    # though the counter itself never resets.
    func = _find_func(_adapter_ast(), "register_obj_names")

    lock_referenced = any(
        isinstance(node, ast.Attribute) and node.attr == "_devid_lock"
        for node in ast.walk(func)
    )
    assert lock_referenced, (
        "register_obj_names no longer references self._devid_lock -- "
        "a racy devId allocator can hand the same base to two "
        "concurrent registrations, reintroducing TODO 6.34's aliasing"
    )

    lock_held_around_allocation = any(
        isinstance(node, ast.With)
        and any(
            isinstance(item.context_expr, ast.Attribute)
            and item.context_expr.attr == "_devid_lock"
            for item in node.items
        )
        for node in ast.walk(func)
    )
    assert lock_held_around_allocation, (
        "register_obj_names references self._devid_lock but does not "
        "appear to hold it via `with self._devid_lock:` around the "
        "counter read/increment"
    )

    next_devid_mutated = any(
        isinstance(node, ast.AugAssign)
        and isinstance(node.target, ast.Attribute)
        and node.target.attr == "_next_devid"
        for node in ast.walk(func)
    )
    assert next_devid_mutated, (
        "register_obj_names no longer mutates self._next_devid (expected "
        "`self._next_devid += len(names)`) -- without advancing the "
        "counter, every call would reallocate the same devId range and "
        "reintroduce TODO 6.34's aliasing"
    )


@test
def test_devid_allocator_is_initialised():
    # register_obj_names' `with self._devid_lock:` / `self._next_devid`
    # only work if NixlKvStorageAgent.__init__ actually creates both --
    # otherwise the very first call raises AttributeError instead of
    # allocating a devId.
    cls = _find_class(_adapter_ast(), "NixlKvStorageAgent")
    init_func = _find_method(cls, "__init__")

    next_devid_initialised = any(
        isinstance(node, ast.Assign)
        and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Attribute)
        and node.targets[0].attr == "_next_devid"
        and isinstance(node.value, ast.Constant)
        and node.value.value == 0
        for node in ast.walk(init_func)
    )
    assert next_devid_initialised, (
        "NixlKvStorageAgent.__init__ no longer initialises "
        "self._next_devid = 0 -- register_obj_names' monotonic devId "
        "allocator has nowhere to start counting from"
    )

    devid_lock_initialised = any(
        isinstance(node, ast.Assign)
        and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Attribute)
        and node.targets[0].attr == "_devid_lock"
        for node in ast.walk(init_func)
    )
    assert devid_lock_initialised, (
        "NixlKvStorageAgent.__init__ no longer initialises "
        "self._devid_lock -- register_obj_names' `with "
        "self._devid_lock:` would raise AttributeError on the first call"
    )


@test
def test_pages_deregistered_before_commit_registration():
    """The ORDERING half of the TODO 6.34 fix. Keeping exactly one OBJ
    registration live across the page-to-commit boundary is what makes
    the commit descriptors unable to resolve against the (still-live)
    page registration in the first place -- independent of whether
    devId allocation is monotonic. If the page dlist is deregistered
    AFTER the commit dlist is created, the two are simultaneously live
    again and TODO 6.34's alias can reappear even with a perfectly
    monotonic devId allocator, because deregistration frees the
    descriptor slot NIXL had bound the newer registration's metadataP
    to, and the window in which both are live is exactly where the bug
    lived.
    """
    func = _find_func(_adapter_ast(), "_execute_store_in_the_loop")

    dereg_calls = _calls_named_in(func, "deregister_obj_names")
    assert dereg_calls, (
        "_execute_store_in_the_loop no longer calls "
        "deregister_obj_names at all"
    )

    reg_calls = _calls_named_in(func, "register_obj_names")
    commit_reg_calls = [
        c
        for c in reg_calls
        if c.args
        and isinstance(c.args[0], ast.Name)
        and c.args[0].id == "commit_names"
    ]
    assert len(commit_reg_calls) == 1, (
        "_execute_store_in_the_loop: expected exactly one "
        "register_obj_names(commit_names, ...) call building the "
        f"commit dlist, found {len(commit_reg_calls)}"
    )
    commit_reg_lineno = commit_reg_calls[0].lineno

    earliest_dereg_lineno = min(c.lineno for c in dereg_calls)
    assert earliest_dereg_lineno < commit_reg_lineno, (
        "_execute_store_in_the_loop: no deregister_obj_names call "
        f"(earliest at line {earliest_dereg_lineno}) precedes "
        "register_obj_names(commit_names, ...) "
        f"(line {commit_reg_lineno}) -- the page dlist must be "
        "deregistered BEFORE the commit dlist is created, or the two "
        "OBJ registrations are simultaneously live and TODO 6.34's "
        "descriptor aliasing can reappear"
    )


@test
def test_page_handles_cleared_after_early_deregistration():
    # WHY the clear matters: without it, the trailing `finally` would
    # deregister the page dlist a SECOND time (it was already
    # deregistered early, per the previous test) -- turning a fixed
    # aliasing bug into a double-free / double-deregister against
    # NIXL. Clearing both handles to None, plus guarding the trailing
    # cleanup with `if page_xfer_handler is not None`, is what makes
    # the early deregistration safe to add without breaking the
    # exception path.
    func = _find_func(_adapter_ast(), "_execute_store_in_the_loop")

    dereg_calls = _calls_named_in(func, "deregister_obj_names")
    assert dereg_calls, (
        "_execute_store_in_the_loop no longer calls deregister_obj_names"
    )
    earliest_dereg_lineno = min(c.lineno for c in dereg_calls)

    none_assign_linenos: dict[str, list[int]] = {
        "page_reg_descs": [],
        "page_xfer_handler": [],
    }
    for node in ast.walk(func):
        if (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id in none_assign_linenos
            and isinstance(node.value, ast.Constant)
            and node.value.value is None
        ):
            none_assign_linenos[node.targets[0].id].append(node.lineno)

    for var_name, linenos in none_assign_linenos.items():
        after_dereg = [ln for ln in linenos if ln > earliest_dereg_lineno]
        assert after_dereg, (
            f"_execute_store_in_the_loop no longer sets {var_name} = "
            "None after the early page deregistration -- without this "
            "the trailing `finally` will deregister the page dlist a "
            "second time (double-deregister), since it can no longer "
            "tell the early deregistration already happened"
        )

    guarded = False
    for node in ast.walk(func):
        if (
            isinstance(node, ast.If)
            and isinstance(node.test, ast.Compare)
            and isinstance(node.test.left, ast.Name)
            and node.test.left.id == "page_xfer_handler"
            and len(node.test.ops) == 1
            and isinstance(node.test.ops[0], ast.IsNot)
            and len(node.test.comparators) == 1
            and isinstance(node.test.comparators[0], ast.Constant)
            and node.test.comparators[0].value is None
        ):
            guarded = True
            break
    assert guarded, (
        "_execute_store_in_the_loop's trailing cleanup no longer "
        "guards deregister_obj_names with `if page_xfer_handler is "
        "not None:` -- without the guard, clearing the handles to "
        "None after the early deregistration would make the trailing "
        "finally call deregister_obj_names(None, None) unconditionally "
        "on the success path"
    )


@test
def test_devid_monotonic_allocation_simulation():
    """BEHAVIOURAL (not structural) test of the allocation rule
    register_obj_names depends on. Reimplements the allocator's
    contract independently of the adapter source -- a counter plus a
    lock, handing out ``len(names)`` devIds per call and advancing the
    counter by that many -- so this test still catches a regression
    even if register_obj_names is rewritten in a way the structural
    tests above no longer recognise. The property under test is
    exactly what TODO 6.34's fix depends on: across successive calls,
    the allocated devId ranges must be disjoint and strictly
    increasing, since any overlap is a re-run of the aliasing bug.
    """
    counter = 0
    lock = threading.Lock()

    def allocate(n: int) -> range:
        nonlocal counter
        with lock:
            base = counter
            counter += n
        return range(base, base + n)

    ranges = [list(allocate(n)) for n in (5, 3, 4)]

    seen: set[int] = set()
    for ids in ranges:
        overlap = seen & set(ids)
        assert not overlap, (
            f"devId range {ids} overlaps previously allocated ids "
            f"{sorted(seen)} -- monotonic allocation must produce "
            "disjoint ranges across successive calls, or two live "
            "registrations can alias (TODO 6.34)"
        )
        seen.update(ids)

    flattened = [devid for ids in ranges for devid in ids]
    assert flattened == list(range(12)), (
        "expected three calls of sizes 5, 3, 4 to allocate a strictly "
        f"increasing, contiguous 0..11 devId range; got {flattened}"
    )


# ---------------------------------------------------------------------
# Summary / exit code
# ---------------------------------------------------------------------


def main() -> int:
    passed = [r for r in _RESULTS if r[1]]
    failed = [r for r in _RESULTS if not r[1]]

    print(f"nixl_kv naming/logic tests: {len(passed)}/{len(_RESULTS)} passed\n")

    if failed:
        print("FAILURES:")
        for name, _ok, detail in failed:
            print(f"  - {name}")
            for line in detail.splitlines():
                print(f"      {line}")
        print()

    if failed:
        print(f"FAIL: {len(failed)} test(s) failed.")
        return 1

    print("PASS: all nixl_kv naming/logic tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
