import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Standalone completion notification policy and delivery.
 *
 * ozozka:notification is a generic pi.events publication, not an adapter call.
 * Version 1 carries id/sessionId/title/body/severity/observedAt and
 * desktopDelivered. Consumers can retain it, mark attention, or provide a
 * fallback only when desktop delivery failed. No host negotiation is required,
 * and removing every consumer leaves normal desktop delivery unchanged.
 */
export default function (pi: ExtensionAPI) {
  // Settlement, not agent_end: retries and queued work must finish first.
  pi.on("agent_settled", async (_event, ctx) => {
    if (!ctx.hasUI) return;
    const projectName = basename(ctx.cwd) || ctx.cwd;
    let desktopDelivered = false;
    try {
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
          "Pi",
          "0",
          "",
          projectName,
          "Done",
          "0",
          "0",
          "-1",
        ],
        { timeout: 5000 },
      );
      desktopDelivered = result.code === 0;
    } catch {
      // Delivery failure must never interrupt agent work.
    }
    pi.events.emit("ozozka:notification", {
      version: 1,
      id: randomUUID(),
      sessionId: ctx.sessionManager.getSessionId(),
      observedAt: Date.now(),
      title: projectName,
      body: "Done",
      severity: "info",
      desktopDelivered,
    });
    if (!desktopDelivered)
      ctx.ui.notify("Could not send desktop notification", "warning");
  });
}
