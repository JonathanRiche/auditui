import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";

type Invocation = {
  exitCode: number;
  stdout: string;
  stderr: string;
};

const engine = resolve(process.env.AUDIBLE_ENGINE ?? "engine/zig-out/bin/audible-zig");
const sandboxes: string[] = [];

async function sandbox(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "audible-cli-compat-"));
  sandboxes.push(root);
  for (const directory of ["home", "config", "data", "state", "cache", "cwd"]) {
    await mkdir(join(root, directory), { recursive: true, mode: 0o700 });
  }
  return root;
}

function environment(root: string): Record<string, string> {
  const env: Record<string, string> = {
    HOME: join(root, "home"),
    AUDIBLE_CONFIG_DIR: join(root, "config"),
    AUDIBLE_DATA_DIR: join(root, "data"),
    AUDIBLE_STATE_DIR: join(root, "state"),
    AUDIBLE_CACHE_DIR: join(root, "cache"),
  };
  for (const name of ["PATH", "LANG", "LC_ALL", "TZ"]) {
    const value = process.env[name];
    if (value !== undefined) env[name] = value;
  }
  return env;
}

async function invoke(root: string, args: string[]): Promise<Invocation> {
  const child = Bun.spawn([engine, ...args], {
    cwd: join(root, "cwd"),
    env: environment(root),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { exitCode, stdout, stderr };
}

async function invokeWithTerminal(
  root: string,
  args: string[],
  responses: Array<{ prompt: string; value: string }>,
): Promise<Invocation> {
  // util-linux `script` supplies a controlling PTY, matching the secure user
  // flow without teaching the application to accept secrets from pipes/argv.
  const quote = (value: string) => `'${value.replaceAll("'", `'\\''`)}'`;
  const command = [engine, ...args].map(quote).join(" ");
  const child = Bun.spawn(["script", "--quiet", "--return", "--command", command, "/dev/null"], {
    cwd: join(root, "cwd"),
    env: environment(root),
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  const reader = child.stdout.getReader();
  const decoder = new TextDecoder();
  let stdout = "";
  let responseIndex = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    stdout += decoder.decode(value, { stream: true });
    while (responseIndex < responses.length && stdout.includes(responses[responseIndex]!.prompt)) {
      child.stdin.write(`${responses[responseIndex]!.value}\n`);
      responseIndex += 1;
    }
  }
  child.stdin.end();
  const [exitCode, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
  expect(responseIndex, `not all PTY prompts were observed: ${stdout}`).toBe(responses.length);
  return { exitCode, stdout, stderr };
}

async function expectSuccess(root: string, args: string[]): Promise<Invocation> {
  const result = await invoke(root, args);
  expect(result.exitCode, `${args.join(" ")}\n${result.stderr}`).toBe(0);
  expect(result.stderr).toBe("");
  return result;
}

async function expectFailure(root: string, args: string[], errorName: string): Promise<Invocation> {
  const result = await invoke(root, args);
  expect(result.exitCode, `${args.join(" ")} unexpectedly succeeded`).not.toBe(0);
  expect(result.stderr).toContain(errorName);
  return result;
}

async function writeProfile(
  root: string,
  name: string,
  body: object,
  native = true,
): Promise<string> {
  const directory = native ? join(root, "config", "profiles") : join(root, "home", ".audible");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, `${name}.json`);
  await writeFile(path, `${JSON.stringify(body)}\n`, { mode: 0o600 });
  await chmod(path, 0o600);
  return path;
}

async function writeLibrary(root: string): Promise<void> {
  await writeFile(
    join(root, "cache", "library.json"),
    JSON.stringify({
      items: [
        {
          id: "old",
          asin: "B000OLD001",
          title: "A title, with a comma",
          authors: ['Ada "Quoted" North'],
          narrators: ["Morgan Vale"],
          durationSeconds: 100,
          positionSeconds: 25,
          releaseDate: "2024-01-02",
          coverUrl: "https://example.invalid/old.jpg",
        },
        {
          id: "middle",
          asin: "B000MID001",
          title: "Middle Book",
          authors: ["Bea Writer"],
          narrators: [],
          durationSeconds: 200,
          positionSeconds: 100,
          releaseDate: "2025-06-15",
        },
        {
          id: "new",
          asin: "B000NEW001",
          title: "Newest Book",
          authors: [],
          narrators: ["New Narrator"],
          durationSeconds: 0,
          positionSeconds: 0,
          releaseDate: "2026-09-03",
        },
      ],
    }),
    { mode: 0o600 },
  );
}

afterEach(async () => {
  await Promise.all(sandboxes.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

describe("human CLI root contract", () => {
  test("help, no-argument help, and version are stable and secret-free", async () => {
    const root = await sandbox();
    const plain = await expectSuccess(root, []);
    const explicit = await expectSuccess(root, ["--help"]);
    const version = await expectSuccess(root, ["--version"]);
    expect(plain.stdout).toContain("Usage: audible [OPTIONS] COMMAND [ARGS]...");
    expect(explicit.stdout).toBe(plain.stdout);
    expect(explicit.stdout).toContain("wishlist list|export|add|remove");
    expect(version.stdout).toMatch(/^audible-zig \d+\.\d+\.\d+\n$/);
    expect(`${plain.stdout}${version.stdout}`).not.toMatch(/adp_token|refresh_token|private_key/i);
  });

  test("a global profile works before or after the command", async () => {
    const root = await sandbox();
    await writeProfile(root, "fixture", { adp_token: "synthetic", activation_bytes: "1a2b3c4d" });
    const before = await expectSuccess(root, ["--profile", "fixture", "activation-bytes"]);
    const after = await expectSuccess(root, ["activation-bytes", "--profile", "fixture"]);
    expect(before.stdout).toBe("1a2b3c4d\n");
    expect(after.stdout).toBe(before.stdout);
  });

  test("global options reject missing values regardless of placement", async () => {
    const root = await sandbox();
    await expectFailure(root, ["--profile"], "MissingOptionValue");
    await expectFailure(root, ["activation-bytes", "--profile"], "MissingOptionValue");
  });

  test("passwords are forbidden on argv", async () => {
    const root = await sandbox();
    const result = await invoke(root, ["--password", "never-print-this", "library", "list"]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("passwords are never accepted in argv");
    expect(result.stderr).not.toContain("never-print-this");
  });
});

describe("documented native CLI deviations", () => {
  test("nested group help is intentionally consolidated into root help", async () => {
    const root = await sandbox();
    for (const group of [["library"], ["wishlist"], ["manage"], ["manage", "auth-file"]]) {
      const result = await expectSuccess(root, [...group, "--help"]);
      expect(result.stdout).toContain("Usage: audible [OPTIONS] COMMAND [ARGS]...");
    }
  });
});

describe("isolated library list and exports", () => {
  test("list reads only the isolated cache and applies inclusive date filters", async () => {
    const root = await sandbox();
    await writeLibrary(root);
    const all = await expectSuccess(root, ["library", "list"]);
    expect(all.stdout).toContain("B000OLD001: A title, with a comma");
    expect(all.stdout).toContain("B000NEW001: Newest Book");
    const bounded = await expectSuccess(root, [
      "library",
      "list",
      "--start-date",
      "2025-01-01",
      "--end-date",
      "2025-12-31",
    ]);
    expect(bounded.stdout).toBe("B000MID001: Middle Book\n");
  });

  test("CSV and TSV exports quote fields, preserve columns, filter dates, and replace {format}", async () => {
    const root = await sandbox();
    await writeLibrary(root);
    const csv = await expectSuccess(root, [
      "library",
      "export",
      "--format",
      "csv",
      "--output",
      "owned.{format}",
    ]);
    expect(csv.stdout).toBe("Exported owned.csv\n");
    const csvBody = await readFile(join(root, "cwd", "owned.csv"), "utf8");
    expect(csvBody).toContain('B000OLD001,"A title, with a comma","Ada ""Quoted"" North"');
    expect(csvBody).toContain(",100,25.00,2024-01-02,");

    const tsv = await expectSuccess(root, [
      "library",
      "export",
      "--format",
      "tsv",
      "--output",
      "recent.{format}",
      "--start-date",
      "2025-01-01",
      "--end-date",
      "2025-12-31",
    ]);
    expect(tsv.stdout).toBe("Exported recent.tsv\n");
    const tsvBody = await readFile(join(root, "cwd", "recent.tsv"), "utf8");
    expect(tsvBody).toContain("B000MID001\tMiddle Book");
    expect(tsvBody).not.toContain("B000OLD001");
    expect(tsvBody).not.toContain("B000NEW001");
  });

  test("JSON export is parseable, filtered, and uses the requested extension", async () => {
    const root = await sandbox();
    await writeLibrary(root);
    await expectSuccess(root, [
      "library",
      "export",
      "-f",
      "json",
      "-o",
      "snapshot.{format}",
      "--start-date",
      "2025-01-01",
      "--end-date",
      "2025-12-31",
    ]);
    const items = JSON.parse(await readFile(join(root, "cwd", "snapshot.json"), "utf8"));
    expect(items).toHaveLength(1);
    expect(items[0].asin).toBe("B000MID001");
  });

  test("missing caches are harmless and invalid formats fail before writing", async () => {
    const root = await sandbox();
    const list = await expectSuccess(root, ["library", "list"]);
    expect(list.stdout).toBe("");
    const exported = await expectSuccess(root, [
      "library",
      "export",
      "-f",
      "json",
      "-o",
      "empty.{format}",
    ]);
    expect(exported.stdout).toBe("[]\n");
    await writeLibrary(root);
    await expectFailure(root, ["library", "export", "--format", "xml"], "InvalidOutputFormat");
  });

  test("date filters reject malformed and reversed ranges", async () => {
    const root = await sandbox();
    await writeLibrary(root);
    await expectFailure(root, ["library", "list", "--start-date", "September-3"], "InvalidDate");
    await expectFailure(
      root,
      ["library", "list", "--start-date", "2026-01-01", "--end-date", "2025-01-01"],
      "InvalidDateRange",
    );
  });
});

describe("profile discovery, import, and local removal safety", () => {
  test("native profiles shadow legacy profiles and unsafe files are labeled", async () => {
    const root = await sandbox();
    await writeProfile(root, "same", { activation_bytes: "12345678" }, false);
    await writeProfile(root, "same", { activation_bytes: "87654321" }, true);
    const unsafe = await writeProfile(root, "unsafe", { activation_bytes: "11111111" });
    await chmod(unsafe, 0o644);
    const result = await expectSuccess(root, ["manage", "profile", "list"]);
    expect(result.stdout.match(/^same\t/gm)).toHaveLength(1);
    expect(result.stdout).toContain("same\tsecure");
    expect(result.stdout).toContain("unsafe\tunsafe-permissions");
  });

  test("import requires a private source, never overwrites, and installs mode 0600", async () => {
    const root = await sandbox();
    const source = join(root, "cwd", "source.json");
    await writeFile(source, '{"activation_bytes":"12345678"}\n', { mode: 0o600 });
    await chmod(source, 0o600);
    const imported = await expectSuccess(root, ["manage", "profile", "import", source, "imported"]);
    expect(imported.stdout).toBe("Imported profile imported\n");
    const destination = join(root, "config", "profiles", "imported.json");
    expect((await stat(destination)).mode & 0o777).toBe(0o600);
    await expectFailure(
      root,
      ["manage", "profile", "import", source, "imported"],
      "PathAlreadyExists",
    );

    const publicSource = join(root, "cwd", "public.json");
    await writeFile(publicSource, "{}\n", { mode: 0o644 });
    await chmod(publicSource, 0o644);
    const rejected = await invoke(root, ["manage", "profile", "import", publicSource, "rejected"]);
    expect(rejected.exitCode).not.toBe(0);
    expect(rejected.stderr).toContain("credential file permissions are unsafe");
  });

  test("remove requires confirmation and cannot traverse outside the profile directory", async () => {
    const root = await sandbox();
    const profile = await writeProfile(root, "disposable", { activation_bytes: "12345678" });
    const denied = await invoke(root, ["manage", "profile", "remove", "--profile", "disposable"]);
    expect(denied.exitCode).not.toBe(0);
    expect(denied.stderr).toContain("confirmation required");
    expect(await readFile(profile, "utf8")).toContain("activation_bytes");
    const removed = await expectSuccess(root, [
      "manage",
      "profile",
      "remove",
      "--profile",
      "disposable",
      "--yes",
    ]);
    expect(removed.stdout).toContain("Audible device registration was not changed");
    await expect(Bun.file(profile).exists()).resolves.toBe(false);

    const outside = join(root, "config", "escape.json");
    await writeFile(outside, "must survive\n", { mode: 0o600 });
    await expectFailure(
      root,
      ["manage", "profile", "remove", "--profile", "../escape", "--yes"],
      "InvalidProfileName",
    );
    expect(await readFile(outside, "utf8")).toBe("must survive\n");
  });
});

describe("network commands validate locally before transport", () => {
  test("generic API rejects insecure endpoints, methods, bodies, and query injection", async () => {
    const root = await sandbox();
    await writeProfile(root, "fixture", { adp_token: "synthetic", activation_bytes: "12345678" });
    await expectFailure(
      root,
      ["api", "http://api.audible.ca/library", "-P", "fixture"],
      "InsecureTransport",
    );
    await expectFailure(
      root,
      ["api", "library", "-P", "fixture", "--method", "PATCH"],
      "InvalidHttpMethod",
    );
    await expectFailure(
      root,
      ["api", "library", "-P", "fixture", "--body", "not-json"],
      "InvalidJsonBody",
    );
    await expectFailure(
      root,
      ["api", "library", "-P", "fixture", "--param", "missing-equals"],
      "InvalidQueryParameter",
    );
  });

  test("wishlist mutations require an ASIN and explicit confirmation before network", async () => {
    const root = await sandbox();
    await writeProfile(root, "fixture", { adp_token: "synthetic", activation_bytes: "12345678" });
    const missing = await invoke(root, ["wishlist", "add", "-P", "fixture"]);
    expect(missing.exitCode).not.toBe(0);
    expect(missing.stderr).toContain("at least one --asin is required");
    const denied = await invoke(root, ["wishlist", "add", "-P", "fixture", "--asin", "B012345678"]);
    expect(denied.exitCode).not.toBe(0);
    expect(denied.stderr).toContain("confirmation required");
    await expectFailure(
      root,
      ["wishlist", "remove", "-P", "fixture", "--asin", "bad/asin", "--yes"],
      "InvalidAsin",
    );
  });
});

describe("human download selection", () => {
  test("selection is mandatory and legacy AAX fails closed without an explicit fallback", async () => {
    const root = await sandbox();
    await writeLibrary(root);
    await expectFailure(root, ["download"], "DownloadSelectionRequired");
    await expectFailure(
      root,
      ["download", "--asin", "B000OLD001", "--aax"],
      "LegacyAaxUnavailable",
    );
    await expectFailure(root, ["download", "--title", "not in this library"], "NoMatchingTitles");
  });
});

describe("auth-file transformation", () => {
  test("local removal is explicit and never claims remote deregistration", async () => {
    const root = await sandbox();
    const authFile = join(root, "cwd", "remove-me.json");
    await writeFile(authFile, '{"adp_token":"synthetic"}\n', { mode: 0o600 });
    await chmod(authFile, 0o600);

    await expectFailure(
      root,
      ["manage", "auth-file", "remove", "--auth-file", authFile],
      "confirmation required",
    );
    expect(await Bun.file(authFile).exists()).toBe(true);

    const removed = await expectSuccess(root, [
      "manage",
      "auth-file",
      "remove",
      "--auth-file",
      authFile,
      "--yes",
    ]);
    expect(removed.stdout).toContain("Audible device registration was not changed");
    expect(await Bun.file(authFile).exists()).toBe(false);
  });

  test("redirected passwords are rejected instead of being accepted from a pipe", async () => {
    const root = await sandbox();
    const authFile = join(root, "cwd", "auth.json");
    await writeFile(authFile, '{"adp_token":"synthetic"}\n', { mode: 0o600 });
    await chmod(authFile, 0o600);
    await expectFailure(
      root,
      ["manage", "auth-file", "encrypt", "--auth-file", authFile],
      "PasswordTerminalUnavailable",
    );
    expect(JSON.parse(await readFile(authFile, "utf8")).adp_token).toBe("synthetic");
  });

  test("encrypt/decrypt round-trips through hidden controlling-terminal prompts", async () => {
    const root = await sandbox();
    const authFile = join(root, "cwd", "roundtrip.json");
    const plaintext = '{"adp_token":"synthetic-adp","device_private_key":"synthetic-key"}\n';
    await writeFile(authFile, plaintext, { mode: 0o600 });
    await chmod(authFile, 0o600);

    const encrypted = await invokeWithTerminal(
      root,
      ["manage", "auth-file", "encrypt", "--auth-file", authFile],
      [
        { prompt: "New auth-file passphrase:", value: "fixture-password" },
        { prompt: "Confirm auth-file passphrase:", value: "fixture-password" },
      ],
    );
    expect(encrypted.exitCode, encrypted.stderr).toBe(0);
    expect(encrypted.stdout).toContain("Auth file encrypted.");
    expect(encrypted.stdout).not.toContain("fixture-password");
    expect(JSON.parse(await readFile(authFile, "utf8"))).toHaveProperty("ciphertext");
    expect((await stat(authFile)).mode & 0o777).toBe(0o600);

    const decrypted = await invokeWithTerminal(
      root,
      ["manage", "auth-file", "decrypt", "--auth-file", authFile],
      [{ prompt: "Auth-file passphrase:", value: "fixture-password" }],
    );
    expect(decrypted.exitCode, decrypted.stderr).toBe(0);
    expect(decrypted.stdout).toContain("Auth file decrypted with owner-only permissions.");
    expect(decrypted.stdout).not.toContain("fixture-password");
    expect(await readFile(authFile, "utf8")).toBe(plaintext);
    expect((await stat(authFile)).mode & 0o777).toBe(0o600);
  });
});
