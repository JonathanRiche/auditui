import { chmod, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { assertOk, RpcHarness } from "./rpc-harness";

const harness = await RpcHarness.start("auditui-yoto-rpc-");
try {
  const accountDirectory = join(harness.sandbox, "config", "yoto");
  await mkdir(accountDirectory, { recursive: true, mode: 0o700 });
  const credentials = join(accountDirectory, "family.json");
  await Bun.write(
    credentials,
    JSON.stringify({
      version: 1,
      client_id: "synthetic-public-client",
      access_token: "synthetic-access-token",
      refresh_token: "synthetic-refresh-token",
      token_type: "Bearer",
      scope: "user:content:view family:library:view offline_access profile",
      expires_at: 4_102_444_800,
    }),
  );
  await chmod(credentials, 0o600);
  await Bun.write(
    join(harness.sandbox, "cache", "library-yoto-family.json"),
    JSON.stringify({
      items: [
        {
          id: "card-1",
          provider: "yoto",
          account: "family",
          title: "Synthetic Bedtime Card",
          authors: ["Fixture Author"],
          durationSeconds: 90,
          downloaded: false,
          streamable: true,
          downloadable: false,
        },
      ],
    }),
  );

  const profiles = assertOk(await harness.request("profile.list"), "Yoto profile list");
  const items = profiles.items as Array<Record<string, unknown>>;
  const account = items.find((item) => item.provider === "yoto");
  if (account?.name !== "yoto:family" || account.account !== "family") {
    throw new Error(`Yoto account was not discovered: ${JSON.stringify(profiles)}`);
  }

  assertOk(
    await harness.request("profile.select", {
      profile: "yoto:family",
      provider: "yoto",
      account: "family",
    }),
    "Yoto profile selection",
  );
  const library = assertOk(
    await harness.request("library.list", { provider: "yoto", account: "family" }),
    "Yoto library list",
  );
  const card = (library.items as Array<Record<string, unknown>>)[0];
  if (card?.id !== "card-1" || card.provider !== "yoto" || card.downloadable !== false) {
    throw new Error(`Yoto library identity/capabilities were lost: ${JSON.stringify(library)}`);
  }
  const search = assertOk(
    await harness.request("library.search", {
      provider: "yoto",
      account: "family",
      query: "bedtime",
    }),
    "Yoto library search",
  );
  if ((search.items as unknown[]).length !== 1)
    throw new Error("Yoto search did not use its cache");

  const download = await harness.request("downloads.start", {
    provider: "yoto",
    account: "family",
    itemId: "card-1",
  });
  if (download.ok !== false || download.error?.code !== "UNSUPPORTED") {
    throw new Error(`Yoto download did not fail safely: ${JSON.stringify(download)}`);
  }

  assertOk(
    await harness.request("profile.remove", { profile: "yoto:family", confirm: true }),
    "Yoto local account removal",
  );
  const afterRemoval = assertOk(
    await harness.request("profile.list"),
    "profile list after removal",
  );
  if (
    (afterRemoval.items as Array<Record<string, unknown>>).some((item) => item.provider === "yoto")
  ) {
    throw new Error("removed Yoto account remained discoverable");
  }

  await harness.close();
  console.log("Yoto RPC identity, cache, selection, search, capability, and removal checks passed");
} finally {
  await harness.cleanup();
}
