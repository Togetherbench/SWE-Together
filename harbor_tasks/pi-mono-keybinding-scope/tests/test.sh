#!/bin/bash
set +e

mkdir -p /logs/verifier
REWARD_FILE="/logs/verifier/reward.txt"
REWARD="0.0"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

cd /workspace/pi-mono 2>/dev/null || cd /workspace/$(ls /workspace 2>/dev/null | head -1) 2>/dev/null

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

if [ ! -f "$RUNNER_FILE" ] || [ ! -f "$KB_AGENT_FILE" ] || [ ! -f "$KB_TUI_FILE" ]; then
    echo "ERROR: required source files missing"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

###############################################################################
# P2P GATE: existing extensions-runner tests must still pass (gating, no reward)
###############################################################################
echo ""
echo "=== P2P Gate: existing extensions-runner tests must still pass ==="

P2P_OUT=$("$BUN_BIN" test packages/coding-agent/test/extensions-runner.test.ts 2>&1)
echo "$P2P_OUT" | tail -20
P2P_FAIL=$(echo "$P2P_OUT" | grep -cE "\(fail\)")
P2P_PASS=$(echo "$P2P_OUT" | grep -cE "\(pass\)")
if [ "$P2P_FAIL" -gt 0 ] || [ "$P2P_PASS" -lt 1 ]; then
    echo "P2P GATE FAILED: existing tests broken ($P2P_PASS pass, $P2P_FAIL fail)"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
echo "P2P gate passed ($P2P_PASS pass, $P2P_FAIL fail)"

# We'll accumulate a numeric score in hundredths.
SCORE_PCT=0

###############################################################################
# F2P Gate A (0.20): Behavioral — picker-only key (ctrl+s) registers WITHOUT
# being flagged as a built-in/reserved conflict.
# ctrl+s in DEFAULT_KEYBINDINGS is bound only to picker-scope actions
# (app.session.toggleSort, app.models.save). On the buggy base, this key
# is treated as reserved/conflicting. After a correct fix, it should register
# cleanly with no conflict warning mentioning ctrl+s.
###############################################################################
echo ""
echo "=== F2P Gate A (0.20): picker-only ctrl+s registers without conflict ==="

VG_A="$TEST_DIR/_verifier_picker_ctrls.test.ts"
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

describe("verifier-picker-ctrls", () => {
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

    it("ctrl+s (picker-scope only) is registered, not flagged as conflict", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+s", {
                    description: "picker-scope-only key",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "picker.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        expect(shortcuts.has("ctrl+s")).toBe(true);

        const warnMsgs = warnSpy.mock.calls.map(c => c.map(String).join(" ")).join("\n");
        const diags = (runner as any).shortcutDiagnostics ?? [];
        const diagMsgs = diags.map((d: any) => String(d?.message ?? "")).join("\n");
        const all = warnMsgs + "\n" + diagMsgs;

        const flagged = /ctrl\+s/i.test(all) && /(conflict|built-in|reserved|blocked)/i.test(all);
        expect(flagged, `ctrl+s unexpectedly flagged. Messages:\n${all}`).toBe(false);

        warnSpy.mockRestore();
    });
});
TESTEOF

VG_A_OUT=$("$BUN_BIN" test "$VG_A" 2>&1)
echo "$VG_A_OUT" | tail -15
VGA_FAIL=$(echo "$VG_A_OUT" | grep -cE "\(fail\)")
VGA_PASS=$(echo "$VG_A_OUT" | grep -cE "\(pass\)")
if [ "$VGA_PASS" -ge 1 ] && [ "$VGA_FAIL" -eq 0 ]; then
    SCORE_PCT=$((SCORE_PCT + 20))
    echo "Gate A: PASS (+0.20)"
else
    echo "Gate A: FAIL"
fi
rm -f "$VG_A"

###############################################################################
# F2P Gate B (0.20): Behavioral — multiple picker-only keys all register cleanly
# (ctrl+r, ctrl+p, ctrl+n in default bindings are picker-scope: rename,
# togglePath, toggleNamedFilter on session picker).
###############################################################################
echo ""
echo "=== F2P Gate B (0.20): multiple picker-only keys register without conflict ==="

VG_B="$TEST_DIR/_verifier_picker_multi.test.ts"
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

describe("verifier-picker-multi", () => {
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

    it("ctrl+r and ctrl+n (picker-only in default bindings) register cleanly", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+r", { description: "x", handler: async () => {} });
                pi.registerShortcut("ctrl+n", { description: "x", handler: async () => {} });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "picker2.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        expect(shortcuts.has("ctrl+r")).toBe(true);
        expect(shortcuts.has("ctrl+n")).toBe(true);

        const warnMsgs = warnSpy.mock.calls.map(c => c.map(String).join(" ")).join("\n");
        const diags = (runner as any).shortcutDiagnostics ?? [];
        const diagMsgs = diags.map((d: any) => String(d?.message ?? "")).join("\n");
        const all = warnMsgs + "\n" + diagMsgs;

        for (const key of ["ctrl+r", "ctrl+n"]) {
            const flagged = new RegExp(key.replace("+", "\\+"), "i").test(all)
                && /(conflict|built-in|reserved|blocked)/i.test(all);
            expect(flagged, `${key} unexpectedly flagged.\n${all}`).toBe(false);
        }
        warnSpy.mockRestore();
    });
});
TESTEOF

VG_B_OUT=$("$BUN_BIN" test "$VG_B" 2>&1)
echo "$VG_B_OUT" | tail -15
VGB_FAIL=$(echo "$VG_B_OUT" | grep -cE "\(fail\)")
VGB_PASS=$(echo "$VG_B_OUT" | grep -cE "\(pass\)")
if [ "$VGB_PASS" -ge 1 ] && [ "$VGB_FAIL" -eq 0 ]; then
    SCORE_PCT=$((SCORE_PCT + 20))
    echo "Gate B: PASS (+0.20)"
else
    echo "Gate B: FAIL"
fi
rm -f "$VG_B"

###############################################################################
# F2P Gate C (0.25): Behavioral negative — editor/global keys MUST still
# produce a conflict (warning OR be blocked from registering).
# ctrl+c → app.clear (global/editor scope) — must not be silently allowed.
# ctrl+t → app.thinking.cycle (global) — must produce conflict signal.
###############################################################################
echo ""
echo "=== F2P Gate C (0.25): editor/global keys still flagged or blocked ==="

VG_C="$TEST_DIR/_verifier_global_blocked.test.ts"
cat > "$VG_C" << 'TESTEOF'
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

describe("verifier-global-blocked", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-vgc-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("ctrl+c (app.clear, global) is signalled as conflict (blocked or warned)", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+c", {
                    description: "Conflicts with global app.clear",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "global.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        const warnMsgs = warnSpy.mock.calls.map(c => c.map(String).join(" ")).join("\n");
        const diags = (runner as any).shortcutDiagnostics ?? [];
        const diagMsgs = diags.map((d: any) => String(d?.message ?? "")).join("\n");
        const all = warnMsgs + "\n" + diagMsgs;

        const blocked = !shortcuts.has("ctrl+c");
        const warned = /ctrl\+c/i.test(all) && /(conflict|built-in|reserved|blocked)/i.test(all);

        expect(blocked || warned, `ctrl+c was silently allowed. Messages:\n${all}`).toBe(true);
        warnSpy.mockRestore();
    });
});
TESTEOF

VG_C_OUT=$("$BUN_BIN" test "$VG_C" 2>&1)
echo "$VG_C_OUT" | tail -15
VGC_FAIL=$(echo "$VG_C_OUT" | grep -cE "\(fail\)")
VGC_PASS=$(echo "$VG_C_OUT" | grep -cE "\(pass\)")
if [ "$VGC_PASS" -ge 1 ] && [ "$VGC_FAIL" -eq 0 ]; then
    SCORE_PCT=$((SCORE_PCT + 25))
    echo "Gate C: PASS (+0.25)"
else
    echo "Gate C: FAIL"
fi
rm -f "$VG_C"

###############################################################################
# F2P Gate D (0.15): Structural — runner.ts has been edited to introduce
# scope-awareness. Buggy base uses RESERVED_KEYBINDINGS_FOR_EXTENSION_CONFLICTS
# allow-list. A correct fix should either remove that or implement scope-based
# logic (PICKER_SCOPES, isGlobalKeybinding, scope checks, etc.).
# This gate detects "did the structural concept land", but is gated low.
###############################################################################
echo ""
echo "=== F2P Gate D (0.15): runner.ts shows scope-based discrimination ==="

D_HIT=0
if grep -qE "(PICKER_SCOPES|isGlobalKeybinding|isPickerScope|scope[: ]*['\"](picker|editor|app|overlay|selector|session-picker)|app\.session\.|app\.models\.|app\.tree\.|definitions\[.*\]\.scope|getEditorScope)" "$RUNNER_FILE" 2>/dev/null; then
    D_HIT=1
fi

# Also accept that scope-handling moved to keybindings.ts and runner consults it.
if [ "$D_HIT" -eq 0 ]; then
    if grep -qE "(scope|getEditorScope|canConflict|conflictsWith)" "$KB_AGENT_FILE" 2>/dev/null \
       && grep -qE "(scope|getEditorScope|canConflict|getDefinitions)" "$RUNNER_FILE" 2>/dev/null; then
        D_HIT=1
    fi
fi

if [ "$D_HIT" -eq 1 ]; then
    SCORE_PCT=$((SCORE_PCT + 15))
    echo "Gate D: PASS (+0.15)"
else
    echo "Gate D: FAIL — no scope-based discrimination detected in runner/keybindings"
fi

###############################################################################
# F2P Gate E (0.10): Completeness — keybindings.ts (agent or tui) shows that
# picker-scoped actions have been distinguished from editor/app actions.
# A complete fix touches keybindings declarations OR runner with scope tags.
###############################################################################
echo ""
echo "=== F2P Gate E (0.10): keybinding declarations carry scope info ==="

E_HIT=0
# Look for scope: "picker"|"selector"|"session-picker"|"overlay" patterns in
# either tui or agent keybindings files, OR PICKER_SCOPES style array.
if grep -qE "scope[ ]*:[ ]*['\"](picker|selector|session-picker|overlay|tree|models)" "$KB_AGENT_FILE" "$KB_TUI_FILE" 2>/dev/null; then
    E_HIT=1
fi

if [ "$E_HIT" -eq 0 ]; then
    if grep -qE "PICKER_SCOPES|SCOPE_COEXISTENCE|KEYBINDING_SCOPES|coexistingScopes|conflictsWith" "$KB_AGENT_FILE" "$KB_TUI_FILE" "$RUNNER_FILE" 2>/dev/null; then
        E_HIT=1
    fi
fi

if [ "$E_HIT" -eq 1 ]; then
    SCORE_PCT=$((SCORE_PCT + 10))
    echo "Gate E: PASS (+0.10)"
else
    echo "Gate E: FAIL — no scope-tagged keybinding declarations"
fi

###############################################################################
# F2P Gate F (0.10): Behavioral — extension-to-extension conflict detection
# still works (a correct refactor must preserve the second-extension-wins
# diagnostic). This catches over-aggressive removals of conflict logic.
###############################################################################
echo ""
echo "=== F2P Gate F (0.10): extension-vs-extension conflict still detected ==="

VG_F="$TEST_DIR/_verifier_ext_ext.test.ts"
cat > "$VG_F" << 'TESTEOF'
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

describe("verifier-ext-ext", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-vgf-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("two extensions registering same key produce a conflict diagnostic", async () => {
        const ext1 = `
            export default function(pi) {
                pi.registerShortcut("ctrl+shift+y", { description: "a", handler: async () => {} });
            }
        `;
        const ext2 = `
            export default function(pi) {
                pi.registerShortcut("ctrl+shift+y", { description: "b", handler: async () => {} });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "a.ts"), ext1);
        fs.writeFileSync(path.join(extensionsDir, "b.ts"), ext2);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        expect(shortcuts.has("ctrl+shift+y")).toBe(true);

        const warnMsgs = warnSpy.mock.calls.map(c => c.map(String).join(" ")).join("\n");
        const diags = (runner as any).shortcutDiagnostics ?? [];
        const diagMsgs = diags.map((d: any) => String(d?.message ?? "")).join("\n");
        const all = warnMsgs + "\n" + diagMsgs;

        const detected = /ctrl\+shift\+y/i.test(all) && /conflict/i.test(all);
        expect(detected, `extension-vs-extension conflict not reported. Messages:\n${all}`).toBe(true);

        warnSpy.mockRestore();
    });
});
TESTEOF

VG_F_OUT=$("$BUN_BIN" test "$VG_F" 2>&1)
echo "$VG_F_OUT" | tail -15
VGF_FAIL=$(echo "$VG_F_OUT" | grep -cE "\(fail\)")
VGF_PASS=$(echo "$VG_F_OUT" | grep -cE "\(pass\)")
if [ "$VGF_PASS" -ge 1 ] && [ "$VGF_FAIL" -eq 0 ]; then
    SCORE_PCT=$((SCORE_PCT + 10))
    echo "Gate F: PASS (+0.10)"
else
    echo "Gate F: FAIL"
fi
rm -f "$VG_F"

###############################################################################
# Final
###############################################################################
echo ""
echo "=== Total ==="
REWARD=$(awk -v s="$SCORE_PCT" 'BEGIN { printf "%.2f", s/100 }')
echo "Score pct: $SCORE_PCT  → REWARD=$REWARD"
echo "$REWARD" > "$REWARD_FILE"
exit 0