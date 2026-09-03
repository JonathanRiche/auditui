import { readdir, readFile } from "node:fs/promises";
import type { Dirent } from "node:fs";
import { join } from "node:path";

const allowed = new Set([
  "0BSD",
  "Apache-2.0",
  "BSD-2-Clause",
  "BSD-3-Clause",
  "ISC",
  "MIT",
  "MIT OR Apache-2.0",
]);
const roots = ["node_modules", "tui/node_modules"];
const seen = new Map<string, string>();

async function collect(directory: string, depth = 0): Promise<void> {
  if (depth > 3) return;
  let entries: Dirent[];
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const child = join(directory, entry.name);
    if (entry.name.startsWith("@")) {
      await collect(child, depth + 1);
      continue;
    }
    try {
      const pkg = JSON.parse(await readFile(join(child, "package.json"), "utf8"));
      if (typeof pkg.name === "string" && typeof pkg.version === "string") {
        const license = typeof pkg.license === "string" ? pkg.license : "UNKNOWN";
        seen.set(`${pkg.name}@${pkg.version}`, license);
      }
    } catch {
      // Not a package root.
    }
    await collect(child, depth + 1);
  }
}

for (const root of roots) await collect(root);
const rejected = [...seen].filter(([, license]) => !allowed.has(license));
if (rejected.length > 0) {
  console.error("Dependencies with missing or unreviewed licenses:");
  for (const [pkg, license] of rejected) console.error(`- ${pkg}: ${license}`);
  process.exit(1);
}
console.log(`License metadata check passed for ${seen.size} installed packages.`);
