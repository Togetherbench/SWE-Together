#!/bin/bash
set +e

mkdir -p /logs/verifier
REWARD_FILE="/logs/verifier/reward.txt"
REWARD="0.0"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

cd /workspace/pi-mono 2>/dev/null || cd /workspace/$(ls /workspace 2>/dev/null | head -1) 2>/dev/null

# Locate bun
BUN_BIN=$(command -v bun)
if [ -z "$BUN_BIN" ]; then
    for p in /root/.bun/bin/bun /usr/local/bin/bun /opt/bun/bin/bun; do
        [ -x "$p" ] && BUN_BIN="$p" && break
    done
fi
if [ -z "$BUN_BIN" ]; then
    echo "ERROR: bun not found"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

echo "Using bun: $BUN_BIN"
echo "Working dir: $(pwd)"

RUNNER_FILE="packages/coding-agent/src/core/extensions/runner.ts"
KB_AGENT_FILE="packages/coding-agent/src/core/keybindings.ts"
KB_TUI_FILE="packages/tui/src/keybindings.ts"
TEST_DIR="packages/coding-agent/test"

if [ ! -f "$RUNNER_FILE" ]; then
    echo "ERROR: runner.ts missing"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

###############################################################################
# P2P GATE (gating only, no reward): existing keybinding tests must still pass.
# This guards against destructive changes. No partial credit awarded here.
###############################################################################
echo ""
echo "=== P2P Gate: existing extensions-runner tests must still pass ==="

P2P_OUT=$("$BUN_BIN" test packages/coding-agent/test/extensions-runner.test.ts 2>&1)
echo "$P2P_OUT" | tail -10
P2P_FAIL=$(echo "$P2P_OUT" | grep -cE "\(fail\)")
P2P_PASS=$(echo "$P2P_OUT" | grep -cE "\(pass\)")
if [ "$P2P_FAIL" -gt 0 ] || [ "$P2P_PASS" -lt 1 ]; then
    echo "P2P GATE FAILED: existing tests broken ($P2P_PASS pass, $P2P_FAIL fail)"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
echo "P2P gate passed ($P2P_PASS pass, $P2P_FAIL fail)"

SCORE_PCT=0

###############################################################################
# F2P Gate A (0.45): Picker-only keys must NOT trigger built-in conflict
# warnings AND must be registered. On the buggy base, ctrl+s/ctrl+r (bound
# to picker-only actions like app.session.toggleSort, app.models.save, etc.)
# either get blocked or warned about → this test fails on base, passes on fix.
###############################################################################
echo ""
echo "=== F2P Gate A (0.45): picker-only keys are not flagged as conflicts ==="

VG_A="$TEST_DIR/_verifier_picker_scope.test.ts"
cat > "$VG_A" << 'TESTEOF'
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { discoverAndLoadExtensions } from "../src/core/extensions/loader.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { DEFAULT_KEYBINDINGS } from "../src/core/keybindings.js";
import { ModelRegistry } from "../src/core/model-registry.js";
import { SessionManager } from "../src/core/session-manager.js";

describe("verifier-picker-scope", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-vga-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("picker-only keys (ctrl+s, ctrl+r) are registered and not flagged", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+s", {
                    description: "picker-only key",
                    handler: async () => {},
                });
                pi.registerShortcut("ctrl+r", {
                    description: "picker-only key",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "picker.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        // Both extension shortcuts must be registered (not blocked).
        expect(shortcuts.has("ctrl+s")).toBe(true);
        expect(shortcuts.has("ctrl+r")).toBe(true);

        const warnMsgs = warnSpy.mock.calls.map(c => c.map(String).join(" ")).join("\n");
        const diags = (runner as any).shortcutDiagnostics ?? [];
        const diagMsgs = diags.map((d: any) => String(d?.message ?? "")).join("\n");
        const allMsgs = (warnMsgs + "\n" + diagMsgs).toLowerCase();

        // Picker-scope action ids that should NOT appear as conflicts
        const pickerActions = [
            "togglesessionsort", "renamesession", "togglepath",
            "togglepinned", "togglenamedfilter",
        ];
        for (const action of pickerActions) {
            const flagged = allMsgs.includes(action) &&
                (allMsgs.includes("conflict") || allMsgs.includes("built-in") || allMsgs.includes("reserved"));
            expect(flagged, `picker action ${action} unexpectedly flagged. Messages: ${warnMsgs}\n${diagMsgs}`).toBe(false);
        }

        // Also: there should be no warning that *mentions* ctrl+s or ctrl+r as a conflict.
        const ctrlSConflict = /ctrl\+s.*(conflict|built-in|reserved)/i.test(warnMsgs + "\n" + diagMsgs)
            || /(conflict|built-in|reserved).*ctrl\+s/i.test(warnMsgs + "\n" + diagMsgs);
        const ctrlRConflict = /ctrl\+r.*(conflict|built-in|reserved)/i.test(warnMsgs + "\n" + diagMsgs)
            || /(conflict|built-in|reserved).*ctrl\+r/i.test(warnMsgs + "\n" + diagMsgs);
        expect(ctrlSConflict, `ctrl+s flagged as conflict: ${warnMsgs}\n${diagMsgs}`).toBe(false);
        expect(ctrlRConflict, `ctrl+r flagged as conflict: ${warnMsgs}\n${diagMsgs}`).toBe(false);

        warnSpy.mockRestore();
    });
});
TESTEOF

VG_A_OUT=$("$BUN_BIN" test "$VG_A" 2>&1)
echo "$VG_A_OUT" | tail -15
VGA_FAIL=$(echo "$VG_A_OUT" | grep -cE "\(fail\)")
VGA_PASS=$(echo "$VG_A_OUT" | grep -cE "\(pass\)")
if [ "$VGA_PASS" -ge 1 ] && [ "$VGA_FAIL" -eq 0 ]; then
    SCORE_PCT=$((SCORE_PCT + 45))
    echo "Gate A: PASS (+0.45)"
else
    echo "Gate A: FAIL [$VGA_PASS pass, $VGA_FAIL fail]"
fi
rm -f "$VG_A"

###############################################################################
# F2P Gate B (0.45): Editor-scope keys MUST still produce a conflict warning
# (or be blocked) when claimed by an extension. This guards against the trivial
# "remove all conflict checks" fix. We test ctrl+c (app.clear / tui.input.copy)
# which is unambiguously editor-active in the base codebase.
###############################################################################
echo ""
echo "=== F2P Gate B (0.45): editor-scope keys still produce conflict signal ==="

VG_B="$TEST_DIR/_verifier_editor_scope.test.ts"
cat > "$VG_B" << 'TESTEOF'
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { discoverAndLoadExtensions } from "../src/core/extensions/loader.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { DEFAULT_KEYBINDINGS } from "../src/core/keybindings.js";
import { ModelRegistry } from "../src/core/model-registry.js";
import { SessionManager } from "../src/core/session-manager.js";

describe("verifier-editor-scope", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-vgb-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("editor-scope key (ctrl+c) still triggers conflict signal", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+c", {
                    description: "claims editor-scope key",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "editor.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        const warnMsgs = warnSpy.mock.calls.map(c => c.map(String).join(" ")).join("\n");
        const diags = (runner as any).shortcutDiagnostics ?? [];
        const diagMsgs = diags.map((d: any) => String(d?.message ?? "")).join("\n");
        const allMsgs = (warnMsgs + "\n" + diagMsgs).toLowerCase();

        // Either: extension shortcut was blocked (not in map), OR a conflict
        // warning/diagnostic was produced. A trivially-broken fix that just
        // removes all checks would have neither.
        const blocked = !shortcuts.has("ctrl+c");
        const warned = allMsgs.includes("ctrl+c") &&
            (allMsgs.includes("conflict") || allMsgs.includes("built-in") ||
             allMsgs.includes("reserved") || allMsgs.includes("blocked"));

        expect(blocked || warned,
            `ctrl+c (editor-scope) should be blocked or warned about. blocked=${blocked} warnMsgs=${warnMsgs} diagMsgs=${diagMsgs}`
        ).toBe(true);

        warnSpy.mockRestore();
    });
});
TESTEOF

VG_B_OUT=$("$BUN_BIN" test "$VG_B" 2>&1)
echo "$VG_B_OUT" | tail -15
VGB_FAIL=$(echo "$VG_B_OUT" | grep -cE "\(fail\)")
VGB_PASS=$(echo "$VG_B_OUT" | grep -cE "\(pass\)")
if [ "$VGB_PASS" -ge 1 ] && [ "$VGB_FAIL" -eq 0 ]; then
    SCORE_PCT=$((SCORE_PCT + 45))
    echo "Gate B: PASS (+0.45)"
else
    echo "Gate B: FAIL [$VGB_PASS pass, $VGB_FAIL fail]"
fi
rm -f "$VG_B"

###############################################################################
# F2P Gate C (0.10): Hardcoded RESERVED_KEYBINDINGS_FOR_EXTENSION_CONFLICTS
# allowlist no longer drives the conflict check. The fix replaces it with a
# scope-derived mechanism. We assert the runner.ts has *changed* away from the
# original mechanism: either the original literal list is gone, or scope-based
# logic has been added. On no-op base, neither holds → 0.0.
###############################################################################
echo ""
echo "=== F2P Gate C (0.10): scope-based mechanism replaces hardcoded list ==="

GATE_C=0
# The base file contains a comment line: "Only editor-global shortcuts are reserved here. Picker-specific bindings are not."
# AND the array RESERVED_KEYBINDINGS_FOR_EXTENSION_CONFLICTS with specific contents.
# A real fix either removes/renames that array or adds scope-aware logic.

# Detect addition of scope-related logic in runner OR keybindings:
SCOPE_ADDED=0
grep -qE "scope|Scope|isGlobalKeybinding|buildGlobalKeys|buildEditorKeys|getEditorScope|PICKER_SCOPES|EDITOR_SCOPE|ConflictScope|coexist|canConflict" "$RUNNER_FILE" 2>/dev/null && SCOPE_ADDED=1
grep -qE "scope:|ScopeId|ConflictScope|getEditorScope|SCOPE_COEXISTENCE|KEYBINDING_SCOPES" "$KB_AGENT_FILE" 2>/dev/null && SCOPE_ADDED=1
grep -qE "scope:|ScopeId|ConflictScope|KEYBINDING_SCOPES|getEditorScope" "$KB_TUI_FILE" 2>/dev/null && SCOPE_ADDED=1

# Detect removal of the original comment guidance (acts as a marker that the
# code section was rewritten):
ORIG_COMMENT_GONE=1
if grep -q "Only editor-global shortcuts are reserved here. Picker-specific bindings are not." "$RUNNER_FILE" 2>/dev/null; then
    # Original verbatim comment still present. Check if scope mechanism nonetheless added.
    if [ "$SCOPE_ADDED" -eq 0 ]; then
        ORIG_COMMENT_GONE=0
    fi
fi

if [ "$SCOPE_ADDED" -eq 1 ] && [ "$ORIG_COMMENT_GONE" -eq 1 ]; then
    GATE_C=1
fi

if [ "$GATE_C" -eq 1 ]; then
    SCORE_PCT=$((SCORE_PCT + 10))
    echo "Gate C: PASS (+0.10)"
else
    echo "Gate C: FAIL (no scope-based mechanism detected; SCOPE_ADDED=$SCOPE_ADDED, ORIG_COMMENT_GONE=$ORIG_COMMENT_GONE)"
fi

###############################################################################
# Final reward
###############################################################################
REWARD=$(awk -v p="$SCORE_PCT" 'BEGIN { printf "%.2f", p / 100.0 }')
echo ""
echo "=== Final Reward: $REWARD (raw $SCORE_PCT/100) ==="
echo "$REWARD" > "$REWARD_FILE"