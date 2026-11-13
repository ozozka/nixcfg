/**
 * Project documentation as context: README.md and the Markdown files under docs/ (skipping _
 * entries and links) join the context files of every run. The --docs flag is the only switch,
 * so plain `pi` loads nothing and `wpi` passes it. /docs lists the context files of the
 * current run.
 */

import { lstat, readdir, readFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { projectRoot } from "./lib/shared.ts";

const FLAG = "docs";
type ContextFile = { path: string; content: string };

async function loadDocs(cwd: string, ctx: ExtensionContext): Promise<ContextFile[]> {
  const root = projectRoot(cwd);
  const files: ContextFile[] = [];

  async function visit(path: string, recurse: boolean) {
    try {
      const info = await lstat(path);
      // Do not follow links into unrelated projects or outside the docs tree.
      if (info.isSymbolicLink()) return;
      if (info.isDirectory() && recurse) {
        const entries = await readdir(path);
        // Recurse in stable order, pruning underscore-prefixed files and subtrees.
        for (const name of entries.sort()) {
          // biome-ignore lint/performance/noAwaitInLoops: sequential visits keep the file order stable.
          if (!name.startsWith("_")) await visit(join(path, name), true);
        }
      } else if (info.isFile() && (!recurse || path.endsWith(".md"))) {
        files.push({ path, content: await readFile(path, "utf8") });
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      if (ctx.hasUI) {
        ctx.ui.notify(`Could not load documentation ${path}: ${String(error)}`, "warning");
      }
    }
  }

  await visit(join(root, "README.md"), false);
  await visit(join(root, "docs"), true);
  return files;
}

export default function (pi: ExtensionAPI) {
  pi.registerFlag(FLAG, {
    description: "Add README.md and docs/**/*.md to the context",
    type: "boolean",
    default: false,
  });
  // The flag's value is known only after loading, not in this factory.
  const enabled = () => pi.getFlag(FLAG) === true;
  let snapshot: { cwd: string; files: ContextFile[] } | undefined;

  async function getDocs(ctx: ExtensionContext): Promise<ContextFile[]> {
    if (!snapshot || snapshot.cwd !== ctx.cwd) {
      snapshot = { cwd: ctx.cwd, files: await loadDocs(ctx.cwd, ctx) };
    }
    return snapshot.files;
  }

  pi.on("session_start", () => {
    snapshot = undefined;
  });

  pi.registerCommand("docs", {
    description: "List the context files of the current run",
    handler: async (_args, ctx) => {
      const on = enabled();
      const trust = on && !ctx.isProjectTrusted() ? " (waiting for project trust)" : "";
      const paths = new Set(
        (ctx.getSystemPromptOptions().contextFiles ?? []).map((file) =>
          resolve(ctx.cwd, file.path),
        ),
      );
      if (on && ctx.isProjectTrusted()) {
        for (const file of await getDocs(ctx)) paths.add(file.path);
      }
      const files = [...paths].map((path) => {
        const local = relative(ctx.cwd, path);
        return `  ${local.startsWith("..") ? path : local || path}`;
      });
      ctx.ui.notify(
        `Docs ${on ? "on" : "off"} (--${FLAG})${trust}\n${files.join("\n") || "  (none)"}`,
        "info",
      );
    },
  });

  pi.on("before_agent_start", async (event, ctx) => {
    if (!enabled() || !ctx.isProjectTrusted()) return;
    const files = await getDocs(ctx);
    // Each run starts with Pi's base context. Add one stable copy per path,
    // preserving AGENTS.md and context contributed by other extensions.
    const existing = new Set(
      event.systemPromptOptions.contextFiles.map((file) => resolve(ctx.cwd, file.path)),
    );
    for (const file of files) {
      if (existing.has(file.path)) continue;
      event.systemPromptOptions.contextFiles.push({ ...file });
      existing.add(file.path);
    }
  });

  pi.on("session_shutdown", () => {
    snapshot = undefined;
  });
}
