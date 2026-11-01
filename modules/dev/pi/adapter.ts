/**
 * Native Emacs adapter, protocol v1 (Pi 1.4).
 *
 * Architecture / decisions:
 * - Pi's standard RPC remains the primary transport. This is an explicitly
 *   loaded extension, NOT another agent backend and NOT an auto-loaded plugin.
 * - A private, per-agent Unix socket carries structured telemetry and trust
 *   questions. Stdout belongs exclusively to Pi RPC. Telemetry must never enter
 *   model context or bloat session JSONL via appendEntry/sendMessage.
 * - status.ts and notify.ts publish generic pi.events records and know nothing
 *   about this file. Removing this adapter leaves their standalone UI/delivery.
 * - MY_AGENT_SOCKET/TOKEN are launch-scoped capabilities, not configuration or
 *   secrets stored in Nix. Emacs creates a 0700 directory; hello authenticates the
 *   connection and process. No sockets/processes are started in the factory.
 * - Trust runs BEFORE RPC is bound. Connect lazily in project_trust, respect
 *   saved/global policy, and fail closed. A failed adapter never approves work.
 * - Commands needing ExtensionCommandContext run through /emacs-agent, invoked
 *   by an RPC prompt, NOT through socket callbacks with a stale cached context.
 *   This preserves Pi's cancellation hooks, mutation queues and lifecycle.
 * - Reload/switch replaces extension runtimes. Each runtime has a fresh identity,
 *   subscriptions, socket and context. Cleanup is idempotent; pending questions
 *   resolve as cancelled on disconnect. Never retain old session-bound objects.
 *
 * Wire: strict LF-delimited UTF-8 JSON, not readline (U+2028/2029 are content).
 * Every adapter record has v:1, runtime, seq, type, and optional id/data. Emacs
 * replies with v:1 and matching id. hello additionally carries token and pid.
 * Unknown records/errors remain visible at the frontend. Backpressure uses the
 * socket's ordered write queue; a failed connection is reported, never silently
 * represented as successful delivery. No periodic reconnection or network calls.
 *
 * Limitations: RPC does not execute arbitrary terminal components, custom
 * renderers, terminal input/editor factories or interactive CLI auth screens.
 * Native operations are preferred; deliberate CLI handoff is the last resort.
 * The two channels have independent order: runtime/session identity, rather than
 * arrival timing, binds telemetry to its session. Full raw records are retained.
 */
import { randomUUID } from "node:crypto";
import { createConnection, type Socket } from "node:net";
import { StringDecoder } from "node:string_decoder";
import {
  type ExtensionAPI,
  type ExtensionCommandContext,
  getAgentDir,
  ProjectTrustStore,
  SessionManager,
  SettingsManager,
  VERSION,
} from "@earendil-works/pi-coding-agent";

type RecordData = Record<string, unknown>;
function object(value: unknown): RecordData {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error("Expected an object");
  return value as RecordData;
}
function text(value: unknown): string {
  if (typeof value !== "string" || !value)
    throw new Error("Expected nonempty text");
  return value;
}

export default function (pi: ExtensionAPI) {
  const path = process.env.MY_AGENT_SOCKET ?? "";
  const token = process.env.MY_AGENT_TOKEN;
  if (!path || !token) return;

  const runtime = randomUUID();
  let seq = 0;
  let socket: Socket | undefined;
  let connecting: Promise<boolean> | undefined;
  let authenticated = false;
  let disposed = false;
  let sessionId: string | undefined;
  let lastStatus: unknown;
  const questions = new Map<string, (value: RecordData) => void>();
  const unsubscribe: Array<() => void> = [];

  function send(type: string, data?: unknown, id?: string) {
    if (!authenticated || !socket || socket.destroyed) return false;
    socket.write(
      `${JSON.stringify({ v: 1, runtime, seq: ++seq, type, id, sessionId, data })}\n`,
    );
    return true;
  }

  function cancelQuestions() {
    for (const resolve of questions.values()) resolve({ cancelled: true });
    questions.clear();
  }

  function connect(): Promise<boolean> {
    if (disposed) return Promise.resolve(false);
    if (authenticated) return Promise.resolve(true);
    if (connecting) return connecting;
    connecting = new Promise<boolean>((resolve) => {
      const client = createConnection(path);
      socket = client;
      const decoder = new StringDecoder("utf8");
      let fragment = "";
      let settled = false;
      const finish = (ok: boolean) => {
        if (settled) return;
        settled = true;
        clearTimeout(deadline);
        resolve(ok);
      };
      const deadline = setTimeout(() => {
        client.destroy();
        finish(false);
      }, 5000);
      client.on("connect", () => {
        client.write(
          `${JSON.stringify({ v: 1, type: "hello", runtime, token, pid: process.pid, piVersion: VERSION })}\n`,
        );
      });
      function line(raw: string) {
        try {
          const record = object(JSON.parse(raw.replace(/\r$/, "")));
          if (record.v !== 1) throw new Error("Unsupported adapter protocol");
          if (record.type === "hello" && record.token === token) {
            authenticated = true;
            finish(true);
          } else if (authenticated && typeof record.id === "string") {
            const answer = questions.get(record.id);
            if (answer) {
              questions.delete(record.id);
              answer(record);
            } else
              send("error", { message: "Unmatched adapter response", record });
          } else throw new Error("Unexpected adapter response");
        } catch (error) {
          console.error("Emacs adapter input:", String(error), raw);
        }
      }
      client.on("data", (chunk: Buffer) => {
        fragment += decoder.write(chunk);
        let end = fragment.indexOf("\n");
        while (end !== -1) {
          line(fragment.slice(0, end));
          fragment = fragment.slice(end + 1);
          end = fragment.indexOf("\n");
        }
      });
      client.on("end", () => {
        fragment += decoder.end();
        if (fragment) line(fragment);
      });
      client.on("error", (error) => {
        console.error("Emacs adapter connection:", error.message);
        finish(false);
      });
      client.on("close", () => {
        authenticated = false;
        cancelQuestions();
        finish(false);
      });
    });
    return connecting;
  }

  // Registered before session_start, so startup publication order is irrelevant.
  unsubscribe.push(
    pi.events.on("ozozka:status:update", (data) => {
      lastStatus = data;
      send("status", data);
    }),
  );
  unsubscribe.push(
    pi.events.on("ozozka:notification", (data) => {
      if (!send("notification", data))
        console.error(
          "Emacs adapter notification not forwarded:",
          JSON.stringify(data),
        );
    }),
  );

  pi.on("project_trust", async (event) => {
    const agentDir = getAgentDir();
    const saved = new ProjectTrustStore(agentDir).get(event.cwd);
    if (saved !== null) return { trusted: "undecided" };
    const policy = SettingsManager.create(event.cwd, agentDir, {
      projectTrusted: false,
    }).getDefaultProjectTrust();
    if (policy !== "ask") return { trusted: "undecided" };
    if (!(await connect())) return { trusted: "no" };
    const id = randomUUID();
    const answer = await new Promise<RecordData>((resolve) => {
      questions.set(id, resolve);
      if (!send("trust", { cwd: event.cwd }, id)) {
        questions.delete(id);
        resolve({ cancelled: true });
      }
    });
    return {
      trusted: answer.trusted === true ? "yes" : "no",
      remember: answer.cancelled !== true && answer.remember === true,
    };
  });

  pi.on("session_start", async (_event, ctx) => {
    sessionId = ctx.sessionManager.getSessionId();
    if (!(await connect())) {
      ctx.ui.notify(
        "Emacs adapter unavailable; RPC remains active. Trust is never granted by connection failure.",
        "warning",
      );
      return;
    }
    send("ready", {
      piVersion: VERSION,
      cwd: ctx.cwd,
      sessionFile: ctx.sessionManager.getSessionFile(),
      trusted: ctx.isProjectTrusted(),
      capabilities: [
        "snapshot",
        "sessions",
        "tree",
        "label",
        "reload",
        "tools",
        "trust",
        "status",
        "notification",
      ],
      limitations: [
        "custom terminal components",
        "terminal editor/input factories",
        "interactive CLI login/logout/share/bug",
        "extension-specific argument completion callbacks",
        "runtime import (resume existing Pi JSONL natively instead)",
      ],
    });
    pi.events.emit("ozozka:status:request", { version: 1 });
    if (lastStatus !== undefined) send("status", lastStatus);
  });

  async function command(args: string, ctx: ExtensionCommandContext) {
    const request = object(JSON.parse(args));
    const id = text(request.id);
    const op = text(request.op);
    // Result must precede reload: reload disposes this socket and command ctx.
    if (op === "reload") {
      if (!ctx.isIdle()) throw new Error("Wait until idle before reload");
      send("result", { reloading: true }, id);
      await ctx.reload();
      return;
    }
    let result: unknown;
    switch (op) {
      case "snapshot":
        result = {
          cwd: ctx.cwd,
          trusted: ctx.isProjectTrusted(),
          systemPrompt: ctx.getSystemPrompt(),
          promptOptions: ctx.getSystemPromptOptions(),
          tools: pi.getAllTools(),
          activeTools: pi.getActiveTools(),
          commands: pi.getCommands(),
          settings: pi.getSettings(),
        };
        break;
      case "sessions":
        result = await SessionManager.listAll();
        break;
      case "trust": {
        if (!ctx.isIdle())
          throw new Error("Wait until idle before changing trust");
        if (!["Allow", "Decline", "Forget"].includes(text(request.decision)))
          throw new Error("Expected Allow, Decline or Forget");
        const decision =
          request.decision === "Forget" ? null : request.decision === "Allow";
        new ProjectTrustStore(getAgentDir()).set(ctx.cwd, decision);
        result = { cwd: ctx.cwd, decision, applies: "next process startup" };
        break;
      }
      case "tree":
        if (!ctx.isIdle()) throw new Error("Wait until idle before navigating");
        result = await ctx.navigateTree(text(request.entryId), {
          summarize: request.summarize === true,
          customInstructions:
            typeof request.instructions === "string"
              ? request.instructions
              : undefined,
        });
        break;
      case "label":
        pi.setLabel(
          text(request.entryId),
          typeof request.label === "string" ? request.label : undefined,
        );
        result = { labelled: true };
        break;
      case "tools":
        if (!ctx.isIdle())
          throw new Error("Wait until idle before changing tools");
        if (
          !Array.isArray(request.names) ||
          !request.names.every((name) => typeof name === "string")
        )
          throw new Error("Expected tool names");
        pi.setActiveTools(request.names);
        result = pi.getActiveTools();
        break;
      case "complete": {
        // Pi's public command inventory omits argument-completion callbacks.
        // Do not claim support or reach into ExtensionRunner's private state.
        throw new Error(
          "Extension argument completion is not exposed by Pi's public RPC/extension API",
        );
      }
      case "import": {
        if (!ctx.isIdle()) throw new Error("Wait until idle before importing");
        // Runtime import isn't exposed to extensions. Do not rewrite session
        // JSONL behind Pi's back; explain the supported CLI path instead.
        throw new Error(
          "Import requires a Pi runtime API not exposed to extensions; resume an existing Pi JSONL with /resume, or use explicit CLI handoff /import.",
        );
      }
      default:
        throw new Error(`Unknown adapter operation: ${op}`);
    }
    send("result", result, id);
  }

  pi.registerCommand("emacs-agent", {
    description: "Private native frontend operation (not sent to the model)",
    handler: async (args, ctx) => {
      let id: string | undefined;
      try {
        id = text(object(JSON.parse(args)).id);
        await command(args, ctx);
      } catch (error) {
        if (!send("failure", { message: String(error) }, id))
          ctx.ui.notify(`Emacs adapter: ${String(error)}`, "error");
      }
    },
  });

  pi.on("session_shutdown", () => {
    if (disposed) return;
    disposed = true;
    cancelQuestions();
    for (const off of unsubscribe) off();
    socket?.end();
    // end() flushes the ordered write queue, unlike destroy().
    socket?.unref();
    socket = undefined;
  });
}
