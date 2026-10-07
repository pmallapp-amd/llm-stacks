"""test_nixl_kv_naming.py — pins the exact on-device naming format produced
by nixl_kv_l2_adapter.py (design doc §4). This is this adapter's persistence
format: the backend has no delete primitive, so a silent change here makes
every object already on the device unreachable at once. Run with:

    python3 -m pytest overlays/lmcache/test_nixl_kv_naming.py -v

No NIXL, no lmcache, no device required — these are pure functions.
"""
from __future__ import annotations

import dataclasses

import pytest

from nixl_kv_l2_adapter import (
    commit_name,
    object_key_to_string,
    page_name,
    validate_namespace,
)


@dataclasses.dataclass
class _FakeObjectKey:
    model_name: str
    kv_rank: int
    object_group_id: int
    chunk_hash: bytes
    cache_salt: str = ""


def test_object_key_to_string_exact_bytes():
    key = _FakeObjectKey(
        model_name="Qwen3-8B",
        kv_rank=1,
        object_group_id=255,
        chunk_hash=b"\xde\xad\xbe\xef",
    )
    assert object_key_to_string(key) == "Qwen3-8B@00000001@ff@deadbeef"


def test_object_key_to_string_includes_cache_salt_when_present():
    key = _FakeObjectKey(
        model_name="Qwen3-8B",
        kv_rank=0,
        object_group_id=1,
        chunk_hash=b"\x01",
        cache_salt="seed7",
    )
    assert object_key_to_string(key) == "Qwen3-8B@00000000@1@01@seed7"


def test_object_key_to_string_omits_empty_cache_salt():
    key = _FakeObjectKey(
        model_name="m", kv_rank=0, object_group_id=0, chunk_hash=b"\x00",
    )
    assert object_key_to_string(key) == "m@00000000@0@00"


def test_object_key_to_string_rejects_reserved_chars_in_field():
    key = _FakeObjectKey(
        model_name="bad@name", kv_rank=0, object_group_id=0, chunk_hash=b"\x00",
    )
    with pytest.raises(ValueError):
        object_key_to_string(key)


def test_page_name_uses_tilde_ordinal():
    assert page_name("ns1", "obj", 0) == "ns1@obj~0"
    assert page_name("ns1", "obj", 9215) == "ns1@obj~9215"


def test_commit_name_uses_bang_c_suffix():
    assert commit_name("ns1", "obj") == "ns1@obj!c"


def test_page_and_commit_names_never_collide():
    # ~ (tile ordinal) and !c (commit suffix) must be unambiguous against
    # each other and against patch 0007's own '#' sub-split scheme.
    names = {page_name("ns", "obj", i) for i in range(16)}
    names.add(commit_name("ns", "obj"))
    assert len(names) == 17


@pytest.mark.parametrize("bad_ns", ["has@at", "has~tilde", "has!bang", ""])
def test_validate_namespace_rejects_reserved_chars_and_empty(bad_ns):
    with pytest.raises(ValueError):
        validate_namespace(bad_ns)


def test_validate_namespace_accepts_plain_hex():
    validate_namespace("deadbeefcafe")
