/**
 * Code shared by the Pi extensions in the folder above. Not an extension itself: Pi loads the
 * .ts files directly in extensions/ and folders with an index file, so lib/ is skipped.
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  type ExtensionContext,
  getAgentDir,
  type Theme,
} from "@earendil-works/pi-coding-agent";

export type ThemeColor = Parameters<Theme["fg"]>[0];
export type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;

// Event bus: extensions send status line segments to status.ts through this channel.

const STATUS_CHANNEL = "status";

// A part of the status line (status.ts), ordered by key. Without render, the segment is
// removed; spinner colors the working spinner (the first segment by key that sets one wins).
export interface StatusSegment {
  key: string;
  render?: (theme: Theme) => string;
  spinner?: ThemeColor;
}

export function sendStatus(pi: ExtensionAPI, segment: StatusSegment) {
  pi.events.emit(STATUS_CHANNEL, segment);
}

export function onStatus(pi: ExtensionAPI, handler: (segment: StatusSegment) => void) {
  pi.events.on(STATUS_CHANNEL, (data) => handler(data as StatusSegment));
}

// Sessions and messages

// The project root: the nearest directory with .git (a directory, or a file in worktrees),
// else the directory itself.
export function projectRoot(cwd: string): string {
  const start = resolve(cwd);
  for (let directory = start; ; directory = dirname(directory)) {
    if (existsSync(join(directory, ".git"))) return directory;
    if (dirname(directory) === directory) return start;
  }
}

// The data of the latest custom entry of a type on the current branch.
export function lastEntry<T>(ctx: ExtensionContext, customType: string): T | undefined {
  let data: T | undefined;
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type === "custom" && entry.customType === customType) data = entry.data as T;
  }
  return data;
}

// The text parts of an assistant message, one per line.
export function assistantText(message: AssistantMessage): string {
  return message.content
    .flatMap((part) => (part.type === "text" ? [part.text] : []))
    .join("\n");
}

// A tool result with one text part.
export function reply<T>(text: string, details: T, isError = false) {
  const content = [{ type: "text" as const, text }];
  return isError ? { content, details, isError } : { content, details };
}

const TRAILING_ZERO = /\.0$/;

export function formatTokens(count: number): string {
  if (count < 1000) return String(count);
  if (count < 10_000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1_000_000) return `${Math.round(count / 1000)}k`;
  return `${(count / 1_000_000).toFixed(1).replace(TRAILING_ZERO, "")}M`;
}

// Definition files: Markdown with frontmatter in a folder under Pi's agent directory (modes/,
// agents/). Field checks throw messages naming the key, so a bad file explains itself.

const THINKING_LEVELS: readonly string[] = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
];

// Parses each .md file in the folder, in name order, into a map keyed by the file name; errors
// are collected for a startup warning instead of stopping the load.
export function loadDefinitions<T>(
  folder: string,
  parse: (content: string, name: string) => T,
): { definitions: Map<string, T>; errors: string[] } {
  const dir = join(getAgentDir(), folder);
  const definitions = new Map<string, T>();
  const errors: string[] = [];
  let files: string[] = [];
  try {
    files = readdirSync(dir).filter((file) => file.endsWith(".md"));
  } catch {
    errors.push(`no ${folder} directory at ${dir}`);
  }
  for (const file of files.sort()) {
    try {
      const name = basename(file, ".md");
      definitions.set(name, parse(readFileSync(join(dir, file), "utf8"), name));
    } catch (error) {
      errors.push(`${file}: ${(error as Error).message}`);
    }
  }
  return { definitions, errors };
}

// Unknown keys are errors, so typos do not pass silently.
export function rejectUnknown(rest: object) {
  const extra = Object.keys(rest);
  if (extra.length > 0) throw new Error(`unknown keys: ${extra.join(", ")}`);
}

export function requiredText(value: unknown, key: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${key} is required`);
  return value.trim();
}

// Accepts both YAML spellings: `key: a, b` and `key: [a, b]`.
export function optionalList(value: unknown, key: string): string[] | undefined {
  if (value === undefined) return undefined;
  const list = typeof value === "string" ? value.split(",") : value;
  if (!(Array.isArray(list) && list.every((item) => typeof item === "string")))
    throw new Error(`${key} must be a comma-separated string or a list`);
  return list.map((item) => item.trim()).filter(Boolean);
}

export function optionalThinking(value: unknown): ThinkingLevel | undefined {
  if (value !== undefined && !THINKING_LEVELS.includes(String(value)))
    throw new Error(`thinking must be one of: ${THINKING_LEVELS.join(", ")}`);
  return value as ThinkingLevel | undefined;
}
