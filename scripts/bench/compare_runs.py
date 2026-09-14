#!/usr/bin/env python3
"""compare_runs.py — compare two or more llama-benchy result.json files.

Pure stdlib (json, argparse, statistics, os, sys) — no llama-benchy import,
no requirement that the machine running this comparison has llama-benchy
(or even python's ML stack) installed. It only ever reads the JSON output
llama-benchy already wrote to disk.

Two independent modes:

  Default (multi-run comparison): join benchmark entries across 2+ runs on
  (concurrency, context_size, prompt_size, response_size,
  is_context_prefill_phase) and report each run's mean +/- std against a
  chosen baseline run, per metric, with a delta, a ratio, and a
  significance marker.

  --prefix-benefit: within a SINGLE run's result.json, pair every
  depth>0 ("warm") row against its depth==0 ("cold") counterpart at the
  same (concurrency, prompt_size, response_size) and report the speedup.
  This is the one number that answers "did the remote KV cache on SMC3
  actually help" — see docs/BENCHMARKING.md.

WHY the significance marker exists at all: a benchmark run's mean is a
single point estimate over --runs samples: it always looks like SOME
number changed between two runs, even when nothing did. Marking a row `*`
only when the magnitude of the difference between the two means exceeds
the SUM of their standard deviations is a deliberately simple, deliberately
conservative bar (not a rigorous statistical test — no t-test, no
confidence interval, no correction for multiple comparisons) chosen
because it is auditable by eye from the printed numbers alone: a reader
can verify `|Δmean| > (std_a + std_b)` themselves without trusting this
script's math. A 5% difference sitting inside both runs' own noise band is
not a result — it is two noisy measurements of the same number.

Schema drift / missing metrics: llama-benchy's JSON schema is versioned
(top-level "version" field) and this script was written against v0.4.0 as
documented in the task that produced it, not against a live installed copy
this repo has verified. Every field access below therefore goes through
.get() with a None default and every downstream computation checks for
None before doing arithmetic — an absent or renamed field degrades a
single cell to "N/A", never a crash.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import statistics
import sys
from typing import Any

METRICS: list[str] = [
    "est_ppt",
    "e2e_ttft",
    "ttfr",
    "pp_throughput",
    "tg_throughput",
    "peak_throughput",
]

KEY_FIELDS: tuple[str, ...] = (
    "concurrency",
    "context_size",
    "prompt_size",
    "response_size",
    "is_context_prefill_phase",
)


# ─────────────────────────────────────────────────────────────────────────────
# Loading
# ─────────────────────────────────────────────────────────────────────────────
def resolve_result_path(path: str) -> str:
    """Accept either a result.json file directly or a run directory
    (scripts/bench/lib-bench.sh's benchy_run creates
    <BENCHY_RESULT_DIR>/<timestamp>-<label>/result.json) containing one.
    """
    if os.path.isdir(path):
        candidate = os.path.join(path, "result.json")
        if os.path.isfile(candidate):
            return candidate
        raise FileNotFoundError(
            f"{path} is a directory but contains no result.json"
        )
    return path


def load_run(path: str) -> dict[str, Any]:
    resolved = resolve_result_path(path)
    with open(resolved, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{resolved}: expected a JSON object at the top level, got {type(data).__name__}")
    data.setdefault("benchmarks", [])
    if not isinstance(data["benchmarks"], list):
        raise ValueError(f"{resolved}: 'benchmarks' is not a list (schema drift?)")
    data["_source_path"] = resolved
    return data


def run_label(run: dict[str, Any], index: int) -> str:
    """Best-effort human label for a run in table headers. Falls back
    through several plausible identifying fields before giving up to a
    positional index — never crashes on an absent field.
    """
    src = run.get("_source_path")
    if src:
        parent = os.path.basename(os.path.dirname(src)) or src
        return parent
    ts = run.get("timestamp")
    if ts:
        return str(ts)
    return f"run{index}"


# ─────────────────────────────────────────────────────────────────────────────
# Entry access — tolerant of schema drift throughout.
# ─────────────────────────────────────────────────────────────────────────────
def entry_key(entry: dict[str, Any]) -> tuple:
    return tuple(entry.get(f) for f in KEY_FIELDS)


def format_key(key: tuple) -> str:
    parts = []
    for field, val in zip(KEY_FIELDS, key):
        parts.append(f"{field}={val if val is not None else 'NA'}")
    return " ".join(parts)


def get_stat(entry: dict[str, Any], metric: str) -> tuple[float | None, float | None]:
    """Returns (mean, std) for the given metric on this entry, or (None,
    None) if the metric is absent, malformed, or not a dict with a
    numeric 'mean'. If 'std' is absent but 'values' is present and has
    2+ samples, std is derived with statistics.pstdev as a fallback —
    llama-benchy's own reported std should always be preferred when
    present, since it may be computed over more/different samples than
    whatever 'values' happens to retain.
    """
    stat = entry.get(metric)
    if not isinstance(stat, dict):
        return None, None
    mean = stat.get("mean")
    if not isinstance(mean, (int, float)):
        return None, None
    std = stat.get("std")
    if isinstance(std, (int, float)):
        return float(mean), float(std)
    values = stat.get("values")
    if isinstance(values, list) and len(values) >= 2:
        numeric_values = [v for v in values if isinstance(v, (int, float))]
        if len(numeric_values) >= 2:
            try:
                return float(mean), float(statistics.pstdev(numeric_values))
            except statistics.StatisticsError:
                return float(mean), None
    return float(mean), None


def is_significant(delta: float | None, std_a: float | None, std_b: float | None) -> bool:
    if delta is None or std_a is None or std_b is None:
        return False
    return abs(delta) > (std_a + std_b)


def fmt_num(x: float | None, digits: int = 2) -> str:
    if x is None:
        return "NA"
    return f"{x:.{digits}f}"


def fmt_mean_std(mean: float | None, std: float | None, digits: int = 2) -> str:
    if mean is None:
        return "NA"
    if std is None:
        return f"{mean:.{digits}f} +/- NA"
    return f"{mean:.{digits}f} +/- {std:.{digits}f}"


# ─────────────────────────────────────────────────────────────────────────────
# Mode 1: multi-run comparison
# ─────────────────────────────────────────────────────────────────────────────
def build_comparison_rows(
    runs: list[dict[str, Any]], baseline_idx: int, metrics: list[str]
) -> list[dict[str, Any]]:
    """One row per (join key, metric). Only keys present in the BASELINE
    run are iterated — a key that exists in a non-baseline run but not the
    baseline has nothing to be a delta OF, so it is intentionally left out
    rather than fabricating a baseline-less comparison.
    """
    baseline = runs[baseline_idx]
    baseline_entries: dict[tuple, dict[str, Any]] = {}
    for e in baseline.get("benchmarks", []):
        if isinstance(e, dict):
            baseline_entries[entry_key(e)] = e

    other_indices = [i for i in range(len(runs)) if i != baseline_idx]
    other_entries_by_run: list[dict[tuple, dict[str, Any]]] = []
    for i in other_indices:
        idx_map: dict[tuple, dict[str, Any]] = {}
        for e in runs[i].get("benchmarks", []):
            if isinstance(e, dict):
                idx_map[entry_key(e)] = e
        other_entries_by_run.append(idx_map)

    # Metric is the OUTER loop, key the inner one — deliberately, so every
    # row for a given metric is contiguous in the output (render_comparison
    # groups by metric and starts a new table header whenever the metric
    # changes; iterating key-outer would cycle through all metrics once
    # per key, re-printing a fresh header on almost every row instead of
    # one table per metric).
    rows: list[dict[str, Any]] = []
    sorted_keys = sorted(baseline_entries.keys(), key=lambda k: tuple(str(x) for x in k))
    for metric in metrics:
        for key in sorted_keys:
            b_entry = baseline_entries[key]
            b_mean, b_std = get_stat(b_entry, metric)
            row: dict[str, Any] = {
                "key": key,
                "metric": metric,
                "baseline_mean": b_mean,
                "baseline_std": b_std,
                "others": [],
            }
            for pos, other_idx in enumerate(other_indices):
                o_entry = other_entries_by_run[pos].get(key)
                if o_entry is None:
                    row["others"].append(
                        {"run_index": other_idx, "mean": None, "std": None, "delta": None, "ratio": None, "significant": False}
                    )
                    continue
                o_mean, o_std = get_stat(o_entry, metric)
                delta = None
                ratio = None
                if b_mean is not None and o_mean is not None:
                    delta = o_mean - b_mean
                    ratio = (o_mean / b_mean) if b_mean != 0 else None
                row["others"].append(
                    {
                        "run_index": other_idx,
                        "mean": o_mean,
                        "std": o_std,
                        "delta": delta,
                        "ratio": ratio,
                        "significant": is_significant(delta, b_std, o_std),
                    }
                )
            rows.append(row)
    return rows


def render_comparison(
    runs: list[dict[str, Any]], baseline_idx: int, metrics: list[str], fmt: str
) -> str:
    rows = build_comparison_rows(runs, baseline_idx, metrics)
    labels = [run_label(r, i) for i, r in enumerate(runs)]
    baseline_label = labels[baseline_idx]
    other_indices = [i for i in range(len(runs)) if i != baseline_idx]

    if fmt == "json":
        out = {
            "baseline": baseline_label,
            "baseline_index": baseline_idx,
            "runs": labels,
            "significance_rule": "abs(delta) > (std_baseline + std_other)",
            "rows": [],
        }
        for row in rows:
            out_row = {
                "key": {f: v for f, v in zip(KEY_FIELDS, row["key"])},
                "metric": row["metric"],
                "baseline": {"mean": row["baseline_mean"], "std": row["baseline_std"]},
                "others": [],
            }
            for o in row["others"]:
                out_row["others"].append(
                    {
                        "run": labels[o["run_index"]],
                        "mean": o["mean"],
                        "std": o["std"],
                        "delta": o["delta"],
                        "ratio": o["ratio"],
                        "significant": o["significant"],
                    }
                )
            out["rows"].append(out_row)
        return json.dumps(out, indent=2)

    if fmt == "csv":
        buf = io.StringIO()
        writer = csv.writer(buf)
        header = list(KEY_FIELDS) + [
            "metric",
            f"baseline[{baseline_label}]_mean",
            f"baseline[{baseline_label}]_std",
        ]
        for oi in other_indices:
            lbl = labels[oi]
            header += [f"{lbl}_mean", f"{lbl}_std", f"{lbl}_delta", f"{lbl}_ratio", f"{lbl}_significant"]
        writer.writerow(header)
        for row in rows:
            line = list(row["key"]) + [row["metric"], row["baseline_mean"], row["baseline_std"]]
            for o in row["others"]:
                line += [o["mean"], o["std"], o["delta"], o["ratio"], o["significant"]]
            writer.writerow(line)
        return buf.getvalue()

    # md (default)
    lines: list[str] = []
    lines.append(f"# Comparison — baseline: `{baseline_label}`")
    lines.append("")
    lines.append(
        "Significance (`*`): `abs(delta) > (std_baseline + std_other)` — a"
        " conservative, eyeball-auditable bar. A row without `*` is a"
        " difference that fits inside both runs' own measurement noise and"
        " should NOT be reported as a finding on its own."
    )
    lines.append("")
    current_metric = None
    for row in rows:
        if row["metric"] != current_metric:
            current_metric = row["metric"]
            lines.append(f"## {current_metric}")
            lines.append("")
            header = list(KEY_FIELDS) + [f"baseline[{baseline_label}]"]
            for oi in other_indices:
                header.append(labels[oi])
            lines.append("| " + " | ".join(header) + " |")
            lines.append("|" + "---|" * len(header))
        cells = [str(v) if v is not None else "NA" for v in row["key"]]
        cells.append(fmt_mean_std(row["baseline_mean"], row["baseline_std"]))
        for o in row["others"]:
            marker = "*" if o["significant"] else ""
            cell = fmt_mean_std(o["mean"], o["std"])
            if o["delta"] is not None:
                cell += f" (d={fmt_num(o['delta'])}, x{fmt_num(o['ratio'], 3) if o['ratio'] is not None else 'NA'}){marker}"
            cells.append(cell)
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n"


# ─────────────────────────────────────────────────────────────────────────────
# Mode 2: --prefix-benefit — within a single run, cold vs warm
# ─────────────────────────────────────────────────────────────────────────────
def build_prefix_benefit_rows(run: dict[str, Any], metrics: list[str]) -> list[dict[str, Any]]:
    """Cold row: context_size in (0, None) AND is_context_prefill_phase is
    falsy (that combination is the plain, no-cache-context inference
    request — llama-benchy's `pp{n}` row). Warm row: context_size > 0 AND
    is_context_prefill_phase is falsy (the `pp{n} @ d{N}` inference row
    that SHOULD hit the cache staged by the paired `ctx_pp @ d{N}` row).
    Rows where is_context_prefill_phase is truthy are the context-LOAD
    step itself (`ctx_pp @ d{N}`) and are deliberately excluded from both
    sides: that phase is the prefill node populating the cache, not a
    user-facing request, so it is not a fair point of comparison against
    a cold inference request.
    """
    entries = [e for e in run.get("benchmarks", []) if isinstance(e, dict)]

    def is_ctx_phase(e: dict[str, Any]) -> bool:
        return bool(e.get("is_context_prefill_phase"))

    def match_key(e: dict[str, Any]) -> tuple:
        return (e.get("concurrency"), e.get("prompt_size"), e.get("response_size"))

    cold_index: dict[tuple, dict[str, Any]] = {}
    for e in entries:
        ctx = e.get("context_size")
        if (ctx is None or ctx == 0) and not is_ctx_phase(e):
            cold_index[match_key(e)] = e

    rows: list[dict[str, Any]] = []
    for e in entries:
        ctx = e.get("context_size")
        if ctx is None or ctx == 0 or is_ctx_phase(e):
            continue
        cold = cold_index.get(match_key(e))
        row: dict[str, Any] = {
            "concurrency": e.get("concurrency"),
            "prompt_size": e.get("prompt_size"),
            "response_size": e.get("response_size"),
            "depth": ctx,
            "metrics": {},
        }
        if cold is None:
            row["cold_missing"] = True
            rows.append(row)
            continue
        for metric in metrics:
            cold_mean, cold_std = get_stat(cold, metric)
            warm_mean, warm_std = get_stat(e, metric)
            speedup = None
            delta = None
            if cold_mean is not None and warm_mean is not None:
                delta = cold_mean - warm_mean
                speedup = (cold_mean / warm_mean) if warm_mean != 0 else None
            row["metrics"][metric] = {
                "cold_mean": cold_mean,
                "cold_std": cold_std,
                "warm_mean": warm_mean,
                "warm_std": warm_std,
                "delta": delta,
                "speedup": speedup,
                "significant": is_significant(delta, cold_std, warm_std),
            }
        rows.append(row)
    return rows


def render_prefix_benefit(run: dict[str, Any], metrics: list[str], fmt: str, label: str) -> str:
    rows = build_prefix_benefit_rows(run, metrics)

    if fmt == "json":
        return json.dumps({"run": label, "rows": rows}, indent=2)

    if fmt == "csv":
        buf = io.StringIO()
        writer = csv.writer(buf)
        header = ["concurrency", "prompt_size", "response_size", "depth", "metric",
                  "cold_mean", "cold_std", "warm_mean", "warm_std", "delta", "speedup", "significant"]
        writer.writerow(header)
        for row in rows:
            if row.get("cold_missing"):
                writer.writerow([row["concurrency"], row["prompt_size"], row["response_size"],
                                  row["depth"], "ALL", "NA", "NA", "NA", "NA", "NA", "NA", "FALSE"])
                continue
            for metric, m in row["metrics"].items():
                writer.writerow([
                    row["concurrency"], row["prompt_size"], row["response_size"], row["depth"],
                    metric, m["cold_mean"], m["cold_std"], m["warm_mean"], m["warm_std"],
                    m["delta"], m["speedup"], m["significant"],
                ])
        return buf.getvalue()

    # md (default)
    lines: list[str] = []
    lines.append(f"# Prefix-cache benefit — run: `{label}`")
    lines.append("")
    lines.append(
        "`speedup = cold_est_ppt_mean / warm_est_ppt_mean` (and equivalently"
        " for the other latency metrics) — >1 means the warm (cached)"
        " request was faster than the cold one at the same"
        " (concurrency, prompt_size, response_size). This is the single"
        " number answering: did the remote KV cache on SMC3 actually help."
    )
    lines.append("")
    header = ["concurrency", "prompt_size", "response_size", "depth"]
    for metric in metrics:
        header.append(f"{metric} cold")
        header.append(f"{metric} warm")
        header.append(f"{metric} speedup")
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "---|" * len(header))
    for row in rows:
        cells = [str(row["concurrency"]), str(row["prompt_size"]), str(row["response_size"]), str(row["depth"])]
        if row.get("cold_missing"):
            cells += ["NO MATCHING COLD ROW"] * (len(header) - len(cells))
            lines.append("| " + " | ".join(cells) + " |")
            continue
        for metric in metrics:
            m = row["metrics"][metric]
            marker = "*" if m["significant"] else ""
            cells.append(fmt_mean_std(m["cold_mean"], m["cold_std"]))
            cells.append(fmt_mean_std(m["warm_mean"], m["warm_std"]))
            speedup_str = fmt_num(m["speedup"], 3) if m["speedup"] is not None else "NA"
            cells.append(f"{speedup_str}x{marker}")
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n"


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────
def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "files",
        nargs="+",
        help="2+ result.json files (or run directories containing one) for"
             " comparison mode; 1+ for --prefix-benefit mode",
    )
    parser.add_argument(
        "--metric",
        action="append",
        dest="metrics",
        choices=METRICS,
        help=f"metric to report (repeatable). Default: all of {METRICS}",
    )
    parser.add_argument(
        "--format",
        choices=["md", "csv", "json"],
        default="md",
        help="output format (default: md)",
    )
    parser.add_argument(
        "--baseline",
        type=int,
        default=0,
        metavar="IDX",
        help="index (0-based) into 'files' to use as the comparison baseline (default: 0)",
    )
    parser.add_argument(
        "--prefix-benefit",
        action="store_true",
        help="within each result.json, pair depth>0 (warm) rows against"
             " their depth==0 (cold) counterpart and report the speedup",
    )
    args = parser.parse_args(argv)

    metrics = args.metrics or list(METRICS)

    runs: list[dict[str, Any]] = []
    for path in args.files:
        try:
            runs.append(load_run(path))
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            print(f"error loading {path}: {exc}", file=sys.stderr)
            return 1

    if args.prefix_benefit:
        outputs = []
        for i, run in enumerate(runs):
            label = run_label(run, i)
            outputs.append(render_prefix_benefit(run, metrics, args.format, label))
        sep = "\n" if args.format == "md" else "\n---\n"
        print(sep.join(outputs))
        return 0

    if len(runs) < 2:
        print(
            "warning: comparison mode normally takes 2+ files; with only 1,"
            " every delta/ratio/significance column will be NA (there is"
            " nothing to compare against). Use --prefix-benefit if you meant"
            " to compare cold vs warm rows WITHIN this one file.",
            file=sys.stderr,
        )

    if args.baseline < 0 or args.baseline >= len(runs):
        print(
            f"error: --baseline={args.baseline} is out of range for {len(runs)} file(s)",
            file=sys.stderr,
        )
        return 1

    print(render_comparison(runs, args.baseline, metrics, args.format))
    return 0


if __name__ == "__main__":
    sys.exit(main())
