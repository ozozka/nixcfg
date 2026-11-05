import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import test, { type TestContext } from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import docsExtension from "./extensions/docs.ts";

type ContextFile = { path: string; content: string };
type Notice = { message: string; level?: "info" | "warning" | "error" };
type MockContext = {
  cwd: string;
  hasUI: boolean;
  isProjectTrusted: () => boolean;
  isIdle: () => boolean;
  sessionManager: { getBranch: () => never[] };
  getSystemPromptOptions: () => { contextFiles: ContextFile[] };
  ui: { notify: (message: string, level?: Notice["level"]) => void };
};
type MockEvent = { systemPromptOptions?: { contextFiles: ContextFile[] } };
type Handler = (event: MockEvent, ctx: MockContext) => void | Promise<void>;
type Command = {
  description: string;
  handler: (args: string, ctx: MockContext) => Promise<void>;
};

// Node strips these types to run the tests; it does not type-check them.
function harness(cwd: string, trusted = true) {
  const handlers = new Map<string, Handler>();
  const commands = new Map<string, Command>();
  const warnings: Notice[] = [];
  // Only implement the API/context surface used by this extension. Keep the
  // assertion at this mock boundary rather than fabricating the entire Pi API.
  docsExtension({
    on: (name: string, handler: Handler) => handlers.set(name, handler),
    registerCommand: (name: string, command: Command) => commands.set(name, command),
    appendEntry: () => {},
  } as unknown as ExtensionAPI);
  const ctx: MockContext = {
    cwd,
    hasUI: true,
    isProjectTrusted: () => trusted,
    isIdle: () => true,
    sessionManager: { getBranch: () => [] },
    getSystemPromptOptions: () => ({ contextFiles: [] }),
    ui: { notify: (message, level) => warnings.push({ message, level }) },
  };
  function handler(name: string): Handler {
    const callback = handlers.get(name);
    assert.ok(callback, `Missing handler: ${name}`);
    return callback;
  }
  handler("session_start")({}, ctx);
  return {
    commands,
    ctx,
    warnings,
    async inject(existing: ContextFile[] = []): Promise<ContextFile[]> {
      const event = { systemPromptOptions: { contextFiles: [...existing] } };
      await handler("before_agent_start")(event, ctx);
      return event.systemPromptOptions.contextFiles;
    },
  };
}

async function fixture(t: TestContext) {
  const root = await mkdtemp(join(tmpdir(), "pi-docs-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  return {
    root,
    async file(name: string, content = name): Promise<void> {
      const path = join(root, name);
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, content);
    },
  };
}

test("recursive Markdown discovery prunes underscore entries and skips links", async (t) => {
  const { root, file } = await fixture(t);
  for (const name of [
    "README.md",
    "justfile",
    "docs/z.md",
    "docs/a space.md",
    "docs/nested/deep/guide.md",
    "docs/nested/ignored.txt",
    "docs/_hidden.md",
    "docs/_private/visible.md",
    "docs/_archive.md/visible.md",
    "docs/nested/_drafts/visible.md",
    "docs/nested/_hidden.md",
  ]) {
    await file(name);
  }
  await symlink(join(root, "docs"), join(root, "docs/nested/cycle"));
  await symlink(join(root, "docs/_hidden.md"), join(root, "docs/linked.md"));
  await symlink(join(root, "docs/_private"), join(root, "docs/linked-dir"));
  const files = await harness(root).inject();
  const expected = ["README.md", "docs/a space.md", "docs/nested/deep/guide.md", "docs/z.md"];
  assert.deepEqual(
    files.map((entry) => relative(root, entry.path)),
    expected,
  );
  assert.deepEqual(
    files.map((entry) => entry.content),
    expected,
  );
});

test("missing files and symlinked README/docs roots are skipped", async (t) => {
  const { root, file } = await fixture(t);
  assert.deepEqual(await harness(root).inject(), []);
  await file("outside/secret.md");
  await symlink(join(root, "outside/secret.md"), join(root, "README.md"));
  await symlink(join(root, "outside"), join(root, "docs"));
  assert.deepEqual(await harness(root).inject(), []);
});

test("untrusted projects do not inject documentation", async (t) => {
  const { root, file } = await fixture(t);
  await file("README.md");
  assert.deepEqual(await harness(root, false).inject(), []);
});

test("existing context is preserved without duplicate documentation", async (t) => {
  const { root, file } = await fixture(t);
  await file("README.md");
  await file("docs/nested/guide.md");
  const existing = [
    { path: join(root, "AGENTS.md"), content: "native instructions" },
    { path: join(root, "README.md"), content: "already loaded" },
  ];
  const files = await harness(root).inject(existing);
  assert.equal(files.length, 3);
  assert.deepEqual(files.slice(0, 2), existing);
  assert.equal(files[2].path, join(root, "docs/nested/guide.md"));
});

test("Pi keeps Git-root selection when launched in a subdirectory", async (t) => {
  const { root, file } = await fixture(t);
  await file(".git", "gitdir: /not/executed");
  await file("README.md");
  await mkdir(join(root, "src"));
  const files = await harness(join(root, "src")).inject();
  assert.deepEqual(
    files.map((entry) => entry.path),
    [join(root, "README.md")],
  );
});

test("docs command still disables injection and no longer advertises justfile", async (t) => {
  const { root, file } = await fixture(t);
  await file("README.md");
  const runtime = harness(root);
  const command = runtime.commands.get("docs");
  assert.ok(command);
  assert.ok(!command.description.includes("justfile"));
  await command.handler("off", runtime.ctx);
  assert.deepEqual(await runtime.inject(), []);
  await command.handler("on", runtime.ctx);
  assert.equal((await runtime.inject()).length, 1);
});
