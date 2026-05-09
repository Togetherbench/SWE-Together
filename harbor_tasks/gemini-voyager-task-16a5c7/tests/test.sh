#!/usr/bin/env bash
# Verifier — gemini-voyager trademark rename.
#
# The user received a trademark complaint for the Chrome extension "Gemini Voyager"
# and asked the agent to rename only USER-FACING strings (not the GitHub URL,
# not internal debug logs, not unrelated build scripts). Behavioral gates check
# that the rename took effect on each user-visible surface; we accept any
# non-empty replacement (the user themselves suggested both "Voyager" and
# "Gem Voyager"), but the result must no longer contain the literal phrase
# "Gemini Voyager".
#
# All gates are evaluated by inspecting the post-edit repo on disk. No vitest
# pass-rate dependency — vitest is informational only.
set +e

export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO=/opt/gemini-voyager
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

cd "$REPO" || { echo "ERROR: cd $REPO failed" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# (No vitest run — the gates evaluate the rename via direct filesystem
# inspection; running the full vitest suite would add ~90s for no extra signal,
# since source-side regex already verifies the test file was updated.)
# ──────────────────────────────────────────────────────────────────────────────
TEST_LOG="/dev/null"
TEST_RC=0

# ──────────────────────────────────────────────────────────────────────────────
# Gate evaluation — pure Python over filesystem state.
# ──────────────────────────────────────────────────────────────────────────────
python3 - "$REPO" "$TEST_LOG" "$TEST_RC" "$GATES_FILE" "$REWARD_FILE" <<'PYEOF'
import json, os, re, sys

REPO, TEST_LOG, TEST_RC, GATES_FILE, REWARD_FILE = sys.argv[1:6]
TEST_RC = int(TEST_RC)

LOCALES = ["ar", "en", "es", "fr", "ja", "ko", "pt", "ru", "zh", "zh_TW"]

# The literal phrase the trademark complaint targets. Case-sensitive; matches
# the strings the gold patch removes.
GEMINI_VOYAGER = "Gemini Voyager"

def read(path):
    try:
        with open(os.path.join(REPO, path), "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        return None

def load_locale(code):
    raw = read(f"src/locales/{code}/messages.json")
    if raw is None:
        return None, f"missing locale {code}"
    try:
        return json.loads(raw), None
    except Exception as e:
        return None, f"locale {code} not valid JSON: {e}"

verdicts = {}
notes = {}

# ── F2P_LOCALE_EXTNAME ────────────────────────────────────────────────────────
# All 10 locales must have extName.message != "Gemini Voyager" AND non-empty.
# We do NOT require the replacement to be exactly "Voyager" — user floated
# "Gem Voyager" as an alternative, so any non-empty rename that drops the
# literal phrase is accepted.
ext_failures = []
for code in LOCALES:
    data, err = load_locale(code)
    if err:
        ext_failures.append(f"{code}: {err}")
        continue
    msg = (data.get("extName") or {}).get("message")
    if not isinstance(msg, str) or not msg.strip():
        ext_failures.append(f"{code}: extName.message empty/missing")
    elif GEMINI_VOYAGER in msg:
        ext_failures.append(f"{code}: extName.message still contains '{GEMINI_VOYAGER}'")
verdicts["F2P_LOCALE_EXTNAME"] = (len(ext_failures) == 0)
notes["F2P_LOCALE_EXTNAME"] = ext_failures or "all 10 locales renamed"

# ── F2P_LOCALE_PMTITLE ────────────────────────────────────────────────────────
# All 10 locales must have pm_title.message != "Gemini Voyager".
pm_failures = []
for code in LOCALES:
    data, err = load_locale(code)
    if err:
        pm_failures.append(f"{code}: {err}")
        continue
    msg = (data.get("pm_title") or {}).get("message")
    if not isinstance(msg, str) or not msg.strip():
        pm_failures.append(f"{code}: pm_title.message empty/missing")
    elif GEMINI_VOYAGER in msg:
        pm_failures.append(f"{code}: pm_title.message still contains '{GEMINI_VOYAGER}'")
verdicts["F2P_LOCALE_PMTITLE"] = (len(pm_failures) == 0)
notes["F2P_LOCALE_PMTITLE"] = pm_failures or "all 10 locales renamed"

# ── F2P_EXPORT_FOOTERS ────────────────────────────────────────────────────────
# Each of the four export services has a user-visible footer string that the
# gold patch renames. We want each FOOTER STRING to no longer contain
# "Gemini Voyager". We allow the GitHub URL `github.com/Nagi-ovo/gemini-voyager`
# to remain (the user explicitly said GitHub stays unchanged), so we strip
# anything that looks like a URL before checking.
#
# To stay implementation-agnostic, we extract every JS/TS string-literal-like
# region from the file and check footer-region content.
URL_RE = re.compile(r"https?://[^\s'\"`<>]+")

def has_user_facing_brand(content):
    """Strip URLs and check whether the literal 'Gemini Voyager' still appears
    in user-facing text. Returns list of offending lines (empty if clean)."""
    if content is None:
        return ["file missing"]
    bad = []
    for ln, line in enumerate(content.splitlines(), 1):
        # Drop URLs (the GitHub repo URL is allowed to remain).
        stripped = URL_RE.sub("", line)
        if GEMINI_VOYAGER in stripped:
            bad.append(f"line {ln}: {line.strip()[:120]}")
    return bad

# We narrow the check to only the user-visible footer/export-text portions of
# each file. Doing a whole-file grep would mis-flag developer comments like
# "Strategy 1: Get from active conversation in Gemini Voyager Folder UI" —
# that comment is internal-only, the user's scope explicitly excluded code
# comments and console.error tags ("我觉得 generate sponsor 那些也没必要改").
def slice_footer(path, anchor_re, span=12):
    """Return the union of lines surrounding EVERY match of anchor_re. We
    accumulate windows so multiple anchor matches each contribute their
    surroundings — defends against false-first-match pitfalls when the same
    method name appears at the call site AND the definition site."""
    content = read(path)
    if content is None:
        return None, f"{path} missing"
    lines = content.splitlines()
    arx = re.compile(anchor_re)
    selected = set()
    matched_any = False
    for i, line in enumerate(lines):
        if arx.search(line):
            matched_any = True
            lo = max(0, i - 2)
            hi = min(len(lines), i + span)
            for j in range(lo, hi):
                selected.add(j)
    if not matched_any:
        return None, f"{path}: anchor /{anchor_re}/ not found"
    return "\n".join(lines[j] for j in sorted(selected)), None

export_failures = []
# 1. MarkdownFormatter — formatFooter() returns the "*Exported from [...]*" line.
slc, err = slice_footer(
    "src/features/export/services/MarkdownFormatter.ts",
    r"private\s+static\s+formatFooter|Exported from",
    span=14,
)
if err:
    export_failures.append(err)
else:
    bad = has_user_facing_brand(slc)
    if bad:
        export_failures.append(f"MarkdownFormatter footer: {bad[0]}")

# 2. PDFPrintService — renderFooter() returns the "Exported from [...]" HTML.
slc, err = slice_footer(
    "src/features/export/services/PDFPrintService.ts",
    r"renderFooter|gv-print-footer",
    span=14,
)
if err:
    export_failures.append(err)
else:
    bad = has_user_facing_brand(slc)
    if bad:
        export_failures.append(f"PDFPrintService footer: {bad[0]}")

# 3. ImageExportService — two "Exported from Gemini Voyager" footer occurrences.
content = read("src/features/export/services/ImageExportService.ts")
if content is None:
    export_failures.append("ImageExportService.ts missing")
else:
    # Count footer-style occurrences (inside <div>Exported from … </div>)
    footer_lines = [
        l for l in content.splitlines()
        if "Exported from" in l and "Gemini Voyager" in URL_RE.sub("", l)
    ]
    if footer_lines:
        export_failures.append(
            f"ImageExportService still has 'Exported from Gemini Voyager' "
            f"in {len(footer_lines)} footer line(s)"
        )

# 4. DeepResearchPDFPrintService — footer "<p>Exported from … </p>".
slc, err = slice_footer(
    "src/features/export/services/DeepResearchPDFPrintService.ts",
    r"gv-dr-print-footer|Exported from",
    span=10,
)
if err:
    export_failures.append(err)
else:
    bad = has_user_facing_brand(slc)
    if bad:
        export_failures.append(f"DeepResearchPDFPrintService footer: {bad[0]}")

# 5. deepResearch/formatter.ts — "Generated by [Gemini Voyager](URL)" footer.
slc, err = slice_footer(
    "src/pages/content/deepResearch/formatter.ts",
    r"Generated by|formatToMarkdown",
    span=10,
)
if err:
    export_failures.append(err)
else:
    bad = has_user_facing_brand(slc)
    if bad:
        export_failures.append(f"deepResearch/formatter footer: {bad[0]}")

verdicts["F2P_EXPORT_FOOTERS"] = (len(export_failures) == 0)
notes["F2P_EXPORT_FOOTERS"] = export_failures or "all export footers renamed"

# ── F2P_PROMPT_TITLE_RUNTIME ─────────────────────────────────────────────────
# src/pages/content/prompt/index.ts assigns titleText.textContent in two
# places (initial render + refreshUITexts). Both must be renamed. We accept
# any non-empty replacement (no enforcing the literal "Voyager").
content = read("src/pages/content/prompt/index.ts")
prompt_failures = []
if content is None:
    prompt_failures.append("prompt/index.ts missing")
else:
    # Find every titleText.textContent = "..." assignment.
    matches = re.findall(
        r"titleText\.textContent\s*=\s*['\"]([^'\"]*)['\"]\s*;",
        content,
    )
    if len(matches) < 2:
        prompt_failures.append(
            f"expected ≥2 titleText.textContent assignments, found {len(matches)}: {matches}"
        )
    else:
        for i, val in enumerate(matches):
            if not val.strip():
                prompt_failures.append(f"titleText assignment #{i+1} is empty string")
            elif GEMINI_VOYAGER in val:
                prompt_failures.append(
                    f"titleText assignment #{i+1} still = '{val}' (contains '{GEMINI_VOYAGER}')"
                )
verdicts["F2P_PROMPT_TITLE_RUNTIME"] = (len(prompt_failures) == 0)
notes["F2P_PROMPT_TITLE_RUNTIME"] = prompt_failures or "both titleText sites renamed"

# ── F2P_TEST_UPDATED ──────────────────────────────────────────────────────────
# MarkdownFormatter.test.ts asserts the footer contains the brand. After the
# rename, that assertion must NOT hard-code "Gemini Voyager" (otherwise the
# test would fail against the renamed footer). We accept any update that
# breaks the literal "Gemini Voyager" hard-coding (e.g., changed to "Voyager",
# "Gem Voyager", or even a non-brand assertion).
content = read("src/features/export/services/__tests__/MarkdownFormatter.test.ts")
test_failures = []
if content is None:
    test_failures.append("MarkdownFormatter.test.ts missing")
else:
    # Look at toContain calls; none of them should hard-code the trademark phrase.
    bad_assertions = re.findall(
        r"toContain\s*\(\s*['\"]([^'\"]*Gemini Voyager[^'\"]*)['\"]\s*\)",
        content,
    )
    if bad_assertions:
        test_failures.append(
            f"toContain still hard-codes 'Gemini Voyager': {bad_assertions[0]!r}"
        )

verdicts["F2P_TEST_UPDATED"] = (len(test_failures) == 0)
notes["F2P_TEST_UPDATED"] = test_failures or "test file updated"

# ── Build gates.json (audit log) ──────────────────────────────────────────────
gate_records = []
for gid, ok in verdicts.items():
    gate_records.append({
        "id": gid,
        "kind": "F2P",
        "pass": bool(ok),
        "details": notes[gid],
    })
with open(GATES_FILE, "w") as f:
    json.dump(gate_records, f, indent=2)

# ── Weighted-replace reward ──────────────────────────────────────────────────
WEIGHTS = {
    "F2P_LOCALE_EXTNAME": 0.30,
    "F2P_LOCALE_PMTITLE": 0.20,
    "F2P_EXPORT_FOOTERS": 0.25,
    "F2P_PROMPT_TITLE_RUNTIME": 0.15,
    "F2P_TEST_UPDATED": 0.10,
}
assert abs(sum(WEIGHTS.values()) - 1.0) < 1e-9, "weights must sum to 1.0"

# P2P_REGRESSION informational only.
p2p_failed = False

f2p_any_pass = any(verdicts.get(gid) for gid in WEIGHTS)
existing = 0.0  # no legacy reward to inherit; weighted-replace formula collapses cleanly when sum(W)=1.0

if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    inner = max(0.0, 1.0 - sum(WEIGHTS.values()))
    reward = existing * inner
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)

reward = max(0.0, min(1.0, reward))
with open(REWARD_FILE, "w") as f:
    f.write(f"{reward:.6f}\n")

print("─────────────────────────────────────────────────")
print("Gate verdicts:")
for gid, w in WEIGHTS.items():
    mark = "PASS" if verdicts.get(gid) else "FAIL"
    print(f"  [{mark}]  {gid}  (weight {w}) — {notes[gid] if isinstance(notes[gid], str) else notes[gid][:1]}")
print(f"vitest exit={TEST_RC}  (informational)")
print(f"Final reward: {reward:.4f}")
PYEOF

cat "$REWARD_FILE"
