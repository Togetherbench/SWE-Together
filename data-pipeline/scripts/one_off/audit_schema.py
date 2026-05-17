#!/usr/bin/env python3
"""Schema audit over canonical-patch JSON artifacts.

Two layers are scanned:
  1. Source layer   - data-pipeline/artifacts_<source>/canonical_patches/*.json
  2. Reference layer- harbor_tasks/<task>/reference_patch.json

For each file, we tally:
  * top-level keys (frequency, observed value types, presence per layer)
  * value distribution for critical enum-ish fields:
      _fidelity, _extraction.method, _reliability.status,
      _status, _category, _curation_method, _source
  * format of `files_changed` and `numstat` (name-status vs numstat vs bare path)
  * shape of `_review` sub-block
  * cross-name aliasing across keys with the same semantic role
  * the SWE-bench-style fields (FAIL_TO_PASS / PASS_TO_PASS / base_commit / patch)
    so we can size the gap from current state -> SWE-bench-compatible.

Output: machine-readable JSON to stdout (also writes audit_schema_result.json
next to the script), plus a short human summary.

Re-runnable. No mutations.
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
SOURCE_GLOB = "data-pipeline/artifacts_*/canonical_patches/*.json"
REFERENCE_GLOB = "harbor_tasks/*/reference_patch.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

NAMESTATUS_RE = re.compile(r"^[AMDRCTU][0-9]*\t")  # M\tpath, R100\told\tnew
NUMSTAT_RE = re.compile(r"^[0-9-]+\t[0-9-]+\t")     # 3\t1\tpath, -\t-\tbinary
PATH_ONLY_RE = re.compile(r"^[^\t]+$")

CRITICAL_FIELDS = [
    "_fidelity",
    "_status",
    "_category",
    "_source",
    "_reconstruction",
    "_curation_method",
]


def jtype(v: Any) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "float"
    if isinstance(v, str):
        return "str"
    if isinstance(v, list):
        if not v:
            return "list[empty]"
        inner = sorted({jtype(x) for x in v})
        return "list[" + "|".join(inner) + "]"
    if isinstance(v, dict):
        return "object"
    return type(v).__name__


def classify_files_changed_line(line: str) -> str:
    if not line.strip():
        return "blank"
    if NAMESTATUS_RE.match(line):
        return "name-status"
    if NUMSTAT_RE.match(line):
        return "numstat"
    if PATH_ONLY_RE.match(line):
        return "bare-path"
    return "other"


def classify_files_changed(value: Any) -> str:
    """Return a single label describing the dominant line shape."""
    if value is None or value == "":
        return "empty"
    if isinstance(value, list):
        # rare but seen in some hyperswitch records
        return "list"
    if not isinstance(value, str):
        return f"non-string:{jtype(value)}"
    labels = Counter()
    for line in value.splitlines():
        line = line.rstrip("\n")
        if not line:
            continue
        labels[classify_files_changed_line(line)] += 1
    if not labels:
        return "empty"
    if len(labels) == 1:
        return next(iter(labels))
    return "mixed:" + ",".join(f"{k}={n}" for k, n in labels.most_common())


def classify_numstat(value: Any) -> str:
    if value is None or value == "":
        return "empty"
    if not isinstance(value, str):
        return f"non-string:{jtype(value)}"
    labels = Counter()
    for line in value.splitlines():
        line = line.rstrip("\n")
        if not line:
            continue
        if NUMSTAT_RE.match(line):
            labels["numstat"] += 1
        elif NAMESTATUS_RE.match(line):
            labels["name-status"] += 1
        elif PATH_ONLY_RE.match(line):
            labels["bare-path"] += 1
        else:
            labels["other"] += 1
    if not labels:
        return "empty"
    if len(labels) == 1:
        return next(iter(labels))
    return "mixed:" + ",".join(f"{k}={n}" for k, n in labels.most_common())


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

def collect(paths: list[Path], layer: str) -> dict:
    key_freq: Counter = Counter()
    key_types: dict[str, Counter] = defaultdict(Counter)
    key_present: dict[str, list[str]] = defaultdict(list)

    enum_distribution: dict[str, Counter] = defaultdict(Counter)
    nested_distribution: dict[str, Counter] = defaultdict(Counter)
    files_changed_dist: Counter = Counter()
    numstat_dist: Counter = Counter()
    review_shape_dist: Counter = Counter()
    reliability_status_dist: Counter = Counter()
    extraction_method_dist: Counter = Counter()
    patch_truncated_dist: Counter = Counter()
    has_patch_field: Counter = Counter()
    has_swe_fail_to_pass: Counter = Counter()
    has_swe_pass_to_pass: Counter = Counter()
    files_count_vs_numstat_mismatch = 0

    n_files = 0
    parse_errors: list[str] = []

    for p in paths:
        try:
            data = json.loads(p.read_text())
        except Exception as e:  # noqa: BLE001
            parse_errors.append(f"{p}: {e}")
            continue
        if not isinstance(data, dict):
            parse_errors.append(f"{p}: top-level is {type(data).__name__}, not dict")
            continue

        n_files += 1
        for k, v in data.items():
            key_freq[k] += 1
            key_types[k][jtype(v)] += 1
            if len(key_present[k]) < 3:
                key_present[k].append(str(p.relative_to(ROOT)))

        # critical enum-like fields
        for f in CRITICAL_FIELDS:
            if f in data:
                enum_distribution[f][str(data[f])] += 1

        # nested _extraction.*
        ext = data.get("_extraction")
        if isinstance(ext, dict):
            for k, v in ext.items():
                nested_distribution[f"_extraction.{k}"][str(v)] += 1
            if "method" in ext:
                extraction_method_dist[str(ext["method"])] += 1

        # nested _reliability.*
        rel = data.get("_reliability")
        if isinstance(rel, dict):
            for k, v in rel.items():
                nested_distribution[f"_reliability.{k}"][jtype(v)] += 1
            if "status" in rel:
                reliability_status_dist[str(rel["status"])] += 1

        # files_changed / numstat formats
        if "files_changed" in data:
            files_changed_dist[classify_files_changed(data["files_changed"])] += 1
        if "numstat" in data:
            numstat_dist[classify_numstat(data["numstat"])] += 1

        # _review shape
        rev = data.get("_review")
        if isinstance(rev, dict):
            shape = "+".join(sorted(rev.keys()))
            review_shape_dist[shape] += 1
        elif rev is None and "_review" in data:
            review_shape_dist["null"] += 1

        if "patch" in data:
            has_patch_field[jtype(data["patch"])] += 1
        if "patch_truncated" in data:
            patch_truncated_dist[str(data["patch_truncated"])] += 1
        if "FAIL_TO_PASS" in data:
            has_swe_fail_to_pass[jtype(data["FAIL_TO_PASS"])] += 1
        if "PASS_TO_PASS" in data:
            has_swe_pass_to_pass[jtype(data["PASS_TO_PASS"])] += 1

        # sanity: files_changed_count vs lines in files_changed
        fcc = data.get("files_changed_count")
        fc = data.get("files_changed")
        if isinstance(fcc, int) and isinstance(fc, str):
            n_lines = sum(1 for ln in fc.splitlines() if ln.strip())
            if n_lines and n_lines != fcc:
                files_count_vs_numstat_mismatch += 1

    return {
        "layer": layer,
        "n_files": n_files,
        "key_freq": dict(key_freq.most_common()),
        "key_types": {k: dict(t) for k, t in key_types.items()},
        "key_examples": dict(key_present),
        "enum_distribution": {k: dict(c) for k, c in enum_distribution.items()},
        "nested_distribution": {k: dict(c) for k, c in nested_distribution.items()},
        "files_changed_format": dict(files_changed_dist),
        "numstat_format": dict(numstat_dist),
        "review_block_shape": dict(review_shape_dist),
        "reliability_status": dict(reliability_status_dist),
        "extraction_method": dict(extraction_method_dist),
        "patch_truncated": dict(patch_truncated_dist),
        "has_patch_field": dict(has_patch_field),
        "FAIL_TO_PASS": dict(has_swe_fail_to_pass),
        "PASS_TO_PASS": dict(has_swe_pass_to_pass),
        "files_count_vs_lines_mismatch": files_count_vs_numstat_mismatch,
        "parse_errors": parse_errors,
    }


def main() -> int:
    source_files = sorted(ROOT.glob(SOURCE_GLOB))
    reference_files = sorted(ROOT.glob(REFERENCE_GLOB))

    source = collect(source_files, "source")
    reference = collect(reference_files, "reference")

    # cross-layer "same task" linkage check: every reference_patch should have
    # a sibling source patch under data-pipeline/artifacts_*/canonical_patches/
    ref_task_names: set[str] = set()
    for p in reference_files:
        ref_task_names.add(p.parent.name)
    source_task_names: set[str] = set()
    for p in source_files:
        try:
            data = json.loads(p.read_text())
            tn = data.get("_task_name")
            if tn:
                source_task_names.add(tn)
        except Exception:  # noqa: BLE001
            continue

    linkage = {
        "reference_tasks": len(ref_task_names),
        "source_tasks_with_task_name": len(source_task_names),
        "reference_without_source": sorted(ref_task_names - source_task_names)[:25],
        "source_without_reference": sorted(source_task_names - ref_task_names)[:25],
    }

    out = {
        "source_layer": source,
        "reference_layer": reference,
        "linkage": linkage,
    }

    # write next to the script
    out_path = Path(__file__).with_suffix(".result.json")
    out_path.write_text(json.dumps(out, indent=2, sort_keys=True))

    # human summary
    print(f"== Canonical-patch schema audit ==", file=sys.stderr)
    print(f"source_layer: {source['n_files']} files", file=sys.stderr)
    print(f"reference_layer: {reference['n_files']} files", file=sys.stderr)
    print(f"top source keys: {list(source['key_freq'])[:20]}", file=sys.stderr)
    print(f"top reference keys: {list(reference['key_freq'])[:20]}", file=sys.stderr)
    print(f"_fidelity values (source): {source['enum_distribution'].get('_fidelity', {})}", file=sys.stderr)
    print(f"_fidelity values (reference): {reference['enum_distribution'].get('_fidelity', {})}", file=sys.stderr)
    print(f"extraction.method (source): {source['extraction_method']}", file=sys.stderr)
    print(f"extraction.method (reference): {reference['extraction_method']}", file=sys.stderr)
    print(f"reliability.status (source): {source['reliability_status']}", file=sys.stderr)
    print(f"reliability.status (reference): {reference['reliability_status']}", file=sys.stderr)
    print(f"files_changed format (source): {source['files_changed_format']}", file=sys.stderr)
    print(f"files_changed format (reference): {reference['files_changed_format']}", file=sys.stderr)
    print(f"numstat format (source): {source['numstat_format']}", file=sys.stderr)
    print(f"numstat format (reference): {reference['numstat_format']}", file=sys.stderr)
    print(f"review block shapes (source): {source['review_block_shape']}", file=sys.stderr)
    print(f"review block shapes (reference): {reference['review_block_shape']}", file=sys.stderr)
    print(f"linkage: {linkage['reference_tasks']} ref tasks, {linkage['source_tasks_with_task_name']} source tasks, "
          f"{len(linkage['reference_without_source'])} ref without source, "
          f"{len(linkage['source_without_reference'])} source without reference (top 25 each saved).",
          file=sys.stderr)
    print(json.dumps(out, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
