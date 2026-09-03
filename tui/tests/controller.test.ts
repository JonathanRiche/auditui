import { expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import type { KeyEvent } from "@opentui/core";
import { AppController } from "../src/app/controller";
import { initialState, reducer } from "../src/app/state";
import type { Action } from "../src/app/types";
import { EngineSupervisor } from "../src/engine/process";
import type { EngineClient } from "../src/engine/client";
import { RpcRequestError } from "../src/engine/protocol";

const key = (name: string, sequence = name, shift = false) =>
  ({ name, sequence, eventType: "press", ctrl: false, meta: false, shift }) as KeyEvent;

test("keyboard navigation, help, and search are reducer-driven", () => {
  let state = reducer(initialState(), {
    type: "library.loaded",
    items: [
      {
        id: "1",
        title: "Dune",
        authors: [],
        narrators: [],
        durationSeconds: 10,
        positionSeconds: 0,
        downloaded: false,
      },
      {
        id: "2",
        title: "Emma",
        authors: [],
        narrators: [],
        durationSeconds: 10,
        positionSeconds: 0,
        downloaded: false,
      },
    ],
  });
  const dispatch = (action: Action) => {
    state = reducer(state, action);
  };
  const controller = new AppController(
    { getState: () => state, dispatch, quit() {} },
    new EngineSupervisor(),
  );
  controller.handleKey(key("l"));
  expect(state.selectedIndex).toBe(1);
  controller.handleKey(key("?"));
  expect(state.helpVisible).toBe(true);
  controller.handleKey(key("q"));
  expect(state.helpVisible).toBe(false);
  controller.handleKey(key("/"));
  controller.handleKey(key("d"));
  expect(state).toMatchObject({ searchMode: true, query: "d" });
  expect(state.visibleItems.map((item) => item.title)).toEqual(["Dune"]);
});

test("library vim keys move spatially and shifted h/l cycle top-level screens", () => {
  let state = reducer(initialState(120, 30), {
    type: "library.loaded",
    items: Array.from({ length: 8 }, (_, index) => ({
      id: `${index}`,
      title: `Book ${index}`,
      authors: [],
      narrators: [],
      durationSeconds: 10,
      positionSeconds: 0,
      downloaded: false,
    })),
  });
  const dispatch = (action: Action) => {
    state = reducer(state, action);
  };
  const controller = new AppController(
    { getState: () => state, dispatch, quit() {} },
    new EngineSupervisor(),
  );

  controller.handleKey(key("l"));
  expect(state.selectedIndex).toBe(1);
  controller.handleKey(key("j"));
  expect(state.selectedIndex).toBe(4);
  controller.handleKey(key("k"));
  expect(state.selectedIndex).toBe(1);
  controller.handleKey(key("h"));
  expect(state.selectedIndex).toBe(0);

  controller.handleKey(key("l", "L", true));
  expect(state.screen).toBe("wishlist");
  controller.handleKey(key("l", "L", true));
  expect(state.screen).toBe("downloads");
  controller.handleKey(key("l", "L", true));
  expect(state.screen).toBe("now-playing");
  controller.handleKey(key("l", "L", true));
  expect(state.screen).toBe("settings");
  controller.handleKey(key("l", "L", true));
  expect(state).toMatchObject({ screen: "library", searchMode: true });
  controller.handleKey(key("l", "L", true));
  expect(state).toMatchObject({ screen: "library", searchMode: false });
  controller.handleKey(key("h", "H", true));
  expect(state).toMatchObject({ screen: "library", searchMode: true });
});

test("escape and search respect screen context", () => {
  let state = reducer(initialState(), {
    type: "library.loaded",
    items: [
      {
        id: "1",
        title: "Dune",
        authors: [],
        narrators: [],
        durationSeconds: 10,
        positionSeconds: 0,
        downloaded: false,
      },
    ],
  });
  let quitCount = 0;
  const dispatch = (action: Action) => {
    state = reducer(state, action);
  };
  const controller = new AppController(
    {
      getState: () => state,
      dispatch,
      quit() {
        quitCount += 1;
      },
    },
    new EngineSupervisor(),
  );

  controller.handleKey(key("return"));
  expect(state.screen).toBe("detail");
  controller.handleKey(key("escape"));
  expect(state.screen).toBe("library");
  expect(quitCount).toBe(0);

  controller.handleKey(key("2"));
  expect(state.screen).toBe("wishlist");
  controller.handleKey(key("3"));
  expect(state.screen).toBe("downloads");
  controller.handleKey(key("4"));
  expect(state.screen).toBe("now-playing");
  controller.handleKey(key("5"));
  expect(state.screen).toBe("settings");
  controller.handleKey(key("1"));
  expect(state.screen).toBe("library");
  controller.handleKey(key("/"));
  expect(state).toMatchObject({ screen: "library", searchMode: true });
  controller.handleKey(key("escape"));
  expect(state).toMatchObject({ screen: "library", searchMode: false, query: "" });

  controller.handleKey(key("q"));
  expect(quitCount).toBe(1);
});

test("emits only canonical protocol parameters for media actions", async () => {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const client = {
    async request(method: string, params: Record<string, unknown> = {}) {
      calls.push({ method, params });
      if (method === "profile.list") return { items: [] };
      if (method === "library.list") return { items: [] };
      if (method === "downloads.list") return { items: [] };
      if (method === "player.status") return { paused: true };
      return {};
    },
  } as EngineClient;
  const emitter = new EventEmitter();
  const supervisor = {
    on: emitter.on.bind(emitter),
    start: () => emitter.emit("ready", client),
    stop: async () => {},
  } as unknown as EngineSupervisor;
  let state = reducer(initialState(), {
    type: "library.loaded",
    items: [
      {
        id: "1",
        asin: "B001",
        title: "Dune",
        authors: [],
        narrators: [],
        durationSeconds: 10,
        positionSeconds: 0,
        downloaded: false,
        localPath: "/library/Dune.m4b",
      },
    ],
  });
  const controller = new AppController(
    {
      getState: () => state,
      dispatch: (action) => {
        state = reducer(state, action);
      },
      quit() {},
    },
    supervisor,
  );
  controller.start();
  await Bun.sleep(0);
  // Startup replaced the library with the synthetic empty response; restore the selected title.
  state = reducer(state, {
    type: "library.loaded",
    items: [
      {
        id: "1",
        asin: "B001",
        title: "Dune",
        authors: [],
        narrators: [],
        durationSeconds: 10,
        positionSeconds: 0,
        downloaded: false,
        localPath: "/library/Dune.m4b",
      },
    ],
  });
  controller.handleKey(key("d"));
  controller.handleKey(key("return"));
  controller.handleKey(key("return"));
  controller.handleKey(key("h"));
  controller.handleKey(key("]"));
  controller.handleKey(key("."));
  await Bun.sleep(0);

  expect(calls.find((call) => call.method === "downloads.start")?.params).toEqual({ asin: "B001" });
  const commands = calls
    .filter((call) => call.method === "player.command")
    .map((call) => call.params);
  expect(commands).toContainEqual({
    command: "play",
    path: "/library/Dune.m4b",
    itemId: "1",
    title: "Dune",
  });
  expect(commands).toContainEqual({ command: "seek-relative", value: -10 });
  expect(commands).toContainEqual({ command: "chapter-next" });
  expect(commands).toContainEqual({ command: "set-speed", value: 1.05 });
});

test("does not issue play without a canonical local path", () => {
  let state = reducer(initialState(), {
    type: "library.loaded",
    items: [
      {
        id: "1",
        asin: "B001",
        title: "Dune",
        authors: [],
        narrators: [],
        durationSeconds: 10,
        positionSeconds: 0,
        downloaded: false,
      },
    ],
  });
  state = reducer(state, { type: "navigate", screen: "detail" });
  const controller = new AppController(
    {
      getState: () => state,
      dispatch: (action) => {
        state = reducer(state, action);
      },
      quit() {},
    },
    new EngineSupervisor(),
  );
  controller.handleKey(key("return"));
  expect(state.message).toBe("Download this title before playing it");
});

test("r refreshes the selected account using canonical RPC parameters", async () => {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const client = {
    async request(method: string, params: Record<string, unknown> = {}) {
      calls.push({ method, params });
      if (method === "profile.list")
        return { items: [{ name: "Jonathan-zig", securePermissions: true }] };
      if (method === "library.refresh")
        return { profile: "Jonathan-zig", itemCount: 7, tokenRefreshed: false };
      if (method === "library.list") return { items: [] };
      return {};
    },
  } as EngineClient;
  const emitter = new EventEmitter();
  const supervisor = {
    on: emitter.on.bind(emitter),
    start: () => emitter.emit("ready", client),
    stop: async () => {},
  } as unknown as EngineSupervisor;
  let state = initialState();
  const controller = new AppController(
    {
      getState: () => state,
      dispatch: (action) => {
        state = reducer(state, action);
      },
      quit() {},
    },
    supervisor,
  );
  controller.start();
  await Bun.sleep(5);
  const automaticRefreshes = calls.filter((call) => call.method === "library.refresh").length;
  expect(automaticRefreshes).toBe(1);
  controller.handleKey(key("r"));
  await Bun.sleep(5);
  expect(calls.filter((call) => call.method === "library.refresh")).toHaveLength(
    automaticRefreshes + 1,
  );
  expect(calls).toContainEqual({ method: "library.refresh", params: { profile: "Jonathan-zig" } });
  expect(state.message).toBe("Refreshed 7 Audible titles");
});

test("encrypted refresh directs users to hidden terminal prompting", async () => {
  const client = {
    async request(method: string) {
      if (method === "profile.list")
        return { items: [{ name: "Jonathan-zig", securePermissions: true }] };
      if (method === "library.refresh")
        throw new RpcRequestError("PASSWORD_REQUIRED", "safe engine message");
      if (method === "library.list") return { items: [] };
      return {};
    },
  } as EngineClient;
  const emitter = new EventEmitter();
  const supervisor = {
    on: emitter.on.bind(emitter),
    start: () => emitter.emit("ready", client),
    stop: async () => {},
  } as unknown as EngineSupervisor;
  let state = initialState();
  const controller = new AppController(
    {
      getState: () => state,
      dispatch: (action) => {
        state = reducer(state, action);
      },
      quit() {},
    },
    supervisor,
  );
  controller.start();
  await Bun.sleep(0);
  controller.handleKey(key("r"));
  await Bun.sleep(0);
  expect(state.message).toContain("secure interactive unlock");
  expect(state.message).not.toContain("safe engine message");
});

test("encrypted refresh and onboarding use secure controlling-terminal handoffs", async () => {
  const calls: string[] = [];
  let unlocks = 0;
  let connects = 0;
  const client = {
    async request(method: string) {
      calls.push(method);
      if (method === "profile.list")
        return { items: [{ name: "locked", securePermissions: true }] };
      if (method === "library.refresh")
        throw new RpcRequestError("PASSWORD_REQUIRED", "must not be displayed");
      if (method === "library.list") return { items: [] };
      if (method === "downloads.list") return { jobs: [] };
      if (method === "player.status") return {};
      return {};
    },
  } as EngineClient;
  const emitter = new EventEmitter();
  const supervisor = {
    on: emitter.on.bind(emitter),
    start: () => emitter.emit("ready", client),
    stop: async () => {},
  } as unknown as EngineSupervisor;
  let state = initialState();
  const controller = new AppController(
    {
      getState: () => state,
      dispatch: (action) => {
        state = reducer(state, action);
      },
      async runInteractiveRefresh(profile) {
        expect(profile).toBe("locked");
        unlocks += 1;
        return true;
      },
      async runInteractiveConnect() {
        connects += 1;
        return true;
      },
      quit() {},
    },
    supervisor,
  );
  controller.start();
  await Bun.sleep(0);
  controller.handleKey(key("r"));
  await Bun.sleep(5);
  expect(unlocks).toBe(1);
  expect(state.message).toBe("Audible library refreshed");
  expect(state.message).not.toContain("must not be displayed");

  state = reducer(state, { type: "profile.loaded", name: null, secure: true });
  controller.beginOnboarding();
  await Bun.sleep(5);
  expect(connects).toBe(1);
  expect(calls).not.toContain("auth.complete");
  expect(state.authInputMode).toBe(false);
});

test("selecting a settings profile persists it through the engine", async () => {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const client = {
    async request(method: string, params: Record<string, unknown> = {}) {
      calls.push({ method, params });
      if (method === "profile.select") return { profile: "second", selected: true };
      if (method === "library.refresh") return { profile: "second", itemCount: 0 };
      if (method === "library.list") return { items: [] };
      if (method === "downloads.list") return { jobs: [] };
      if (method === "player.status") return {};
      return {};
    },
  } as EngineClient;
  const emitter = new EventEmitter();
  const supervisor = {
    on: emitter.on.bind(emitter),
    start: () => emitter.emit("ready", client),
    stop: async () => {},
  } as unknown as EngineSupervisor;
  let state = initialState();
  state = reducer(state, {
    type: "profiles.loaded",
    profiles: [
      { name: "first", secure: true },
      { name: "second", secure: true },
    ],
  });
  state = reducer(state, { type: "navigate", screen: "settings" });
  state = reducer(state, { type: "move", amount: 1 });
  const controller = new AppController(
    {
      getState: () => state,
      dispatch: (action) => {
        state = reducer(state, action);
      },
      quit() {},
    },
    supervisor,
  );
  controller.start();
  await Bun.sleep(0);
  // Initialization may replace the profile list, so restore the selection
  // before activating the Settings row.
  state = reducer(state, {
    type: "profiles.loaded",
    profiles: [
      { name: "first", secure: true },
      { name: "second", secure: true },
    ],
  });
  state = reducer(state, { type: "navigate", screen: "settings" });
  state = reducer(state, { type: "move", amount: 1 });
  controller.handleKey(key("return"));
  await Bun.sleep(5);
  expect(calls).toContainEqual({ method: "profile.select", params: { profile: "second" } });
  expect(state.profileName).toBe("second");
});

test("command palette and product actions emit canonical wishlist, retry, and player commands", async () => {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const client = {
    async request(method: string, params: Record<string, unknown> = {}) {
      calls.push({ method, params });
      if (method === "profile.list") return { items: [{ name: "test", securePermissions: true }] };
      if (method === "library.list") return { items: [] };
      if (method === "wishlist.list") return { items: [] };
      if (method === "downloads.list") return { jobs: [] };
      if (method === "player.status") return {};
      return {};
    },
  } as EngineClient;
  const emitter = new EventEmitter();
  const supervisor = {
    on: emitter.on.bind(emitter),
    start: () => emitter.emit("ready", client),
    stop: async () => {},
  } as unknown as EngineSupervisor;
  let state = initialState();
  const controller = new AppController(
    {
      getState: () => state,
      dispatch: (action) => {
        state = reducer(state, action);
      },
      quit() {},
    },
    supervisor,
  );
  controller.start();
  await Bun.sleep(0);

  controller.handleKey({ ...key("p"), ctrl: true } as KeyEvent);
  expect(state.commandPaletteVisible).toBe(true);
  controller.handleKey(key("down"));
  controller.handleKey(key("return"));
  expect(state.screen).toBe("wishlist");

  state = reducer(state, {
    type: "wishlist.loaded",
    items: [
      {
        id: "B012345678",
        asin: "B012345678",
        title: "Dune",
        authors: [],
        narrators: [],
        durationSeconds: 0,
        positionSeconds: 0,
        downloaded: false,
      },
    ],
  });
  controller.handleKey(key("x"));
  expect(state.confirmation?.kind).toBe("wishlist.remove");
  controller.handleKey(key("y"));
  await Bun.sleep(0);
  expect(calls).toContainEqual({
    method: "wishlist.remove",
    params: { asin: "B012345678", profile: "test" },
  });

  state = reducer(state, { type: "navigate", screen: "wishlist" });
  controller.handleKey(key("a"));
  controller.handleKey(key("text", "B012345678"));
  controller.handleKey(key("return"));
  controller.handleKey(key("return"));
  await Bun.sleep(0);
  expect(calls).toContainEqual({
    method: "wishlist.add",
    params: { asin: "B012345678", profile: "test" },
  });

  state = reducer(state, {
    type: "library.loaded",
    items: [
      {
        id: "B012345678",
        asin: "B012345678",
        title: "Dune",
        authors: [],
        narrators: [],
        durationSeconds: 100,
        positionSeconds: 0,
        downloaded: false,
      },
    ],
  });
  state = reducer(state, {
    type: "download.list",
    jobs: [
      { jobId: "j", itemId: "B012345678", title: "Dune", state: "failed", received: 5, total: 100 },
    ],
  });
  state = reducer(state, { type: "navigate", screen: "downloads" });
  controller.handleKey(key("r"));
  await Bun.sleep(0);
  expect(calls).toContainEqual({
    method: "downloads.start",
    params: { asin: "B012345678", profile: "test" },
  });

  state = reducer(state, {
    type: "player.status",
    player: {
      itemId: "B012345678",
      title: "Dune",
      positionSeconds: 42,
      durationSeconds: 100,
      bookmarks: [{ id: "7", positionSeconds: 20, label: "Start" }],
    },
  });
  state = reducer(state, { type: "navigate", screen: "now-playing" });
  controller.handleKey(key("b"));
  controller.handleKey(key("+"));
  controller.handleKey(key("s"));
  controller.handleKey(key("x"));
  controller.selectChapter(2);
  await Bun.sleep(0);
  const playerCalls = calls
    .filter((call) => call.method === "player.command")
    .map((call) => call.params);
  expect(playerCalls).toContainEqual({ command: "bookmark-add", label: "Bookmark at 42s" });
  expect(playerCalls).toContainEqual({ command: "set-volume", value: 100 });
  expect(playerCalls).toContainEqual({ command: "set-sleep-timer", value: 900 });
  expect(playerCalls).toContainEqual({ command: "bookmark-delete", bookmarkId: 7 });
  expect(playerCalls).toContainEqual({ command: "chapter-set", value: 2 });
});

test("profile selection persists and safe local removal requires confirmation", async () => {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const client = {
    async request(method: string, params: Record<string, unknown> = {}) {
      calls.push({ method, params });
      if (method === "profile.list")
        return {
          items: [
            { name: "first", securePermissions: true },
            { name: "second", securePermissions: true },
          ],
          selectedProfile: "first",
        };
      if (method === "library.list") return { items: [] };
      if (method === "downloads.list") return { jobs: [] };
      if (method === "player.status") return {};
      return {};
    },
  } as EngineClient;
  const emitter = new EventEmitter();
  const supervisor = {
    on: emitter.on.bind(emitter),
    start: () => emitter.emit("ready", client),
    stop: async () => {},
  } as unknown as EngineSupervisor;
  let state = initialState();
  const controller = new AppController(
    {
      getState: () => state,
      dispatch: (action) => {
        state = reducer(state, action);
      },
      quit() {},
    },
    supervisor,
  );
  controller.start();
  await Bun.sleep(0);
  controller.navigateTo("settings");
  controller.selectProfile("second");
  await Bun.sleep(0);
  expect(calls).toContainEqual({ method: "profile.select", params: { profile: "second" } });
  expect(state.profileName).toBe("second");

  controller.requestProfileRemoval();
  expect(state.confirmation).toEqual({
    kind: "profile.remove",
    profile: "second",
    title: "second",
  });
  controller.handleKey(key("y"));
  await Bun.sleep(0);
  expect(calls).toContainEqual({
    method: "profile.remove",
    params: { profile: "second", confirm: true },
  });
  expect(state.message).toContain("Audible account was not changed");
});

test("streams Yoto items without routing them through Audible downloads", async () => {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const client = {
    async request(method: string, params: Record<string, unknown> = {}) {
      calls.push({ method, params });
      if (method === "profile.list") return { items: [] };
      if (method === "library.list") return { items: [] };
      if (method === "downloads.list") return { jobs: [] };
      if (method === "player.status") return {};
      return {};
    },
  } as EngineClient;
  const emitter = new EventEmitter();
  const supervisor = {
    on: emitter.on.bind(emitter),
    start: () => emitter.emit("ready", client),
    stop: async () => {},
  } as unknown as EngineSupervisor;
  let state = initialState();
  let connectedProvider = "";
  const controller = new AppController(
    {
      getState: () => state,
      dispatch: (action) => {
        state = reducer(state, action);
      },
      async runInteractiveConnect(provider) {
        connectedProvider = provider;
        return false;
      },
      quit() {},
    },
    supervisor,
  );
  controller.start();
  await Bun.sleep(0);
  state = reducer(state, {
    type: "library.loaded",
    items: [
      {
        id: "yoto-1",
        title: "Bedtime Story",
        authors: [],
        narrators: [],
        durationSeconds: 600,
        positionSeconds: 0,
        downloaded: false,
        provider: "yoto",
        account: "kids-room",
        streamable: true,
        downloadable: false,
      },
    ],
  });
  controller.activateItem("yoto-1");
  await Bun.sleep(0);
  expect(calls).toContainEqual({
    method: "player.command",
    params: {
      command: "play",
      itemId: "yoto-1",
      title: "Bedtime Story",
      provider: "yoto",
      account: "kids-room",
    },
  });
  expect(calls.some((call) => call.method === "downloads.start")).toBe(false);

  controller.handleKey(key("d"));
  expect(state.message).toContain("stream-only");
  controller.beginProviderOnboarding("yoto");
  await Bun.sleep(0);
  expect(connectedProvider).toBe("yoto");
});
