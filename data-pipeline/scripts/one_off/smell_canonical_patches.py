#!/usr/bin/env python3
"""Audit every canonical patch and classify by health.

Bucket meanings:
  CLEAN_OR_OK             -- safe to use as reference truth
  CURATED                 -- has _curation_method (manually re-extracted)
  MANUALLY_VERIFIED       -- has _fidelity_verified flag (audit-cleared)
  INTENTIONALLY_EMPTY     -- empty patch documented with _audit_note (e.g., no closing PR)
  DIRECTIONAL_UNVERIFIED  -- _fidelity = directional, no verification (suspect)
  LOSSY_UNFIXED           -- _fidelity = lossy, no curation (broken)
  EMPTY_PATCH             -- patch field is empty (no signal)
  ZERO_FILES              -- non-empty patch but files_changed_count = 0 (corrupt)
  PARSE_FAIL              -- JSON didn't parse (corrupt)

Exits nonzero if any of {DIRECTIONAL_UNVERIFIED, LOSSY_UNFIXED, EMPTY_PATCH,
ZERO_FILES, PARSE_FAIL} has items. Skips files under `_dropped/` and
`_pre_promote_*/`.

Documented `_fidelity` tier vocabulary (see notes/README.md `_fidelity` section):
  exact, directional, lossy, verifier_aligned, upstream_canonical, reconstructed,
  clean, high, curated.
The last three (`clean`, `high`, `curated`) are curator-set after manual
verification and treated the same as `exact`.
"""
import argparse
import glob
import json
import os
import sys
from collections import defaultdict


ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))


def classify(d: dict) -> str:
    patch = d.get("patch", "") or ""
    fidelity = d.get("_fidelity", "unknown")
    fidelity_verified = d.get("_fidelity_verified", False)
    has_curation = "_curation_method" in d
    has_audit_note = "_audit_note" in d
    files_count = d.get("files_changed_count", 0)

    if not patch.strip():
        return "INTENTIONALLY_EMPTY" if has_audit_note else "EMPTY_PATCH"
    if files_count == 0:
        return "ZERO_FILES"
    if has_curation:
        return "CURATED"
    if fidelity_verified:
        return "MANUALLY_VERIFIED"
    if fidelity == "lossy":
        return "LOSSY_UNFIXED"
    if fidelity == "directional":
        return "DIRECTIONAL_UNVERIFIED"
    return "CLEAN_OR_OK"


def is_explicitly_unreliable(d: dict) -> bool:
    """A canonical with `_reliability.status = FLAGGED_UNRELIABLE` was
    intentionally given up on (codex-format gap, install_config bug, etc.) —
    the audit knows it's imperfect and consumers should treat it as such.
    Informational only; doesn't trip fail_count."""
    rel = d.get("_reliability")
    return bool(rel and rel.get("status") == "FLAGGED_UNRELIABLE")


FAIL_BUCKETS = {
    "DIRECTIONAL_UNVERIFIED",
    "LOSSY_UNFIXED",
    "EMPTY_PATCH",
    "ZERO_FILES",
    "PARSE_FAIL",
}


# Curator-set tiers (manual verification); treated identically to "exact".
# See notes/README.md `_fidelity` section.
CURATOR_TIERS = {"clean", "high", "curated"}

# Full documented tier vocabulary. Used by the schema-vocab check below.
VALID_FIDELITY = {
    "exact", "directional", "lossy",
    "verifier_aligned", "upstream_canonical", "reconstructed",
    "unknown",
} | CURATOR_TIERS


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    pattern = os.path.join(ROOT, "data-pipeline", "artifacts_*",
                           "canonical_patches", "*.json")
    all_jsons = sorted(p for p in glob.glob(pattern)
                       if "/_dropped/" not in p
                       and "/_pre_promote_" not in p)

    by_source: dict[str, int] = defaultdict(int)
    buckets: dict[str, list[dict]] = defaultdict(list)
    explicit_unreliable: list[dict] = []  # informational; not failing
    for p in all_jsons:
        source = p.split("/artifacts_", 1)[1].split("/", 1)[0]
        by_source[source] += 1
        try:
            d = json.load(open(p))
        except Exception as e:
            buckets["PARSE_FAIL"].append({"path": p, "source": source,
                                          "task": "?", "reason": str(e)})
            continue
        bucket = classify(d)
        item = {
            "path": p, "source": source,
            "task": d.get("_task_name", "?"),
            "fidelity": d.get("_fidelity", "?"),
            "files": d.get("files_changed_count", 0),
        }
        buckets[bucket].append(item)
        if is_explicitly_unreliable(d):
            explicit_unreliable.append({
                **item,
                "reason": (d.get("_reliability") or {}).get("reason", "?"),
            })

    fail_count = sum(len(buckets[k]) for k in FAIL_BUCKETS)
    if args.strict:
        fail_count += len(buckets.get("CURATED", []))

    if args.json:
        report = {
            "total": len(all_jsons),
            "by_source": dict(by_source),
            "buckets": {k: len(v) for k, v in buckets.items()},
            "details": {k: v for k, v in buckets.items() if k in FAIL_BUCKETS},
            "fail_count": fail_count,
        }
        print(json.dumps(report, indent=2))
    else:
        print(f"Total canonicals: {len(all_jsons)}")
        print("\nBy source:")
        for src, n in sorted(by_source.items()):
            print(f"  {src:18}  {n:>3}")
        print("\nBuckets:")
        order = ["CLEAN_OR_OK", "CURATED", "MANUALLY_VERIFIED",
                 "INTENTIONALLY_EMPTY",
                 "DIRECTIONAL_UNVERIFIED", "LOSSY_UNFIXED",
                 "EMPTY_PATCH", "ZERO_FILES", "PARSE_FAIL"]
        for k in order:
            n = len(buckets.get(k, []))
            flag = "  !!" if (k in FAIL_BUCKETS and n > 0) else "    "
            print(f"{flag} {k:24}  {n:>3}")
        for k in FAIL_BUCKETS:
            if buckets.get(k):
                print(f"\n[{k}]")
                for item in buckets[k]:
                    print(f"  {item['source']:14} {item['task']:42} "
                          f"fidelity={item['fidelity']:14} files={item['files']}")
        if explicit_unreliable:
            print(f"\n[EXPLICITLY_UNRELIABLE]  {len(explicit_unreliable)} "
                  f"(informational; flagged by audit, not failing)")
            for item in explicit_unreliable:
                print(f"  {item['source']:14} {item['task']:42} "
                      f"reason={item['reason']}")
        print(f"\nfail_count = {fail_count}  "
              f"({'OK' if fail_count == 0 else 'NEEDS ATTENTION'})")

    return 1 if fail_count > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
