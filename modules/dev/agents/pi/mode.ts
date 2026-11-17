/**
 * Modes: Markdown files in modes/ under Pi's agent directory, switched with /mode or Shift+Tab.
 * A mode excludes tools, sets the thinking level, and adds its body to the system prompt.
 */

import {
  type ExtensionAPI,
  type ExtensionContext,
  parseFrontmatter,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import { Key } from "@earendil-works/pi-tui";
import {
  lastEntry,
  loadDefinitions,
  optionalList,
  optionalThinking,
  rejectUnknown,
  requiredText,
  sendStatus,
  type ThinkingLevel,
} from "./lib/shared.ts";

// Modes

const MODE_ENTRY = "mode";
// The default mode: no mode file, the normal settings.
const FREE = "free";
const FREE_COLOR = "warning";
// Theme colors a mode can use in the status line.
const COLORS = ["text", "muted", "dim", "accent", "success", "warning", "error"] as const;
type Color = (typeof COLORS)[number];

interface Mode {
  description: string;
  order?: number;
  color: Color;
  thinkingLevel?: ThinkingLevel;
  excludeTools: string[];
  instructions: string;
}

// A type alias: parseFrontmatter needs the implicit index signature an interface lacks.
type ModeFrontmatter = {
  description?: unknown;
  order?: unknown;
  color?: unknown;
  thinking?: unknown;
  "exclude-tools"?: unknown;
};

// Validates one mode file.
function parseMode(content: string, name: string): Mode {
  if (name === FREE) throw new Error(`"${FREE}" is the default mode`);
  const { frontmatter, body } = parseFrontmatter<ModeFrontmatter>(content);
  const {
    description,
    order,
    color = "text",
    thinking,
    "exclude-tools": exclude,
    ...unknown
  } = frontmatter;
  rejectUnknown(unknown);
  if (order !== undefined && typeof order !== "number")
    throw new Error("order must be a number");
  if (!COLORS.includes(color as Color))
    throw new Error(`color must be one of: ${COLORS.join(", ")}`);
  return {
    description: requiredText(description, "description"),
    order,
    color: color as Color,
    thinkingLevel: optionalThinking(thinking),
    excludeTools: optionalList(exclude, "exclude-tools") ?? [],
    instructions: requiredText(body, "the instructions (body)"),
  };
}

function loadModes(): { modes: Map<string, Mode>; errors: string[] } {
  const { definitions: modes, errors } = loadDefinitions("modes", parseMode);
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

// Recorded in the session; `saved` holds the settings to restore when leaving the mode, and
// `left` the settings restored when a mode was left. Pi saves tool changes only with the next
// model request, so a session reopened after leaving a mode would otherwise get the mode's
// tools back.
interface ModeState {
  name?: string;
  saved?: Saved;
  left?: Saved;
}

// Asks the user to pick one of the labeled values; undefined when cancelled.
async function pick<T>(
  ctx: ExtensionContext,
  title: string,
  entries: [label: string, value: T][],
): Promise<{ value: T } | undefined> {
  const choice = await ctx.ui.select(
    title,
    entries.map(([label]) => label),
  );
  const entry = entries.find(([label]) => label === choice);
  return entry && { value: entry[1] };
}

export default function (pi: ExtensionAPI) {
  const { modes, errors } = loadModes();
  let state: ModeState = {};
  const isModeName = (value: unknown): value is string =>
    typeof value === "string" && modes.has(value);
  const currentMode = () => (state.name ? modes.get(state.name) : undefined);
  // Modes

  // Sends the mode to status.ts, which starts its status line with it (segments sort by key).
  function updateStatus() {
    const mode = currentMode();
    const name = state.name ?? FREE;
    const color = mode?.color ?? FREE_COLOR;
    sendStatus(pi, {
      key: MODE_ENTRY,
      render: (theme: Theme) => theme.bold(theme.fg(color, name)),
      // The working spinner takes the mode color too.
      spinner: color,
    });
  }

  // Applies a target state: the mode's settings, or the saved ones when leaving a mode (the
  // current mode's, or the recorded `left` ones when restoring a session).
  function apply(next: ModeState) {
    const mode = next.name ? modes.get(next.name) : undefined;
    const restored = state.saved ?? next.left;
    if (mode && next.saved) {
      const tools = next.saved.tools.filter((tool) => !mode.excludeTools.includes(tool));
      pi.setActiveTools(tools);
      pi.setThinkingLevel(mode.thinkingLevel ?? next.saved.thinkingLevel);
    } else if (restored) {
      pi.setActiveTools(restored.tools);
      pi.setThinkingLevel(restored.thinkingLevel);
    }
    state = mode ? next : {};
    updateStatus();
  }

  function switchTo(ctx: ExtensionContext, name: string | undefined) {
    if (name === state.name) return;
    // Switching between modes keeps the settings from before the first one.
    const saved = state.saved ?? {
      tools: pi.getActiveTools(),
      thinkingLevel: pi.getThinkingLevel(),
    };
    apply(name ? { name, saved } : {});
    pi.appendEntry(MODE_ENTRY, name ? state : { left: saved });
    ctx.ui.notify(`Mode: ${name ?? FREE}`, "info");
  }

  function restoreMode(ctx: ExtensionContext) {
    const recorded = lastEntry<ModeState>(ctx, MODE_ENTRY) ?? {};
    // A mode removed since it was recorded counts as free.
    if (isModeName(recorded.name) && recorded.saved) apply(recorded);
    else apply({ left: recorded.left ?? recorded.saved });
  }

  pi.on("session_start", (_event, ctx) => {
    if (errors.length > 0) ctx.ui.notify(`Modes: ${errors.join("; ")}`, "warning");
    restoreMode(ctx);
  });
  pi.on("session_tree", (_event, ctx) => {
    restoreMode(ctx);
  });

  pi.on("before_agent_start", (event) => {
    // Empty sections are omitted by Pi; leaving a mode must also remove its instructions.
    event.systemPromptOptions.sections.mode = currentMode()?.instructions ?? "";
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

      const choice = await pick<string | undefined>(ctx, "Mode", [
        [`${FREE}: normal settings`, undefined],
        ...[...modes].map(([name, mode]): [string, string] => [
          `${name}: ${mode.description}`,
          name,
        ]),
      ]);
      if (choice) switchTo(ctx, choice.value);
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
