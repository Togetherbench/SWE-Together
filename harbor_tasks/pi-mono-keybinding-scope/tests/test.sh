#!/bin/bash
set +e

mkdir -p /logs/verifier
REWARD_FILE="/logs/verifier/reward.txt"
cd /workspace/pi-mono

# Use integer scoring (hundredths) to avoid bc dependency, convert at end
SCORE_INT=0

###############################################################################
# Gate 1 (P2P, weight 0.05): Existing shortcut conflict tests still pass
# These 7 tests verify reserved/non-reserved conflict behavior.
# Passes on unmodified base AND correct fix (regression guard).
# F2P/P2P: P2P
###############################################################################

echo "=== Gate 1 (P2P): Existing shortcut conflict tests ==="
GATE1_OUTPUT=$(bun test packages/coding-agent/test/extensions-runner.test.ts -t "shortcut conflicts" 2>&1)
GATE1_PASS=$(echo "$GATE1_OUTPUT" | grep -c "(pass)")
GATE1_FAIL=$(echo "$GATE1_OUTPUT" | grep "(fail)" | grep -c "shortcut conflicts")
echo "$GATE1_OUTPUT" | tail -5
echo "Shortcut conflict tests: $GATE1_PASS pass, $GATE1_FAIL fail"

if [ "$GATE1_PASS" -ge 6 ] && [ "$GATE1_FAIL" -eq 0 ]; then
    SCORE_INT=$((SCORE_INT + 5))
    echo "Gate 1: PASS (+0.05)"
else
    echo "Gate 1: FAIL"
fi

###############################################################################
# Gate 2 (F2P, weight 0.35): Session-picker scope key ctrl+s NOT warned,
# AND editor-scope key ctrl+b still warned for cursorLeft.
# Fails on base (ctrl+s warns about toggleSessionSort). Passes on correct fix.
# Also guards against "remove all warnings" bad fix via ctrl+b check.
# F2P/P2P: F2P
###############################################################################

echo ""
echo "=== Gate 2 (F2P): ctrl+s scope-aware, ctrl+b still warned ==="

cat > packages/coding-agent/test/_verifier_gate2.test.ts << 'TESTEOF'
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

describe("gate2: scope-aware ctrl+s and ctrl+b", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-gate2-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("ctrl+s not warned for toggleSessionSort AND ctrl+b still warned for cursorLeft", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+s", {
                    description: "Test session-picker scope key",
                    handler: async () => {},
                });
                pi.registerShortcut("ctrl+b", {
                    description: "Test editor scope key",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "scope-test.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        const warnMessages = warnSpy.mock.calls.map(c => String(c[0]));

        // ctrl+s should NOT produce a warning about toggleSessionSort
        // (toggleSessionSort is session-picker scope, not checked for extension conflicts)
        const hasSessionSortWarn = warnMessages.some(w =>
            w.includes("toggleSessionSort") || w.includes("toggleSessionSort".toLowerCase())
        );
        expect(hasSessionSortWarn).toBe(false);

        // ctrl+b SHOULD still produce a warning about cursorLeft
        // (cursorLeft is editor scope, still checked for conflicts)
        const hasCursorLeftWarn = warnMessages.some(w =>
            w.includes("cursorLeft") || w.includes("cursorleft")
        );
        expect(hasCursorLeftWarn).toBe(true);

        // Both shortcuts should be allowed (neither is reserved)
        expect(shortcuts.has("ctrl+s")).toBe(true);
        expect(shortcuts.has("ctrl+b")).toBe(true);

        warnSpy.mockRestore();
    });
});
TESTEOF

GATE2_OUTPUT=$(bun test packages/coding-agent/test/_verifier_gate2.test.ts 2>&1)
GATE2_PASS=$(echo "$GATE2_OUTPUT" | grep -c "(pass)")
echo "$GATE2_OUTPUT" | tail -10
echo "Gate 2 tests: $GATE2_PASS pass"

if [ "$GATE2_PASS" -ge 1 ]; then
    SCORE_INT=$((SCORE_INT + 35))
    echo "Gate 2: PASS (+0.35)"
else
    echo "Gate 2: FAIL"
fi

###############################################################################
# Gate 3 (F2P, weight 0.35): Session-picker key ctrl+r NOT warned,
# AND reserved action ctrl+c still blocked.
# Fails on base (ctrl+r warns about renameSession). Passes on correct fix.
# Guards against "remove all conflict checking" via ctrl+c reserved check.
# F2P/P2P: F2P
###############################################################################

echo ""
echo "=== Gate 3 (F2P): ctrl+r scope-aware, ctrl+c still blocked ==="

cat > packages/coding-agent/test/_verifier_gate3.test.ts << 'TESTEOF'
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

describe("gate3: scope-aware ctrl+r and reserved ctrl+c", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-gate3-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("ctrl+r not warned for renameSession AND ctrl+c still blocked as reserved", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+r", {
                    description: "Test session-picker scope key",
                    handler: async () => {},
                });
                pi.registerShortcut("ctrl+c", {
                    description: "Test reserved key",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "scope-test.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        const warnMessages = warnSpy.mock.calls.map(c => String(c[0]));

        // ctrl+r should NOT produce a warning about renameSession
        // (renameSession is session-picker scope, not checked for extension conflicts)
        const hasRenameWarn = warnMessages.some(w =>
            w.includes("renameSession") || w.includes("renamesession")
        );
        expect(hasRenameWarn).toBe(false);

        // ctrl+r should be allowed in shortcuts
        expect(shortcuts.has("ctrl+r")).toBe(true);

        // ctrl+c should still be BLOCKED (it is reserved for 'clear')
        expect(shortcuts.has("ctrl+c")).toBe(false);

        warnSpy.mockRestore();
    });
});
TESTEOF

GATE3_OUTPUT=$(bun test packages/coding-agent/test/_verifier_gate3.test.ts 2>&1)
GATE3_PASS=$(echo "$GATE3_OUTPUT" | grep -c "(pass)")
echo "$GATE3_OUTPUT" | tail -10
echo "Gate 3 tests: $GATE3_PASS pass"

if [ "$GATE3_PASS" -ge 1 ]; then
    SCORE_INT=$((SCORE_INT + 35))
    echo "Gate 3: PASS (+0.35)"
else
    echo "Gate 3: FAIL"
fi

###############################################################################
# Gate 4 (F2P, weight 0.25): Session-picker key ctrl+backspace NOT warned.
# Fails on base (warns about deleteSessionNoninvasive). Passes on correct fix.
# F2P/P2P: F2P
###############################################################################

echo ""
echo "=== Gate 4 (F2P): ctrl+backspace scope-aware ==="

cat > packages/coding-agent/test/_verifier_gate4.test.ts << 'TESTEOF'
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

describe("gate4: scope-aware ctrl+backspace", () => {
    let tempDir: string;
    let extensionsDir: string;
    let sessionManager: SessionManager;
    let modelRegistry: ModelRegistry;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-gate4-"));
        extensionsDir = path.join(tempDir, "extensions");
        fs.mkdirSync(extensionsDir);
        sessionManager = SessionManager.inMemory();
        const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
        modelRegistry = new ModelRegistry(authStorage);
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    it("ctrl+backspace not warned for deleteSessionNoninvasive", async () => {
        const extCode = `
            export default function(pi) {
                pi.registerShortcut("ctrl+backspace", {
                    description: "Test session-picker scope key",
                    handler: async () => {},
                });
            }
        `;
        fs.writeFileSync(path.join(extensionsDir, "scope-test.ts"), extCode);

        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

        const result = await discoverAndLoadExtensions([], tempDir, tempDir);
        const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
        const shortcuts = runner.getShortcuts(DEFAULT_KEYBINDINGS);

        const warnMessages = warnSpy.mock.calls.map(c => String(c[0]));

        // ctrl+backspace should NOT produce a warning about deleteSessionNoninvasive
        // (deleteSessionNoninvasive is session-picker scope, not checked for conflicts)
        const hasDeleteSessionWarn = warnMessages.some(w =>
            w.includes("deleteSessionNoninvasive") || w.includes("deletesessionnoninvasive")
        );
        expect(hasDeleteSessionWarn).toBe(false);

        // ctrl+backspace should be allowed
        expect(shortcuts.has("ctrl+backspace")).toBe(true);

        warnSpy.mockRestore();
    });
});
TESTEOF

GATE4_OUTPUT=$(bun test packages/coding-agent/test/_verifier_gate4.test.ts 2>&1)
GATE4_PASS=$(echo "$GATE4_OUTPUT" | grep -c "(pass)")
echo "$GATE4_OUTPUT" | tail -10
echo "Gate 4 tests: $GATE4_PASS pass"

if [ "$GATE4_PASS" -ge 1 ]; then
    SCORE_INT=$((SCORE_INT + 25))
    echo "Gate 4: PASS (+0.25)"
else
    echo "Gate 4: FAIL"
fi

###############################################################################
# Final score — convert from hundredths to decimal
###############################################################################

echo ""
echo "================================"
# Convert integer hundredths to decimal string
WHOLE=$((SCORE_INT / 100))
FRAC=$((SCORE_INT % 100))
if [ "$FRAC" -lt 10 ]; then
    SCORE="${WHOLE}.0${FRAC}"
else
    SCORE="${WHOLE}.${FRAC}"
fi
echo "Final score: $SCORE"
echo "================================"
echo "$SCORE" > "$REWARD_FILE"
