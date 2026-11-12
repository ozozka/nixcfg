/**
 * /undo: restores the files to how they were before the latest prompt on this branch and moves
 * the conversation back to that prompt, with its text in the editor, like Claude's /rewind.
 * Repeating it steps further back.
 *
 * Before each prompt, the working tree (tracked and untracked files, minus ignored ones) is
 * saved as a commit through a temporary index, so the user's index, HEAD, and branches stay
 * untouched. Commits are recorded in the session and kept alive by the refs/pi/checkpoint
 * reflog, so git gc expires them after 30 days (gc.reflogExpireUnreachable) with no manual
 * cleanup; older prompts can no longer be undone. Undo restores files only; commits made since
 * stay.
 */

import { copyFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const ENTRY_TYPE = "checkpoint";
const REF = "refs/pi/checkpoint";

interface Checkpoint {
  commit: string;
}

function count(files: number): string {
  return `${files} ${files === 1 ? "file" : "files"}`;
}

export default function (pi: ExtensionAPI) {
  // Runs git in the repository root, optionally with a temporary index.
  async function git(root: string, args: string[], index?: string): Promise<string> {
    const env = [
      "GIT_AUTHOR_NAME=pi",
      "GIT_AUTHOR_EMAIL=pi@localhost",
      "GIT_COMMITTER_NAME=pi",
      "GIT_COMMITTER_EMAIL=pi@localhost",
      ...(index ? [`GIT_INDEX_FILE=${index}`] : []),
    ];
    const result = await pi.exec("env", [...env, "git", ...args], {
      cwd: root,
      timeout: 60_000,
    });
    if (result.code !== 0) throw new Error(`git ${args[0]}: ${result.stderr.trim()}`);
    return result.stdout.trim();
  }

  async function repositoryRoot(cwd: string): Promise<string | undefined> {
    const result = await pi.exec("git", ["rev-parse", "--show-toplevel"], { cwd });
    return result.code === 0 ? result.stdout.trim() : undefined;
  }

  // Runs `use` with a temporary index, seeded from the real one to reuse its file stat cache.
  async function withTempIndex<T>(
    root: string,
    use: (index: string) => Promise<T>,
  ): Promise<T> {
    const directory = await mkdtemp(join(tmpdir(), "pi-undo-"));
    const index = join(directory, "index");
    try {
      const real = resolve(root, await git(root, ["rev-parse", "--git-path", "index"]));
      await copyFile(real, index).catch(() => undefined);
      return await use(index);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }

  // Saves the working tree as a commit and records it in the checkpoint reflog.
  function snapshot(root: string): Promise<string> {
    return withTempIndex(root, async (index) => {
      await git(root, ["add", "--all", "."], index);
      const tree = await git(root, ["write-tree"], index);
      const head = await git(root, ["rev-parse", "--quiet", "--verify", "HEAD"]).catch(
        () => "",
      );
      const parents = head ? ["-p", head] : [];
      const commit = await git(root, ["commit-tree", tree, ...parents, "-m", "pi checkpoint"]);
      await git(root, ["update-ref", "--create-reflog", "-m", "pi checkpoint", REF, commit]);
      return commit;
    });
  }

  pi.on("before_agent_start", async (_event, ctx) => {
    // One-shot runs without a UI, such as subagents, have no prompt to undo.
    if (!ctx.hasUI) return;
    const root = await repositoryRoot(ctx.cwd);
    if (!root) return;
    try {
      pi.appendEntry(ENTRY_TYPE, { commit: await snapshot(root) } satisfies Checkpoint);
    } catch (error) {
      ctx.ui.notify(`Checkpoint failed: ${(error as Error).message}`, "warning");
    }
  });

  // The latest checkpoint on the branch, the entry before it, and the prompt that followed it.
  function latestCheckpoint(ctx: ExtensionContext) {
    const branch = ctx.sessionManager.getBranch();
    for (let i = branch.length - 1; i >= 0; i--) {
      const entry = branch[i];
      if (entry.type !== "custom" || entry.customType !== ENTRY_TYPE) continue;
      // The first prompt of a session follows a system message.
      const prompt = branch
        .slice(i + 1)
        .flatMap((next) => (next.type === "message" ? [next.message] : []))
        .find((message) => message.role === "user");
      const text =
        prompt === undefined
          ? ""
          : typeof prompt.content === "string"
            ? prompt.content
            : prompt.content
                .flatMap((part) => (part.type === "text" ? [part.text] : []))
                .join("");
      return { checkpoint: entry.data as Checkpoint, parentId: entry.parentId, prompt: text };
    }
    return undefined;
  }

  async function undo(ctx: ExtensionCommandContext) {
    await ctx.waitForIdle();
    const root = await repositoryRoot(ctx.cwd);
    const found = latestCheckpoint(ctx);
    if (!(root && found?.parentId)) {
      ctx.ui.notify("Nothing to undo on this branch", "info");
      return;
    }
    const { checkpoint, parentId, prompt } = found;
    const exists = await git(root, ["cat-file", "-e", `${checkpoint.commit}^{commit}`]).then(
      () => true,
      () => false,
    );
    if (!exists) {
      ctx.ui.notify(
        "The checkpoint for this prompt has expired; nothing was changed",
        "warning",
      );
      return;
    }

    // Compare against a snapshot of the current files, which also keeps them recoverable.
    const current = await snapshot(root);
    const changes = (
      await git(root, [
        "diff",
        "--name-status",
        "--no-renames",
        "-z",
        checkpoint.commit,
        current,
      ])
    )
      .split("\0")
      .filter(Boolean);
    const restore: string[] = [];
    const remove: string[] = [];
    for (let i = 0; i + 1 < changes.length; i += 2) {
      (changes[i] === "A" ? remove : restore).push(changes[i + 1]);
    }
    const files = [...restore, ...remove];

    const summary = files.length
      ? `${count(files.length)} will be restored:\n${files.slice(0, 15).join("\n")}${files.length > 15 ? "\n..." : ""}`
      : "No files changed since then.";
    if (ctx.hasUI) {
      const confirmed = await ctx.ui.confirm(
        "Undo the latest prompt?",
        `${prompt ? `Prompt: ${prompt.slice(0, 200)}\n\n` : ""}${summary}\n\nCommits made since stay. Current files are kept as ${current.slice(0, 12)} in the ${REF} reflog.`,
      );
      if (!confirmed) return;
    }

    if (restore.length) {
      await withTempIndex(root, async (index) => {
        await git(root, ["read-tree", checkpoint.commit], index);
        await git(root, ["checkout-index", "--force", "--", ...restore], index);
      });
    }
    await Promise.all(remove.map((file) => rm(join(root, file), { force: true })));

    const result = await ctx.navigateTree(parentId);
    if (!result.cancelled && ctx.hasUI) ctx.ui.setEditorText(prompt);
    ctx.ui.notify(`Undone: ${count(files.length)} restored`, "info");
  }

  pi.registerCommand("undo", {
    description: "Restore files and the conversation to before the latest prompt",
    handler: async (_args, ctx) => {
      try {
        await undo(ctx);
      } catch (error) {
        ctx.ui.notify(`Undo failed: ${(error as Error).message}`, "error");
      }
    },
  });
}
