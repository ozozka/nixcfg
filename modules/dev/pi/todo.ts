/**
 * Task list for multi-step work, shaped like Claude's TodoWrite and Codex's update_plan: the
 * model sends the whole list with a status per item on every update.
 *
 * State is stored in tool result details (not external files), so branching keeps the list
 * correct for that point in history. A widget above the editor shows the list while items are
 * open. Vendored from the Pi todo example.
 */

import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

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

const DESCRIPTION = `Track multi-step work in a task list the user can follow.
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
function modelText(items: TodoItem[]): string {
  if (items.length === 0) return "Task list cleared.";
  const lines = items.map((item) => `[${item.status}] ${item.text}`);
  return `Task list updated (${summary(items)}):\n${lines.join("\n")}`;
}

export default function (pi: ExtensionAPI) {
  // In-memory state, reconstructed from the session branch.
  let items: TodoItem[] = [];

  // Shown while work is open; a finished or empty list leaves the editor area clean.
  const updateWidget = (ctx: ExtensionContext) => {
    if (!ctx.hasUI) return;
    const open = items.some((item) => item.status !== "completed");
    const theme = ctx.ui.theme;
    ctx.ui.setWidget(
      "todo",
      open
        ? [
            theme.fg("muted", `Todos ${summary(items)}`),
            ...items.map((item) => formatItem(item, theme)),
          ]
        : undefined,
    );
  };

  const reconstructState = (ctx: ExtensionContext) => {
    items = [];
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "message") continue;
      const msg = entry.message;
      if (msg.role !== "toolResult" || msg.toolName !== "todo") continue;
      if (isTodoDetails(msg.details) && !msg.details.error) items = msg.details.items;
    }
    updateWidget(ctx);
  };

  pi.on("session_start", (_event, ctx) => reconstructState(ctx));
  pi.on("session_tree", (_event, ctx) => reconstructState(ctx));

  pi.registerTool({
    name: "todo",
    label: "Todo",
    description: DESCRIPTION,
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
        content: [{ type: "text", text: modelText(items) }],
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
}
