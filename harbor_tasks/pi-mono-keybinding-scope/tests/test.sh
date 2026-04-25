#!/bin/bash
set +e

mkdir -p /logs/verifier
REWARD_FILE="/logs/verifier/reward.txt"

# Ensure common tool paths
export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

cd /workspace/pi-mono 2>/dev/null || cd /workspace/$(ls /workspace | head -1) 2>/dev/null

SCORE_INT=0

# Find bun
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

echo "Using bun at: $BUN_BIN"
echo "Working dir: $(pwd)"

###############################################################################
# Gate 0 (structural sanity, 0.05): The fix must touch keybinding/runner code.
###############################################################################
echo ""
echo "=== Gate 0 (structural, 0.05): Fix touches relevant code ==="

RUNNER_FILE="packages/coding-agent/src/core/extensions/runner.ts"
KB_AGENT_FILE="packages/coding-agent/src/core/keybindings.ts"
KB_TUI_FILE="packages/tui/src/keybindings.ts"

GATE0_OK=0
if [ -f "$RUNNER_FILE" ] || [ -f "$KB_AGENT_FILE" ] || [ -f "$KB_TUI_FILE" ]; then
    # Check that someone has shifted away from the hardcoded RESERVED list OR added scope-based mechanism
    SCOPE_HINTS=0
    grep -q -E "scope|Scope|picker|session\.|tree\.|models\." "$RUNNER_FILE" 2>/dev/null && SCOPE_HINTS=$((SCOPE_HINTS+1))
    grep -q -E "scope|Scope" "$KB_AGENT_FILE" 2>/dev/null && SCOPE_HINTS=$((SCOPE_HINTS+1))
    if [ "$SCOPE_HINTS" -ge 1 ]; then
        GATE0_OK=1
        SCORE_INT=$((SCORE_INT + 5))
        echo "Gate 0: PASS (+0.05)"
    else
        echo "Gate 0: FAIL (no scope-related changes detected)"
    fi
else
    echo "Gate 0: FAIL (target files missing)"
fi

###############################################################################
# Gate 1 (P2P, 0.10): Existing shortcut conflict tests still pass
###############################################################################
echo ""
echo "=== Gate 1 (P2P, 0.10): Existing shortcut-conflict tests still pass ==="

GATE1_OUT=$("$BUN_BIN" test packages/coding-agent/test/extensions-runner.test.ts -t "shortcut conflicts" 2>&1)
echo "$GATE1_OUT" | tail -8
GATE1_FAIL=$(echo "$GATE1_OUT" | grep -cE "\(fail\)")
GATE1_PASS=$(echo "$GATE1_OUT" | grep -cE "\(pass\)")
if [ "$GATE1_FAIL" -eq 0 ] && [ "$GATE1_PASS" -ge 4 ]; then
    SCORE_INT=$((SCORE_INT + 10))
    echo "Gate 1: PASS (+0.10) [$GATE1_PASS pass, $GATE1_FAIL fail]"
else
    echo "Gate 1: FAIL [$GATE1_PASS pass, $GATE1_FAIL fail]"
fi

###############################################################################
# Gate 2 (F2P behavioral, 0.30):
# Picker-only keys (e.g. ctrl+s for toggleSessionSort, ctrl+r for renameSession)
# should NOT produce a "conflict with built-in" style warning when registered
# by an extension. They should be ALLOWED in the resulting shortcut map.
###############################################################################
echo ""
echo "=== Gate 2 (F2P, 0.30): picker-only keys do NOT trigger built-in conflict warnings ==="

VG2=packages/coding-agent/test/_verifier_gate2.test.ts
cat > "$VG2" << 'TESTEOF'
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

describe("verifier-gate2: picker-scope keys not flagged", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-vg2-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("ctrl+s and ctrl+r (picker-only bindings) produce no built-in-conflict warnings and are registered", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+s", {
                    description: "session-picker scope key",
                    handler: async () => {},
                });
                pi.registerShortcut("ctrl+r", {
                    description: "another picker-scope key",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "picker-keys.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        const warnMessages = warnSpy.mock.calls.map(c => c.map(String).join(" "));
        const diags = (runner as any).shortcutDiagnostics ?? [];
        const diagMessages: string[] = diags.map((d: any) => String(d?.message ?? ""));
        const allMessages = [...warnMessages, ...diagMessages].join("\n");

        // Picker-scope action ids that should NOT appear as conflicts
        const pickerActionIds = [
            "toggleSessionSort", "renameSession", "togglePath",
            "togglePinned", "toggleNamedFilter",
        ];
        for (const actionId of pickerActionIds) {
            const lc = allMessages.toLowerCase();
            // Should not warn that the extension shortcut conflicts with these picker actions
            const conflictMention = lc.includes(actionId.toLowerCase()) &&
                (lc.includes("conflict") || lc.includes("built-in") || lc.includes("reserved"));
            expect(conflictMention, `unexpected conflict warning for picker action ${actionId}: ${allMessages}`).toBe(false);
        }

        // Both extension shortcuts must be registered (not blocked).
        expect(shortcuts.has("ctrl+s")).toBe(true);
        expect(shortcuts.has("ctrl+r")).toBe(true);

        warnSpy.mockRestore();
    });
});
TESTEOF

GATE2_OUT=$("$BUN_BIN" test "$VG2" 2>&1)
echo "$GATE2_OUT" | tail -15
GATE2_FAIL=$(echo "$GATE2_OUT" | grep -cE "\(fail\)")
GATE2_PASS=$(echo "$GATE2_OUT" | grep -cE "\(pass\)")
if [ "$GATE2_PASS" -ge 1 ] && [ "$GATE2_FAIL" -eq 0 ]; then
    SCORE_INT=$((SCORE_INT + 30))
    echo "Gate 2: PASS (+0.30)"
else
    echo "Gate 2: FAIL [$GATE2_PASS pass, $GATE2_FAIL fail]"
fi
rm -f "$VG2"

###############################################################################
# Gate 3 (F2P behavioral, 0.30):
# Editor-scope keys (e.g. ctrl+b for cursorLeft, ctrl+f for cursorRight) MUST
# still produce a warning when an extension tries to claim them, because they
# remain truly conflicting. This guards against the trivial "remove all checks" fix.
###############################################################################
echo ""
echo "=== Gate 3 (F2P, 0.30): editor-scope keys still produce conflict warnings ==="

VG3=packages/coding-agent/test/_verifier_gate3.test.ts
cat > "$VG3" << 'TESTEOF'
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

describe("verifier-gate3: editor-scope keys still flagged", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-vg3-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("ctrl+b (editor cursorLeft) still produces a conflict signal", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+b", {
                    description: "tries to claim editor cursorLeft key",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "editor-key.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        runner.getShortcuts(DEFAULT_KEYBINDINGS);

        const warnMessages = warnSpy.mock.calls.map(c => c.map(String).join(" "));
        const diags = (runner as any).shortcutDiagnostics ?? [];
        const diagMessages: string[] = diags.map((d: any) => String(d?.message ?? ""));
        const allMessages = [...warnMessages, ...diagMessages].join("\n").toLowerCase();

        // Must signal a conflict for an editor-scope action (cursorLeft)
        // Accept either an explicit cursorLeft mention OR a generic conflict/built-in mention with ctrl+b
        const mentionsCursorLeft = allMessages.includes("cursorleft");
        const mentionsCtrlBConflict = allMessages.includes("ctrl+b") &&
            (allMessages.includes("conflict") || allMessages.includes("built-in") || allMessages.includes("reserved"));
        expect(mentionsCursorLeft || mentionsCtrlBConflict,
            `expected an editor-scope conflict signal for ctrl+b but got:\n${allMessages}`).toBe(true);

        warnSpy.mockRestore();
    });

    it("reserved app action key (e.g. ctrl+c for app.clear) is still blocked from registration", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+c", {
                    description: "tries to claim app.clear",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "reserved-key.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        // ctrl+c is a reserved/app-critical key — extension must NOT take it over.
        expect(shortcuts.has("ctrl+c")).toBe(false);

        warnSpy.mockRestore();
    });
});
TESTEOF

GATE3_OUT=$("$BUN_BIN" test "$VG3" 2>&1)
echo "$GATE3_OUT" | tail -20
GATE3_FAIL=$(echo "$GATE3_OUT" | grep -cE "\(fail\)")
GATE3_PASS=$(echo "$GATE3_OUT" | grep -cE "\(pass\)")
if [ "$GATE3_PASS" -ge 2 ] && [ "$GATE3_FAIL" -eq 0 ]; then
    SCORE_INT=$((SCORE_INT + 30))
    echo "Gate 3: PASS (+0.30)"
elif [ "$GATE3_PASS" -ge 1 ] && [ "$GATE3_FAIL" -le 1 ]; then
    SCORE_INT=$((SCORE_INT + 15))
    echo "Gate 3: PARTIAL (+0.15) [$GATE3_PASS pass, $GATE3_FAIL fail]"
else
    echo "Gate 3: FAIL [$GATE3_PASS pass, $GATE3_FAIL fail]"
fi
rm -f "$VG3"

###############################################################################
# Gate 4 (F2P behavioral, 0.15):
# Verify the *base* behavior was buggy (sanity that we're testing real fix):
# Specifically, verify that the unmodified RESERVED list approach has been
# replaced — i.e., grepping for the specific old hardcoded list should show
# either no list, or the picker-scope ids are excluded from being flagged.
# Behavioral check: register an extension shortcut at a key that ONLY exists
# in a picker-scope binding (not also in editor scope), and confirm it ends
# up in the shortcuts map AND no diagnostic mentions a built-in conflict.
###############################################################################
echo ""
echo "=== Gate 4 (F2P, 0.15): no diagnostic emitted for purely-picker bindings ==="

VG4=packages/coding-agent/test/_verifier_gate4.test.ts
cat > "$VG4" << 'TESTEOF'
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

describe("verifier-gate4: zero diagnostics for picker-only keys", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-vg4-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("registering picker-scope key produces zero shortcut diagnostics", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+s", {
                    description: "picker scope only",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "ext.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        const diags = (runner as any).shortcutDiagnostics ?? [];
        // No diagnostic at all should be raised for the lone picker-scope ctrl+s registration.
        expect(diags.length).toBe(0);
        expect(shortcuts.has("ctrl+s")).toBe(true);

        warnSpy.mockRestore();
    });
});
TESTEOF

GATE4_OUT=$("$BUN_BIN" test "$VG4" 2>&1)
echo "$GATE4_OUT" | tail -12
GATE4_FAIL=$(echo "$GATE4_OUT" | grep -cE "\(fail\)")
GATE4_PASS=$(echo "$GATE4_OUT" | grep -cE "\(pass\)")
if [ "$GATE4_PASS" -ge 1 ] && [ "$GATE4_FAIL" -eq 0 ]; then
    SCORE_INT=$((SCORE_INT + 15))
    echo "Gate 4: PASS (+0.15)"
else
    echo "Gate 4: FAIL [$GATE4_PASS pass, $GATE4_FAIL fail]"
fi
rm -f "$VG4"

###############################################################################
# Gate 5 (typecheck regression, 0.10): Whole package still type-checks/builds
# at the test level — i.e. the rest of the existing tests in the file haven't
# been broken by the change.
###############################################################################
echo ""
echo "=== Gate 5 (P2P, 0.10): full extensions-runner.test.ts file passes ==="

GATE5_OUT=$("$BUN_BIN" test packages/coding-agent/test/extensions-runner.test.ts 2>&1)
echo "$GATE5_OUT" | tail -6
GATE5_FAIL=$(echo "$GATE5_OUT" | grep -cE "\(fail\)")
GATE5_PASS=$(echo "$GATE5_OUT" | grep -cE "\(pass\)")
if [ "$GATE5_FAIL" -eq 0 ] && [ "$GATE5_PASS" -ge 6 ]; then
    SCORE_INT=$((SCORE_INT + 10))
    echo "Gate 5: PASS (+0.10) [$GATE5_PASS pass, $GATE5_FAIL fail]"
else
    echo "Gate 5: FAIL [$GATE5_PASS pass, $GATE5_FAIL fail]"
fi

###############################################################################
# Final reward
###############################################################################
REWARD=$(awk -v s="$SCORE_INT" 'BEGIN { printf "%.2f", s/100 }')
echo ""
echo "=== Final score: $SCORE_INT/100 = $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"
exit 0