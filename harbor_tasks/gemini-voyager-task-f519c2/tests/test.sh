#!/usr/bin/env bash
# Behavioral structural verifier for gemini-voyager-task-f519c2.
# Detects the folder drag-and-drop fix in src/pages/content/folder/manager.ts
# (Nagi-ovo/gemini-voyager PR #430).
#
# Two structural changes are required:
# 1. dragleave handler in setupDropZone must use coordinate boundary check
#    (getBoundingClientRect + clientX/clientY + rect.{left,right,top,bottom})
#    rather than unconditionally removing the gv-folder-dragover class on
#    every dragleave event.
# 2. A helper (canonically named ensureConversationsInFolder) must pre-insert
#    conversations from native-sidebar drags into folderContents[folderId]
#    BEFORE reorderOrMoveConversations is called. Detected via:
#       a `!sourceFolderId` guard immediately followed by a helper call,
#       which precedes the reorderOrMoveConversations(...) call inside the
#       same drop handler, AND the helper's body has non-trivial structure.
#
# We use Python regex / brace-matching instead of the typescript-package AST,
# because the bundled `typescript` version drifts and the prior TS-AST verifier
# crashed under typescript@6.x (`getText()` requires explicit source-file arg).
set +e

export PATH="/usr/local/bin:/usr/bin:/bin:/home/agent/.bun/bin:/root/.bun/bin:${PATH}"

TASK_DIR="${TASK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REPO_DIR="${REPO_DIR:-/opt/gemini-voyager}"
mkdir -p "$LOGS_DIR"

SOURCE_FILE="$REPO_DIR/src/pages/content/folder/manager.ts"

if [ ! -f "$SOURCE_FILE" ]; then
    echo "ERROR: missing $SOURCE_FILE" >&2
    echo 0.0 > "$LOGS_DIR/reward.txt"
    exit 0
fi

python3 - "$SOURCE_FILE" "$LOGS_DIR/reward.txt" "$LOGS_DIR/gates.json" <<'PYEOF'
import json, re, sys

src_path, reward_path, gates_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path).read()

verdicts = {}

def extract_brace_block(text, start_idx):
    """Return substring from `{` at start_idx through matching `}` (inclusive)."""
    if start_idx >= len(text) or text[start_idx] != '{':
        return None
    depth = 0
    i = start_idx
    while i < len(text):
        c = text[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return text[start_idx:i + 1]
        i += 1
    return None

def find_method_body(src, method_name):
    """Find first method declaration with `method_name` and return its body block."""
    pattern = re.compile(
        r'(?:private|public|protected)?\s*' + re.escape(method_name) + r'\s*\(([^)]*)\)\s*(?::\s*[\w<>\[\]| ]+)?\s*\{',
        re.DOTALL,
    )
    m = pattern.search(src)
    if not m:
        return None
    return extract_brace_block(src, m.end() - 1)

def strip_top_brace(s):
    s = s.strip()
    if s.startswith('{') and s.endswith('}'):
        return s[1:-1]
    return s

def strip_nested_braces(s):
    out, depth = [], 0
    for c in s:
        if c == '{':
            depth += 1
            continue
        if c == '}':
            depth -= 1
            continue
        if depth == 0:
            out.append(c)
    return ''.join(out)

# ---------------------------------------------------------------------------
# Gate 1: dragleave_fix
# Inside setupDropZone, the dragleave handler must use coordinate boundary
# check (getBoundingClientRect + clientX/Y + rect.{left,right,top,bottom}) OR
# the classList.remove(...gv-folder-dragover...) call must be inside a nested
# block (gated by an `if`), not at the top level of the handler.
# ---------------------------------------------------------------------------
def gate_dragleave_fix(src):
    method_body = find_method_body(src, 'setupDropZone')
    if not method_body:
        return False
    # find addEventListener('dragleave', <handler>)
    m = re.search(r"addEventListener\s*\(\s*['\"]dragleave['\"]\s*,", method_body)
    if not m:
        return False
    rest = method_body[m.end():]
    brace_idx = rest.find('{')
    if brace_idx == -1:
        return False
    handler = extract_brace_block(rest, brace_idx)
    if not handler:
        return False
    # Patched form
    has_rect_call = 'getBoundingClientRect' in handler
    has_boundary = bool(re.search(r'rect\.(left|right|top|bottom)', handler)) or \
                   bool(re.search(r'\.(left|right|top|bottom)\b', handler))
    has_clientxy = ('clientX' in handler) or ('clientY' in handler)
    if has_rect_call and has_boundary and has_clientxy:
        return True
    # Alternative: classList.remove call is inside a nested `if` block, not
    # at the top level of the handler body.
    inner = strip_top_brace(handler)
    top_level = strip_nested_braces(inner)
    has_unconditional = bool(re.search(r'classList\.remove\([^)]*gv-folder-dragover', top_level))
    has_gated_remove = bool(re.search(r'classList\.remove\([^)]*gv-folder-dragover', handler))
    return (not has_unconditional) and has_gated_remove

verdicts['dragleave_fix'] = gate_dragleave_fix(src)

# ---------------------------------------------------------------------------
# Helper: locate the helper method that pre-inserts conversations.
# Canonical name is `ensureConversationsInFolder`. Accept other names if they
# are private, take folderId+dragData params, and the body has the
# distinguishing pattern: writes to `this.data.folderContents[<id>]` AND
# checks for existence with `.some(...conversationId === ...)`. The base file
# has `addConversationToFolder` which is similar but does NOT contain the
# .some() existence check + sortIndex computation in one method.
# ---------------------------------------------------------------------------
def find_helper_method_body(src):
    """Return (name, body) of the helper method, or None."""
    # Canonical first
    m = re.search(
        r'\bprivate\s+ensureConversationsInFolder\s*\([^)]*\)\s*(?::\s*\w+)?\s*\{',
        src,
    )
    if m:
        body = extract_brace_block(src, m.end() - 1)
        if body:
            return ('ensureConversationsInFolder', body)
    # Generic discovery: a private method with folderId+dragData params whose
    # body contains BOTH `folderContents[<id>]` push semantics AND the
    # existence check `.some(...conversationId`. This is the signature of the
    # post-fix helper, distinct from base's addConversationToFolder.
    method_re = re.compile(
        r'\bprivate\s+([A-Za-z_][\w]*)\s*\(([^)]*)\)\s*(?::\s*\w+)?\s*\{',
        re.DOTALL,
    )
    for m in method_re.finditer(src):
        name = m.group(1)
        params = m.group(2)
        if 'folderId' not in params and 'parentId' not in params:
            continue
        if 'dragData' not in params and 'DragData' not in params:
            continue
        body = extract_brace_block(src, m.end() - 1)
        if not body:
            continue
        # Distinguishing markers — must be the post-fix helper, NOT
        # the pre-existing `addConversationToFolder`.
        # Post-fix helper:
        #   - handles BOTH dragData.conversations (multi-select) AND
        #     dragData.conversationId (single)  → must reference both
        #   - is "silent": does NOT call removeConversationFromFolder
        #   - is "silent": does NOT call saveData/refresh/this.refresh
        #   - has an iterating block over `items` or `convs`
        marker_pre_existence = bool(re.search(r"\.some\s*\(\s*\(?\s*\w+\s*\)?\s*=>\s*[^)]*conversationId\s*===", body))
        marker_sortindex = ('sortIndex' in body) or ('maxSortIndex' in body)
        marker_folder_contents = bool(re.search(r'this\.data\.folderContents\s*\[', body))
        marker_handles_array = ('dragData.conversations' in body)
        marker_handles_single = ('dragData.conversationId' in body)
        marker_silent = (
            'removeConversationFromFolder' not in body
            and 'this.saveData' not in body
            and 'this.refresh(' not in body
        )
        if (marker_pre_existence and marker_sortindex and marker_folder_contents
                and marker_handles_array and marker_handles_single
                and marker_silent):
            return (name, body)
    return None

helper = find_helper_method_body(src)

# ---------------------------------------------------------------------------
# Gate 2: ensure_method — helper exists with the post-fix signature
# ---------------------------------------------------------------------------
verdicts['ensure_method'] = helper is not None

# ---------------------------------------------------------------------------
# Gate 3: drop_preinsert — somewhere in the file there is a `!sourceFolderId`
# guard whose body calls the helper, and that guard appears before a
# reorderOrMoveConversations call within the same drop handler region.
# We require:
#   - regex finds `if (!sourceFolderId)` (allowing whitespace) followed by a
#     call to the helper method (canonical `ensureConversationsInFolder` OR
#     the generically-discovered helper) within the if-body
#   - this guard is followed (within next ~1000 chars) by a
#     reorderOrMoveConversations call
# ---------------------------------------------------------------------------
def gate_drop_preinsert(src, helper):
    helper_name = helper[0] if helper else None
    # Find every `if (!sourceFolderId)` block
    for m in re.finditer(r'if\s*\(\s*!\s*sourceFolderId\s*\)\s*\{', src):
        block = extract_brace_block(src, m.end() - 1)
        if not block:
            continue
        helper_called = False
        if helper_name and re.search(r'\bthis\.' + re.escape(helper_name) + r'\s*\(', block):
            helper_called = True
        # Generic fallback: any `this.<name>(` call referencing a folder/parent id
        if not helper_called and re.search(r'\bthis\.\w+\s*\(\s*(folderId|parentId)\b', block):
            helper_called = True
        if not helper_called:
            continue
        # check: a reorderOrMoveConversations call within ~1500 chars after the if-block
        tail = src[m.end():m.end() + 1500]
        if 'reorderOrMoveConversations' in tail:
            return True
    return False

verdicts['drop_preinsert'] = gate_drop_preinsert(src, helper)

# ---------------------------------------------------------------------------
# Gate 4: method_depth — the helper body must have non-trivial structure:
# folderContents access + iteration + push + sortIndex / maxSortIndex
# (≥4 distinguishing markers).
# ---------------------------------------------------------------------------
def gate_method_depth(helper):
    if helper is None:
        return False
    name, body = helper
    has_contents = 'folderContents[' in body
    has_loop = bool(re.search(r'\bfor\s*\(|\.forEach\s*\(|\.map\s*\(|\.reduce\s*\(', body))
    has_push = ('.push(' in body) or ('[...' in body)
    has_sort = ('sortIndex' in body) or ('maxSortIndex' in body)
    has_existence = bool(re.search(r'\.some\s*\(', body))
    # statement count proxy
    body_no_str = re.sub(r"'[^']*'|\"[^\"]*\"|`[^`]*`", "''", body)
    stmt_count = body_no_str.count(';')
    return has_contents and has_loop and has_push and has_sort and has_existence and stmt_count > 4

verdicts['method_depth'] = gate_method_depth(helper)

# ---------------------------------------------------------------------------
# Score (weighted-replace formula)
# ---------------------------------------------------------------------------
WEIGHTS = {
    'dragleave_fix': 0.30,
    'ensure_method': 0.25,
    'drop_preinsert': 0.25,
    'method_depth': 0.20,
}

f2p_any_pass = any(verdicts.values())
inner = 0.0
inner_share = max(0.0, 1.0 - sum(WEIGHTS.values()))

if not f2p_any_pass:
    reward = 0.0
else:
    reward = inner * inner_share
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)

reward = max(0.0, min(1.0, reward))
open(reward_path, 'w').write(f"{reward:.6f}\n")
json.dump({'verdicts': verdicts, 'reward': reward}, open(gates_path, 'w'), indent=2)

print("=== gemini-voyager-task-f519c2 verifier ===")
for g in ('dragleave_fix', 'ensure_method', 'drop_preinsert', 'method_depth'):
    print(f"  [{ 'PASS' if verdicts[g] else 'FAIL' }] {g} (weight {WEIGHTS[g]})")
print(f"  reward = {reward:.4f}")
PYEOF

cat "$LOGS_DIR/reward.txt"
