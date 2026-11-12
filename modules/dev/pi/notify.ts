/**
 * Desktop notifications over D-Bus: "Done" with the first line of the final message when a run
 * settles, "Failed" with the error when it ended in one (nothing after Escape), "Input required"
 * when a dialog waits during a run, and notices other extensions send on the "notify" event bus channel as
 * { message, final? }, such as finished roadmap steps. A final notice (a completed plan) stays
 * on the card instead of the run's "Done".
 *
 * Each session keeps one notification and replaces it in place (Notify's replaces_id), since
 * the notification server keeps cards until they are dismissed; a replaced card moves back to
 * the top. Sends are serialized, so a quick second notification still replaces the first.
 */

import { basename } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const NOTIFICATION_ID = /^u (\d+)/;
const NOTIFY_CHANNEL = "notify";
// Longest summary shown after "Done: " or "Failed: ".
const SUMMARY_LENGTH = 80;

// The first non-empty line of a text, shortened to fit a notification.
function firstLine(text: string): string {
  const line =
    text
      .split("\n")
      .find((candidate) => candidate.trim() !== "")
      ?.trim() ?? "";
  return line.length > SUMMARY_LENGTH ? `${line.slice(0, SUMMARY_LENGTH - 1)}…` : line;
}

export default function (pi: ExtensionAPI) {
  // The session's notification ID; 0 creates a new one.
  let cardId = 0;
  let queue = Promise.resolve();
  // The current session, for notices from other extensions.
  let context: ExtensionContext | undefined;
  // A final notice arrived during the current run, so "Done" would hide it.
  let kept = false;

  async function send(ctx: ExtensionContext, message: string) {
    try {
      const projectName = basename(ctx.cwd) || ctx.cwd;

      // NixOS supplies busctl through systemd; no terminal protocol or libnotify.
      const result = await pi.exec(
        "busctl",
        [
          "--user",
          "--timeout=3",
          "--", // The expiration argument below is a negative number.
          "call",
          "org.freedesktop.Notifications",
          "/org/freedesktop/Notifications",
          "org.freedesktop.Notifications",
          "Notify",
          "susssasa{sv}i",
          "Pi", // Application name.
          String(cardId), // The notification to replace; 0 creates one.
          "", // Use the notification service's default icon.
          projectName,
          message,
          "0", // No actions.
          "0", // No hints.
          "-1", // Use the notification service's default expiration.
        ],
        { timeout: 5000 },
      );
      if (result.code !== 0) {
        ctx.ui.notify("Could not send desktop notification", "warning");
        return;
      }
      const id = NOTIFICATION_ID.exec(result.stdout.trim());
      if (id) cardId = Number(id[1]);
    } catch {
      // A missing bus or notification service must not interrupt the agent.
      ctx.ui.notify("Could not send desktop notification", "warning");
    }
  }

  // "Failed: <error>" or "Done: <first line of the final message>", from the last assistant message.
  function outcome(ctx: ExtensionContext): string {
    const last = ctx.sessionManager
      .getBranch()
      .flatMap((entry) => (entry.type === "message" ? [entry.message] : []))
      .filter((message) => message.role === "assistant")
      .at(-1);
    if (last?.role !== "assistant") return "Done";
    if (last.stopReason === "error") {
      const error = firstLine(last.errorMessage ?? "");
      return error ? `Failed: ${error}` : "Failed";
    }
    const text = last.content
      .flatMap((part) => (part.type === "text" ? [part.text] : []))
      .join("\n");
    const summary = firstLine(text);
    return summary ? `Done: ${summary}` : "Done";
  }

  function notify(ctx: ExtensionContext, message: string) {
    if (ctx.mode !== "tui") return;
    queue = queue.then(() => send(ctx, message));
    return queue;
  }

  // A new or resumed session starts its own notification.
  pi.on("session_start", (_event, ctx) => {
    cardId = 0;
    context = ctx;
  });

  pi.events.on(NOTIFY_CHANNEL, (data) => {
    const { message, final } = (data ?? {}) as { message?: unknown; final?: unknown };
    if (typeof message !== "string" || !context) return;
    if (final === true) kept = true;
    notify(context, message);
  });

  pi.on("agent_start", () => {
    kept = false;
  });

  // Unlike agent_end, this fires only after retries and queued work finish.
  pi.on("agent_settled", (event, ctx) => {
    if (kept || event.aborted) return;
    return notify(ctx, outcome(ctx));
  });

  // Dialogs raised during a run (questions, confirmations) wait for the user; dialogs the
  // user opens with a command while Pi is idle need no notification.
  pi.on("ui_prompt_start", (_event, ctx) => {
    if (!ctx.isIdle()) return notify(ctx, "Input required");
  });
}
