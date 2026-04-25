#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0
TOTAL=0

pass() { local w=$1; shift; echo "PASS ($w): $*"; SCORE=$((SCORE + w)); TOTAL=$((TOTAL + w)); }
fail() { local w=$1; shift; echo "FAIL ($w): $*"; TOTAL=$((TOTAL + w)); }

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
which npx >/dev/null 2>&1 || export PATH="/root/.npm-global/bin:/root/.local/bin:$PATH"

REPO_DIR="/workspace/pi-mono"
if [ ! -d "$REPO_DIR" ]; then
    REPO_DIR=$(find /workspace -maxdepth 2 -type d -name "pi-mono" 2>/dev/null | head -1)
fi
if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ]; then
    echo "ERROR: cannot locate pi-mono workspace"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

cd "$REPO_DIR" || { echo "0.0" > "$REWARD_FILE"; exit 0; }

PKG_DIR="$REPO_DIR/packages/coding-agent"
PM_FILE="$PKG_DIR/src/core/package-manager.ts"
MAIN_FILE="$PKG_DIR/src/main.ts"

if [ ! -f "$PM_FILE" ] || [ ! -f "$MAIN_FILE" ]; then
    echo "ERROR: required source files missing"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ============================================================
# Structural pre-check (weight 5): install() handles "local" type
# ============================================================
echo "=== Structural Gate: install() recognizes local source type ==="
# Look for any handling of parsed.type === "local" or parsed.type==="local" in install method body
if awk '/async install\(/,/^\t\}/' "$PM_FILE" | grep -E '"local"|'\''local'\''' >/dev/null; then
    pass 5 "install() references local source type"
else
    fail 5 "install() does not handle local source type"
fi

# ============================================================
# Structural Gate: remove() handles local source type
# ============================================================
echo "=== Structural Gate: remove() recognizes local source type ==="
if awk '/async remove\(/,/^\t\}/' "$PM_FILE" | grep -E '"local"|'\''local'\''' >/dev/null; then
    pass 5 "remove() references local source type"
else
    fail 5 "remove() does not handle local source type"
fi

# ============================================================
# Structural Gate: install/remove no longer throw "Unsupported"
# unconditionally for local. Confirm "Unsupported" message remains
# but local branch returns/handles before reaching it.
# ============================================================
echo "=== Structural Gate: source no longer throws on local in install ==="
INSTALL_BODY=$(awk '/async install\(/,/^\t\}/' "$PM_FILE")
REMOVE_BODY=$(awk '/async remove\(/,/^\t\}/' "$PM_FILE")
# Check that install body contains "local" before the Unsupported throw, OR no Unsupported throw remains
if echo "$INSTALL_BODY" | grep -q "local"; then
    pass 5 "install() body mentions local handling"
else
    fail 5 "install() body has no local handling"
fi
if echo "$REMOVE_BODY" | grep -q "local"; then
    pass 5 "remove() body mentions local handling"
else
    fail 5 "remove() body has no local handling"
fi

# ============================================================
# P2P Gate (weight 15): Existing package-manager tests pass
# ============================================================
echo ""
echo "=== P2P Gate: Existing package-manager tests ==="
P2P_OUTPUT=$(cd "$PKG_DIR" && timeout 300 npx vitest --run test/package-manager.test.ts 2>&1)
echo "$P2P_OUTPUT" | tail -25
if echo "$P2P_OUTPUT" | grep -qE "Tests +[0-9]+ passed" && ! echo "$P2P_OUTPUT" | grep -qE "Tests.*[0-9]+ failed"; then
    pass 15 "Existing package-manager tests pass"
else
    fail 15 "Existing package-manager tests failed/broken"
fi

# ============================================================
# F2P Behavioral Gates: Run a fresh behavioral test we author here
# ============================================================
echo ""
echo "=== F2P Behavioral Gates: writing local-install.test.ts ==="

TEST_FILE="$PKG_DIR/test/local-install-bench.test.ts"
mkdir -p "$PKG_DIR/test"

# Inspect existing test file to mirror its imports/setup pattern
EXISTING_TEST="$PKG_DIR/test/package-manager.test.ts"

cat > "$TEST_FILE" <<'TEST_EOF'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve, isAbsolute } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PackageManager } from "../src/core/package-manager.js";
import { SettingsManager } from "../src/core/settings-manager.js";

describe("local extension install/remove (bench)", () => {
	let tempDir: string;
	let agentDir: string;
	let projectDir: string;
	let settingsManager: SettingsManager;
	let packageManager: PackageManager;

	beforeEach(() => {
		tempDir = mkdtempSync(join(tmpdir(), "pi-local-bench-"));
		agentDir = join(tempDir, "agent");
		projectDir = join(tempDir, "project");
		mkdirSync(agentDir, { recursive: true });
		mkdirSync(join(projectDir, ".pi"), { recursive: true });
		mkdirSync(join(projectDir, "extensions"), { recursive: true });
		writeFileSync(join(projectDir, "extensions", "my-ext.ts"), "export default {};");
		settingsManager = new SettingsManager({ agentDir, cwd: projectDir });
		packageManager = new PackageManager({
			settingsManager,
			agentDir,
			cwd: projectDir,
		} as any);
	});

	afterEach(() => {
		try { rmSync(tempDir, { recursive: true, force: true }); } catch {}
	});

	it("install accepts a local file path without throwing Unsupported", async () => {
		const extPath = join(projectDir, "extensions", "my-ext.ts");
		let err: any = null;
		try {
			await packageManager.install(extPath);
		} catch (e) {
			err = e;
		}
		// Must not throw "Unsupported"
		if (err) {
			expect(String(err.message || err)).not.toMatch(/Unsupported/i);
		}
	});

	it("install validates non-existent local path", async () => {
		const bogus = join(projectDir, "does-not-exist-xyz.ts");
		let threw = false;
		try {
			await packageManager.install(bogus);
		} catch (e) {
			threw = true;
		}
		expect(threw).toBe(true);
	});

	it("remove accepts a local file path without throwing Unsupported", async () => {
		const extPath = join(projectDir, "extensions", "my-ext.ts");
		let err: any = null;
		try {
			await packageManager.remove(extPath);
		} catch (e) {
			err = e;
		}
		if (err) {
			expect(String(err.message || err)).not.toMatch(/Unsupported/i);
		}
	});

	it("user-scope local path stored relative to agentDir settings file", async () => {
		const extPath = join(projectDir, "extensions", "my-ext.ts");
		// Try installAndPersist for user scope, falling back to install + manual settings inspection
		const pm: any = packageManager;
		if (typeof pm.installAndPersist === "function") {
			await pm.installAndPersist(extPath, { scope: "user" });
		} else {
			await pm.install(extPath);
		}
		const sm: any = settingsManager;
		const settings = typeof sm.getGlobalSettings === "function"
			? sm.getGlobalSettings()
			: typeof sm.getUserSettings === "function" ? sm.getUserSettings() : {};
		const pkgs = settings?.packages ?? [];
		expect(pkgs.length).toBeGreaterThan(0);
		const stored = pkgs[0]?.source ?? pkgs[0];
		const storedStr = typeof stored === "string" ? stored : JSON.stringify(stored);
		// Stored path must NOT be absolute, must NOT contain projectDir absolute path
		expect(storedStr).not.toContain(projectDir);
		// When resolved from agentDir, it must point to extPath
		// Extract path-like field
		const pathField = (typeof stored === "object" && stored?.path) ? stored.path : storedStr;
		const cleaned = pathField.replace(/^["']|["']$/g, "");
		// Resolve from agentDir
		const resolved = isAbsolute(cleaned) ? cleaned : resolve(agentDir, cleaned);
		expect(resolved).toBe(extPath);
	});

	it("project-scope local path stored relative to .pi directory", async () => {
		const extPath = join(projectDir, "extensions", "my-ext.ts");
		const pm: any = packageManager;
		if (typeof pm.installAndPersist === "function") {
			await pm.installAndPersist(extPath, { scope: "project" });
		} else {
			await pm.install(extPath, { local: true });
		}
		const sm: any = settingsManager;
		const settings = typeof sm.getProjectSettings === "function"
			? sm.getProjectSettings()
			: typeof sm.getLocalSettings === "function" ? sm.getLocalSettings() : {};
		const pkgs = settings?.packages ?? [];
		if (pkgs.length === 0) {
			// Some implementations only persist via installAndPersist; if absent, treat as N/A but fail
			throw new Error("project-scope packages not persisted");
		}
		const stored = pkgs[0]?.source ?? pkgs[0];
		const pathField = (typeof stored === "object" && stored?.path) ? stored.path : (typeof stored === "string" ? stored : "");
		const cleaned = pathField.replace(/^["']|["']$/g, "");
		const piDir = join(projectDir, ".pi");
		expect(cleaned).not.toContain(projectDir + "/extensions");
		const resolved = isAbsolute(cleaned) ? cleaned : resolve(piDir, cleaned);
		expect(resolved).toBe(extPath);
	});
});
TEST_EOF

# Run only this test file
F2P_OUTPUT=$(cd "$PKG_DIR" && timeout 300 npx vitest --run --reporter=verbose test/local-install-bench.test.ts 2>&1)
echo "$F2P_OUTPUT" | tail -80

passed_test() {
    echo "$F2P_OUTPUT" | grep -E "✓|√" | grep -qF "$1"
}

# Gate F1 (weight 12): install accepts local without Unsupported
if passed_test "install accepts a local file path without throwing Unsupported"; then
    pass 12 "install() handles local paths"
else
    fail 12 "install() does not handle local paths properly"
fi

# Gate F2 (weight 8): install validates non-existent path
if passed_test "install validates non-existent local path"; then
    pass 8 "install() validates path existence"
else
    fail 8 "install() doesn't validate path existence"
fi

# Gate F3 (weight 10): remove accepts local without Unsupported
if passed_test "remove accepts a local file path without throwing Unsupported"; then
    pass 10 "remove() handles local paths"
else
    fail 10 "remove() does not handle local paths"
fi

# Gate F4 (weight 15): user-scope local path relative to agentDir
if passed_test "user-scope local path stored relative to agentDir settings file"; then
    pass 15 "User-scope path stored relative to agentDir"
else
    fail 15 "User-scope path NOT stored relative to agentDir"
fi

# Gate F5 (weight 15): project-scope local path relative to .pi
if passed_test "project-scope local path stored relative to .pi directory"; then
    pass 15 "Project-scope path stored relative to .pi"
else
    fail 15 "Project-scope path NOT stored relative to .pi"
fi

# ============================================================
# Structural audit: main.ts updatePackageSources scope-aware
# ============================================================
echo ""
echo "=== Structural Audit: main.ts updatePackageSources scope-aware ==="
if grep -q "updatePackageSources" "$MAIN_FILE"; then
    # check that updatePackageSources or its callers use agentDir or .pi as base
    UPS_REGION=$(awk '/updatePackageSources/,/^\}/' "$MAIN_FILE" | head -200)
    if echo "$UPS_REGION" | grep -E "agentDir|\.pi|baseDir|settingsDir|relative" >/dev/null; then
        pass 5 "updatePackageSources uses scope-aware base directory"
    else
        fail 5 "updatePackageSources lacks scope-aware base"
    fi
else
    fail 5 "updatePackageSources not found in main.ts"
fi

# ============================================================
# Structural audit: package-manager resolvePath / scope-aware base
# ============================================================
echo ""
echo "=== Structural Audit: package-manager scope-aware path resolution ==="
# Look for any resolution that branches on scope, or uses agentDir vs cwd/.pi
if grep -E "scope.*===.*['\"]user['\"]|scope.*===.*['\"]project['\"]" "$PM_FILE" >/dev/null && \
   grep -E "agentDir|\.pi" "$PM_FILE" >/dev/null; then
    pass 5 "package-manager has scope-aware base resolution"
else
    fail 5 "package-manager lacks scope-aware base resolution"
fi

# ============================================================
# Final reward
# ============================================================
echo ""
echo "=== Results ==="
echo "Score: $SCORE / $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
    REWARD="0.00"
else
    REWARD=$(awk "BEGIN { printf \"%.2f\", $SCORE / $TOTAL }")
fi

echo "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"