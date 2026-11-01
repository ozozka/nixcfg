/** Offline integration fixture. Explicitly loaded by ERT; never auto-discovered. */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerCommand("frontend-test", {
    description: "Exercise native UI without a provider request",
    handler: async (args, ctx) => {
      if (args === "dialog") {
        const value = await ctx.ui.select("Fixture selection", [
          "Allow",
          "Block",
        ]);
        ctx.ui.notify(`Selected: ${value}`, "info");
      } else {
        ctx.ui.notify("Fixture notification", "info");
        ctx.ui.setStatus("fixture-status", "Custom status retained");
        ctx.ui.setWidget("fixture-widget", [
          "First widget line",
          "Second widget line",
        ]);
        pi.events.emit("ozozka:notification", {
          version: 1,
          id: "fixture-notification",
          sessionId: ctx.sessionManager.getSessionId(),
          title: "Fixture",
          body: "Structured notification retained",
          desktopDelivered: true,
        });
      }
    },
  });
}
