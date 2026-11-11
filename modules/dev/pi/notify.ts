import { basename } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  async function notify(ctx: ExtensionContext, message: string) {
    if (ctx.mode !== "tui") return;

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
          "0", // Create a new notification.
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
      }
    } catch {
      // A missing bus or notification service must not interrupt the agent.
      ctx.ui.notify("Could not send desktop notification", "warning");
    }
  }

  // Unlike agent_end, this fires only after retries and queued work finish.
  pi.on("agent_settled", (_event, ctx) => notify(ctx, "Done"));

  // Dialogs raised during a run (questions, confirmations) wait for the user; dialogs the
  // user opens with a command while Pi is idle need no notification.
  pi.on("ui_prompt_start", (_event, ctx) => {
    if (!ctx.isIdle()) return notify(ctx, "Input required");
  });
}
