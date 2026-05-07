/**
 * Harbor Verifier — AST-level structural checks.
 *
 * Uses the TypeScript compiler API to verify:
 *   1. Object.hasOwn(customPaths, ...) is called in each target file.
 *   2. No `... in customPaths` BinaryExpression remains in any target file.
 *
 * Usage: bun run ast_check.ts <repo_root>
 * Output: JSON with { gid: boolean, ... } verdicts on stdout.
 */

import * as ts from 'typescript';
import * as path from 'path';
import * as fs from 'fs';

const REPO = process.argv[2] || '/opt/amytis';

// Target files relative to the repo root.
const TARGET_FILES = [
  'src/lib/urls.ts',
  'src/app/[slug]/page.tsx',
  'src/app/[slug]/[postSlug]/page.tsx',
  'src/app/[slug]/page/[page]/page.tsx',
];

// ─── AST helpers ─────────────────────────────────────────────────────────────

function findInOperatorOnCustomPaths(node: ts.Node, sourceFile: ts.SourceFile): boolean {
  let found = false;
  function visit(n: ts.Node) {
    if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.InKeyword) {
      // Check if the right operand references 'customPaths'
      const rightText = n.right.getText(sourceFile);
      if (rightText === 'customPaths') {
        found = true;
      }
    }
    ts.forEachChild(n, visit);
  }
  visit(node);
  return found;
}

function findHasOwnOnCustomPaths(node: ts.Node, sourceFile: ts.SourceFile): boolean {
  let found = false;
  function visit(n: ts.Node) {
    if (ts.isCallExpression(n)) {
      const exprText = n.expression.getText(sourceFile);
      if (exprText === 'Object.hasOwn' && n.arguments.length >= 1) {
        const firstArg = n.arguments[0].getText(sourceFile);
        if (firstArg === 'customPaths') {
          found = true;
        }
      }
    }
    ts.forEachChild(n, visit);
  }
  visit(node);
  return found;
}

// ─── Main ────────────────────────────────────────────────────────────────────

const verdicts: Record<string, boolean> = {};

for (const relPath of TARGET_FILES) {
  const fullPath = path.join(REPO, relPath);
  const fileId = relPath.replace(/[^a-zA-Z0-9]/g, '_');

  if (!fs.existsSync(fullPath)) {
    verdicts[`hasown_${fileId}`] = false;
    verdicts[`no_in_${fileId}`] = false;
    continue;
  }

  const sourceText = fs.readFileSync(fullPath, 'utf-8');
  const sourceFile = ts.createSourceFile(relPath, sourceText, ts.ScriptTarget.Latest, true);

  verdicts[`hasown_${fileId}`] = findHasOwnOnCustomPaths(sourceFile, sourceFile);
  verdicts[`no_in_${fileId}`] = !findInOperatorOnCustomPaths(sourceFile, sourceFile);
}

// Also check: no `in customPaths` pattern in ANY .ts/.tsx file under src/
const allInFiles: string[] = [];
function scanDir(dir: string) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory() && !entry.name.startsWith('.') && entry.name !== 'node_modules') {
      scanDir(full);
    } else if (entry.isFile() && /\.(ts|tsx)$/.test(entry.name)) {
      const rel = path.relative(REPO, full);
      const text = fs.readFileSync(full, 'utf-8');
      const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true);
      if (findInOperatorOnCustomPaths(sf, sf)) {
        allInFiles.push(rel);
      }
    }
  }
}
scanDir(path.join(REPO, 'src'));

verdicts['no_in_custompaths_globally'] = allInFiles.length === 0;
verdicts['all_four_files_have_hasown'] =
  TARGET_FILES.every(f => {
    const fileId = f.replace(/[^a-zA-Z0-9]/g, '_');
    return verdicts[`hasown_${fileId}`] === true;
  });
verdicts['all_four_files_no_in'] =
  TARGET_FILES.every(f => {
    const fileId = f.replace(/[^a-zA-Z0-9]/g, '_');
    return verdicts[`no_in_${fileId}`] === true;
  });

// Output JSON for the harness to parse.
console.log(JSON.stringify(verdicts));
