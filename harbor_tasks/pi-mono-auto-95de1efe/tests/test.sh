#!/bin/bash
set +e

REPO="/workspace/pi-mono"
PKG="$REPO/packages/coding-agent"
LOGDIR="/logs/verifier"
mkdir -p "$LOGDIR"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

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

if ! command -v npx >/dev/null 2>&1; then
  echo "npx missing"; finish
fi

RUNNER_TS="$PKG/src/core/extensions/runner.ts"
REGISTRY_TS="$PKG/src/core/model-registry.ts"

###############################################################################
# GATE [P2P]: existing tests must still pass.
###############################################################################
echo "=== GATE [P2P]: model-registry tests ==="
VITEST_OUT=$(npx vitest --run model-registry.test 2>&1)
echo "$VITEST_OUT" > "$LOGDIR/gate1.log"
if ! echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ passed"; then
  echo "  GATE FAIL — model-registry tests not passing; REWARD=0"
  finish
fi
if echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ failed"; then
  echo "  GATE FAIL — model-registry has failing files; REWARD=0"
  finish
fi
echo "  GATE PASS"

echo "=== GATE [P2P]: extensions-runner tests ==="
VITEST_OUT=$(npx vitest --run extensions-runner.test 2>&1)
echo "$VITEST_OUT" > "$LOGDIR/gate2.log"
if ! echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ passed"; then
  echo "  GATE FAIL — extensions-runner tests not passing; REWARD=0"
  finish
fi
if echo "$VITEST_OUT" | grep -qE "Test Files.*[0-9]+ failed"; then
  echo "  GATE FAIL — extensions-runner has failing files; REWARD=0"
  finish
fi
echo "  GATE PASS"

###############################################################################
# GATE [P2P]: no-op detector. If runner.ts is unchanged from buggy form, REWARD=0.
# The buggy runner.ts has `this.runtime.registerProvider = (name, config) => {`
# (2-arg arrow, no try/catch around modelRegistry.registerProvider).
###############################################################################
echo "=== GATE [P2P]: no-op detection on runner.ts ==="
if [ ! -f "$RUNNER_TS" ]; then
  echo "  runner.ts missing; REWARD=0"
  finish
fi
# Detect whether post-bind registerProvider has a try/catch. If it doesn't,
# this is a no-op patch w.r.t. the issue.
RUNNER_HAS_TRYCATCH=0
# Look for try { ... emitError pattern within registerProvider closure region
if awk '
  /this\.runtime\.registerProvider[[:space:]]*=/ { inreg=1; depth=0 }
  inreg {
    print
    n=gsub(/\{/,"{"); m=gsub(/\}/,"}");
    depth += n - m;
    if (NR>1 && depth<=0 && /\}/) { inreg=0 }
  }
' "$RUNNER_TS" 2>/dev/null | grep -qE "emitError|catch"; then
  RUNNER_HAS_TRYCATCH=1
fi
if [ "$RUNNER_HAS_TRYCATCH" = "0" ]; then
  echo "  GATE FAIL — runner.ts post-bind registerProvider has no error handling (no-op patch)"
  finish
fi
echo "  GATE PASS"

###############################################################################
# F2P GATE 1 (weight 0.15): runner.ts post-bind registerProvider closure
# accepts an extensionPath argument (3rd arg) — types updated.
###############################################################################
echo "=== F2P 1: runner registerProvider has extensionPath param ==="
if grep -E "this\.runtime\.registerProvider[[:space:]]*=[[:space:]]*\(name,[[:space:]]*config,[[:space:]]*extensionPath" "$RUNNER_TS" >/dev/null 2>&1; then
  add_reward 0.15 "runner_extensionPath_param" "PASS"
else
  add_reward 0.15 "runner_extensionPath_param" "FAIL"
fi

###############################################################################
# F2P GATE 2 (weight 0.25): Behavioral test — post-bind invalid registerProvider
# does NOT throw, calls onError with extensionPath, and registry.refresh() is safe.
###############################################################################
echo "=== F2P 2: behavioral runner test ==="

cat > "$PKG/test/verifier-runner-behavioral.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { createExtensionRuntime } from "../src/core/extensions/runtime.js";

describe("verifier runner behavioral", () => {
  let tempDir: string;
  let modelsJsonPath: string;
  let authStorage: AuthStorage;
  let modelRegistry: ModelRegistry;

  const sessionManager: any = {
    getSession: () => undefined,
    listSessions: () => [],
    createSession: () => ({}),
  };
  const extensionActions: any = {};
  const extensionContextActions: any = {};

  beforeEach(() => {
    tempDir = join(tmpdir(), `v-runner-${Date.now()}-${Math.random().toString(36).slice(2)}`);
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

  test("post-bind invalid registration does not throw and is reported", () => {
    const runtime = createExtensionRuntime();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);
    runner.bindCore(extensionActions, extensionContextActions);

    const errors: any[] = [];
    runner.onError((e: any) => errors.push(e));

    expect(() =>
      (runtime.registerProvider as any)(
        "broken-provider",
        { streamSimple: (() => { throw new Error("unused"); }) as any },
        "/tmp/broken-extension.ts",
      ),
    ).not.toThrow();

    expect(errors.length).toBeGreaterThanOrEqual(1);
    const e = errors[0];
    expect(e.extensionPath).toBe("/tmp/broken-extension.ts");
    const msg = (e.error ?? "").toString();
    expect(msg.toLowerCase()).toContain("api");

    expect(() => modelRegistry.refresh()).not.toThrow();
  });

  test("post-bind valid registration still works", () => {
    const runtime = createExtensionRuntime();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);
    runner.bindCore(extensionActions, extensionContextActions);

    const errors: any[] = [];
    runner.onError((e: any) => errors.push(e));

    (runtime.registerProvider as any)(
      "good-provider",
      {
        baseUrl: "https://t.test/v1",
        apiKey: "K",
        api: "openai-completions",
        models: [{
          id: "m1", name: "M", reasoning: false, input: ["text"],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow: 128000, maxTokens: 4096,
        }],
      } as any,
      "/tmp/good.ts",
    );

    expect(errors.length).toBe(0);
    expect(modelRegistry.find("good-provider", "m1")).toBeDefined();
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-runner-behavioral.test 2>&1)
echo "$RESULT" > "$LOGDIR/f2p2.log"
rm -f "$PKG/test/verifier-runner-behavioral.test.ts"

P_RUNNER=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
F_RUNNER=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)

if [ -z "$F_RUNNER" ] && [ "${P_RUNNER:-0}" -ge 2 ]; then
  add_reward 0.25 "runner_behavioral_full" "PASS"
elif [ -z "$F_RUNNER" ] && [ "${P_RUNNER:-0}" -ge 1 ]; then
  add_reward 0.12 "runner_behavioral_partial" "PASS"
else
  add_reward 0.25 "runner_behavioral_full" "FAIL"
fi

###############################################################################
# F2P GATE 3 (weight 0.20): registry atomicity — failed registration leaves
# no partial state; refresh() and subsequent good registration both work.
###############################################################################
echo "=== F2P 3: registry atomicity ==="

cat > "$PKG/test/verifier-atomic.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";

describe("verifier atomic", () => {
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

  test("invalid registration throws synchronously", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    expect(() =>
      registry.registerProvider("broken", {
        streamSimple: (() => { throw new Error("u"); }) as any,
      }),
    ).toThrow();
  });

  test("after failed registration: refresh safe, subsequent good register works", () => {
    const registry = new ModelRegistry(authStorage, modelsJsonPath);
    try {
      registry.registerProvider("broken", {
        streamSimple: (() => { throw new Error("u"); }) as any,
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
echo "$RESULT" > "$LOGDIR/f2p3.log"
rm -f "$PKG/test/verifier-atomic.test.ts"

P_ATOM=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
F_ATOM=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)

if [ -z "$F_ATOM" ] && [ "${P_ATOM:-0}" -ge 4 ]; then
  add_reward 0.20 "registry_atomic_full" "PASS"
elif [ -z "$F_ATOM" ] && [ "${P_ATOM:-0}" -ge 3 ]; then
  add_reward 0.13 "registry_atomic_3of4" "PASS"
elif [ "${P_ATOM:-0}" -ge 2 ]; then
  add_reward 0.06 "registry_atomic_partial" "PASS"
else
  add_reward 0.20 "registry_atomic_full" "FAIL"
fi

###############################################################################
# F2P GATE 4 (weight 0.15): error reporting includes extensionPath identifying
# which extension triggered the failure (behavioral check via onError payload).
# This is distinct from gate 2 because it specifically asserts the message
# format / payload shape used downstream.
###############################################################################
echo "=== F2P 4: error reports identify extension ==="

cat > "$PKG/test/verifier-error-id.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { createExtensionRuntime } from "../src/core/extensions/runtime.js";

describe("verifier error id", () => {
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
    tempDir = join(tmpdir(), `v-eid-${Date.now()}-${Math.random().toString(36).slice(2)}`);
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

  test("error payload contains extensionPath of failing extension", () => {
    const runtime = createExtensionRuntime();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);
    runner.bindCore({}, {});

    const errors: any[] = [];
    runner.onError((e: any) => errors.push(e));

    (runtime.registerProvider as any)(
      "evil-provider",
      { streamSimple: (() => { throw new Error("u"); }) as any },
      "/path/to/extension-A.ts",
    );

    expect(errors.length).toBeGreaterThanOrEqual(1);
    expect(errors[0].extensionPath).toBe("/path/to/extension-A.ts");

    // Different extension, different path
    (runtime.registerProvider as any)(
      "evil2",
      { streamSimple: (() => { throw new Error("u"); }) as any },
      "/path/to/extension-B.ts",
    );
    expect(errors.length).toBeGreaterThanOrEqual(2);
    expect(errors[1].extensionPath).toBe("/path/to/extension-B.ts");
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-error-id.test 2>&1)
echo "$RESULT" > "$LOGDIR/f2p4.log"
rm -f "$PKG/test/verifier-error-id.test.ts"

P_EID=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
F_EID=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)

if [ -z "$F_EID" ] && [ "${P_EID:-0}" -ge 1 ]; then
  add_reward 0.15 "error_identifies_extension" "PASS"
else
  add_reward 0.15 "error_identifies_extension" "FAIL"
fi

###############################################################################
# F2P GATE 5 (weight 0.10): pre-bind path also handles failures.
# When extension calls registerProvider BEFORE bindCore, registrations are
# queued; on bindCore flush they should be wrapped in try/catch (validate before
# mutate) — instruction R3 "every call site". We test via static + behavioral.
###############################################################################
echo "=== F2P 5: pre-bind / flush path handles errors ==="

# Run extensions-runner.test specifically for the existing flush tests, plus
# a new test exercising pre-bind invalid registration.

cat > "$PKG/test/verifier-prebind.test.ts" << 'TSEOF'
import { mkdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test, expect } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { clearApiKeyCache, ModelRegistry } from "../src/core/model-registry.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { createExtensionRuntime } from "../src/core/extensions/runtime.js";

describe("verifier prebind", () => {
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
    tempDir = join(tmpdir(), `v-pb-${Date.now()}-${Math.random().toString(36).slice(2)}`);
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

  test("pre-bind invalid registration does not crash bindCore", () => {
    const runtime = createExtensionRuntime();
    const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);

    // Queue an invalid registration BEFORE bindCore.
    (runtime.registerProvider as any)(
      "early-broken",
      { streamSimple: (() => { throw new Error("u"); }) as any },
    );

    const errors: any[] = [];
    runner.onError((e: any) => errors.push(e));

    expect(() => runner.bindCore({}, {})).not.toThrow();

    // Subsequent good registration should still work.
    (runtime.registerProvider as any)(
      "ok",
      {
        baseUrl: "https://t.test/v1", apiKey: "K", api: "openai-completions",
        models: [{ id: "m1", name: "M", reasoning: false, input: ["text"],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow: 128000, maxTokens: 4096 }],
      } as any,
      "/tmp/ok.ts",
    );
    expect(modelRegistry.find("ok", "m1")).toBeDefined();
  });
});
TSEOF

RESULT=$(npx vitest --run verifier-prebind.test 2>&1)
echo "$RESULT" > "$LOGDIR/f2p5.log"
rm -f "$PKG/test/verifier-prebind.test.ts"

P_PB=$(echo "$RESULT" | grep -oE "Tests[[:space:]]+[0-9]+ passed" | grep -oE "[0-9]+" | head -1)
F_PB=$(echo "$RESULT" | grep -E "Tests.*failed" | grep -oE "[0-9]+ failed" | head -1)

if [ -z "$F_PB" ] && [ "${P_PB:-0}" -ge 1 ]; then
  add_reward 0.10 "prebind_safe" "PASS"
else
  add_reward 0.10 "prebind_safe" "FAIL"
fi

###############################################################################
# F2P GATE 6 (weight 0.15): completeness — the runtime types include an
# extensionPath argument on registerProvider so callsites can pass it.
# We check the runtime.ts (or types file) for an extensionPath?: parameter
# in the registerProvider signature.
###############################################################################
echo "=== F2P 6: registerProvider type signature includes extensionPath ==="

FOUND_TYPE=0
# Search runtime.ts and relevant .d/.ts files in extensions/ for signature
for f in "$PKG/src/core/extensions/runtime.ts" "$PKG/src/core/extensions/types.ts" "$PKG/src/core/extensions"/*.ts; do
  [ -f "$f" ] || continue
  # Look for registerProvider signature with extensionPath
  if grep -E "registerProvider[[:space:]]*[:?]?[[:space:]]*\(.*extensionPath" "$f" >/dev/null 2>&1; then
    FOUND_TYPE=1
    break
  fi
  # Multi-line signature: extract a window around registerProvider
  if awk '/registerProvider/{found=1; cnt=0} found{print; cnt++; if (cnt>5) exit}' "$f" 2>/dev/null | grep -q "extensionPath"; then
    FOUND_TYPE=1
    break
  fi
done

if [ "$FOUND_TYPE" = "1" ]; then
  add_reward 0.15 "type_signature_has_extensionPath" "PASS"
else
  add_reward 0.15 "type_signature_has_extensionPath" "FAIL"
fi

###############################################################################
# Done
###############################################################################
finish