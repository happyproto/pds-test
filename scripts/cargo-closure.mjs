#!/usr/bin/env node

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { parse } from "smol-toml";

const [root, wanted, ...flags] = process.argv.slice(2);
if (!root || !wanted) {
  fail("usage: cargo-closure.mjs <workspace-root> <crate-name> [--lock]");
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function load(path) {
  return parse(readFileSync(path, "utf8"));
}

function expandMember(pattern) {
  if (!pattern.includes("*")) {
    return [join(root, pattern)];
  }
  if (!pattern.endsWith("/*") || pattern.slice(0, -2).includes("*")) {
    fail(`unsupported workspace member pattern: ${pattern}`);
  }
  const parent = join(root, pattern.slice(0, -2));
  return readdirSync(parent, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => join(parent, entry.name));
}

const workspace = load(join(root, "Cargo.toml")).workspace ?? {};
const workspaceDeps = workspace.dependencies ?? {};

const crates = new Map();
for (const pattern of workspace.members ?? []) {
  for (const dir of expandMember(pattern)) {
    const manifestPath = join(dir, "Cargo.toml");
    if (!existsSync(manifestPath)) continue;
    const manifest = load(manifestPath);
    crates.set(manifest.package.name, { dir: relative(root, dir), manifest });
  }
}

if (!crates.has(wanted)) {
  fail(`${wanted} is not a member of the workspace at ${root}`);
}

function* dependencyTables(manifest) {
  for (const key of ["dependencies", "build-dependencies"]) {
    yield manifest[key] ?? {};
  }
  for (const target of Object.values(manifest.target ?? {})) {
    for (const key of ["dependencies", "build-dependencies"]) {
      yield target[key] ?? {};
    }
  }
}

function* pathDependencies(manifest) {
  for (const table of dependencyTables(manifest)) {
    for (const [alias, declared] of Object.entries(table)) {
      if (typeof declared !== "object") continue;
      const spec = declared.workspace ? workspaceDeps[alias] : declared;
      if (typeof spec !== "object" || spec.path === undefined) continue;
      // A renamed dependency is keyed by its alias; `package` names the crate.
      yield spec.package ?? declared.package ?? alias;
    }
  }
}

const closure = new Set();
const pending = [wanted];
while (pending.length > 0) {
  const name = pending.pop();
  if (closure.has(name)) continue;
  if (!crates.has(name)) {
    fail(`path dependency ${name} is not a workspace member`);
  }
  closure.add(name);
  pending.push(...pathDependencies(crates.get(name).manifest));
}

const byteOrder = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

if (!flags.includes("--lock")) {
  const dirs = [...closure].map((name) => crates.get(name).dir).sort(byteOrder);
  process.stdout.write(`${dirs.join("\n")}\n`);
  process.exit(0);
}

const packages = load(join(root, "Cargo.lock")).package ?? [];
const byName = new Map();
for (const pkg of packages) {
  if (!byName.has(pkg.name)) byName.set(pkg.name, []);
  byName.get(pkg.name).push(pkg);
}

function resolve(reference) {
  const [name, version] = reference.split(" ");
  const candidates = (byName.get(name) ?? []).filter(
    (pkg) => version === undefined || pkg.version === version,
  );
  if (candidates.length !== 1) {
    fail(`Cargo.lock reference "${reference}" does not resolve to one package`);
  }
  return candidates[0];
}

const key = (pkg) => `${pkg.name} ${pkg.version} ${pkg.source ?? ""}`;

const start = [...closure].flatMap((name) => byName.get(name) ?? []);
if (start.length !== closure.size) {
  fail("a workspace crate in the closure is missing from Cargo.lock");
}

const reached = new Map();
const queue = [...start];
while (queue.length > 0) {
  const pkg = queue.pop();
  if (reached.has(key(pkg))) continue;
  reached.set(key(pkg), pkg);
  queue.push(...(pkg.dependencies ?? []).map(resolve));
}

const lines = [...reached.values()]
  .map((pkg) => [pkg.name, pkg.version, pkg.source ?? "-", pkg.checksum ?? "-"])
  .sort(
    (a, b) =>
      byteOrder(a[0], b[0]) || byteOrder(a[1], b[1]) || byteOrder(a[2], b[2]),
  )
  .map((fields) => fields.join(" "));
process.stdout.write(`${lines.join("\n")}\n`);
