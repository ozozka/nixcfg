/**
 * Named modes: each sets the thinking level, removes tools, and appends instructions to the
 * system prompt. The default mode, free, is the normal settings. Entering a mode saves the
 * current tools and thinking level; leaving restores them. The mode starts the status line in
 * bold, in its color; Shift+Tab cycles the modes by their order.
 *
 * Modes are Markdown files in modes/ under Pi's agent directory, loaded at startup: the file
 * name is the mode name, the frontmatter its settings (including `order` and the status
 * `color`), and the body its instructions. A mode
 * with `next` asks, when a run ends with open tasks, whether to switch to that mode and send
 * `next-prompt`.
 *
 * The state is recorded in the session on every switch and restored from the current branch,
 * so resuming or navigating with /tree brings back the matching mode. Derived from the Pi
 * preset example.
 */

import { readdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import {
  type ExtensionAPI,
  type ExtensionContext,
  getAgentDir,
  parseFrontmatter,
} from "@earendil-works/pi-coding-agent";
import { Key } from "@earendil-works/pi-tui";

type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;

const THINKING_LEVELS: readonly string[] = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
];

const ENTRY_TYPE = "mode";
// The default mode: no mode file, the normal settings.
const FREE = "free";
const FREE_COLOR = "text";
// Theme colors a mode can use in the status line.
const COLORS = ["text", "muted", "dim", "accent", "success", "warning", "error"] as const;
type Color = (typeof COLORS)[number];
const TRAILING_PERIOD = /\.$/;

interface Mode {
  description: string;
  order?: number;
  color: Color;
  thinkingLevel?: ThinkingLevel;
  excludeTools: string[];
  // Mode to offer when a run ends with open tasks, and the prompt sent after switching.
  next?: string;
  nextPrompt?: string;
  instructions: string;
}

// A type alias: parseFrontmatter needs the implicit index signature an interface lacks.
type ModeFrontmatter = {
  description?: unknown;
  order?: unknown;
  color?: unknown;
  thinking?: unknown;
  "exclude-tools"?: unknown;
  next?: unknown;
  "next-prompt"?: unknown;
};

function optionalString(value: unknown, key: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || !value.trim()) throw new Error(`${key} must be a string`);
  return value.trim();
}

// Validates one mode file; unknown keys are errors, so typos do not pass silently.
function parseMode(content: string): Mode {
  const { frontmatter, body } = parseFrontmatter<ModeFrontmatter>(content);
  const {
    description,
    order,
    color = "text",
    thinking,
    "exclude-tools": exclude,
    next,
    "next-prompt": nextPrompt,
    ...unknown
  } = frontmatter;
  const extra = Object.keys(unknown);
  if (extra.length > 0) throw new Error(`unknown keys: ${extra.join(", ")}`);
  if (typeof description !== "string" || !description.trim())
    throw new Error("description is required");
  if (order !== undefined && typeof order !== "number")
    throw new Error("order must be a number");
  if (!COLORS.includes(color as Color))
    throw new Error(`color must be one of: ${COLORS.join(", ")}`);
  if (thinking !== undefined && !THINKING_LEVELS.includes(String(thinking)))
    throw new Error(`thinking must be one of: ${THINKING_LEVELS.join(", ")}`);
  // Accepts both YAML spellings: `exclude-tools: edit, write` and `[edit, write]`.
  const list = typeof exclude === "string" ? exclude.split(",") : (exclude ?? []);
  if (!(Array.isArray(list) && list.every((t) => typeof t === "string")))
    throw new Error("exclude-tools must be a comma-separated string or a list");
  if ((next === undefined) !== (nextPrompt === undefined))
    throw new Error("next and next-prompt go together");
  if (!body.trim()) throw new Error("the instructions (body) are empty");
  return {
    description: description.trim(),
    order,
    color: color as Color,
    thinkingLevel: thinking as ThinkingLevel | undefined,
    excludeTools: list.map((t) => t.trim()).filter(Boolean),
    next: optionalString(next, "next"),
    nextPrompt: optionalString(nextPrompt, "next-prompt"),
    instructions: body.trim(),
  };
}

function loadModes(): { modes: Map<string, Mode>; errors: string[] } {
  const dir = join(getAgentDir(), "modes");
  const modes = new Map<string, Mode>();
  const errors: string[] = [];
  let files: string[] = [];
  try {
    files = readdirSync(dir).filter((file) => file.endsWith(".md"));
  } catch {
    errors.push(`no modes directory at ${dir}`);
  }
  for (const file of files) {
    try {
      const name = basename(file, ".md");
      if (name === FREE) throw new Error(`"${FREE}" is the default mode`);
      modes.set(name, parseMode(readFileSync(join(dir, file), "utf8")));
    } catch (error) {
      errors.push(`${file}: ${(error as Error).message}`);
    }
  }
  for (const [name, mode] of modes) {
    if (mode.next && mode.next !== FREE && !modes.has(mode.next)) {
      errors.push(`${name}.md: next mode "${mode.next}" does not exist`);
      mode.next = undefined;
      mode.nextPrompt = undefined;
    }
  }
  // Cycle order: by `order`, then by name.
  const sorted = [...modes].sort(
    ([a, x], [b, y]) =>
      (x.order ?? Number.POSITIVE_INFINITY) - (y.order ?? Number.POSITIVE_INFINITY) ||
      a.localeCompare(b),
  );
  return { modes: new Map(sorted), errors };
}

interface Saved {
  tools: string[];
  thinkingLevel: ThinkingLevel;
}

// Recorded in the session; `saved` holds the settings to restore when leaving the mode.
interface ModeState {
  name?: string;
  saved?: Saved;
}

// Whether the latest todo tool result on the branch (see todo.ts) has unfinished items.
function hasOpenTasks(ctx: ExtensionContext): boolean {
  let items: { status?: string }[] = [];
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "message") continue;
    const msg = entry.message;
    if (msg.role !== "toolResult" || msg.toolName !== "todo") continue;
    const details = msg.details as { items?: unknown; error?: string } | undefined;
    if (Array.isArray(details?.items) && !details.error) items = details.items;
  }
  return items.some((item) => item.status !== "completed");
}

export default function (pi: ExtensionAPI) {
  const { modes, errors } = loadModes();
  let state: ModeState = {};

  const isModeName = (value: unknown): value is string =>
    typeof value === "string" && modes.has(value);

  function updateStatus(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;
    const theme = ctx.ui.theme;
    const mode = state.name ? modes.get(state.name) : undefined;
    // Pi orders statuses by key, so "mode" comes before the other status entries.
    ctx.ui.setStatus(
      ENTRY_TYPE,
      theme.bold(theme.fg(mode?.color ?? FREE_COLOR, state.name ?? FREE)),
    );
  }

  // Applies a target state: the mode's settings, or the saved ones when leaving a mode.
  function apply(ctx: ExtensionContext, next: ModeState) {
    const mode = next.name ? modes.get(next.name) : undefined;
    if (mode && next.saved) {
      pi.setActiveTools(next.saved.tools.filter((tool) => !mode.excludeTools.includes(tool)));
      pi.setThinkingLevel(mode.thinkingLevel ?? next.saved.thinkingLevel);
    } else if (state.saved) {
      pi.setActiveTools(state.saved.tools);
      pi.setThinkingLevel(state.saved.thinkingLevel);
    }
    state = mode ? next : {};
    updateStatus(ctx);
  }

  function switchTo(ctx: ExtensionContext, name: string | undefined) {
    if (name === state.name) return;
    // Switching between modes keeps the settings from before the first one.
    const saved = state.saved ?? {
      tools: pi.getActiveTools(),
      thinkingLevel: pi.getThinkingLevel(),
    };
    apply(ctx, name ? { name, saved } : {});
    pi.appendEntry(ENTRY_TYPE, state);
    ctx.ui.notify(`Mode: ${name ?? FREE}`, "info");
  }

  function restore(ctx: ExtensionContext) {
    let recorded: ModeState = {};
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === ENTRY_TYPE) {
        recorded = entry.data as ModeState;
      }
    }
    // A mode removed since it was recorded counts as free.
    if (isModeName(recorded.name) && recorded.saved) apply(ctx, recorded);
    else if (state.name) apply(ctx, {});
    else updateStatus(ctx);
  }

  pi.on("session_start", (_event, ctx) => {
    if (errors.length > 0) ctx.ui.notify(`Modes: ${errors.join("; ")}`, "warning");
    restore(ctx);
  });
  pi.on("session_tree", (_event, ctx) => restore(ctx));

  pi.on("agent_settled", async (event, ctx) => {
    const mode = state.name ? modes.get(state.name) : undefined;
    if (!(mode?.next && mode.nextPrompt) || event.aborted || !ctx.hasUI) return;
    if (!hasOpenTasks(ctx)) return;
    const { next, nextPrompt } = mode;
    const accept = next === FREE ? `Yes, leave ${state.name} mode` : `Yes, switch to ${next}`;
    const choice = await ctx.ui.select(nextPrompt.replace(TRAILING_PERIOD, "?"), [
      accept,
      `Keep ${state.name} mode`,
    ]);
    if (choice !== accept) return;
    switchTo(ctx, next === FREE ? undefined : next);
    pi.sendUserMessage(nextPrompt);
  });

  pi.on("before_agent_start", (event) => {
    const mode = state.name ? modes.get(state.name) : undefined;
    if (!mode) return;
    return { systemPrompt: `${event.systemPrompt}\n\n${mode.instructions}` };
  });

  pi.registerCommand("mode", {
    description: `Switch mode: /mode, /mode <name>, /mode ${FREE}`,
    handler: async (args, ctx) => {
      const requested = args.trim();
      if (requested === FREE) return switchTo(ctx, undefined);
      if (isModeName(requested)) return switchTo(ctx, requested);
      if (requested) {
        const available = [FREE, ...modes.keys()].join(", ");
        ctx.ui.notify(`Unknown mode "${requested}". Available: ${available}`, "error");
        return;
      }
      if (!ctx.hasUI) return;

      const labels = new Map<string, string | undefined>([
        [`${FREE}: normal settings`, undefined],
        ...[...modes].map(([name, mode]) => [`${name}: ${mode.description}`, name] as const),
      ]);
      const choice = await ctx.ui.select("Mode", [...labels.keys()]);
      if (choice !== undefined) switchTo(ctx, labels.get(choice));
    },
  });

  // Pi's default thinking-level cycle uses Shift+Tab; keybindings.json moves it to Ctrl+T.
  pi.registerShortcut(Key.shift("tab"), {
    description: "Cycle modes",
    handler: (ctx) => {
      const order: (string | undefined)[] = [undefined, ...modes.keys()];
      switchTo(ctx, order[(order.indexOf(state.name) + 1) % order.length]);
    },
  });
}
