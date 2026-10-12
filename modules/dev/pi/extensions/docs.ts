import { existsSync } from "node:fs";
import { lstat, readdir, readFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const ENTRY_TYPE = "project-docs-setting";
type ContextFile = { path: string; content: string };

function projectRoot(cwd: string): string {
  const start = resolve(cwd);
  for (let directory = start; ; directory = dirname(directory)) {
    // Supports both repositories and worktrees (.git can be a file).
    if (existsSync(join(directory, ".git"))) return directory;
    if (dirname(directory) === directory) return start;
  }
}

function restoreSetting(ctx: ExtensionContext): boolean {
  let enabled = true;
  for (const entry of ctx.sessionManager.getBranch()) {
    if (
      entry.type === "custom" &&
      entry.customType === ENTRY_TYPE &&
      typeof entry.data === "object" &&
      entry.data !== null &&
      "enabled" in entry.data &&
      typeof entry.data.enabled === "boolean"
    )
      enabled = entry.data.enabled;
  }
  return enabled;
}

async function loadDocs(
  cwd: string,
  ctx: ExtensionContext,
): Promise<ContextFile[]> {
  const root = projectRoot(cwd);
  const files: ContextFile[] = [];

  async function visit(path: string, recurse: boolean) {
    try {
      const info = await lstat(path);
      // Do not follow links into unrelated projects or outside the docs tree.
      if (info.isSymbolicLink()) return;
      if (info.isDirectory() && recurse) {
        const entries = await readdir(path);
        // Only direct Markdown children of docs/ are context files.
        for (const name of entries.sort()) await visit(join(path, name), false);
      } else if (info.isFile() && path.toLowerCase().endsWith(".md")) {
        files.push({ path, content: await readFile(path, "utf8") });
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      if (ctx.hasUI) {
        ctx.ui.notify(
          `Could not load documentation ${path}: ${String(error)}`,
          "warning",
        );
      }
    }
  }

  await visit(join(root, "README.md"), false);
  await visit(join(root, "docs"), true);
  return files;
}

export default function (pi: ExtensionAPI) {
  let enabled = true;
  let snapshot: { cwd: string; files: ContextFile[] } | undefined;
  let hasInjected = false;

  async function getDocs(ctx: ExtensionContext): Promise<ContextFile[]> {
    if (!snapshot || snapshot.cwd !== ctx.cwd) {
      snapshot = { cwd: ctx.cwd, files: await loadDocs(ctx.cwd, ctx) };
    }
    return snapshot.files;
  }

  pi.on("session_start", (_event, ctx) => {
    enabled = restoreSetting(ctx);
    snapshot = undefined;
    hasInjected = false;
  });

  pi.on("session_tree", (_event, ctx) => {
    enabled = restoreSetting(ctx);
  });

  pi.registerCommand("docs", {
    description:
      "Show or switch README/docs context injection for this session",
    getArgumentCompletions: (prefix) =>
      ["on", "off"]
        .filter((value) => value.startsWith(prefix))
        .map((value) => ({ value, label: value })),
    handler: async (args, ctx) => {
      const value = args.trim().toLowerCase();
      if (!value) {
        const trust =
          enabled && !ctx.isProjectTrusted()
            ? " (waiting for project trust)"
            : "";
        const paths = new Set(
          (ctx.getSystemPromptOptions().contextFiles ?? []).map((file) =>
            resolve(ctx.cwd, file.path),
          ),
        );
        if (enabled && ctx.isProjectTrusted()) {
          for (const file of await getDocs(ctx)) paths.add(file.path);
        }
        const files = [...paths].map((path) => {
          const local = relative(ctx.cwd, path);
          return `  ${local.startsWith("..") ? path : local || path}`;
        });
        ctx.ui.notify(
          `Docs ${enabled ? "on" : "off"}${trust}\n${files.join("\n") || "  (none)"}`,
          "info",
        );
        return;
      }
      if (value !== "on" && value !== "off") {
        ctx.ui.notify("Usage: /docs [on|off]", "warning");
        return;
      }
      if (!ctx.isIdle()) {
        ctx.ui.notify(
          "Wait until Pi is idle before changing documentation context.",
          "warning",
        );
        return;
      }
      const next = value === "on";
      if (next !== enabled) {
        enabled = next;
        // Durable session data, not a message sent to the model.
        pi.appendEntry(ENTRY_TYPE, { enabled });
      }
      const history =
        !enabled && hasInjected
          ? " Previously sent documentation remains in history."
          : "";
      ctx.ui.notify(
        `Docs ${value}; applies to the next prompt.${history}`,
        "info",
      );
    },
  });

  pi.on("before_agent_start", async (event, ctx) => {
    if (!enabled || !ctx.isProjectTrusted()) return;
    const files = await getDocs(ctx);
    // Each run starts with Pi's base context. Add one stable copy per path,
    // preserving AGENTS.md and context contributed by other extensions.
    const existing = new Set(
      event.systemPromptOptions.contextFiles.map((file) =>
        resolve(ctx.cwd, file.path),
      ),
    );
    for (const file of files) {
      if (existing.has(file.path)) continue;
      event.systemPromptOptions.contextFiles.push({ ...file });
      existing.add(file.path);
      hasInjected = true;
    }
  });

  pi.on("session_shutdown", () => {
    snapshot = undefined;
  });
}
