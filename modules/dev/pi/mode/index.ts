/**
 * Named modes and the task list.
 *
 * Modes: each sets the thinking level, removes tools, and appends instructions to the system
 * prompt. The default mode, free, is the normal settings. Entering a mode saves the current
 * tools and thinking level; leaving restores them. The mode starts the status line in bold, in
 * its color; Shift+Tab cycles the modes by their order.
 *
 * Modes are Markdown files in modes/ under Pi's agent directory, loaded at startup: the file
 * name is the mode name, the frontmatter its settings (including `order` and the status
 * `color`), and the body its instructions. A mode with `next` asks, when a run ends with open
 * tasks, whether to switch to that mode and send `next-prompt`. The mode state is recorded in
 * the session on every switch and restored from the current branch, so resuming or navigating
 * with /tree brings back the matching mode. Derived from the Pi preset example.
 *
 * Task list: the `todo` tool, shaped like Claude's TodoWrite and Codex's update_plan: the model
 * sends the whole list with a status per item on every update. State is stored in tool result
 * details, so branching keeps the list correct for that point in history. A widget above the
 * editor shows the list while items are open, and compaction re-sends open items to the model.
 * Derived from the Pi todo example.
 *
 * Roadmap: modes with `roadmap: true` get the `roadmap` tool, which writes plans to the project's
 * roadmap board and ticks their steps (see roadmap.ts); the widget then shows the current plan
 * above the session tasks, and `next` checks the plan's open steps instead of the tasks.
 */

import { readdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { StringEnum } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  type ExtensionContext,
  getAgentDir,
  parseFrontmatter,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import { Key, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import {
  type Board,
  completePlan,
  currentPlan,
  findBoard,
  type Plan,
  planText,
  projectRoot,
  saveBoard,
  tickStep,
  writePlan,
} from "./roadmap.ts";

type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;

// Modes

const THINKING_LEVELS: readonly string[] = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
];

const MODE_ENTRY = "mode";
// The default mode: no mode file, the normal settings.
const FREE = "free";
const FREE_COLOR = "text";
// Theme colors a mode can use in the status line.
const COLORS = ["text", "muted", "dim", "accent", "success", "warning", "error"] as const;
type Color = (typeof COLORS)[number];
const TRAILING_PERIOD = /\.$/;
const BLOCKED = /^\s*Blocked:/;
// Upper bound on automatic continuations per prompt.
const AUTO_CONTINUE_LIMIT = 50;

interface Mode {
  description: string;
  order?: number;
  color: Color;
  thinkingLevel?: ThinkingLevel;
  excludeTools: string[];
  // Mode to offer when a run ends with open tasks, and the prompt sent after switching.
  next?: string;
  nextPrompt?: string;
  // Enables the roadmap tool and tracks open work on the roadmap plan.
  roadmap: boolean;
  // Continues the run while the roadmap plan makes progress (see agent_before_settle).
  autoContinue: boolean;
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
  roadmap?: unknown;
  "auto-continue"?: unknown;
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
    roadmap = false,
    "auto-continue": autoContinue = false,
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
  if (typeof roadmap !== "boolean") throw new Error("roadmap must be true or false");
  if (typeof autoContinue !== "boolean") throw new Error("auto-continue must be true or false");
  if (autoContinue && !roadmap) throw new Error("auto-continue needs roadmap: true");
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
    roadmap,
    autoContinue,
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

// Task list

const STATUSES = ["pending", "in_progress", "completed"] as const;
type Status = (typeof STATUSES)[number];

interface TodoItem {
  text: string;
  status: Status;
}

interface TodoDetails {
  items: TodoItem[];
  error?: string;
}

const TodoParams = Type.Object({
  items: Type.Array(
    Type.Object({
      text: Type.String({ description: "Task, phrased as an action" }),
      status: StringEnum(STATUSES),
    }),
    { description: "The complete list; it replaces the previous one. Empty clears it." },
  ),
});

const TODO_DESCRIPTION = `Track multi-step work in a task list the user can follow.
Send the whole list on every update; it replaces the previous one.
- Use it for work with three or more steps, or when the user lists several tasks; skip it for trivial requests.
- Keep exactly one item in_progress while working, and mark items completed as soon as they are done.
- Add newly discovered steps, and remove steps that no longer apply.`;

function isTodoDetails(value: unknown): value is TodoDetails {
  return (
    typeof value === "object" && value !== null && Array.isArray((value as TodoDetails).items)
  );
}

function icon(item: TodoItem, theme: Theme): string {
  if (item.status === "completed") return theme.fg("success", "✓");
  if (item.status === "in_progress") return theme.fg("accent", "▸");
  return theme.fg("dim", "○");
}

function formatItem(item: TodoItem, theme: Theme): string {
  const text = item.status === "completed" ? theme.fg("dim", item.text) : item.text;
  return `${icon(item, theme)} ${text}`;
}

function summary(items: TodoItem[]): string {
  const done = items.filter((item) => item.status === "completed").length;
  return `${done}/${items.length} completed`;
}

// Plain text for the model: one line per item with its status.
function modelText(heading: string, items: TodoItem[]): string {
  if (items.length === 0) return "Task list cleared.";
  const lines = items.map((item) => `[${item.status}] ${item.text}`);
  return `${heading} (${summary(items)}):\n${lines.join("\n")}`;
}

// Roadmap

const ROADMAP_TOOL = "roadmap";
const ROADMAP_ACTIONS = ["show", "write", "tick", "complete"] as const;

const RoadmapParams = Type.Object({
  action: StringEnum(ROADMAP_ACTIONS),
  plan: Type.Optional(
    Type.String({
      description:
        "Plan name; write needs it, the others default to the active plan (or the only one in Plans)",
    }),
  ),
  content: Type.Optional(
    Type.String({
      description: "write: the plan body in the plan format, without its heading",
    }),
  ),
  step: Type.Optional(Type.Number({ description: "tick: the step number" })),
  delivered: Type.Optional(
    Type.Array(Type.String(), {
      description: "complete: one Completed line per delivered capability",
    }),
  ),
});

const ROADMAP_DESCRIPTION = `Manage plans on the project's roadmap board (docs/roadmap.md, README.md's Roadmap section, or a root todo.md that is created when there is no board).
Actions:
- show: the board's plans and the current plan's text.
- write: add a plan to Plans, or replace an existing plan's body where it is.
- tick: mark a step done; the plan moves from Plans to Active on its first tick.
- complete: when all steps are ticked, replace the plan with Completed lines.
Plan format (the body, without the heading): bullets only; bold groups \`- **Goal**:\`, \`- **Findings**:\`, \`- **Decisions**:\`, \`- **Specification**:\`, and \`- **Steps**:\`, leaving out empty ones; each step under Steps is \`  - [ ] **1. Title**: details\`, numbered from 1, one commit each.`;

interface RoadmapDetails {
  path?: string;
  plan?: { name: string; section: string; steps: { title: string; done: boolean }[] };
  error?: string;
}

function planSummary(plan: Plan): RoadmapDetails["plan"] {
  return {
    name: plan.name,
    section: plan.section,
    steps: plan.steps.map((step) => ({
      title: `${step.number}. ${step.title}`,
      done: step.done,
    })),
  };
}

function progress(plan: Plan): string {
  return `${plan.steps.filter((step) => step.done).length}/${plan.steps.length}`;
}

function boardOverview(board: Board): string {
  if (board.plans.length === 0) return "No plans on the board.";
  return board.plans
    .map((plan) => `- ${plan.name} (${plan.section}, ${progress(plan)} steps done)`)
    .join("\n");
}

interface RoadmapInput {
  action: string;
  plan?: string;
  content?: string;
  step?: number;
  delivered?: string[];
}

// Runs a roadmap action and returns the message for the model and the plan it concerns.
function roadmapAction(
  cwd: string,
  params: {
    action: string;
    plan?: string;
    content?: string;
    step?: number;
    delivered?: string[];
  },
): { text: string; board: Board; plan?: Plan } {
  let board = findBoard(cwd);
  const where = board.path.slice(projectRoot(cwd).length + 1);
  const target = () => {
    const plan = currentPlan(board, params.plan);
    if (!plan)
      throw new Error(
        params.plan ? `no plan named "${params.plan}"` : "no active plan; name the plan",
      );
    return plan;
  };
  switch (params.action) {
    case "show": {
      const plan = currentPlan(board, params.plan);
      const text = plan ? `\n\n${planText(board, plan)}` : "";
      return { text: `Board in ${where}:\n${boardOverview(board)}${text}`, board, plan };
    }
    case "write": {
      if (!(params.plan && params.content)) throw new Error("write needs plan and content");
      board = writePlan(board, params.plan, params.content);
      saveBoard(board);
      const plan = currentPlan(board, params.plan) as Plan;
      return {
        text: `Plan "${plan.name}" written to ${plan.section} in ${where}.`,
        board,
        plan,
      };
    }
    case "tick": {
      if (params.step === undefined) throw new Error("tick needs step");
      board = tickStep(board, target(), params.step);
      saveBoard(board);
      const plan = currentPlan(board, params.plan) as Plan;
      const next = plan.steps.find((step) => !step.done);
      const rest = next ? ` Next: ${next.number}. ${next.title}` : " All steps are done.";
      return { text: `Step ${params.step} ticked (${progress(plan)}).${rest}`, board, plan };
    }
    case "complete": {
      const plan = target();
      board = completePlan(board, plan, params.delivered ?? []);
      saveBoard(board);
      return { text: `Plan "${plan.name}" completed in ${where}.`, board };
    }
    default:
      throw new Error(`unknown action ${params.action}`);
  }
}

// The plan the widget and the mode checks follow, or undefined without a readable board.
function trackedPlan(cwd: string): Plan | undefined {
  try {
    const board = findBoard(cwd);
    return board.created ? undefined : currentPlan(board);
  } catch {
    return undefined;
  }
}

export default function (pi: ExtensionAPI) {
  const { modes, errors } = loadModes();
  let state: ModeState = {};
  // In-memory task list, reconstructed from the session branch.
  let items: TodoItem[] = [];
  // A plan was written in the current run; roadmap modes offer `next` only then.
  let planWritten = false;

  const isModeName = (value: unknown): value is string =>
    typeof value === "string" && modes.has(value);
  const hasOpenTasks = () => items.some((item) => item.status !== "completed");
  const currentMode = () => (state.name ? modes.get(state.name) : undefined);
  const roadmapMode = () => currentMode()?.roadmap === true;
  const hasOpenSteps = (ctx: ExtensionContext) =>
    trackedPlan(ctx.cwd)?.steps.some((step) => !step.done) === true;

  // Task list

  // Shown while work is open: the roadmap plan in roadmap modes, then the session tasks.
  function updateWidget(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;
    const theme = ctx.ui.theme;
    const lines: string[] = [];
    const plan = roadmapMode() ? trackedPlan(ctx.cwd) : undefined;
    if (plan?.steps.some((step) => !step.done)) {
      const next = plan.steps.find((step) => !step.done);
      lines.push(theme.fg("muted", `Plan ${plan.name} ${progress(plan)}`));
      for (const step of plan.steps) {
        const mark = step.done
          ? theme.fg("success", "✓")
          : step === next
            ? theme.fg("accent", "▸")
            : theme.fg("dim", "○");
        const title = `${step.number}. ${step.title}`;
        lines.push(`${mark} ${step.done ? theme.fg("dim", title) : title}`);
      }
    }
    if (hasOpenTasks()) {
      lines.push(theme.fg("muted", `Todos ${summary(items)}`));
      lines.push(...items.map((item) => formatItem(item, theme)));
    }
    ctx.ui.setWidget("todo", lines.length > 0 ? lines : undefined);
  }

  function restoreTasks(ctx: ExtensionContext) {
    items = [];
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "message") continue;
      const msg = entry.message;
      if (msg.role !== "toolResult" || msg.toolName !== "todo") continue;
      if (isTodoDetails(msg.details) && !msg.details.error) items = msg.details.items;
    }
    updateWidget(ctx);
  }

  // The summary replaces earlier todo calls in the model's context, so it would lose the list.
  // In roadmap modes the current plan is re-sent too, read from the board.
  pi.on("session_compact", (_event, ctx) => {
    const reminders: string[] = [];
    if (roadmapMode()) {
      try {
        const board = findBoard(ctx.cwd);
        const plan = board.created ? undefined : currentPlan(board);
        if (plan?.steps.some((step) => !step.done))
          reminders.push(`Roadmap plan from before compaction:\n${planText(board, plan)}`);
      } catch {
        // An unreadable board has nothing to re-send.
      }
    }
    if (hasOpenTasks()) reminders.push(modelText("Task list from before compaction", items));
    if (reminders.length === 0) return;
    pi.sendMessage(
      { customType: "todo-reminder", content: reminders.join("\n\n"), display: false },
      // Mid-run compaction reaches the next model call; manual /compact the next prompt.
      { deliverAs: ctx.isIdle() ? "nextTurn" : "steer" },
    );
  });

  pi.registerTool({
    name: "todo",
    label: "Todo",
    description: TODO_DESCRIPTION,
    parameters: TodoParams,

    // biome-ignore lint/suspicious/useAwait: Pi's tool API requires a Promise.
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const next = params.items.map((item) => ({
        text: item.text.trim(),
        status: item.status,
      }));
      const active = next.filter((item) => item.status === "in_progress").length;
      if (active > 1) {
        const error = `${active} items are in_progress; keep at most one.`;
        return {
          content: [{ type: "text", text: `Error: ${error} The list was not changed.` }],
          details: { items, error } satisfies TodoDetails,
        };
      }
      items = next;
      updateWidget(ctx);
      return {
        content: [{ type: "text", text: modelText("Task list updated", items) }],
        details: { items } satisfies TodoDetails,
      };
    },

    renderCall(args, theme, _context) {
      const count = Array.isArray(args.items) ? args.items.length : 0;
      const text =
        theme.fg("toolTitle", theme.bold("todo ")) +
        theme.fg("muted", count === 0 ? "clear" : `${count} items`);
      return new Text(text, 0, 0);
    },

    renderResult(result, _options, theme, _context) {
      const details = result.details;
      if (!isTodoDetails(details)) {
        const text = result.content[0];
        return new Text(text?.type === "text" ? text.text : "", 0, 0);
      }
      if (details.error) return new Text(theme.fg("error", `Error: ${details.error}`), 0, 0);
      if (details.items.length === 0)
        return new Text(theme.fg("dim", "Task list cleared"), 0, 0);
      const lines = [
        theme.fg("muted", summary(details.items)),
        ...details.items.map((item) => formatItem(item, theme)),
      ];
      return new Text(lines.join("\n"), 0, 0);
    },
  });

  // Roadmap

  pi.registerTool({
    name: ROADMAP_TOOL,
    label: "Roadmap",
    description: ROADMAP_DESCRIPTION,
    parameters: RoadmapParams,

    // biome-ignore lint/suspicious/useAwait: Pi's tool API requires a Promise.
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      try {
        const result = roadmapAction(ctx.cwd, params as RoadmapInput);
        if (params.action === "write") planWritten = true;
        updateWidget(ctx);
        return {
          content: [{ type: "text", text: result.text }],
          details: {
            path: result.board.path,
            plan: result.plan && planSummary(result.plan),
          } satisfies RoadmapDetails,
        };
      } catch (error) {
        const message = (error as Error).message;
        return {
          content: [{ type: "text", text: `Error: ${message}. The board was not changed.` }],
          details: { error: message } satisfies RoadmapDetails,
          isError: true,
        };
      }
    },

    renderCall(args, theme, _context) {
      const target =
        args.action === "tick" ? `step ${args.step ?? "?"}` : (args.plan ?? "current plan");
      return new Text(
        theme.fg("toolTitle", theme.bold(`roadmap ${args.action} `)) +
          theme.fg("muted", target),
        0,
        0,
      );
    },

    renderResult(result, _options, theme, _context) {
      const details = result.details as RoadmapDetails | undefined;
      if (details?.error) return new Text(theme.fg("error", `Error: ${details.error}`), 0, 0);
      const text = result.content[0];
      return new Text(theme.fg("muted", text?.type === "text" ? text.text : ""), 0, 0);
    },
  });

  // Modes

  function updateStatus(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;
    const theme = ctx.ui.theme;
    const mode = state.name ? modes.get(state.name) : undefined;
    // Pi orders statuses by key, so "mode" comes before the other status entries.
    ctx.ui.setStatus(
      MODE_ENTRY,
      theme.bold(theme.fg(mode?.color ?? FREE_COLOR, state.name ?? FREE)),
    );
  }

  // Applies a target state: the mode's settings, or the saved ones when leaving a mode.
  function apply(ctx: ExtensionContext, next: ModeState) {
    const mode = next.name ? modes.get(next.name) : undefined;
    if (mode && next.saved) {
      const tools = next.saved.tools.filter((tool) => !mode.excludeTools.includes(tool));
      pi.setActiveTools(mode.roadmap ? [...tools, ROADMAP_TOOL] : tools);
      pi.setThinkingLevel(mode.thinkingLevel ?? next.saved.thinkingLevel);
    } else if (state.saved) {
      pi.setActiveTools(state.saved.tools);
      pi.setThinkingLevel(state.saved.thinkingLevel);
    }
    state = mode ? next : {};
    updateStatus(ctx);
    updateWidget(ctx);
  }

  function switchTo(ctx: ExtensionContext, name: string | undefined) {
    if (name === state.name) return;
    // Switching between modes keeps the settings from before the first one.
    const saved = state.saved ?? {
      tools: pi.getActiveTools(),
      thinkingLevel: pi.getThinkingLevel(),
    };
    apply(ctx, name ? { name, saved } : {});
    pi.appendEntry(MODE_ENTRY, state);
    ctx.ui.notify(`Mode: ${name ?? FREE}`, "info");
  }

  function restoreMode(ctx: ExtensionContext) {
    let recorded: ModeState = {};
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === MODE_ENTRY) {
        recorded = entry.data as ModeState;
      }
    }
    // A mode removed since it was recorded counts as free.
    if (isModeName(recorded.name) && recorded.saved) apply(ctx, recorded);
    else if (state.name) apply(ctx, {});
    else {
      // Outside roadmap modes the roadmap tool stays inactive.
      pi.setActiveTools(pi.getActiveTools().filter((tool) => tool !== ROADMAP_TOOL));
      updateStatus(ctx);
    }
  }

  pi.on("session_start", (_event, ctx) => {
    if (errors.length > 0) ctx.ui.notify(`Modes: ${errors.join("; ")}`, "warning");
    restoreMode(ctx);
    restoreTasks(ctx);
  });
  pi.on("session_tree", (_event, ctx) => {
    restoreMode(ctx);
    restoreTasks(ctx);
  });

  pi.on("agent_settled", async (event, ctx) => {
    const mode = state.name ? modes.get(state.name) : undefined;
    updateWidget(ctx);
    if (!(mode?.next && mode.nextPrompt) || event.aborted || !ctx.hasUI) return;
    if (!(mode.roadmap ? planWritten && hasOpenSteps(ctx) : hasOpenTasks())) return;
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

  // Auto-continue: a prompt's run keeps going while each part of it ticks a step, so a model
  // that stops early resumes the plan. It stops when a part ticks nothing, the model reports
  // "Blocked:", the run fails or is aborted, or the limit is reached; with all steps ticked it
  // asks once to finish the plan. Continuing before settling keeps notify.ts quiet between steps.
  let baseline: { plan?: string; done: number } = { done: 0 };
  let continuations = 0;
  let finishRequested = false;

  const snapshot = (cwd: string) => {
    const plan = trackedPlan(cwd);
    return { plan: plan?.name, done: plan?.steps.filter((step) => step.done).length ?? 0 };
  };

  pi.on("agent_before_settle", (event, ctx) => {
    if (!currentMode()?.autoContinue || event.outcome !== "completed") return;
    const previous = baseline;
    baseline = snapshot(ctx.cwd);
    const plan = trackedPlan(ctx.cwd);
    if (!plan) return;
    const stop = (reason: string) => ctx.ui.notify(`Exec stopped: ${reason}`, "info");

    const last = event.context.llmMessages.filter((entry) => entry.role === "assistant").at(-1);
    const text =
      last?.role === "assistant"
        ? last.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("")
        : "";
    if (BLOCKED.test(text)) return stop("blocked");
    if (continuations >= AUTO_CONTINUE_LIMIT)
      return stop(`${AUTO_CONTINUE_LIMIT} continuations`);

    let message: string;
    if (plan.steps.some((step) => !step.done)) {
      if (previous.plan !== plan.name || baseline.done <= previous.done)
        return stop("no step was ticked");
      message = "Continue with the next step.";
    } else {
      if (finishRequested) return;
      finishRequested = true;
      message = "All steps are ticked. Finish the plan.";
    }
    continuations++;
    return {
      entries: [
        ...event.entries,
        {
          type: "custom_message",
          customType: "exec-continue",
          content: message,
          display: true,
        },
      ],
      continue: true,
    };
  });

  pi.on("before_agent_start", (event, ctx) => {
    planWritten = false;
    baseline = snapshot(ctx.cwd);
    continuations = 0;
    finishRequested = false;
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
