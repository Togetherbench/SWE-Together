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
# 0.15 * 4 = 0.60 (remaining 0.40 goes to upstream F2P gates)
[ $g1 -eq 1 ] && { echo "PASS (0.15): install local no-Unsupported"; add_score 0.15; } || echo "FAIL (0.15): install local no-Unsupported"
[ $g2 -eq 1 ] && { echo "PASS (0.15): remove local no-Unsupported"; add_score 0.15; } || echo "FAIL (0.15): remove local no-Unsupported"
[ $g3 -eq 1 ] && { echo "PASS (0.15): install local completes"; add_score 0.15; } || echo "FAIL (0.15): install local completes"
[ $g4 -eq 1 ] && { echo "PASS (0.15): remove local completes"; add_score 0.15; } || echo "FAIL (0.15): remove local completes"

# Cleanup
rm -f "$TEST_FILE"

REWARD="$SCORE_AWK"
echo ""
echo "Existing gates reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"

# ---- inner-claude upstream gates ----
GATES_FILE="/logs/verifier/gates.json"
mkdir -p "$(dirname "$GATES_FILE")"

emit_gate() {
    local gid="$1"
    local passed="$2"
    local detail="$3"
    echo "{\"id\": \"$gid\", \"passed\": $passed, \"detail\": \"$detail\"}" >> "$GATES_FILE"
}

# F2P upstream gate 1: vitest local install/remove tests exist and pass
echo ""
echo "=== Upstream F2P: vitest local install/remove tests exist and pass ==="
F2P_U1_OUTPUT=$(cd "$PKG_DIR" && timeout 120 npx vitest --run test/package-manager.test.ts -t "local.*install|install.*local" 2>&1)
echo "$F2P_U1_OUTPUT" | tail -10
if echo "$F2P_U1_OUTPUT" | grep -qE "Tests +[0-9]+ passed"; then
    echo "PASS: upstream F2P vitest local install tests"
    emit_gate "f2p_upstream_vitest_local_install_tests" "true" "local install/remove tests found and passed"
else
    echo "FAIL: upstream F2P vitest local install tests"
    emit_gate "f2p_upstream_vitest_local_install_tests" "false" "no local install/remove tests found or they failed"
fi

# F2P upstream gate 2: test count > 91
echo ""
echo "=== Upstream F2P: package-manager test count > 91 ==="
F2P_U2_OUTPUT=$(cd "$PKG_DIR" && timeout 120 npx vitest --run test/package-manager.test.ts 2>&1)
echo "$F2P_U2_OUTPUT" | tail -10
if echo "$F2P_U2_OUTPUT" | grep -qE "Tests +(9[2-9]|[1-9][0-9]{2,}) passed"; then
    echo "PASS: upstream F2P test count > 91"
    emit_gate "f2p_upstream_vitest_test_count_gt91" "true" "test count exceeds 91"
else
    echo "FAIL: upstream F2P test count <= 91"
    emit_gate "f2p_upstream_vitest_test_count_gt91" "false" "test count is 91 or fewer"
fi

# P2P upstream gate 1: full package-manager tests pass
echo ""
echo "=== Upstream P2P: existing package-manager tests pass ==="
# Reuse F2P_U2_OUTPUT from test count gate (same command)
if echo "$F2P_U2_OUTPUT" | grep -qE "Tests +[0-9]+ passed"; then
    if echo "$F2P_U2_OUTPUT" | grep -qE "Tests.*[0-9]+ failed"; then
        echo "FAIL: upstream P2P existing tests have failures"
        emit_gate "p2p_upstream_vitest_pm_pass" "false" "some tests failed"
    else
        echo "PASS: upstream P2P existing tests pass"
        emit_gate "p2p_upstream_vitest_pm_pass" "true" "all tests passed"
    fi
else
    echo "FAIL: upstream P2P no tests passed"
    emit_gate "p2p_upstream_vitest_pm_pass" "false" "no tests passed"
fi

# P2P upstream gate 2: tsgo type checking
echo ""
echo "=== Upstream P2P: tsgo --noEmit ==="
TSGO_OUTPUT=$(cd "$REPO_DIR" && timeout 60 npx tsgo --noEmit 2>&1)
TSGO_RC=$?
echo "$TSGO_OUTPUT" | tail -10
if [ $TSGO_RC -eq 0 ]; then
    echo "PASS: upstream P2P tsgo type check"
    emit_gate "p2p_upstream_tsgo_noEmit" "true" "type checking passed"
else
    echo "FAIL: upstream P2P tsgo type check"
    emit_gate "p2p_upstream_tsgo_noEmit" "false" "type checking failed"
fi

# P2P upstream gate 3: biome check on package-manager.ts
echo ""
echo "=== Upstream P2P: biome check package-manager.ts ==="
BIOME_OUTPUT=$(cd "$REPO_DIR" && timeout 60 npx biome check packages/coding-agent/src/core/package-manager.ts 2>&1)
BIOME_RC=$?
echo "$BIOME_OUTPUT" | tail -10
if [ $BIOME_RC -eq 0 ]; then
    echo "PASS: upstream P2P biome lint"
    emit_gate "p2p_upstream_biome_pm" "true" "biome lint passed"
else
    echo "FAIL: upstream P2P biome lint"
    emit_gate "p2p_upstream_biome_pm" "false" "biome lint failed"
fi

# ---- end upstream gates ----

# Apply upstream reward tail
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_install_local_nothrow": 0.15,
    "f2p_remove_local_nothrow": 0.15,
    "f2p_install_local_completes": 0.15,
    "f2p_remove_local_completes": 0.15,
    "f2p_upstream_vitest_local_install_tests": 0.2,
    "f2p_upstream_vitest_test_count_gt91": 0.2
}
P2P_REGRESSION = ["p2p_existing_tests_pass", "p2p_upstream_vitest_pm_pass", "p2p_upstream_tsgo_noEmit", "p2p_upstream_biome_pm"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

p2p_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    # Weighted-replace: upstream F2P gate weights replace a proportional
    # share of the bash-computed inner reward. When WEIGHTS sums to 1.0, the
    # inner reward is fully subsumed by upstream gates (intentional). When
    # WEIGHTS sums to <1.0, the remainder scales the legacy inner reward so
    # the total is naturally bounded to [0, 1] without additive inflation.
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF
echo ""
echo "Final reward (after upstream gates):"
cat "$REWARD_FILE"