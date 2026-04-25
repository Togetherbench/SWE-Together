#!/bin/bash
set +e

REPO="/workspace/pi-mono"
PKG="$REPO/packages/coding-agent"
LOGDIR="/logs/verifier"
mkdir -p "$LOGDIR"

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
which npx >/dev/null 2>&1 || export PATH="$(npm bin -g 2>/dev/null):$PATH"

REWARD=0

add_reward() {
  local weight="$1"
  local name="$2"
  local result="$3"
  if [ "$result" = "PASS" ]; then
    REWARD=$(awk -v r="$REWARD" -v w="$weight" 'BEGIN{printf "%.4f", r + w}')
    echo "  PASS (+$weight) [$name]"
  else
    echo "  FAIL (+0)    [$name]"
  fi
}

cd "$PKG" || { echo "$REWARD" > "$LOGDIR/reward.txt"; exit 0; }

###############################################################################
# TEST 1 [P2P]: Existing model-registry tests still pass (weight 0.07)
###############################################################################
echo "=== TEST 1 [P2P]: model-registry tests ==="
VITEST_OUT=$(npx vitest --run model-registry.test 2>&1)
echo "$VITEST_OUT" > "$LOGDIR/test1.log"
if echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ passed" && ! echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ failed"; then
  add_reward 0.07 "model_registry_p2p" "PASS"
else
  add_reward 0.07 "model_registry_p2p" "FAIL"
fi

###############################################################################
# TEST 2 [P2P]: Existing extensions-runner tests still pass (weight 0.08)
###############################################################################
echo "=== TEST 2 [P2P]: extensions-runner tests ==="
VITEST_OUT=$(npx vitest --run extensions-runner.test 2>&1)
echo "$VITEST_OUT" > "$LOGDIR/test2.log"
if echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ passed" && ! echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ failed"; then
  add_reward 0.08 "extension_runner_p2p" "PASS"
else
  add_reward 0.08 "extension_runner_p2p" "FAIL"
fi

###############################################################################
# TEST 3 [F2P]: Core behavior — invalid registerProvider does not corrupt
# registry; subsequent refresh()/find() succeed. (weight 0.20)
###############################################################################
echo "=== TEST 3 [F2P]: registry survives invalid registration ==="

cat > "$PKG/test/verifier-core.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";

describe("verifier: core", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;

  beforeEach(() => {
    tempDir = join(tmpdir(), `v-core-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(tempDir, { recursive: true });
    modelsJsonPath = join(tempDir, "models.json");
    writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(join(tempDir, "auth.json"));
  });

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  test("invalid streamSimple-without-api throws synchronously", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    expect(() =>
      registry.registerProvider("broken-provider", {
        streamSimple: (() => { throw new Error("unused"); }) as any,
      }),
    ).toThrow();
  });

  test("registry remains usable after a failed registration", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    try {
      registry.registerProvider("broken-provider", {
        streamSimple: (() => { throw new Error("unused"); }) as any,
      });
    } catch {}
    expect(() => registry.refresh()).not.toThrow();

    // Adding a valid provider afterward must work
    registry.registerProvider("good", {
      baseUrl: "https://t.test/v1", apiKey: "K", api: "openai-completions" as any,
      models: [{ id: "m1", name: "M", reasoning: false, input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000, maxTokens: 4096 }],
    } as any);
    expect(registry.find("good", "m1")).toBeDefined();
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-core.test 2>&1)
echo "$RESULT" > "$LOGDIR/test3.log"
rm -f "$PKG/test/verifier-core.test.ts"

PASSED_COUNT=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
FAILED=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)

if [ -z "$FAILED" ] && [ "${PASSED_COUNT:-0}" -ge 2 ]; then
  add_reward 0.20 "core_behavior_full" "PASS"
elif [ "${PASSED_COUNT:-0}" -ge 1 ]; then
  add_reward 0.10 "core_behavior_partial" "PASS"
else
  add_reward 0.20 "core_behavior_full" "FAIL"
fi

###############################################################################
# TEST 4 [F2P]: No partial state on failed registration (weight 0.15)
###############################################################################
echo "=== TEST 4 [F2P]: atomicity — no partial state ==="

cat > "$PKG/test/verifier-atomicity.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";

describe("verifier: atomicity", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;

  beforeEach(() => {
    tempDir = join(tmpdir(), `v-atom-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(tempDir, { recursive: true });
    modelsJsonPath = join(tempDir, "models.json");
    writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(join(tempDir, "auth.json"));
  });

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  test("failed re-registration preserves prior valid provider", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    registry.registerProvider("demo", {
      baseUrl: "https://t.test/v1", apiKey: "K", api: "openai-completions" as any,
      models: [{ id: "m1", name: "M", reasoning: false, input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000, maxTokens: 4096 }],
    } as any);
    expect(registry.find("demo", "m1")).toBeDefined();

    try {
      registry.registerProvider("demo", {
        streamSimple: (() => { throw new Error("x"); }) as any,
      });
    } catch {}

    expect(registry.find("demo", "m1")).toBeDefined();
    expect(() => registry.refresh()).not.toThrow();
    expect(registry.find("demo", "m1")).toBeDefined();
  });

  test("failed first-time registration does not appear in models", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    try {
      registry.registerProvider("ghost", {
        streamSimple: (() => { throw new Error("x"); }) as any,
      });
    } catch {}
    const all = registry.getAll ? registry.getAll() : [];
    const hasGhost = Array.isArray(all) && all.some((m: any) => m.provider === "ghost");
    expect(hasGhost).toBe(false);
    expect(() => registry.refresh()).not.toThrow();
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-atomicity.test 2>&1)
echo "$RESULT" > "$LOGDIR/test4.log"
rm -f "$PKG/test/verifier-atomicity.test.ts"

PASSED_COUNT=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
FAILED=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)
if [ -z "$FAILED" ] && [ "${PASSED_COUNT:-0}" -ge 2 ]; then
  add_reward 0.15 "atomicity_full" "PASS"
elif [ "${PASSED_COUNT:-0}" -ge 1 ]; then
  add_reward 0.07 "atomicity_partial" "PASS"
else
  add_reward 0.15 "atomicity_full" "FAIL"
fi

###############################################################################
# TEST 5 [F2P]: Runner integration — invalid post-bind registration does
# NOT throw, error is emitted via runner error reporting, registry survives.
# (weight 0.30)
###############################################################################
echo "=== TEST 5 [F2P]: Runner emits errors instead of crashing ==="

cat > "$PKG/test/verifier-runner.test.ts" << 'TSEOF'
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { createExtensionRuntime } from "../src/core/extensions/runtime.js";

describe("verifier: runner integration", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;
  let modelRegistry: ModelRegistry;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "v-runner-"));
    modelsJsonPath = path.join(tempDir, "models.json");
    fs.writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
    modelRegistry = new ModelRegistry(authStorage, modelsJsonPath);
  });

  afterEach(() => {
    if (tempDir && fs.existsSync(tempDir)) fs.rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  function makeSessionManagerStub(): any {
    return {
      getSessions: () => [],
      onSessionCreated: () => {},
      onSessionRemoved: () => {},
    };
  }

  test("post-bind invalid registration does not throw and reports error", () => {
    const runtime = createExtensionRuntime();
    const sessionManager = makeSessionManagerStub();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);

    const errors: any[] = [];
    if (typeof (runner as any).onError === "function") {
      (runner as any).onError((e: any) => errors.push(e));
    }

    const extActions: any = {};
    const ctxActions: any = {};
    runner.bindCore(extActions, ctxActions);

    let threw = false;
    try {
      (runtime.registerProvider as any)(
        "broken-provider",
        { streamSimple: (() => { throw new Error("x"); }) as any },
        "/tmp/broken-extension.ts",
      );
    } catch {
      threw = true;
    }
    expect(threw).toBe(false);

    // registry must still work
    expect(() => modelRegistry.refresh()).not.toThrow();

    // and the broken provider should NOT have been silently registered
    const all = modelRegistry.getAll ? modelRegistry.getAll() : [];
    const broken = Array.isArray(all) && all.some((m: any) => m.provider === "broken-provider");
    expect(broken).toBe(false);
  });

  test("error includes extension path identification (when supported)", () => {
    const runtime = createExtensionRuntime();
    const sessionManager = makeSessionManagerStub();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);

    const errors: any[] = [];
    if (typeof (runner as any).onError === "function") {
      (runner as any).onError((e: any) => errors.push(e));
    }

    runner.bindCore({} as any, {} as any);
    try {
      (runtime.registerProvider as any)(
        "broken-provider",
        { streamSimple: (() => {}) as any },
        "/tmp/my-broken-extension.ts",
      );
    } catch {}

    // Either an error was emitted via onError, OR the registration was prevented.
    const all = modelRegistry.getAll ? modelRegistry.getAll() : [];
    const broken = Array.isArray(all) && all.some((m: any) => m.provider === "broken-provider");
    expect(broken).toBe(false);

    if (errors.length > 0) {
      const blob = JSON.stringify(errors);
      // Extension path should appear somewhere in the error report
      expect(blob).toMatch(/broken-extension|extensionPath/);
    }
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-runner.test 2>&1)
echo "$RESULT" > "$LOGDIR/test5.log"
rm -f "$PKG/test/verifier-runner.test.ts"

PASSED_COUNT=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
FAILED=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)

if [ -z "$FAILED" ] && [ "${PASSED_COUNT:-0}" -ge 2 ]; then
  add_reward 0.30 "runner_integration_full" "PASS"
elif [ "${PASSED_COUNT:-0}" -ge 1 ]; then
  add_reward 0.15 "runner_integration_partial" "PASS"
else
  add_reward 0.30 "runner_integration_full" "FAIL"
fi

###############################################################################
# TEST 6 [F2P]: Pending (pre-bind) flushing also tolerates invalid configs
# Many extensions register before bindCore — those must also not crash.
# (weight 0.10)
###############################################################################
echo "=== TEST 6 [F2P]: pre-bind queued invalid registration ==="

cat > "$PKG/test/verifier-prebind.test.ts" << 'TSEOF'
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { createExtensionRuntime } from "../src/core/extensions/runtime.js";

describe("verifier: pre-bind", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;
  let modelRegistry: ModelRegistry;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "v-prebind-"));
    modelsJsonPath = path.join(tempDir, "models.json");
    fs.writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
    modelRegistry = new ModelRegistry(authStorage, modelsJsonPath);
  });

  afterEach(() => {
    if (tempDir && fs.existsSync(tempDir)) fs.rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  test("invalid pre-bind registration does not crash bindCore", () => {
    const runtime = createExtensionRuntime();
    const sessionManager: any = {
      getSessions: () => [],
      onSessionCreated: () => {},
      onSessionRemoved: () => {},
    };
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);

    // queue an invalid registration BEFORE bindCore
    try {
      (runtime.registerProvider as any)(
        "queued-broken",
        { streamSimple: (() => {}) as any },
        "/tmp/queued-extension.ts",
      );
    } catch {}

    let threw = false;
    try {
      runner.bindCore({} as any, {} as any);
    } catch {
      threw = true;
    }
    expect(threw).toBe(false);

    const all = modelRegistry.getAll ? modelRegistry.getAll() : [];
    const broken = Array.isArray(all) && all.some((m: any) => m.provider === "queued-broken");
    expect(broken).toBe(false);
    expect(() => modelRegistry.refresh()).not.toThrow();
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-prebind.test 2>&1)
echo "$RESULT" > "$LOGDIR/test6.log"
rm -f "$PKG/test/verifier-prebind.test.ts"

if echo "$RESULT" | grep -qE "Tests[[:space:]]+1 passed" && ! echo "$RESULT" | grep -qE "Tests.*failed"; then
  add_reward 0.10 "prebind_integration" "PASS"
else
  add_reward 0.10 "prebind_integration" "FAIL"
fi

###############################################################################
# TEST 7 [structural]: TypeScript compiles (weight 0.05)
# Catches obvious type-level breakage from edits (e.g. extensionPath typing).
###############################################################################
echo "=== TEST 7 [structural]: tsc/vitest typecheck of modified files ==="
TSC_OUT=$(npx tsc --noEmit -p "$PKG/tsconfig.json" 2>&1)
echo "$TSC_OUT" > "$LOGDIR/test7.log"
ERRCOUNT=$(echo "$TSC_OUT" | grep -cE "error TS[0-9]+:")
if [ "${ERRCOUNT:-0}" -eq 0 ]; then
  add_reward 0.05 "tsc_clean" "PASS"
else
  # accept if tsconfig doesn't exist or returns non-error baseline (best-effort)
  if [ ! -f "$PKG/tsconfig.json" ]; then
    add_reward 0.05 "tsc_skipped" "PASS"
  else
    add_reward 0.05 "tsc_clean" "FAIL"
  fi
fi

###############################################################################
# TEST 8 [structural]: runner.ts has try/catch around registerProvider call
# (weight 0.05) — sanity guard that the runner-side fix exists.
###############################################################################
echo "=== TEST 8 [structural]: runner.ts wraps registerProvider ==="
RUNNER="$PKG/src/core/extensions/runner.ts"
if [ -f "$RUNNER" ]; then
  # look for try { ... registerProvider ... } catch within runtime.registerProvider definition
  if awk '
    /runtime\.registerProvider[[:space:]]*=/ {found=1; depth=0}
    found {
      buf = buf $0 "\n"
      n = gsub(/\{/, "{")
      m = gsub(/\}/, "}")
      depth += n - m
      if (depth <= 0 && /\}/) {
        if (buf ~ /try[[:space:]]*\{/ && buf ~ /catch/) { print "OK"; exit }
        found=0; buf=""
      }
    }
  ' "$RUNNER" | grep -q "OK"; then
    add_reward 0.05 "runner_trycatch" "PASS"
  else
    add_reward 0.05 "runner_trycatch" "FAIL"
  fi
else
  add_reward 0.05 "runner_trycatch" "FAIL"
fi

###############################################################################
echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > "$LOGDIR/reward.txt"
exit 0