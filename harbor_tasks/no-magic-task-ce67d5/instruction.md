Implement the following plan:

# Plan: Implement `microtokenizer.py`

## Context

First script in the no-magic repository. Phase 1 of the implementation sequence — establishes the project's first working educational script. BPE tokenization was chosen as the entry point because it requires no autograd, has clear success criteria, and is the first step in the learning path ("How text becomes numbers").

**Target file:** `01-foundations/microtokenizer.py`
**Expected:** ~180-200 lines, < 2 min runtime, zero dependencies

---

## Implementation Structure

### Section 0: File Thesis + Reference

```python
"""
How text becomes numbers -- the compression algorithm hiding inside every LLM.
Byte-Pair Encoding learns a vocabulary by iteratively merging the most frequent
adjacent token pairs, then encodes new text by replaying those merges in priority order.
"""
# Reference: Philip Gage, "A New Algorithm for Data Compression" (1994).
# GPT-2's byte-level BPE variant (Radford et al., 2019) starts from raw bytes
# rather than characters -- that's the version implemented here.
```

### Section 1: Imports + Seed

- `os`, `urllib.request`, `collections.Counter`
- `random.seed(42)` (repo convention, BPE itself is deterministic)

### Section 2: Constants

| Constant | Value | Rationale |
|----------|-------|-----------|
| `NUM_MERGES` | 256 | Vocab = 512 tokens. Enough compression for demo, fast training. |
| `DATA_URL` | `https://raw.githubusercontent.com/karpathy/makemore/master/names.txt` | |
| `DATA_FILE` | `"names.txt"` | Cached locally, gitignored |

Signpost: production tokenizers use 50K+ merges on gigabytes.

### Section 3: Data Loading

**`load_data(url, filename) -> bytes`** — Download-and-cache pattern via urllib.

Convert corpus to `list[int]` (byte values 0-255). Print stats: byte count, base vocab size, planned merges.

Key intuition comment: bytes-as-base-vocab eliminates "unknown tokens" — every input is representable.

### Section 4: BPE Training

Three functions:

1. **`get_pair_counts(token_ids) -> Counter`**
   - Count adjacent pairs via `zip(ids, ids[1:])`
   - O(n) per call

2. **`apply_merge(token_ids, pair, new_id) -> list[int]`**
   - Left-to-right scan, greedy replacement
   - Why comment: overlapping pairs resolve left-to-right (standard BPE convention)
   - Signpost: O(n) per merge; production uses priority queues for O(n log n) total

3. **`train_bpe(token_ids, num_merges) -> list[tuple[tuple[int, int], int]]`**
   - Main loop: count pairs → find max → merge → record rule
   - Returns ordered merge table (index = priority, `new_id = 256 + index`)
   - Early break if no pairs remain
   - Print progress every 32 steps: merge index, pair, frequency, sequence length

Key intuition: each merge absorbs the most redundancy per step — greedy compression that naturally discovers morphological units ("play" + "ing") without linguistic rules.

### Section 5: Encoding + Decoding

4. **`build_vocab(merges) -> dict[int, bytes]`**
   - Base: `{i: bytes([i]) for i in range(256)}`
   - Merged: `vocab[new_id] = vocab[a] + vocab[b]`
   - Recursive expansion makes decoding trivial — every token maps to definite bytes

5. **`encode(text, merges) -> list[int]`**
   - Convert text to bytes → apply merges in **priority order** (NOT frequency order on new text)
   - Critical "why" comment: priority order ensures deterministic tokenization; re-counting would make output input-dependent
   - Signpost: O(n * M) naive encoding; production uses trie structures for O(n)

6. **`decode(token_ids, vocab) -> str`**
   - Lookup + concatenate + UTF-8 decode
   - Intuition: decode is just a lookup table — round-trip correctness is guaranteed by construction

### Section 6: Inference Demo

Print output in four blocks:

1. **Round-trip tests**: 6 test strings (common name, uncommon name, hyphenated, apostrophe, empty, single char) — each shows `[PASS/FAIL]` with encoded tokens and decoded result.

2. **Compression ratio**: Full corpus byte count vs BPE token count. Must be >= 1.5x.

3. **Top 20 merges**: Show each merge's component tokens and resulting token in human-readable form.

4. **Tokenization example**: One name broken into bytes → tokens → pieces.

---

## Functions Summary

| Function | Signature | Purpose |
|----------|-----------|---------|
| `load_data` | `(url: str, filename: str) -> bytes` | Download and cache dataset |
| `get_pair_counts` | `(token_ids: list[int]) -> Counter` | Count adjacent pair frequencies |
| `apply_merge` | `(token_ids: list[int], pair: tuple[int, int], new_id: int) -> list[int]` | Replace pair occurrences with new token |
| `train_bpe` | `(token_ids: list[int], num_merges: int) -> list[...]` | Learn merge rules from corpus |
| `build_vocab` | `(merges: list[...]) -> dict[int, bytes]` | Build token-to-bytes lookup |
| `encode` | `(text: str, merges: list[...]) -> list[int]` | Tokenize string to IDs |
| `decode` | `(token_ids: list[int], vocab: dict[int, bytes]) -> str` | Detokenize IDs to string |

---

## Comment Plan

| Type | Count | Key Locations |
|------|-------|---------------|
| File thesis | 1 | Top docstring |
| Section headers | 5 | Constants, Data Loading, BPE Training, Encoding/Decoding, Inference |
| "Why" comments | 4+ | Left-to-right merge, priority order encoding, bytes-as-base, greedy compression |
| Math-to-code | 2 | Pair counting formulation, compression ratio |
| Intuition | 3+ | No unknown tokens, morphology emergence, decode simplicity |
| Signpost | 3 | 256 vs 50K merges, O(n*M) vs trie, naive vs priority queue |

Target density: 30-40% comment/blank lines.

---

## Verification

1. `python 01-foundations/microtokenizer.py` exits 0, prints training + inference
2. All round-trip tests print `[PASS]`
3. Compression ratio >= 1.5x
4. Runtime < 2 minutes (expected: 10-30 seconds)
5. No imports outside stdlib
6. Line count ~180-200


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /home/user/.transcript.jsonl

If this plan can be broken down into multiple independent tasks, consider using the TeamCreate tool to create a team and parallelize the work.