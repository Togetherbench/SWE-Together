/**
 * AST-based verifier for gemini-voyager timeline dot reuse fix.
 * Uses the TypeScript compiler API (already a project devDependency).
 *
 * Checks:
 *   G1 - Dot reuse map exists in recalculateAndRenderMarkers
 *   G2 - Orphan dot cleanup exists after marker rebuild
 *   G3 - No blanket querySelectorAll removal in recalculateAndRenderMarkers
 *   G4 - Range-reset path in updateVirtualRangeAndRender preserves in-range dots
 *   G5 - aria-label is updated when reusing existing dot elements
 *
 * Output: JSON map of {gate_id: true/false} lines to stdout.
 */
import * as ts from "typescript";
import { readFileSync } from "fs";

const MANAGER_PATH = "src/pages/content/timeline/manager.ts";

interface Verdicts {
  dot_reuse_map: boolean;
  orphan_cleanup: boolean;
  no_blanket_removal_in_recalc: boolean;
  range_reset_preserves: boolean;
  aria_label_update: boolean;
}

function sourceFile(): ts.SourceFile {
  const src = readFileSync(MANAGER_PATH, "utf-8");
  return ts.createSourceFile("manager.ts", src, ts.ScriptTarget.Latest, true);
}

/** Find a method by name; returns its function body node or null. */
function findMethodBody(
  sf: ts.SourceFile,
  className: string,
  methodName: string,
): ts.Block | null {
  let result: ts.Block | null = null;
  function visit(node: ts.Node) {
    if (result) return;
    if (
      ts.isClassDeclaration(node) &&
      node.name?.text === className
    ) {
      for (const member of node.members) {
        if (
          ts.isMethodDeclaration(member) &&
          member.name &&
          ts.isIdentifier(member.name) &&
          member.name.text === methodName &&
          member.body
        ) {
          result = member.body;
          return;
        }
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(sf);
  return result;
}

// ── G1: Dot reuse map built in recalculateAndRenderMarkers ──────────────
function checkDotReuseMap(body: ts.Block): boolean {
  let hasMapInit = false;
  let hasDotElementFromMap = false;

  function visit(node: ts.Node) {
    // Look for: const oldDots = new Map<string, DotElement>();
    // or any variable assigned to Map with a for-loop filling it from marker dotElement
    if (ts.isVariableStatement(node)) {
      for (const decl of node.declarationList.declarations) {
        if (
          decl.initializer &&
          ts.isNewExpression(decl.initializer) &&
          decl.initializer.expression.getText().includes("Map")
        ) {
          // Check if there's a nearby for-of loop that sets values from marker.dotElement
          hasMapInit = true;
        }
      }
    }
    // Look for: dotElement: oldDots.get(id) ?? null (or equivalent)
    if (
      ts.isPropertyAssignment(node) &&
      ts.isIdentifier(node.name) &&
      node.name.text === "dotElement" &&
      node.initializer
    ) {
      const init = node.initializer.getText();
      if (init.includes(".get(") && init !== "null") {
        hasDotElementFromMap = true;
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(body);
  return hasMapInit && hasDotElementFromMap;
}

// ── G2: Orphan dot cleanup after marker rebuild ─────────────────────────
function checkOrphanCleanup(body: ts.Block): boolean {
  // Look for a for-of loop that calls .remove() on remaining dots
  // Pattern: for (const dot of oldDots.values()) dot.remove();
  let found = false;
  function visit(node: ts.Node) {
    if (found) return;
    if (ts.isForOfStatement(node)) {
      const stmtText = node.statement.getText();
      const exprText = node.expression.getText();
      // expression references .values() of a map/set
      // statement calls .remove()
      if (
        exprText.includes(".values()") &&
        stmtText.includes(".remove()")
      ) {
        found = true;
        return;
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(body);
  // Also accept: for (const dot of orphaned) dot.remove();
  // Or: oldDots.forEach(dot => dot.remove());
  if (!found) {
    // Check for .forEach() + .remove() pattern related to old dots
    function visitCall(node: ts.Node) {
      if (found) return;
      if (ts.isCallExpression(node)) {
        const text = node.getText();
        if (
          (text.includes(".values()") || text.includes("oldDot")) &&
          text.includes(".remove()")
        ) {
          found = true;
          return;
        }
      }
      ts.forEachChild(node, visitCall);
    }
    visitCall(body);
  }
  return found;
}

// ── G3: No blanket querySelectorAll('.timeline-dot').forEach(n => n.remove())
//       in recalculateAndRenderMarkers ─────────────────────────────
function checkNoBlanketRemoval(body: ts.Block): boolean {
  let foundBlanket = false;
  function visit(node: ts.Node) {
    if (foundBlanket) return;
    if (ts.isCallExpression(node)) {
      const text = node.getText();
      // Detect: querySelectorAll('.timeline-dot').forEach((n) => n.remove())
      // or: querySelectorAll('.timeline-dot').forEach(n => n.remove())
      // These would indicate the old destructive pattern
      if (
        text.includes("querySelectorAll") &&
        text.includes("timeline-dot") &&
        text.includes("forEach") &&
        text.includes(".remove()")
      ) {
        foundBlanket = true;
        return;
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(body);
  return !foundBlanket; // true = no blanket removal (good)
}

// ── G4: Range-reset path in updateVirtualRangeAndRender preserves in-range dots ──
function checkRangeResetPreserves(
  sf: ts.SourceFile,
): boolean {
  const body = findMethodBody(
    sf,
    "TimelineManager",
    "updateVirtualRangeAndRender",
  );
  if (!body) return false;

  // Find else branch that handles range reset
  // Should contain selective removal (keepDots set or filter), not blanket
  let foundSelective = false;
  let foundBlanket = false;

  function visit(node: ts.Node) {
    if (ts.isIfStatement(node) && node.elseStatement) {
      const elseStmt = node.elseStatement;
      const elseText = elseStmt.getText();

      // Check for the blanket pattern in the else branch
      if (
        elseText.includes("querySelectorAll") &&
        elseText.includes("timeline-dot") &&
        elseText.includes(".remove()")
      ) {
        // This might be OK if there's a filter/keep condition
        // Check if there's a Set or filter guarding the removal
        if (
          elseText.includes("keepDots") ||
          elseText.includes(".has(") ||
          elseText.includes("Set<") ||
          !elseText.includes("forEach")
        ) {
          foundSelective = true;
        }
        // If forEach remove has a condition (!keepDots.has(n)), it's selective
        if (
          elseText.includes("forEach") &&
          elseText.includes(".remove()") &&
          (elseText.includes("keepDots") ||
           elseText.includes(".has(") ||
           elseText.includes("!keep") ||
           elseText.includes("filter"))
        ) {
          foundSelective = true;
        }
      }
      // Also check for blanket removal without guard
      if (
        elseText.match(/querySelectorAll.*timeline-dot.*forEach.*remove/) &&
        !elseText.match(/keepDots|keep_dots|preserve|\.has\(|Set</)
      ) {
        foundBlanket = true;
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(body);

  // Accept if selective pattern found AND no blanket pattern
  if (foundSelective && !foundBlanket) return true;

  // If no selective pattern found but also no blanket, look for alternative patterns
  // e.g., iterating over markers in range and only removing outside range
  if (!foundBlanket) {
    function visitMarkers(node: ts.Node) {
      if (foundSelective) return;
      // Check for any selective dot management in the else branch
      if (ts.isIfStatement(node) && node.elseStatement) {
        const elseText = node.elseStatement.getText();
        if (
          elseText.includes("markers[") &&
          elseText.includes("dotElement") &&
          elseText.includes("remove()")
        ) {
          foundSelective = true;
        }
      }
      ts.forEachChild(node, visitMarkers);
    }
    visitMarkers(body);
  }

  return foundSelective && !foundBlanket;
}

// ── G5: aria-label updated on reused dots ──────────────────────────────
function checkAriaLabelUpdate(sf: ts.SourceFile): boolean {
  const body = findMethodBody(
    sf,
    "TimelineManager",
    "updateVirtualRangeAndRender",
  );
  if (!body) return false;

  let found = false;
  function visit(node: ts.Node) {
    if (found) return;
    if (ts.isCallExpression(node)) {
      const text = node.getText();
      // setAttribute('aria-label', ...) or ['aria-label'] = ... or ariaLabel
      if (
        text.includes("aria-label") &&
        (text.includes("setAttribute") || text.includes("summary"))
      ) {
        found = true;
        return;
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(body);

  // Also check the `dot.dataset` or `dotElement.setAttribute` pattern
  if (!found) {
    function visitProp(node: ts.Node) {
      if (found) return;
      if (ts.isPropertyAccessExpression(node)) {
        const text = node.getText();
        if (
          text.includes("aria-label") ||
          text.includes("setAttribute")
        ) {
          found = true;
          return;
        }
      }
      ts.forEachChild(node, visitProp);
    }
    visitProp(body);
  }
  return found;
}

// ── Main ───────────────────────────────────────────────────────────────
function main() {
  const sf = sourceFile();

  const recalcBody = findMethodBody(
    sf,
    "TimelineManager",
    "recalculateAndRenderMarkers",
  );
  if (!recalcBody) {
    console.error(
      "FATAL: Could not find recalculateAndRenderMarkers method",
    );
    process.exit(1);
  }

  const verdicts: Verdicts = {
    dot_reuse_map: checkDotReuseMap(recalcBody),
    orphan_cleanup: checkOrphanCleanup(recalcBody),
    no_blanket_removal_in_recalc: checkNoBlanketRemoval(recalcBody),
    range_reset_preserves: checkRangeResetPreserves(sf),
    aria_label_update: checkAriaLabelUpdate(sf),
  };

  // Write each verdict as JSON line
  for (const [gid, passed] of Object.entries(verdicts)) {
    process.stdout.write(
      JSON.stringify({ id: gid, passed }) + "\n",
    );
  }
}

main();
