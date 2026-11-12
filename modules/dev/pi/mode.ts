/**
 * Named modes: each sets the thinking level, the active tools, and instructions appended to
 * the system prompt. No mode means the normal settings. Entering a mode saves the current tools
 * and thinking level; leaving restores them.
 *
 * The state is recorded in the session on every switch and restored from the current branch,
 * so resuming or navigating with /tree brings back the matching mode. A plan run that leaves
 * open tasks asks whether to implement them. Derived from the Pi preset example, with modes
 * defined here instead of presets.json.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Key } from "@earendil-works/pi-tui";

type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;

interface Mode {
  description: string;
  thinkingLevel?: ThinkingLevel;
  // Derives the mode's tools from the tools active before entering it.
  tools?: (tools: string[]) => string[];
  instructions: string;
}

const MODES = {
  plan: {
    description: "Read-only exploration that ends in a plan",
    thinkingLevel: "high",
    tools: (tools) => tools.filter((tool) => tool !== "edit" && tool !== "write"),
    instructions: `## Plan mode

Plan mode is active: explore and plan, and do not change anything.
- The edit and write tools are unavailable. Use bash only for read-only commands: reading, searching, git status, log, and diff.
- Read the relevant code and documentation before proposing changes.
- When a decision belongs to the user, ask with the question tool instead of guessing.
- Write the plan to the task list with the todo tool, one pending item per step.
- End with a short summary of the plan and the decisions it depends on. The user is then asked whether to implement it.`,
  },
} satisfies Record<string, Mode>;

type ModeName = keyof typeof MODES;

interface Saved {
  tools: string[];
  thinkingLevel: ThinkingLevel;
}

// Recorded in the session; `saved` holds the settings to restore when leaving the mode.
interface ModeState {
  name?: ModeName;
  saved?: Saved;
}

const ENTRY_TYPE = "mode";
const OFF = "off";

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

function isModeName(value: unknown): value is ModeName {
  return typeof value === "string" && Object.hasOwn(MODES, value);
}

export default function (pi: ExtensionAPI) {
  let state: ModeState = {};

  function updateStatus(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;
    ctx.ui.setStatus(
      ENTRY_TYPE,
      state.name ? ctx.ui.theme.fg("accent", `mode:${state.name}`) : undefined,
    );
  }

  // Applies a target state: the mode's settings, or the saved ones when leaving a mode.
  function apply(ctx: ExtensionContext, next: ModeState) {
    if (next.name && next.saved) {
      const mode: Mode = MODES[next.name];
      pi.setActiveTools(mode.tools ? mode.tools(next.saved.tools) : next.saved.tools);
      pi.setThinkingLevel(mode.thinkingLevel ?? next.saved.thinkingLevel);
    } else if (state.saved) {
      pi.setActiveTools(state.saved.tools);
      pi.setThinkingLevel(state.saved.thinkingLevel);
    }
    state = next.name ? next : {};
    updateStatus(ctx);
  }

  function switchTo(ctx: ExtensionContext, name: ModeName | undefined) {
    if (name === state.name) return;
    // Switching between modes keeps the settings from before the first one.
    const saved = state.saved ?? {
      tools: pi.getActiveTools(),
      thinkingLevel: pi.getThinkingLevel(),
    };
    apply(ctx, name ? { name, saved } : {});
    pi.appendEntry(ENTRY_TYPE, state);
    ctx.ui.notify(name ? `Mode: ${name}` : "Mode off", "info");
  }

  function restore(ctx: ExtensionContext) {
    let recorded: ModeState = {};
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === ENTRY_TYPE) {
        recorded = entry.data as ModeState;
      }
    }
    // A mode removed from MODES since it was recorded counts as off.
    if (isModeName(recorded.name) && recorded.saved) apply(ctx, recorded);
    else if (state.name) apply(ctx, {});
  }

  pi.on("session_start", (_event, ctx) => restore(ctx));
  pi.on("session_tree", (_event, ctx) => restore(ctx));

  pi.on("agent_settled", async (event, ctx) => {
    if (state.name !== "plan" || event.aborted || !ctx.hasUI || !hasOpenTasks(ctx)) return;
    const implement = "Yes, leave plan mode";
    const choice = await ctx.ui.select("Implement the plan?", [implement, "Keep planning"]);
    if (choice !== implement) return;
    switchTo(ctx, undefined);
    pi.sendUserMessage("Implement the plan.");
  });

  pi.on("before_agent_start", (event) => {
    if (!state.name) return;
    return { systemPrompt: `${event.systemPrompt}\n\n${MODES[state.name].instructions}` };
  });

  pi.registerCommand("mode", {
    description: "Switch mode: /mode, /mode <name>, /mode off",
    handler: async (args, ctx) => {
      const requested = args.trim();
      if (requested === OFF) return switchTo(ctx, undefined);
      if (isModeName(requested)) return switchTo(ctx, requested);
      if (requested) {
        const available = [OFF, ...Object.keys(MODES)].join(", ");
        ctx.ui.notify(`Unknown mode "${requested}". Available: ${available}`, "error");
        return;
      }
      if (!ctx.hasUI) return;

      const labels = new Map<string, ModeName | undefined>([
        [`${OFF}: normal settings`, undefined],
        ...Object.entries(MODES).map(
          ([name, mode]) => [`${name}: ${mode.description}`, name as ModeName] as const,
        ),
      ]);
      const choice = await ctx.ui.select("Mode", [...labels.keys()]);
      if (choice !== undefined) switchTo(ctx, labels.get(choice));
    },
  });

  pi.registerShortcut(Key.ctrlShift("u"), {
    description: "Cycle modes",
    handler: (ctx) => {
      const order: (ModeName | undefined)[] = [
        undefined,
        ...(Object.keys(MODES) as ModeName[]),
      ];
      switchTo(ctx, order[(order.indexOf(state.name) + 1) % order.length]);
    },
  });
}
