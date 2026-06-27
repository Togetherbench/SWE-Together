/**
 * Verify the folder drag-and-drop fix in manager.ts.
 * Usage: bun run verify_fix.ts <check_name>
 * Checks: dragleave_fix, ensure_method, drop_preinsert, method_depth
 *
 * Run from the repo root so that 'typescript' resolves from node_modules.
 * Example: cd /opt/gemini-voyager && bun run /path/to/verify_fix.ts dragleave_fix
 */
import * as ts from 'typescript';
import * as fs from 'fs';

const SOURCE_FILE = 'src/pages/content/folder/manager.ts';
const checkName = process.argv[2];

if (!checkName) {
  console.error('Usage: bun run verify_fix.ts <check_name>');
  process.exit(1);
}

const source = fs.readFileSync(SOURCE_FILE, 'utf8');
const sf = ts.createSourceFile('manager.ts', source, ts.ScriptTarget.Latest, true);

function visitAll(node: ts.Node, cb: (node: ts.Node) => void): void {
  cb(node);
  ts.forEachChild(node, child => visitAll(child, cb));
}

/** Check that a node's text contains classList.remove inside a conditional (not at top level). */
function removeIsConditional(body: ts.Node): boolean {
  let hasUnconditionalRemove = false;
  let hasConditionalRemove = false;

  function check(node: ts.Node): void {
    if (ts.isBlock(node)) {
      node.statements.forEach(stmt => {
        if (ts.isExpressionStatement(stmt)) {
          const text = stmt.getText(source);
          if (text.includes('classList.remove') && text.includes('gv-folder-dragover')) {
            hasUnconditionalRemove = true;
          }
        } else if (ts.isIfStatement(stmt)) {
          const ifText = stmt.getText(source);
          if (ifText.includes('classList.remove') && ifText.includes('gv-folder-dragover')) {
            hasConditionalRemove = true;
          }
        }
      });
    }
    ts.forEachChild(node, child => check(child));
  }
  check(body);
  return hasConditionalRemove && !hasUnconditionalRemove;
}

/** Check that the body has a getBoundingClientRect call plus coordinate comparisons. */
function hasCoordinateCheck(body: ts.Node): boolean {
  const text = body.getText(source);
  return text.includes('getBoundingClientRect') &&
         (text.includes('clientX') || text.includes('clientY')) &&
         (text.includes('rect.left') || text.includes('rect.right') ||
          text.includes('rect.top') || text.includes('rect.bottom'));
}

/** Check 1: dragleave handler in setupDropZone is fixed. */
function checkDragleaveFix(): boolean {
  let found = false;
  let passed = false;

  visitAll(sf, (node) => {
    if (found) return;
    if (ts.isMethodDeclaration(node) && node.name?.getText(source) === 'setupDropZone') {
      const body = node.body;
      if (!body) return;

      // Find addEventListener('dragleave', handler) inside setupDropZone
      visitAll(body, (inner) => {
        if (passed) return;
        if (ts.isCallExpression(inner)) {
          const prop = inner.expression;
          if (ts.isPropertyAccessExpression(prop) && prop.name.text === 'addEventListener') {
            const args = inner.arguments;
            if (args.length >= 2 && ts.isStringLiteral(args[0]) && args[0].text === 'dragleave') {
              found = true;
              const handler = args[1];
              const body2 = ts.isArrowFunction(handler) || ts.isFunctionExpression(handler) ? handler.body : handler;
              // The fix must ensure classList.remove is NOT unconditional
              passed = removeIsConditional(body2) || hasCoordinateCheck(body2);
            }
          }
        }
      });
    }
  });

  return found && passed;
}

/** Check 2: ensureConversationsInFolder method exists as a private method on FolderManager. */
function checkEnsureMethod(): boolean {
  let foundMethod = false;

  visitAll(sf, (node) => {
    if (foundMethod) return;
    if (ts.isMethodDeclaration(node)) {
      const name = node.name?.getText(source) || '';
      if (name === 'ensureConversationsInFolder') {
        // Check modifiers for 'private'
        const modifiers = ts.canHaveModifiers(node) ? ts.getModifiers(node) : undefined;
        const isPrivate = modifiers?.some(m => m.kind === ts.SyntaxKind.PrivateKeyword) ?? false;
        // Check parameters
        const params = node.parameters;
        const hasFolderId = params.some(p => p.name.getText(source) === 'folderId');
        const hasDragData = params.some(p => p.name.getText(source) === 'dragData');
        if (isPrivate && hasFolderId && hasDragData) {
          foundMethod = true;
        }
      }
    }
  });

  return foundMethod;
}

/** Check 3: In at least one context, ensureConversationsInFolder is called before reorderOrMoveConversations. */
function checkDropPreinsert(): boolean {
  let result = false;

  // Collection: for each function, track positions of relevant calls
  visitAll(sf, (node) => {
    if (result) return;
    if (ts.isFunctionDeclaration(node) || ts.isMethodDeclaration(node) || ts.isArrowFunction(node)) {
      const body = ts.isArrowFunction(node) ? node.body : (node as ts.FunctionDeclaration | ts.MethodDeclaration).body;
      if (!body) return;

      const bodyText = body.getText(source);
      const ensurePos = bodyText.indexOf('ensureConversationsInFolder(');
      const reorderPos = bodyText.indexOf('reorderOrMoveConversations(');

      if (ensurePos !== -1 && reorderPos !== -1 && ensurePos < reorderPos) {
        result = true;
      }
    }
  });

  return result;
}

/** Check 4: ensureConversationsInFolder method body has substantial logic (>3 meaningful statements). */
function checkMethodDepth(): boolean {
  let passed = false;

  visitAll(sf, (node) => {
    if (passed) return;
    if (ts.isMethodDeclaration(node) && node.name?.getText(source) === 'ensureConversationsInFolder') {
      const body = node.body;
      if (!body) return;

      // Count direct child statements in the method body
      let stmtCount = 0;
      if (ts.isBlock(body)) {
        let hasContentsAssignment = false;
        let hasMaxSortIndex = false;
        let hasLoop = false;
        let hasPush = false;

        body.statements.forEach(stmt => {
          const t = stmt.getText(source);
          // Count meaningful statements (not just blank/return)
          if (t.trim().length > 5) {
            stmtCount++;
          }
          if (t.includes('folderContents[')) hasContentsAssignment = true;
          if (t.includes('maxSortIndex') || t.includes('sortIndex')) hasMaxSortIndex = true;
          // Iteration patterns: for (const x of ...), .forEach(, .map(, for (let
          if (/\bfor\s*\(/.test(t) || /\.forEach\s*\(/.test(t) || /\.map\s*\(/.test(t)) {
            hasLoop = true;
          }
          // Array addition: .push(, spread [...arr, , or direct assignment
          if (t.includes('.push(') || t.includes('[...') || t.includes('] =')) {
            hasPush = true;
          }
        });

        // Must have structure: folderContents access + sorting + iteration + push
        passed = stmtCount > 3 && hasContentsAssignment && (hasMaxSortIndex || hasLoop) && hasPush;
      }
    }
  });

  return passed;
}

// Run the requested check
let result: boolean;
switch (checkName) {
  case 'dragleave_fix':
    result = checkDragleaveFix();
    break;
  case 'ensure_method':
    result = checkEnsureMethod();
    break;
  case 'drop_preinsert':
    result = checkDropPreinsert();
    break;
  case 'method_depth':
    result = checkMethodDepth();
    break;
  default:
    console.error(`Unknown check: ${checkName}`);
    process.exit(2);
}

console.log(result ? 'PASS' : 'FAIL');
process.exit(result ? 0 : 1);
