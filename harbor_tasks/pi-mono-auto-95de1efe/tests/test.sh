#!/bin/bash
set +e

REPO="/workspace/pi-mono"
PKG="$REPO/packages/coding-agent"
LOGDIR="/logs/verifier"
mkdir -p "$LOGDIR"

GATES_FILE="$LOGDIR/gates.json"
: > "$GATES_FILE"

emit() {
  local id="$1" passed="$2" detail="${3:-}"
  printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

cd "$PKG" 2>/dev/null

###############################################################################
# P2P: existing tests must still pass.
###############################################################################
P2P_OK=1
if command -v npx >/dev/null 2>&1 && [ -d "$PKG" ]; then
  V1=$(cd "$PKG" && npx vitest --run model-registry.test 2>&1)
  echo "$V1" > "$LOGDIR/p2p_model_registry.log"
  V2=$(cd "$PKG" && npx vitest --run extensions-runner.test 2>&1)
  echo "$V2" > "$LOGDIR/p2p_extensions_runner.log"

  if ! echo "$V1" | grep -qE "Test Files.*[0-9]+ passed"; then P2P_OK=0; fi
  if echo "$V1" | grep -qE "Test Files.*[0-9]+ failed"; then P2P_OK=0; fi
  if ! echo "$V2" | grep -qE "Test Files.*[0-9]+ passed"; then P2P_OK=0; fi
  if echo "$V2" | grep -qE "Test Files.*[0-9]+ failed"; then P2P_OK=0; fi
else
  P2P_OK=0
fi

if [ "$P2P_OK" = "1" ]; then
  emit p2p_existing_tests_pass true ""
else
  emit p2p_existing_tests_pass false "model-registry or extensions-runner tests failing"
fi

###############################################################################
# Helper: run a vitest file and capture pass/fail counts
###############################################################################
run_vitest_file() {
  local testfile="$1"
  local logfile="$2"
  local out
  out=$(cd "$PKG" && npx vitest --run "$testfile" 2>&1)
  echo "$out" > "$logfile"
  echo "$out"
}

count_passed() {
  echo "$1" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1
}
count_failed() {
  echo "$1" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+" | head -1
}

# Initialize gate states
G_INVALID_SAFE=0
G_REFRESH_SAFE=0
G_RUNTIME_INVALID_NOTHROW=0
G_RUNTIME_VALID_WORKS=0
G_NO_PARTIAL=0

###############################################################################
# Behavioral test set 1: registry-level (used for t1_f2p_* and t4_f2p_no_partial_state)
###############################################################################
cat > "$PKG/test/verifier-registry-behavior.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";

describe("verifier registry behavior", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;

  beforeEach(() => {
    tempDir = join(tmpdir(), `vrb-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(tempDir, { recursive: true });
    modelsJsonPath = join(tempDir, "models.json");
    writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(join(tempDir, "auth.json"));
  });

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  // CALLER-LEVEL: invalid registration triggers some failure mode (throw OR validation),
  // but a subsequent valid registration MUST still work, AND the registry must
  // not be left in a corrupt state (no ghost partial provider).
  test("invalid then valid registration: valid still works", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    let invalidThrew = false;
    try {
      registry.registerProvider("broken", {
        // Missing required `api`/`baseUrl`/`apiKey`/etc fields. streamSimple is the only thing.
        streamSimple: (() => { throw new Error("u"); }) as any,
      } as any);
    } catch (e) {
      invalidThrew = true;
    }
    // Either threw synchronously OR succeeded but with no partial damage.
    // Then a valid registration must work:
    registry.registerProvider("good", {
      baseUrl: "https://t.test/v1",
      apiKey: "K",
      api: "openai-completions" as any,
      models: [{
        id: "m1", name: "M", reasoning: false, input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000, maxTokens: 4096,
      }],
    } as any);
    expect(registry.find("good", "m1")).toBeDefined();
  });

  test("refresh works after a failed registration", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    try {
      registry.registerProvider("broken", {
        streamSimple: (() => { throw new Error("u"); }) as any,
      } as any);
    } catch {}
    expect(() => registry.refresh()).not.toThrow();
  });

  test("failed registration leaves no partial provider state (validate-before-mutate)", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    let threw = false;
    try {
      registry.registerProvider("ghost", {
        streamSimple: (() => { throw new Error("u"); }) as any,
      } as any);
    } catch {
      threw = true;
    }
    // The fix mandates validate-before-mutate: invalid registrations must throw
    // synchronously at the registry level. (The runtime/runner wraps this in try/catch.)
    expect(threw).toBe(true);

    // And no ghost provider state should be findable
    const ghostFind = registry.find("ghost", "anything");
    expect(ghostFind).toBeUndefined();

    // Refresh remains safe
    expect(() => registry.refresh()).not.toThrow();
  });
});
TSEOF

R1=$(run_vitest_file verifier-registry-behavior.test "$LOGDIR/registry_behavior.log")
rm -f "$PKG/test/verifier-registry-behavior.test.ts"

P1=$(count_passed "$R1"); F1=$(count_failed "$R1")
P1=${P1:-0}

# We can't easily tell which subtests passed without parsing further. Re-run with
# verbose reporter wouldn't help portably. Instead, parse the per-test lines.

# Look for individual test names in output
if echo "$R1" | grep -qE "✓.*invalid then valid registration: valid still works"; then
  G_INVALID_SAFE=1
fi
if echo "$R1" | grep -qE "✓.*refresh works after a failed registration"; then
  G_REFRESH_SAFE=1
fi
if echo "$R1" | grep -qE "✓.*failed registration leaves no partial provider state"; then
  G_NO_PARTIAL=1
fi

# Fallback: if the per-test grep failed but everything passed numerically, credit all
if [ -z "$F1" ] && [ "$P1" -ge 3 ]; then
  G_INVALID_SAFE=1
  G_REFRESH_SAFE=1
  G_NO_PARTIAL=1
fi

###############################################################################
# Behavioral test set 2: runtime/runner-level (used for t4_f2p_runtime_*)
###############################################################################
cat > "$PKG/test/verifier-runtime-behavior.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { createExtensionRuntime } from "../src/core/extensions/runtime.js";

describe("verifier runtime behavior", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;
  let modelRegistry: ModelRegistry;

  const sessionManager: any = {
    getSession: () => undefined,
    listSessions: () => [],
    createSession: () => ({}),
  };

  beforeEach(() => {
    tempDir = join(tmpdir(), `vrt-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(tempDir, { recursive: true });
    modelsJsonPath = join(tempDir, "models.json");
    writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(join(tempDir, "auth.json"));
    modelRegistry = new ModelRegistry(authStorage, modelsJsonPath);
  });

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  test("post-bind invalid registerProvider does not throw", () => {
    const runtime = createExtensionRuntime();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);
    runner.bindCore({} as any, {} as any);

    let onErrCalls = 0;
    if (typeof (runner as any).onError === "function") {
      (runner as any).onError(() => { onErrCalls++; });
    }

    // Invalid config: missing required validation fields. Use any-cast to allow
    // implementations that accept varying numbers of arguments.
    const fn: any = runtime.registerProvider;
    expect(() => {
      try {
        fn("broken-provider",
           { streamSimple: (() => { throw new Error("u"); }) as any },
           "/tmp/broken-extension.ts");
      } catch (e) {
        // Some implementations may still throw at runtime level. The contract is
        // that *the agent's app* doesn't crash. The runner is supposed to swallow.
        // If runtime layer itself throws, this test fails — which is correct,
        // because the issue requires it not to crash.
        throw e;
      }
    }).not.toThrow();

    // Registry must remain usable after the failed registration.
    expect(() => modelRegistry.refresh()).not.toThrow();
  });

  test("post-bind valid registerProvider still works", () => {
    const runtime = createExtensionRuntime();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);
    runner.bindCore({} as any, {} as any);

    const fn: any = runtime.registerProvider;
    fn("good-provider", {
      baseUrl: "https://t.test/v1",
      apiKey: "K",
      api: "openai-completions",
      models: [{
        id: "m1", name: "M", reasoning: false, input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000, maxTokens: 4096,
      }],
    } as any, "/tmp/good.ts");

    expect(modelRegistry.find("good-provider", "m1")).toBeDefined();
  });
});
TSEOF

R2=$(run_vitest_file verifier-runtime-behavior.test "$LOGDIR/runtime_behavior.log")
rm -f "$PKG/test/verifier-runtime-behavior.test.ts"

P2=$(count_passed "$R2"); F2=$(count_failed "$R2")
P2=${P2:-0}

if echo "$R2" | grep -qE "✓.*post-bind invalid registerProvider does not throw"; then
  G_RUNTIME_INVALID_NOTHROW=1
fi
if echo "$R2" | grep -qE "✓.*post-bind valid registerProvider still works"; then
  G_RUNTIME_VALID_WORKS=1
fi

# Fallback: if everything passed numerically
if [ -z "$F2" ] && [ "$P2" -ge 2 ]; then
  G_RUNTIME_INVALID_NOTHROW=1
  G_RUNTIME_VALID_WORKS=1
fi

###############################################################################
# Emit per-gate results
###############################################################################
if [ "$G_INVALID_SAFE" = "1" ]; then
  emit t1_f2p_invalid_registration_safe true ""
else
  emit t1_f2p_invalid_registration_safe false "valid registration after invalid one fails or registry corrupted"
fi

if [ "$G_REFRESH_SAFE" = "1" ]; then
  emit t1_f2p_refresh_safe_after_failure true ""
else
  emit t1_f2p_refresh_safe_after_failure false "refresh() throws or fails after invalid registration"
fi

if [ "$G_RUNTIME_INVALID_NOTHROW" = "1" ]; then
  emit t4_f2p_runtime_invalid_no_throw true ""
else
  emit t4_f2p_runtime_invalid_no_throw false "runtime.registerProvider(invalid) throws unhandled"
fi

if [ "$G_RUNTIME_VALID_WORKS" = "1" ]; then
  emit t4_f2p_runtime_valid_works true ""
else
  emit t4_f2p_runtime_valid_works false "valid registration through runtime no longer works"
fi

if [ "$G_NO_PARTIAL" = "1" ]; then
  emit t4_f2p_no_partial_state true ""
else
  emit t4_f2p_no_partial_state false "failed registration leaves partial state behind"
fi

###############################################################################
# Compute reward
###############################################################################
REWARD=0

# Check P2P_GATING
P2P_FAILED=0
if ! grep -q '"id":"p2p_existing_tests_pass","passed":true' "$GATES_FILE"; then
  P2P_FAILED=1
fi

if [ "$P2P_FAILED" = "0" ]; then
  add_w() {
    REWARD=$(awk -v r="$REWARD" -v w="$1" 'BEGIN{printf "%.4f", r + w}')
  }
  if [ "$G_INVALID_SAFE" = "1" ]; then add_w 0.20; fi
  if [ "$G_REFRESH_SAFE" = "1" ]; then add_w 0.15; fi
  if [ "$G_RUNTIME_INVALID_NOTHROW" = "1" ]; then add_w 0.25; fi
  if [ "$G_RUNTIME_VALID_WORKS" = "1" ]; then add_w 0.20; fi
  if [ "$G_NO_PARTIAL" = "1" ]; then add_w 0.20; fi
fi

printf "%.4f\n" "$REWARD" > "$LOGDIR/reward.txt"
echo "FINAL REWARD: $REWARD"
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjZCAvd29ya3NwYWNlL3BpLW1vbm8gJiYgY29tbWFuZCAtdiBucHggPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_e395cbc7 'npm_typecheck_coding-agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/coding-agent && timeout 120 npx tsgo --noEmit -p tsconfig.build.json 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_522628b0 'vitest_session_manager_coding-agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/coding-agent && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_invalid_registration_safe": 0.2, "t1_f2p_refresh_safe_after_failure": 0.15, "t4_f2p_no_partial_state": 0.2, "t4_f2p_runtime_invalid_no_throw": 0.25, "t4_f2p_runtime_valid_works": 0.2}
P2P_GATING = ["p2p_existing_tests_pass"]
P2P_REGRESSION = ["p2p_upstream_e395cbc7", "p2p_upstream_522628b0"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0