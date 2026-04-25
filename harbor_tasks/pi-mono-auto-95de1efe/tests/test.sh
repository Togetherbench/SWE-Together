#!/bin/bash
set +e

REPO="/workspace/pi-mono"
PKG="$REPO/packages/coding-agent"
LOGDIR="/logs/verifier"
mkdir -p "$LOGDIR"

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

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

finish() {
  echo "FINAL REWARD: $REWARD"
  echo "$REWARD" > "$LOGDIR/reward.txt"
  exit 0
}

cd "$PKG" || finish

###############################################################################
# GATE [P2P]: Existing tests must still pass. If they don't, REWARD stays 0.
###############################################################################
echo "=== GATE [P2P]: model-registry tests ==="
VITEST_OUT=$(npx vitest --run model-registry.test 2>&1)
echo "$VITEST_OUT" > "$LOGDIR/gate1.log"
if ! (echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ passed" && ! echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ failed"); then
  echo "  GATE FAIL — model-registry tests broken; REWARD=0"
  finish
fi
echo "  GATE PASS"

echo "=== GATE [P2P]: extensions-runner tests ==="
VITEST_OUT=$(npx vitest --run extensions-runner.test 2>&1)
echo "$VITEST_OUT" > "$LOGDIR/gate2.log"
if ! (echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ passed" && ! echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ failed"); then
  echo "  GATE FAIL — extensions-runner tests broken; REWARD=0"
  finish
fi
echo "  GATE PASS"

###############################################################################
# TEST A [F2P]: ModelRegistry.registerProvider — failed registration leaves
# no partial state; subsequent refresh() works; subsequent good registration works.
# On the buggy base, applyProviderConfig partially mutates state OR refresh()
# replays a bad config, so this fails.
###############################################################################
echo "=== TEST A [F2P]: registry survives + atomic on failed registration ==="

cat > "$PKG/test/verifier-atomic.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";

describe("verifier: registry atomic", () => {
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

  test("invalid streamSimple-without-api throws synchronously", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    expect(() =>
      registry.registerProvider("broken-provider", {
        streamSimple: (() => { throw new Error("unused"); }) as any,
      }),
    ).toThrow();
  });

  test("after a failed first-time registration: refresh() is safe and good provider can be added", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    try {
      registry.registerProvider("broken-provider", {
        streamSimple: (() => { throw new Error("unused"); }) as any,
      });
    } catch {}
    expect(() => registry.refresh()).not.toThrow();

    registry.registerProvider("good", {
      baseUrl: "https://t.test/v1", apiKey: "K", api: "openai-completions" as any,
      models: [{ id: "m1", name: "M", reasoning: false, input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000, maxTokens: 4096 }],
    } as any);
    expect(registry.find("good", "m1")).toBeDefined();
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

    expect(() => registry.refresh()).not.toThrow();
    expect(registry.find("demo", "m1")).toBeDefined();
  });

  test("failed first-time registration leaves no ghost models", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    try {
      registry.registerProvider("ghost", {
        streamSimple: (() => { throw new Error("x"); }) as any,
      });
    } catch {}
    const all = (registry as any).getAll ? (registry as any).getAll() : [];
    const hasGhost = Array.isArray(all) && all.some((m: any) => m && m.provider === "ghost");
    expect(hasGhost).toBe(false);
    expect(() => registry.refresh()).not.toThrow();
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-atomic.test 2>&1)
echo "$RESULT" > "$LOGDIR/testA.log"
rm -f "$PKG/test/verifier-atomic.test.ts"

PASSED_A=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
FAILED_A=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)

if [ -z "$FAILED_A" ] && [ "${PASSED_A:-0}" -ge 4 ]; then
  add_reward 0.45 "registry_atomic_full" "PASS"
elif [ -z "$FAILED_A" ] && [ "${PASSED_A:-0}" -ge 3 ]; then
  add_reward 0.30 "registry_atomic_3of4" "PASS"
elif [ "${PASSED_A:-0}" -ge 2 ]; then
  add_reward 0.15 "registry_atomic_partial" "PASS"
else
  add_reward 0.45 "registry_atomic_full" "FAIL"
fi

###############################################################################
# TEST B [F2P]: ExtensionRunner.bindCore — post-bind invalid registerProvider
# must NOT throw and SHOULD surface error via runner.onError with the
# extensionPath. On the buggy base, the registerProvider closure is
# `(name, config) => modelRegistry.registerProvider(name, config)` — no
# try/catch, so it throws and the error is not reported via onError.
###############################################################################
echo "=== TEST B [F2P]: runner post-bind invalid registration is caught & reported ==="

cat > "$PKG/test/verifier-runner.test.ts" << 'TSEOF'
import { mkdirSync, mkdtempSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { createExtensionRuntime } from "../src/core/extensions/runtime.js";
import { SessionManager } from "../src/core/session-manager.js";

describe("verifier: runner registerProvider safety", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;
  let modelRegistry: ModelRegistry;
  let sessionManager: SessionManager;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "v-runner-"));
    modelsJsonPath = join(tempDir, "models.json");
    writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(join(tempDir, "auth.json"));
    modelRegistry = new ModelRegistry(authStorage, modelsJsonPath);
    sessionManager = new SessionManager(join(tempDir, "sessions"));
  });

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  test("post-bind invalid registerProvider does not throw and reports extension error", () => {
    const runtime = createExtensionRuntime();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);

    runner.bindCore(undefined as any, undefined as any);

    const errors: any[] = [];
    if (typeof (runner as any).onError === "function") {
      (runner as any).onError((e: any) => errors.push(e));
    }

    expect(() => {
      try {
        (runtime.registerProvider as any)(
          "broken-provider",
          { streamSimple: (() => { throw new Error("unused"); }) as any },
          "/tmp/broken-extension.ts",
        );
      } catch (_e) {
        // If the implementation rethrows after reporting, that's still a fail
        // for "does not throw". Re-throw to fail the test.
        throw _e;
      }
    }).not.toThrow();

    // Registry must remain healthy
    expect(() => modelRegistry.refresh()).not.toThrow();
    expect(modelRegistry.find("broken-provider", "anything")).toBeUndefined();

    // Error must have been reported with extensionPath identifying the source
    expect(errors.length).toBeGreaterThanOrEqual(1);
    const reported = errors[0];
    const epath = reported?.extensionPath ?? "";
    expect(typeof epath).toBe("string");
    expect(epath.length).toBeGreaterThan(0);
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-runner.test 2>&1)
echo "$RESULT" > "$LOGDIR/testB.log"
rm -f "$PKG/test/verifier-runner.test.ts"

PASSED_B=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
FAILED_B=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)

if [ -z "$FAILED_B" ] && [ "${PASSED_B:-0}" -ge 1 ]; then
  add_reward 0.35 "runner_post_bind_safe" "PASS"
else
  add_reward 0.35 "runner_post_bind_safe" "FAIL"
fi

###############################################################################
# TEST C [F2P]: Pre-bind (queued/flushed) registrations also survive an invalid
# entry. On the buggy base, flushing the pending queue throws on the first bad
# entry and aborts subsequent valid entries. After the fix, the bad one is
# reported and the good one is registered.
###############################################################################
echo "=== TEST C [F2P]: runner pre-bind flush tolerates invalid registration ==="

cat > "$PKG/test/verifier-runner-flush.test.ts" << 'TSEOF'
import { mkdtempSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { createExtensionRuntime } from "../src/core/extensions/runtime.js";
import { SessionManager } from "../src/core/session-manager.js";

describe("verifier: runner flush safety", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;
  let modelRegistry: ModelRegistry;
  let sessionManager: SessionManager;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "v-flush-"));
    modelsJsonPath = join(tempDir, "models.json");
    writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(join(tempDir, "auth.json"));
    modelRegistry = new ModelRegistry(authStorage, modelsJsonPath);
    sessionManager = new SessionManager(join(tempDir, "sessions"));
  });

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  test("pre-bind invalid + valid registrations: invalid is reported, valid still applied", () => {
    const runtime = createExtensionRuntime();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);

    // Queue invalid registration before bindCore
    (runtime.registerProvider as any)(
      "broken-provider",
      { streamSimple: (() => { throw new Error("unused"); }) as any },
      "/tmp/broken-extension.ts",
    );

    // Queue valid registration
    (runtime.registerProvider as any)(
      "good-provider",
      {
        baseUrl: "https://t.test/v1",
        apiKey: "K",
        api: "openai-completions",
        models: [{
          id: "gm1", name: "GM", reasoning: false, input: ["text"],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow: 128000, maxTokens: 4096,
        }],
      },
      "/tmp/good-extension.ts",
    );

    const errors: any[] = [];
    if (typeof (runner as any).onError === "function") {
      (runner as any).onError((e: any) => errors.push(e));
    }

    // Bind should not throw even though one queued entry is invalid
    expect(() => runner.bindCore(undefined as any, undefined as any)).not.toThrow();

    // Good provider must be registered
    expect(modelRegistry.find("good-provider", "gm1")).toBeDefined();
    // Bad provider must not be registered
    expect(modelRegistry.find("broken-provider", "anything")).toBeUndefined();
    // Refresh stays healthy
    expect(() => modelRegistry.refresh()).not.toThrow();

    // At least one error reported, with extensionPath
    expect(errors.length).toBeGreaterThanOrEqual(1);
    const matched = errors.some((e: any) =>
      typeof e?.extensionPath === "string" && e.extensionPath.length > 0,
    );
    expect(matched).toBe(true);
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-runner-flush.test 2>&1)
echo "$RESULT" > "$LOGDIR/testC.log"
rm -f "$PKG/test/verifier-runner-flush.test.ts"

PASSED_C=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
FAILED_C=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)

if [ -z "$FAILED_C" ] && [ "${PASSED_C:-0}" -ge 1 ]; then
  add_reward 0.20 "runner_flush_safe" "PASS"
else
  add_reward 0.20 "runner_flush_safe" "FAIL"
fi

echo "FINAL REWARD: $REWARD"
echo "$REWARD" > "$LOGDIR/reward.txt"