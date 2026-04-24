#!/bin/bash
# Verifier for pi-mono issue #2431:
# Invalid extension registerProvider() should not crash app on startup.
# All tests are behavioral (vitest-based TypeScript execution).
# Nop baseline score: 0.10 (only P2P regression gates pass on unmodified code)
set +e

REPO="/workspace/pi-mono"
PKG="$REPO/packages/coding-agent"
LOGDIR="/logs/verifier"
mkdir -p "$LOGDIR"

REWARD=0

add_reward() {
  local weight="$1"
  local name="$2"
  local result="$3"
  if [ "$result" = "PASS" ]; then
    REWARD=$(python3 -c "print(round($REWARD + $weight, 2))")
    echo "  PASS (+$weight) [$name]"
  else
    echo "  FAIL (+0)    [$name]"
  fi
}

###############################################################################
# TEST 1 [P2P]: Existing model-registry tests pass (weight 0.05)
# Passes on base commit AND after correct fix. Guards against regressions.
###############################################################################
echo "=== TEST 1 [P2P]: Existing model-registry tests ==="
cd "$PKG"
VITEST_OUT=$(npx vitest --run model-registry.test 2>&1) || true
if echo "$VITEST_OUT" | grep -q "Test Files.*passed"; then
  add_reward 0.05 "model_registry_p2p" "PASS"
else
  add_reward 0.05 "model_registry_p2p" "FAIL"
fi

###############################################################################
# TEST 2 [P2P]: Existing extension-runner tests pass (weight 0.05)
# Passes on base commit AND after correct fix. Guards against regressions.
###############################################################################
echo "=== TEST 2 [P2P]: Existing extension-runner tests ==="
VITEST_OUT=$(cd "$PKG" && npx vitest --run extensions-runner.test 2>&1) || true
if echo "$VITEST_OUT" | grep -q "Test Files.*passed"; then
  add_reward 0.05 "extension_runner_p2p" "PASS"
else
  add_reward 0.05 "extension_runner_p2p" "FAIL"
fi

###############################################################################
# TEST 3 [F2P]: Core crash fix — registerProvider rejects invalid config,
# refresh() survives afterward. (weight 0.25)
# Fails on base: registerProvider throws but leaves partial state, causing
# refresh() to crash. Passes after fix: validate-before-mutate.
###############################################################################
echo "=== TEST 3 [F2P]: Core crash fix — invalid config + refresh ==="

cat > "$PKG/test/verifier-core.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";

describe("verifier: core crash fix", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;

  beforeEach(() => {
    tempDir = join(tmpdir(), `v-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(tempDir, { recursive: true });
    modelsJsonPath = join(tempDir, "models.json");
    writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(join(tempDir, "auth.json"));
  });

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  test("registerProvider throws on invalid streamSimple config, refresh() survives", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    // Pass a config with streamSimple but missing required 'api' field
    expect(() =>
      registry.registerProvider("broken-provider", {
        streamSimple: (() => { throw new Error("x"); }) as any,
      })
    ).toThrow();
    // After rejection, the registry must still function
    expect(() => registry.refresh()).not.toThrow();
  });
});
TSEOF

RESULT=$(cd "$PKG" && npx vitest --run verifier-core.test 2>&1) || true
rm -f "$PKG/test/verifier-core.test.ts"

if echo "$RESULT" | grep -q "Test Files.*1 passed"; then
  add_reward 0.20 "core_crash_fix" "PASS"
else
  add_reward 0.20 "core_crash_fix" "FAIL"
fi

###############################################################################
# TEST 4 [F2P]: No partial state on failed registration (weight 0.15)
# Fails on base: registerProvider mutates state before validating, leaving
# a broken provider in registeredProviders. Passes after fix: validate first.
###############################################################################
echo "=== TEST 4 [F2P]: No partial state on failed registration ==="

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
    tempDir = join(tmpdir(), `v-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(tempDir, { recursive: true });
    modelsJsonPath = join(tempDir, "models.json");
    writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(join(tempDir, "auth.json"));
  });

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  test("failed registerProvider does not persist in registeredProviders", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    try {
      registry.registerProvider("bad-provider", {
        streamSimple: (() => { throw new Error("x"); }) as any,
      });
    } catch {}
    // The provider must NOT remain in the internal map
    expect((registry as any).registeredProviders.has("bad-provider")).toBe(false);
  });

  test("failed re-registration preserves existing provider models", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    // First: register a valid provider
    registry.registerProvider("demo", {
      baseUrl: "https://t.test/v1", apiKey: "K", api: "openai-completions" as any,
      models: [{ id: "m1", name: "M", reasoning: false, input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000, maxTokens: 4096 }],
    });
    expect(registry.find("demo", "m1")).toBeDefined();

    // Second: attempt invalid re-registration (missing api with streamSimple)
    try {
      registry.registerProvider("demo", {
        streamSimple: (() => { throw new Error("x"); }) as any,
      });
    } catch {}

    // Original model must still be findable
    expect(registry.find("demo", "m1")).toBeDefined();
    expect(() => registry.refresh()).not.toThrow();
    expect(registry.find("demo", "m1")).toBeDefined();
  });
});
TSEOF

RESULT=$(cd "$PKG" && npx vitest --run verifier-atomicity.test 2>&1) || true
rm -f "$PKG/test/verifier-atomicity.test.ts"

if echo "$RESULT" | grep -q "Test Files.*1 passed"; then
  add_reward 0.10 "atomicity" "PASS"
else
  add_reward 0.10 "atomicity" "FAIL"
fi

###############################################################################
# TEST 5 [F2P]: Runner integration — bindCore with bad queued registration
# does NOT throw AND errors are emitted. (weight 0.25)
# Fails on base: bindCore propagates the exception from registerProvider
# uncaught. Passes after fix: try/catch + emitError in runner.
###############################################################################
echo "=== TEST 5 [F2P]: Runner integration — error handling ==="

cat > "$PKG/test/verifier-runner-int.test.ts" << 'TSEOF'
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { createExtensionRuntime } from "../src/core/extensions/loader.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import type { ExtensionActions, ExtensionContextActions } from "../src/core/extensions/types.js";
import { ModelRegistry } from "../src/core/model-registry.js";
import { SessionManager } from "../src/core/session-manager.js";

describe("verifier: runner integration", () => {
  let tempDir: string;
  let sessionManager: SessionManager;
  let modelRegistry: ModelRegistry;

  const ea: ExtensionActions = {
    sendMessage: () => {}, sendUserMessage: () => {}, appendEntry: () => {},
    setSessionName: () => {}, getSessionName: () => undefined, setLabel: () => {},
    getActiveTools: () => [], getAllTools: () => [], setActiveTools: () => {},
    refreshTools: () => {}, getCommands: () => [], setModel: async () => false,
    getThinkingLevel: () => "off", setThinkingLevel: () => {},
  };
  const eca: ExtensionContextActions = {
    getModel: () => undefined, isIdle: () => true, abort: () => {},
    hasPendingMessages: () => false, shutdown: () => {},
    getContextUsage: () => undefined, compact: () => {}, getSystemPrompt: () => "",
  };

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "v-runner-"));
    sessionManager = SessionManager.inMemory();
    const auth = AuthStorage.create(path.join(tempDir, "auth.json"));
    modelRegistry = new ModelRegistry(auth);
  });

  afterEach(() => { fs.rmSync(tempDir, { recursive: true, force: true }); });

  test("bindCore with invalid queued registration: no throw, errors emitted", () => {
    const runtime = createExtensionRuntime();
    runtime.registerProvider("broken", {
      streamSimple: (() => { throw new Error("x"); }) as any,
    } as any);

    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);
    const errors: any[] = [];
    runner.onError((e) => errors.push(e));

    expect(() => runner.bindCore(ea, eca)).not.toThrow();
    // Errors must have been emitted (not swallowed silently)
    expect(errors.length).toBeGreaterThan(0);
    // Error message should contain info about the validation failure
    expect(errors[0].error).toBeTruthy();
  });
});
TSEOF

RESULT=$(cd "$PKG" && npx vitest --run verifier-runner-int.test 2>&1) || true
rm -f "$PKG/test/verifier-runner-int.test.ts"

if echo "$RESULT" | grep -q "Test Files.*1 passed"; then
  add_reward 0.20 "runner_integration" "PASS"
else
  add_reward 0.20 "runner_integration" "FAIL"
fi

###############################################################################
# TEST 6 [F2P]: Post-bind runtime.registerProvider catches errors (weight 0.20)
# Fails on base: post-bind registerProvider lambda directly calls
# modelRegistry.registerProvider without try/catch. Passes after fix.
###############################################################################
echo "=== TEST 6 [F2P]: Post-bind error handling ==="

cat > "$PKG/test/verifier-postbind.test.ts" << 'TSEOF'
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { createExtensionRuntime } from "../src/core/extensions/loader.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import type { ExtensionActions, ExtensionContextActions } from "../src/core/extensions/types.js";
import { ModelRegistry } from "../src/core/model-registry.js";
import { SessionManager } from "../src/core/session-manager.js";

describe("verifier: post-bind error handling", () => {
  let tempDir: string;
  let sessionManager: SessionManager;
  let modelRegistry: ModelRegistry;

  const ea: ExtensionActions = {
    sendMessage: () => {}, sendUserMessage: () => {}, appendEntry: () => {},
    setSessionName: () => {}, getSessionName: () => undefined, setLabel: () => {},
    getActiveTools: () => [], getAllTools: () => [], setActiveTools: () => {},
    refreshTools: () => {}, getCommands: () => [], setModel: async () => false,
    getThinkingLevel: () => "off", setThinkingLevel: () => {},
  };
  const eca: ExtensionContextActions = {
    getModel: () => undefined, isIdle: () => true, abort: () => {},
    hasPendingMessages: () => false, shutdown: () => {},
    getContextUsage: () => undefined, compact: () => {}, getSystemPrompt: () => "",
  };

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "v-postbind-"));
    sessionManager = SessionManager.inMemory();
    const auth = AuthStorage.create(path.join(tempDir, "auth.json"));
    modelRegistry = new ModelRegistry(auth);
  });

  afterEach(() => { fs.rmSync(tempDir, { recursive: true, force: true }); });

  test("runtime.registerProvider after bindCore catches errors", () => {
    const runtime = createExtensionRuntime();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);
    runner.bindCore(ea, eca);

    // After bindCore, registerProvider calls go through the lambda in runner.ts
    // which must catch errors instead of letting them propagate
    expect(() =>
      runtime.registerProvider("broken-post", {
        streamSimple: (() => { throw new Error("x"); }) as any,
      } as any)
    ).not.toThrow();
  });
});
TSEOF

RESULT=$(cd "$PKG" && npx vitest --run verifier-postbind.test 2>&1) || true
rm -f "$PKG/test/verifier-postbind.test.ts"

if echo "$RESULT" | grep -q "Test Files.*1 passed"; then
  add_reward 0.15 "postbind_error_handling" "PASS"
else
  add_reward 0.15 "postbind_error_handling" "FAIL"
fi

###############################################################################
# TEST 7 [F2P]: refresh() resilience — handles stored bad config (weight 0.20)
# The instruction says "Handle errors at every call site where provider
# registration can fail — not just the obvious one." refresh() calls
# applyProviderConfig for every stored provider, and must not crash if one
# is invalid. Fails on base: no try/catch in refresh loop. Passes after
# a thorough fix that protects the refresh path.
###############################################################################
echo "=== TEST 7 [F2P]: refresh() resilience ==="

cat > "$PKG/test/verifier-refresh.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";

describe("verifier: refresh resilience", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;

  beforeEach(() => {
    tempDir = join(tmpdir(), `v-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(tempDir, { recursive: true });
    modelsJsonPath = join(tempDir, "models.json");
    writeFileSync(modelsJsonPath, JSON.stringify({ providers: {} }));
    authStorage = AuthStorage.create(join(tempDir, "auth.json"));
  });

  afterEach(() => {
    if (tempDir && existsSync(tempDir)) rmSync(tempDir, { recursive: true });
    clearApiKeyCache();
  });

  test("refresh() does not crash when a stored config is invalid", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    // Register a good provider first
    registry.registerProvider("good", {
      baseUrl: "https://t.test/v1", apiKey: "K", api: "openai-completions" as any,
      models: [{ id: "m1", name: "M", reasoning: false, input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000, maxTokens: 4096 }],
    });
    // Inject a bad config directly into the internal store. This simulates
    // a scenario where a provider config becomes invalid at refresh time
    // (e.g., a race condition or config corruption). The refresh path must
    // handle errors at this call site per instruction requirement #3.
    (registry as any).registeredProviders.set("corrupt", {
      streamSimple: (() => { throw new Error("x"); }) as any,
    });
    // refresh() must not crash — it should skip the bad provider gracefully
    expect(() => registry.refresh()).not.toThrow();
    // Good provider's models should still be available after refresh
    expect(registry.find("good", "m1")).toBeDefined();
  });
});
TSEOF

RESULT=$(cd "$PKG" && npx vitest --run verifier-refresh.test 2>&1) || true
rm -f "$PKG/test/verifier-refresh.test.ts"

if echo "$RESULT" | grep -q "Test Files.*1 passed"; then
  add_reward 0.20 "refresh_resilience" "PASS"
else
  add_reward 0.20 "refresh_resilience" "FAIL"
fi

###############################################################################
# FINAL SCORE
###############################################################################
echo ""
echo "=== FINAL SCORE ==="
echo "Reward: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt
