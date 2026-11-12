/**
 * Desktop notifications over D-Bus: "Done" when a run settles, and "Input required" when a
 * dialog waits during a run.
 *
 * Each session keeps one notification and replaces it in place (Notify's replaces_id), since
 * the notification server keeps cards until they are dismissed; a replaced card moves back to
 * the top. Sends are serialized, so a quick second notification still replaces the first.
 */

import { basename } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const NOTIFICATION_ID = /^u (\d+)/;

export default function (pi: ExtensionAPI) {
  // The session's notification ID; 0 creates a new one.
  let cardId = 0;
  let queue = Promise.resolve();

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

  function notify(ctx: ExtensionContext, message: string) {
    if (ctx.mode !== "tui") return;
    queue = queue.then(() => send(ctx, message));
    return queue;
  }

  // A new or resumed session starts its own notification.
  pi.on("session_start", () => {
    cardId = 0;
  });

  // Unlike agent_end, this fires only after retries and queued work finish.
  pi.on("agent_settled", (_event, ctx) => notify(ctx, "Done"));

  // Dialogs raised during a run (questions, confirmations) wait for the user; dialogs the
  // user opens with a command while Pi is idle need no notification.
  pi.on("ui_prompt_start", (_event, ctx) => {
    if (!ctx.isIdle()) return notify(ctx, "Input required");
  });
}
