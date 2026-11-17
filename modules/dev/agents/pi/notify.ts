/**
 * Notifications through the terminal: "Done" with the first line of the final message when a run
 * settles, "Failed" with the error when it ended in one (nothing after Escape), "Input required"
 * when a dialog waits during a run.
 *
 * Pi writes an OSC 777 sequence and the terminal decides what a notification is: Emacs sends a
 * desktop card that shows the terminal on click; terminals without support ignore it.
 */

import { basename } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { assistantText } from "./lib/shared.ts";

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
  // OSC 777 `notify;title;body`: control characters would end the sequence, `;` the title.
  function send(ctx: ExtensionContext, message: string) {
    const clean = (text: string) => text.replace(/\p{Cc}/gu, " ");
    const title = clean(`Pi · ${basename(ctx.cwd) || ctx.cwd}`).replaceAll(";", ",");
    process.stdout.write(`\x1b]777;notify;${title};${clean(message)}\x07`);
  }

  // "Failed: <error>" or "Done: <first line of the final message>", from the last assistant message.
  function outcome(ctx: ExtensionContext): string {
    const last = ctx.sessionManager
      .getBranch()
      .flatMap((entry) => (entry.type === "message" ? [entry.message] : []))
      .filter((message) => message.role === "assistant")
      .at(-1);
    const labeled = (label: string, text: string) =>
      firstLine(text) ? `${label}: ${firstLine(text)}` : label;
    if (last?.role !== "assistant") return "Done";
    if (last.stopReason === "error") return labeled("Failed", last.errorMessage ?? "");
    return labeled("Done", assistantText(last));
  }

  function notify(ctx: ExtensionContext, message: string) {
    if (ctx.mode === "tui") send(ctx, message);
  }

  // Unlike agent_end, this fires only after retries and queued work finish.
  pi.on("agent_settled", (event, ctx) => {
    if (event.aborted) return;
    return notify(ctx, outcome(ctx));
  });

  // Dialogs raised during a run (questions, confirmations) wait for the user; dialogs the
  // user opens with a command while Pi is idle need no notification.
  pi.on("ui_prompt_start", (_event, ctx) => {
    if (!ctx.isIdle()) return notify(ctx, "Input required");
  });
}
