#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0

write_reward() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:/root/.npm-global/bin:/root/.local/bin:$PATH"

REPO_DIR="/workspace/pi-mono"
if [ ! -d "$REPO_DIR" ]; then
    REPO_DIR=$(find /workspace -maxdepth 2 -type d -name "pi-mono" 2>/dev/null | head -1)
fi
if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ]; then
    echo "ERROR: cannot locate pi-mono workspace"
    write_reward
fi

cd "$REPO_DIR" || write_reward

PKG_DIR="$REPO_DIR/packages/coding-agent"
PM_FILE="$PKG_DIR/src/core/package-manager.ts"
MAIN_FILE="$PKG_DIR/src/main.ts"

if [ ! -f "$PM_FILE" ] || [ ! -f "$MAIN_FILE" ]; then
    echo "ERROR: required source files missing"
    write_reward
fi

# ============================================================
# P2P GATE (no reward; just guard against destruction)
# Existing package-manager tests must still pass.
# ============================================================
echo "=== P2P Gate: Existing package-manager tests must pass ==="
P2P_OUTPUT=$(cd "$PKG_DIR" && timeout 300 npx vitest --run test/package-manager.test.ts 2>&1)
echo "$P2P_OUTPUT" | tail -30
if ! echo "$P2P_OUTPUT" | grep -qE "Tests +[0-9]+ passed"; then
    echo "P2P GATE FAILED: existing tests didn't run/pass"
    write_reward
fi
if echo "$P2P_OUTPUT" | grep -qE "Tests.*[0-9]+ failed"; then
    echo "P2P GATE FAILED: regression in existing tests"
    write_reward
fi
echo "P2P gate passed"

# ============================================================
# F2P BEHAVIORAL GATES (all reward comes from these)
# Each gate fails on the buggy/unmodified base.
# ============================================================

TEST_FILE="$PKG_DIR/test/local-install-bench.test.ts"

cat > "$TEST_FILE" <<'TEST_EOF'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
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
		settingsManager = new SettingsManager({ agentDir, cwd: projectDir } as any);
		packageManager = new PackageManager({
			settingsManager,
			agentDir,
			cwd: projectDir,
		} as any);
	});

	afterEach(() => {
		try { rmSync(tempDir, { recursive: true, force: true }); } catch {}
	});

	it("F2P_INSTALL_LOCAL_NOTHROW: install accepts local file path without Unsupported", async () => {
		const extPath = join(projectDir, "extensions", "my-ext.ts");
		let err: any = null;
		try {
			await packageManager.install(extPath);
		} catch (e) {
			err = e;
		}
		if (err) {
			expect(String(err.message || err)).not.toMatch(/Unsupported/i);
		}
	});

	it("F2P_REMOVE_LOCAL_NOTHROW: remove accepts local file path without Unsupported", async () => {
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

	it("F2P_INSTALL_VALIDATES_NONEXISTENT: install rejects non-existent local path", async () => {
		const bogus = join(projectDir, "does-not-exist-xyz.ts");
		let threw = false;
		try {
			await packageManager.install(bogus);
		} catch (e) {
			threw = true;
		}
		expect(threw).toBe(true);
	});
});
TEST_EOF

echo ""
echo "=== F2P: Running bench tests ==="
F2P_OUTPUT=$(cd "$PKG_DIR" && timeout 300 npx vitest --run test/local-install-bench.test.ts 2>&1)
echo "$F2P_OUTPUT" | tail -60

# Cleanup the test file regardless
cleanup_test() {
    rm -f "$TEST_FILE"
}

# Parse pass/fail per test name
check_test() {
    local name="$1"
    # vitest with --run prints "✓" for pass and "×" for fail; also shows test name
    if echo "$F2P_OUTPUT" | grep -qE "✓.*$name"; then
        return 0
    fi
    return 1
}

SCORE_AWK="0"
add_score() {
    SCORE_AWK=$(awk -v a="$SCORE_AWK" -v b="$1" 'BEGIN{print a+b}')
}

# Gate 1: install accepts local without Unsupported (weight 0.35)
if check_test "F2P_INSTALL_LOCAL_NOTHROW"; then
    echo "PASS (0.35): install accepts local path without Unsupported"
    add_score 0.35
else
    echo "FAIL (0.35): install still throws Unsupported on local path"
fi

# Gate 2: remove accepts local without Unsupported (weight 0.35)
if check_test "F2P_REMOVE_LOCAL_NOTHROW"; then
    echo "PASS (0.35): remove accepts local path without Unsupported"
    add_score 0.35
else
    echo "FAIL (0.35): remove still throws Unsupported on local path"
fi

# Gate 3: install validates non-existent path (weight 0.30)
# This fails on the buggy base because install throws "Unsupported" (which IS a throw),
# so we need a stricter check: it must throw, AND not throw "Unsupported".
# Re-check: the vitest test only asserts it throws. On buggy base it throws Unsupported → test passes!
# So this isn't F2P. Replace with a stricter behavioral check.

# Re-evaluate gate 3 from raw output: we need it to throw a non-Unsupported error.
# Add an extra inline node check.
echo ""
echo "=== F2P extra: install on existing path must NOT throw, on missing path MUST throw non-Unsupported ==="

EXTRA_OUTPUT=$(cd "$PKG_DIR" && timeout 60 node --input-type=module -e "
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const { PackageManager } = await import('./src/core/package-manager.ts').catch(() => import('./dist/core/package-manager.js')).catch(e => { console.error('IMPORT_FAIL', e.message); process.exit(2); });
" 2>&1)
# That's likely to fail due to TS imports; we rely on the vitest gates instead. Skip the extra.

# Strengthen Gate 3 by adding a vitest check for: install on EXISTING local path must complete without throwing.
cat > "$TEST_FILE" <<'TEST_EOF'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
		settingsManager = new SettingsManager({ agentDir, cwd: projectDir } as any);
		packageManager = new PackageManager({
			settingsManager,
			agentDir,
			cwd: projectDir,
		} as any);
	});

	afterEach(() => {
		try { rmSync(tempDir, { recursive: true, force: true }); } catch {}
	});

	it("F2P_INSTALL_LOCAL_NOTHROW", async () => {
		const extPath = join(projectDir, "extensions", "my-ext.ts");
		let err: any = null;
		try {
			await packageManager.install(extPath);
		} catch (e) {
			err = e;
		}
		if (err) {
			expect(String(err.message || err)).not.toMatch(/Unsupported/i);
		}
	});

	it("F2P_REMOVE_LOCAL_NOTHROW", async () => {
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

	it("F2P_INSTALL_LOCAL_COMPLETES", async () => {
		// On the buggy base, install() throws "Unsupported install source" → this errors.
		// On the fix, install() resolves successfully for an existing local path.
		const extPath = join(projectDir, "extensions", "my-ext.ts");
		await expect(packageManager.install(extPath)).resolves.not.toThrow();
	});

	it("F2P_REMOVE_LOCAL_COMPLETES", async () => {
		const extPath = join(projectDir, "extensions", "my-ext.ts");
		await expect(packageManager.remove(extPath)).resolves.not.toThrow();
	});
});
TEST_EOF

F2P_OUTPUT=$(cd "$PKG_DIR" && timeout 300 npx vitest --run test/local-install-bench.test.ts 2>&1)
echo "$F2P_OUTPUT" | tail -80

# Reset score and re-evaluate against the final test file
SCORE_AWK="0"

# Use vitest summary: each test has ✓ or × prefix.
g1=0; g2=0; g3=0; g4=0
echo "$F2P_OUTPUT" | grep -qE "✓.*F2P_INSTALL_LOCAL_NOTHROW" && g1=1
echo "$F2P_OUTPUT" | grep -qE "✓.*F2P_REMOVE_LOCAL_NOTHROW" && g2=1
echo "$F2P_OUTPUT" | grep -qE "✓.*F2P_INSTALL_LOCAL_COMPLETES" && g3=1
echo "$F2P_OUTPUT" | grep -qE "✓.*F2P_REMOVE_LOCAL_COMPLETES" && g4=1

# Weights — all four are F2P (fail on buggy base which throws "Unsupported install/remove source")
# 0.25 + 0.25 + 0.25 + 0.25 = 1.0
[ $g1 -eq 1 ] && { echo "PASS (0.25): install local no-Unsupported"; add_score 0.25; } || echo "FAIL (0.25): install local no-Unsupported"
[ $g2 -eq 1 ] && { echo "PASS (0.25): remove local no-Unsupported"; add_score 0.25; } || echo "FAIL (0.25): remove local no-Unsupported"
[ $g3 -eq 1 ] && { echo "PASS (0.25): install local completes"; add_score 0.25; } || echo "FAIL (0.25): install local completes"
[ $g4 -eq 1 ] && { echo "PASS (0.25): remove local completes"; add_score 0.25; } || echo "FAIL (0.25): remove local completes"

# Cleanup
rm -f "$TEST_FILE"

REWARD="$SCORE_AWK"
echo ""
echo "Final reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"