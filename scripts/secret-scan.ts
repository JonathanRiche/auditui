import { readdir, readFile } from "node:fs/promises";
import { extname, join, relative } from "node:path";

const root = process.cwd();
const ignoredDirectories = new Set([
  ".git",
  ".tmp",
  ".zig-cache",
  "dist",
  "node_modules",
  "zig-out",
]);
const textExtensions = new Set([
  "",
  ".json",
  ".md",
  ".sh",
  ".toml",
  ".ts",
  ".txt",
  ".yaml",
  ".yml",
  ".zig",
  ".zon",
]);
const forbiddenNames = [
  /^auth.*\.json$/i,
  /\.(?:aax|aaxc|db|db-shm|db-wal|pem|voucher)$/i,
  /activation[-_.]?bytes/i,
];
const tokenPatterns = [
  new RegExp(["AK", "IA", "[0-9A-Z]{16}"].join(""), "g"),
  new RegExp(["gh", "p_", "[A-Za-z0-9]{36,}"].join(""), "g"),
  new RegExp(["github_pat_", "[A-Za-z0-9_]{40,}"].join(""), "g"),
];
const sensitiveJson =
  /"(?:access_token|refresh_token|adp_token|device_private_key|website_cookies|voucher)"\s*:\s*"([^"]+)"/g;
const syntheticPrefixes = ["fixture", "synthetic", "redacted", "example"];
const findings: string[] = [];

async function walk(directory: string): Promise<void> {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) continue;
    const path = join(directory, entry.name);
    const display = relative(root, path);
    if (entry.isDirectory()) {
      await walk(path);
      continue;
    }
    if (!entry.isFile()) continue;
    if (
      !display.startsWith("protocol/fixtures/") &&
      forbiddenNames.some((pattern) => pattern.test(entry.name))
    ) {
      findings.push(`${display}: forbidden credential/media filename`);
    }
    if (!textExtensions.has(extname(entry.name)) || display === "scripts/secret-scan.ts") continue;
    const text = await readFile(path, "utf8");
    for (const pattern of tokenPatterns) {
      pattern.lastIndex = 0;
      if (pattern.test(text)) findings.push(`${display}: possible service credential`);
    }
    sensitiveJson.lastIndex = 0;
    for (const match of text.matchAll(sensitiveJson)) {
      const value = match[1] ?? "";
      if (!syntheticPrefixes.some((prefix) => value.toLowerCase().startsWith(prefix))) {
        findings.push(`${display}: possible populated Audible credential field`);
      }
    }
    if (
      text.includes(["-----BEGIN", " PRIVATE KEY-----"].join("")) &&
      display !== "engine/src/auth/signing.zig"
    ) {
      findings.push(`${display}: embedded private key`);
    }
  }
}

await walk(root);
if (findings.length > 0) {
  console.error(`Secret scan failed:\n${findings.map((finding) => `- ${finding}`).join("\n")}`);
  process.exit(1);
}
console.log(
  "Secret scan passed (credentials, private keys, media, databases, and vouchers absent).\n",
);
