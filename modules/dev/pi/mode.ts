/**
 * Named modes and the roadmap.
 *
 * Modes: each sets the thinking level, removes tools, and appends instructions to the system
 * prompt. The default mode, free, is the normal settings. Entering a mode saves the current
 * tools and thinking level; leaving restores them. The mode starts the status line
 * (status.ts) in bold, in its color; Shift+Tab cycles the modes by their order.
 *
 * Modes are Markdown files in modes/ under Pi's agent directory, loaded at startup: the file
 * name is the mode name, the frontmatter its settings (including `order` and the status
 * `color`), and the body its instructions. A mode with `next` asks, when a run wrote a plan
 * that still has open steps, whether to switch to that mode and send `next-prompt`, where
 * `{plan}` stands for the plan's name. The mode state is recorded in the session on every
 * switch and restored from the current branch, so resuming or navigating with /tree brings
 * back the matching mode. Derived from the Pi preset example.
 *
 * Roadmap: the only place for task organization, in every mode. The `roadmap` tool writes plans
 * to the project's roadmap board and ticks their steps (see Roadmap board below). Each session
 * focuses one plan (`/roadmap`), which the widget below the editor shows while it has open
 * steps and compaction re-sends to the model. Derived from the Pi todo example.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { StringEnum } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  type ExtensionContext,
  parseFrontmatter,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import { Key, Text } from "@earendil-works/pi-tui";
import { type Static, Type } from "typebox";
import {
  assistantText,
  lastEntry,
  loadDefinitions,
  loadMarkdown,
  type Notice,
  optionalList,
  optionalText,
  optionalThinking,
  projectRoot,
  rejectUnknown,
  reply,
  requiredText,
  sendNotice,
  sendStatus,
  type ThinkingLevel,
} from "./lib/shared.ts";

// Modes

const MODE_ENTRY = "mode";
// The default mode: no mode file, the normal settings.
const FREE = "free";
const FREE_COLOR = "text";
// Theme colors a mode can use in the status line.
const COLORS = ["text", "muted", "dim", "accent", "success", "warning", "error"] as const;
type Color = (typeof COLORS)[number];
const TRAILING_PERIOD = /\.$/;
const PLAN_PLACEHOLDER = "{plan}";
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
  "auto-continue"?: unknown;
};

// Validates one mode file.
function parseMode(content: string, name: string): Mode {
  if (name === FREE) throw new Error(`"${FREE}" is the default mode`);
  const { frontmatter, body } = parseFrontmatter<ModeFrontmatter>(content);
  const {
    description,
    order,
    color = "text",
    thinking,
    "exclude-tools": exclude,
    next,
    "next-prompt": nextPrompt,
    "auto-continue": autoContinue = false,
    ...unknown
  } = frontmatter;
  rejectUnknown(unknown);
  if (order !== undefined && typeof order !== "number")
    throw new Error("order must be a number");
  if (!COLORS.includes(color as Color))
    throw new Error(`color must be one of: ${COLORS.join(", ")}`);
  if (typeof autoContinue !== "boolean") throw new Error("auto-continue must be true or false");
  if ((next === undefined) !== (nextPrompt === undefined))
    throw new Error("next and next-prompt go together");
  return {
    description: requiredText(description, "description"),
    order,
    color: color as Color,
    thinkingLevel: optionalThinking(thinking),
    excludeTools: optionalList(exclude, "exclude-tools") ?? [],
    next: optionalText(next, "next"),
    nextPrompt: optionalText(nextPrompt, "next-prompt"),
    autoContinue,
    instructions: requiredText(body, "the instructions (body)"),
  };
}

function loadModes(): { modes: Map<string, Mode>; errors: string[] } {
  const { definitions: modes, errors } = loadDefinitions("modes", parseMode);
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

// Roadmap board: finding, reading, and changing plans in Markdown. A board is six sibling
// headings: Status, Limitations, Backlog, Plans, Active, and Completed. It is docs/roadmap.md or
// the Roadmap section of README.md when they already have Plans, Active, and Completed;
// otherwise a root roadmap.md, created on the first save. Changes add missing sections in
// order. Plans are headings one level below their section, and their steps are
// `- [ ] **1. Title**` lines (ticked with `[x]`). Only Backlog, Plans, Active, and Completed are
// parsed; edits touch only their lines and the blank lines next to them. Changes return a new
// Board; nothing is written until `saveBoard`.

interface Step {
  number: number;
  title: string;
  done: boolean;
  // Line index in the board file.
  line: number;
}

type SectionName = "Status" | "Limitations" | "Backlog" | "Plans" | "Active" | "Completed";

interface Plan {
  name: string;
  section: "Plans" | "Active";
  // Line range in the board file, heading included, end exclusive.
  start: number;
  end: number;
  steps: Step[];
}

interface Range {
  start: number;
  end: number;
}

interface Board {
  path: string;
  // The file does not exist yet; saveBoard creates it.
  created: boolean;
  lines: string[];
  // The part of the file that holds the board, and the heading level of its sections.
  container: Range;
  level: number;
  sections: Map<SectionName, Range>;
  plans: Plan[];
}

interface Heading {
  line: number;
  level: number;
  text: string;
}

const HEADING = /^(#{1,6})\s+(.*?)\s*#*\s*$/;
const FENCE = /^\s*(```|~~~)/;
const STEP = /^\s*- \[([ xX])\] \*\*(\d+)\.\s*(.*?)\*\*/;
const UNTICKED = /- \[ \]/;
const STEPS_GROUP = /^- \*\*Steps\*\*/;
const TRAILING_SPACE = /\s+$/;
// A lone "- No plans recorded." style line in an otherwise empty section.
const PLACEHOLDER = /^- (No|None)\b/;
const BULLET = /^- /;
const SECTION_NAMES: readonly SectionName[] = [
  "Status",
  "Limitations",
  "Backlog",
  "Plans",
  "Active",
  "Completed",
];
// The sections that make an existing document a board.
const REQUIRED: SectionName[] = ["Plans", "Active", "Completed"];
const ROADMAP_FILE = "roadmap.md";
const ROADMAP_TEMPLATE = `# Roadmap\n\n${SECTION_NAMES.map((name) => `## ${name}`).join("\n\n")}\n`;

function headings(lines: string[]): Heading[] {
  const found: Heading[] = [];
  let fenced = false;
  for (const [line, text] of lines.entries()) {
    if (FENCE.test(text)) fenced = !fenced;
    const match = fenced ? null : HEADING.exec(text);
    if (match) found.push({ line, level: match[1].length, text: match[2] });
  }
  return found;
}

// End of the section under `heading`: the next heading at the same or a higher level.
function sectionEnd(all: Heading[], heading: Heading, limit: number): number {
  const next = all.find((h) => h.line > heading.line && h.level <= heading.level);
  return Math.min(next?.line ?? limit, limit);
}

function isReadme(path: string): boolean {
  return basename(path) === "README.md";
}

// The part of the file that holds the board: README's Roadmap section, or the whole file.
function container(path: string, lines: string[], all: Heading[]): Range | undefined {
  if (!isReadme(path)) return { start: 0, end: lines.length };
  const roadmap = all.find((h) => h.text.toLowerCase() === "roadmap");
  return roadmap && { start: roadmap.line, end: sectionEnd(all, roadmap, lines.length) };
}

// Parses the board sections in a file's lines; some may be missing. Undefined for a README
// without a Roadmap section.
function parseBoard(path: string, lines: string[], created = false): Board | undefined {
  const all = headings(lines);
  const range = container(path, lines, all);
  if (!range) return undefined;
  const inside = all.filter((h) => h.line > range.start && h.line < range.end);
  const named = inside.filter((h) => SECTION_NAMES.includes(h.text as SectionName));
  // Without sections yet: one level below the README's Roadmap heading or the file's title.
  const parent = isReadme(path) ? all.find((h) => h.line === range.start) : all[0];
  const level =
    named.length > 0 ? Math.min(...named.map((h) => h.level)) : (parent?.level ?? 1) + 1;
  const sections = new Map<SectionName, Range>();
  for (const heading of named.filter((h) => h.level === level)) {
    const end = sectionEnd(all, heading, range.end);
    sections.set(heading.text as SectionName, { start: heading.line, end });
  }

  const plans: Plan[] = [];
  for (const section of ["Plans", "Active"] as const) {
    const sectionRange = sections.get(section);
    if (!sectionRange) continue;
    const { start, end } = sectionRange;
    for (const heading of all) {
      if (heading.line <= start || heading.line >= end || heading.level !== level + 1) continue;
      const planEnd = sectionEnd(all, heading, end);
      const steps: Step[] = [];
      for (let line = heading.line + 1; line < planEnd; line++) {
        const match = STEP.exec(lines[line]);
        if (!match) continue;
        const done = match[1] !== " ";
        steps.push({ number: Number(match[2]), title: match[3].trim(), done, line });
      }
      plans.push({ name: heading.text, section, start: heading.line, end: planEnd, steps });
    }
  }
  return { path, created, lines, container: range, level, sections, plans };
}

const hasBoard = (board: Board) => REQUIRED.every((name) => board.sections.has(name));

// Finds the board: an existing one in docs/roadmap.md or README.md, else the root roadmap.md,
// which may not exist yet or may still miss sections (ensureSections adds them).
function findBoard(cwd: string): Board {
  const root = projectRoot(cwd);
  for (const path of [join(root, "docs", "roadmap.md"), join(root, "README.md")]) {
    if (!existsSync(path)) continue;
    const board = parseBoard(path, readFileSync(path, "utf8").split("\n"));
    if (board && hasBoard(board)) return board;
  }
  const path = join(root, ROADMAP_FILE);
  if (existsSync(path))
    return parseBoard(path, readFileSync(path, "utf8").split("\n")) as Board;
  return parseBoard(path, ROADMAP_TEMPLATE.split("\n"), true) as Board;
}

function saveBoard(board: Board) {
  writeFileSync(board.path, board.lines.join("\n"));
}

// Parses edited lines; a board that lost its sections (or, while sections are still being
// added, its container) is an error, so nothing broken is written.
function reparse(board: Board, lines: string[], complete = true): Board {
  const parsed = parseBoard(board.path, lines, board.created);
  if (!(parsed && (!complete || hasBoard(parsed))))
    throw new Error("the board was lost while editing; nothing was written");
  return parsed;
}

// Replaces lines [start, end) with `insert`, keeping one blank line on each side of it.
function splice(lines: string[], start: number, end: number, insert: string[]): string[] {
  const before = lines.slice(0, start);
  const after = lines.slice(end);
  while (before.length > 0 && before.at(-1)?.trim() === "") before.pop();
  while (after.length > 0 && after[0].trim() === "") after.shift();
  const block = insert.length > 0 ? ["", ...insert] : [];
  // A board at the end of the file keeps its final newline.
  return [...before, ...block, "", ...after];
}

// The end of a range without its trailing blank lines.
function contentEnd(lines: string[], range: Range): number {
  let end = range.end;
  while (end > range.start + 1 && lines[end - 1].trim() === "") end--;
  return end;
}

// Appends a block to the end of a section, replacing a lone placeholder line.
function appendToSection(lines: string[], range: Range, block: string[]): string[] {
  const end = contentEnd(lines, range);
  const body = lines.slice(range.start + 1, end).filter((line) => line.trim() !== "");
  const lonePlaceholder = body.length === 1 && PLACEHOLDER.test(body[0]);
  return splice(lines, lonePlaceholder ? range.start + 1 : end, end, block);
}

// Adds missing sections in their order: before the next existing one, else after the board.
function ensureSections(board: Board): Board {
  let current = board;
  for (const [index, name] of SECTION_NAMES.entries()) {
    if (current.sections.has(name)) continue;
    const heading = `${"#".repeat(current.level)} ${name}`;
    const { sections } = current;
    const later = SECTION_NAMES.slice(index + 1)
      .map((next) => sections.get(next))
      .find((range) => range !== undefined);
    const at = later ? later.start : contentEnd(current.lines, current.container);
    current = reparse(current, splice(current.lines, at, at, [heading]), false);
  }
  return current;
}

function findPlan(board: Board, name: string): Plan | undefined {
  const wanted = name.trim().toLowerCase();
  return board.plans.find((plan) => plan.name.toLowerCase() === wanted);
}

// The plan to work on: the named one, else the session's focus, else the only active one.
function currentPlan(board: Board, name?: string, focus?: string): Plan | undefined {
  if (name) return findPlan(board, name);
  const focused = focus ? findPlan(board, focus) : undefined;
  if (focused) return focused;
  const active = board.plans.filter((plan) => plan.section === "Active");
  return active.length === 1 ? active[0] : undefined;
}

// Plan content: a leading heading is dropped; it needs a Steps group with steps numbered from 1.
function planBody(content: string): string[] {
  const lines = content.replace(TRAILING_SPACE, "").split("\n");
  while (lines.length > 0 && (lines[0].trim() === "" || HEADING.test(lines[0]))) lines.shift();
  if (!lines.some((line) => STEPS_GROUP.test(line)))
    throw new Error("the plan needs a `- **Steps**:` group");
  const steps = lines.map((line) => STEP.exec(line)).filter((match) => match !== null);
  if (steps.length === 0)
    throw new Error("the plan needs at least one `- [ ] **1. Title**` step");
  for (const [index, match] of steps.entries()) {
    if (Number(match[2]) !== index + 1)
      throw new Error(`steps must be numbered 1, 2, 3, ...; step ${index + 1} is ${match[2]}`);
  }
  if (lines.some((line) => HEADING.test(line)))
    throw new Error("the plan body must be bullets, without headings");
  return lines;
}

// Writes a new plan to Plans, or replaces the body of an existing plan where it is.
function writePlan(board: Board, name: string, content: string): Board {
  const title = name.trim();
  if (!title || title.includes("\n") || title.startsWith("#"))
    throw new Error("the plan needs a plain, one-line name");
  const body = planBody(content);
  const existing = findPlan(board, title);
  const heading = `${"#".repeat(board.level + 1)} ${existing?.name ?? title}`;
  const block = [heading, "", ...body];
  if (existing) return reparse(board, splice(board.lines, existing.start, existing.end, block));
  return reparse(
    board,
    appendToSection(board.lines, board.sections.get("Plans") as Range, block),
  );
}

// Moves a plan from Plans to the end of Active.
function startPlan(board: Board, plan: Plan): Board {
  if (plan.section === "Active") return board;
  const block = board.lines.slice(plan.start, contentEnd(board.lines, plan));
  const removed = reparse(board, splice(board.lines, plan.start, plan.end, []));
  const active = removed.sections.get("Active") as Range;
  return reparse(removed, appendToSection(removed.lines, active, block));
}

// Ticks a step, starting the plan first when it is still in Plans.
function tickStep(board: Board, plan: Plan, number: number): Board {
  if (!plan.steps.some((s) => s.number === number))
    throw new Error(`plan "${plan.name}" has no step ${number}`);
  const started = startPlan(board, plan);
  const step = (findPlan(started, plan.name) as Plan).steps.find((s) => s.number === number);
  if (!step || step.done) return started;
  const lines = [...started.lines];
  lines[step.line] = lines[step.line].replace(UNTICKED, "- [x]");
  return reparse(started, lines);
}

// Replaces a finished plan with one Completed line per delivered capability.
function completePlan(board: Board, plan: Plan, delivered: string[]): Board {
  const open = plan.steps.filter((step) => !step.done).map((step) => step.number);
  if (open.length > 0) throw new Error(`steps not ticked yet: ${open.join(", ")}`);
  const entries = delivered.map((line) => line.trim().replace(BULLET, "")).filter(Boolean);
  if (entries.length === 0) throw new Error("name at least one delivered capability");
  const removed = reparse(board, splice(board.lines, plan.start, plan.end, []));
  return appendItems(removed, "Completed", entries);
}

// Appends one-line bullets to a list section such as Backlog or Completed.
function appendItems(board: Board, section: SectionName, entries: string[]): Board {
  const block = entries.map((entry) => `- ${entry}`);
  const range = board.sections.get(section) as Range;
  const end = contentEnd(board.lines, range);
  const items = board.lines
    .slice(range.start + 1, end)
    .filter((line) => line.startsWith("- ") && !PLACEHOLDER.test(line));
  if (items.length === 0) return reparse(board, appendToSection(board.lines, range, block));
  // The entries form one list: append directly after the last one.
  return reparse(board, [...board.lines.slice(0, end), ...block, ...board.lines.slice(end)]);
}

// Adds an idea to Backlog as one line.
function addBacklog(board: Board, idea: string): Board {
  const entry = idea.trim().replace(BULLET, "");
  if (!entry || entry.includes("\n")) throw new Error("the idea needs one line of text");
  return appendItems(board, "Backlog", [entry]);
}

function planText(board: Board, plan: Plan): string {
  return board.lines.slice(plan.start, contentEnd(board.lines, plan)).join("\n");
}

// Roadmap tool

const ROADMAP_TOOL = "roadmap";
// Session entries recording the focused plan.
const FOCUS_ENTRY = "roadmap-focus";
const ROADMAP_ACTIONS = ["show", "backlog", "write", "focus", "tick", "complete"] as const;

const roadmapText = loadMarkdown(new URL("./roadmap.md", import.meta.url), [
  "plan",
  "content",
  "idea",
  "step",
  "delivered",
  "reminder",
]);
const help = roadmapText.fields;

// These zero-argument templates are also native /commands. Reading their bodies here
// keeps rendering independent of delivery: continuation must not start a new user turn.
const continuePrompt = loadMarkdown(new URL("./prompts/continue-plan.md", import.meta.url), [
  "description",
]).body;
const finishPrompt = loadMarkdown(new URL("./prompts/finish-plan.md", import.meta.url), [
  "description",
]).body;

const RoadmapParams = Type.Object({
  action: StringEnum(ROADMAP_ACTIONS),
  plan: Type.Optional(Type.String({ description: help.plan })),
  content: Type.Optional(Type.String({ description: help.content })),
  idea: Type.Optional(Type.String({ description: help.idea })),
  step: Type.Optional(Type.Number({ description: help.step })),
  delivered: Type.Optional(Type.Array(Type.String(), { description: help.delivered })),
});

interface BoardLocation {
  path: string;
  commitEligible: boolean;
}

interface RoadmapDetails {
  board?: BoardLocation;
  error?: string;
}

// HEAD, not the index: staging a new local board must not make it commit-eligible.
// No HEAD, Git unavailable, or a failed lookup leaves a fallback board local-only.
function boardLocation(cwd: string, path: string): BoardLocation {
  const root = projectRoot(cwd);
  const where = relative(root, path);
  if (where === "README.md" || where.startsWith("docs/"))
    return { path: where, commitEligible: true };
  try {
    execFileSync("git", ["cat-file", "-e", `HEAD:${where}`], {
      cwd: root,
      stdio: "ignore",
      timeout: 5000,
    });
    return { path: where, commitEligible: true };
  } catch {
    return { path: where, commitEligible: false };
  }
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

// Runs a roadmap action and returns the message for the model, the session's focus afterwards
// (null clears it), and a notice for the desktop.
function roadmapAction(
  cwd: string,
  params: Static<typeof RoadmapParams>,
  focus: string | undefined,
): { text: string; board: BoardLocation; focus?: string | null; notice?: Notice } {
  let board = findBoard(cwd);
  // Changes complete the board's sections first.
  if (params.action !== "show") board = ensureSections(board);
  const location = boardLocation(cwd, board.path);
  const where = location.path;
  const target = () => {
    const plan = currentPlan(board, params.plan, focus);
    if (!plan)
      throw new Error(
        params.plan ? `no plan named "${params.plan}"` : "no focused plan; name the plan",
      );
    return plan;
  };
  switch (params.action) {
    case "show": {
      const plan = currentPlan(board, params.plan, focus);
      const text = plan ? `\n\nFocused plan:\n${planText(board, plan)}` : "";
      return { text: `${boardOverview(board)}${text}`, board: location };
    }
    case "backlog": {
      if (!params.idea) throw new Error("backlog needs idea");
      board = addBacklog(board, params.idea);
      saveBoard(board);
      return { text: `Added to Backlog in ${where}.`, board: location };
    }
    case "write": {
      if (!(params.plan && params.content)) throw new Error("write needs plan and content");
      board = writePlan(board, params.plan, params.content);
      saveBoard(board);
      const plan = currentPlan(board, params.plan) as Plan;
      return {
        text: `Plan "${plan.name}" written to ${plan.section} in ${where}, and focused.`,
        board: location,
        focus: plan.name,
      };
    }
    case "focus": {
      if (!params.plan) throw new Error("focus needs plan");
      const plan = target();
      const text = `Focused plan "${plan.name}" (${progress(plan)} steps done).`;
      return { text, board: location, focus: plan.name };
    }
    case "tick": {
      if (params.step === undefined) throw new Error("tick needs step");
      board = tickStep(board, target(), params.step);
      saveBoard(board);
      const plan = currentPlan(board, params.plan, focus) as Plan;
      const next = plan.steps.find((step) => !step.done);
      const rest = next ? ` Next: ${next.number}. ${next.title}` : " All steps are done.";
      const title = plan.steps.find((step) => step.number === params.step)?.title ?? "";
      const text = `Step ${params.step} ticked (${progress(plan)}).${rest}`;
      const notice = { message: `Step ${params.step}/${plan.steps.length} done: ${title}` };
      return { text, board: location, notice };
    }
    case "complete": {
      const plan = target();
      board = completePlan(board, plan, params.delivered ?? []);
      saveBoard(board);
      const cleared = focus?.toLowerCase() === plan.name.toLowerCase();
      const text = `Plan "${plan.name}" completed in ${where}.`;
      const notice = { message: `Plan "${plan.name}" completed`, final: true };
      return { text, board: location, focus: cleared ? null : undefined, notice };
    }
    default:
      throw new Error(`unknown action ${params.action}`);
  }
}

// The plan the widget and the mode checks follow, with its board; undefined without a plan on
// a readable board.
function trackedPlan(
  cwd: string,
  focus: string | undefined,
): { board: Board; plan: Plan } | undefined {
  try {
    const board = findBoard(cwd);
    const plan = board.created ? undefined : currentPlan(board, undefined, focus);
    return plan && { board, plan };
  } catch {
    return undefined;
  }
}

// Asks the user to pick one of the labeled values; undefined when cancelled.
async function pick<T>(
  ctx: ExtensionContext,
  title: string,
  entries: [label: string, value: T][],
): Promise<{ value: T } | undefined> {
  const choice = await ctx.ui.select(
    title,
    entries.map(([label]) => label),
  );
  const entry = entries.find(([label]) => label === choice);
  return entry && { value: entry[1] };
}

export default function (pi: ExtensionAPI) {
  const { modes, errors } = loadModes();
  let state: ModeState = {};
  // A plan was written in the current run; modes offer `next` only then.
  let planWritten = false;
  // The roadmap plan this session works on, recorded in the session (see setFocus).
  let focus: string | undefined;

  const isModeName = (value: unknown): value is string =>
    typeof value === "string" && modes.has(value);
  const currentMode = () => (state.name ? modes.get(state.name) : undefined);

  // Roadmap

  // Shows the focused plan while it has open steps: a header like a Markdown heading (the name
  // bold, its progress muted) and checkboxes as markdown-ts-mode shows them in Emacs
  // (my-modes.el, my-theme.el): a bold ✔ in the primary color (success), a bold ⬦ in the
  // secondary color (warning), and ◆, the filled ⬦, for the next step.
  function updateWidget(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;
    const theme = ctx.ui.theme;
    const plan = trackedPlan(ctx.cwd, focus)?.plan;
    const next = plan?.steps.find((step) => !step.done);
    const lines =
      plan && next
        ? [
            `${theme.bold(plan.name)} ${theme.fg("muted", progress(plan))}`,
            ...plan.steps.map((step) => {
              const mark = step.done ? "✔" : step === next ? "◆" : "⬦";
              const box = theme.bold(theme.fg(step.done ? "success" : "warning", mark));
              // Bold like the step's `**1. Title**` in the roadmap file.
              return `${box} ${theme.bold(`${step.number}. ${step.title}`)}`;
            }),
          ]
        : undefined;
    ctx.ui.setWidget(ROADMAP_TOOL, lines, {
      placement: "belowEditor",
    });
  }

  function setFocus(ctx: ExtensionContext, name: string | undefined) {
    if (name === focus) return;
    focus = name;
    pi.appendEntry(FOCUS_ENTRY, { plan: name ?? null });
    updateWidget(ctx);
  }

  function restoreFocus(ctx: ExtensionContext) {
    const plan = lastEntry<{ plan?: unknown }>(ctx, FOCUS_ENTRY)?.plan;
    focus = typeof plan === "string" ? plan : undefined;
    updateWidget(ctx);
  }

  // The summary replaces earlier roadmap calls in the model's context, so the focused plan is
  // re-sent, read from the board.
  pi.on("session_compact", (_event, ctx) => {
    const tracked = trackedPlan(ctx.cwd, focus);
    if (!tracked?.plan.steps.some((step) => !step.done)) return;
    const reminder = help.reminder.replaceAll("{plan}", planText(tracked.board, tracked.plan));
    pi.sendMessage(
      { customType: "roadmap-reminder", content: reminder, display: false },
      // Mid-run compaction reaches the next model call; manual /compact the next prompt.
      { deliverAs: ctx.isIdle() ? "nextTurn" : "steer" },
    );
  });

  pi.registerTool({
    name: ROADMAP_TOOL,
    label: "Roadmap",
    description: roadmapText.body,
    parameters: RoadmapParams,

    // biome-ignore lint/suspicious/useAwait: Pi's tool API requires a Promise.
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      try {
        const result = roadmapAction(ctx.cwd, params, focus);
        if (result.focus !== undefined) setFocus(ctx, result.focus ?? undefined);
        if (result.notice) sendNotice(pi, result.notice);
        if (params.action === "write") planWritten = true;
        updateWidget(ctx);
        const status = result.board.commitEligible ? "commit-eligible" : "local-only";
        return reply(`Board: ${result.board.path} (${status}).\n${result.text}`, {
          board: result.board,
        } satisfies RoadmapDetails);
      } catch (error) {
        const message = (error as Error).message;
        return reply(
          `Error: ${message}. The board was not changed.`,
          { error: message } satisfies RoadmapDetails,
          true,
        );
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

  // Sends the mode to status.ts, which starts its status line with it (segments sort by key).
  function updateStatus() {
    const mode = currentMode();
    const name = state.name ?? FREE;
    const color = mode?.color ?? FREE_COLOR;
    sendStatus(pi, {
      key: MODE_ENTRY,
      render: (theme: Theme) => theme.bold(theme.fg(color, name)),
      // The working spinner takes the mode color too.
      spinner: color,
    });
  }

  // Applies a target state: the mode's settings, or the saved ones when leaving a mode.
  function apply(ctx: ExtensionContext, next: ModeState) {
    const mode = next.name ? modes.get(next.name) : undefined;
    if (mode && next.saved) {
      const tools = next.saved.tools.filter((tool) => !mode.excludeTools.includes(tool));
      pi.setActiveTools(tools);
      pi.setThinkingLevel(mode.thinkingLevel ?? next.saved.thinkingLevel);
    } else if (state.saved) {
      pi.setActiveTools(state.saved.tools);
      pi.setThinkingLevel(state.saved.thinkingLevel);
    }
    state = mode ? next : {};
    updateStatus();
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
    const recorded = lastEntry<ModeState>(ctx, MODE_ENTRY) ?? {};
    // A mode removed since it was recorded counts as free.
    if (isModeName(recorded.name) && recorded.saved) apply(ctx, recorded);
    else if (state.name) apply(ctx, {});
    else updateStatus();
  }

  pi.on("session_start", (_event, ctx) => {
    if (errors.length > 0) ctx.ui.notify(`Modes: ${errors.join("; ")}`, "warning");
    restoreFocus(ctx);
    restoreMode(ctx);
  });
  pi.on("session_tree", (_event, ctx) => {
    restoreFocus(ctx);
    restoreMode(ctx);
  });

  pi.on("agent_settled", async (event, ctx) => {
    const mode = currentMode();
    updateWidget(ctx);
    if (!(mode?.next && mode.nextPrompt) || event.aborted || !ctx.hasUI) return;
    const plan = planWritten ? trackedPlan(ctx.cwd, focus)?.plan : undefined;
    if (!plan?.steps.some((step) => !step.done)) return;
    const { next } = mode;
    // `{plan}` in next-prompt names the plan, so the message and the focus agree.
    const nextPrompt = mode.nextPrompt.replaceAll(PLAN_PLACEHOLDER, plan.name);
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

  const snapshot = (plan: Plan | undefined) => ({
    plan: plan?.name,
    done: plan?.steps.filter((step) => step.done).length ?? 0,
  });

  pi.on("agent_before_settle", (event, ctx) => {
    if (!currentMode()?.autoContinue || event.outcome !== "completed") return;
    const plan = trackedPlan(ctx.cwd, focus)?.plan;
    const previous = baseline;
    baseline = snapshot(plan);
    if (!plan) return;
    const stop = (reason: string) => ctx.ui.notify(`Exec stopped: ${reason}`, "info");

    const last = event.context.llmMessages.filter((entry) => entry.role === "assistant").at(-1);
    const text = last?.role === "assistant" ? assistantText(last) : "";
    // A stop the user should see on the card; a run that ticks nothing usually asks something,
    // which notify.ts's "Done" summary already shows.
    const alert = (notice: string) => sendNotice(pi, { message: notice, final: true });
    if (BLOCKED.test(text)) {
      alert(text.trim().split("\n")[0]);
      return stop("blocked");
    }
    if (continuations >= AUTO_CONTINUE_LIMIT) {
      alert(`Stopped after ${AUTO_CONTINUE_LIMIT} continuations`);
      return stop(`${AUTO_CONTINUE_LIMIT} continuations`);
    }

    let message: string;
    if (plan.steps.some((step) => !step.done)) {
      if (previous.plan !== plan.name || baseline.done <= previous.done)
        return stop("no step was ticked");
      message = continuePrompt;
    } else {
      if (finishRequested) return;
      finishRequested = true;
      message = finishPrompt;
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
    baseline = snapshot(trackedPlan(ctx.cwd, focus)?.plan);
    continuations = 0;
    finishRequested = false;
    const mode = currentMode();
    if (!mode) return;
    return { systemPrompt: `${event.systemPrompt}\n\n${mode.instructions}` };
  });

  pi.registerCommand("roadmap", {
    description: "Focus a roadmap plan for this session: /roadmap, /roadmap <name>",
    handler: async (args, ctx) => {
      let board: Board;
      try {
        board = findBoard(ctx.cwd);
      } catch (error) {
        ctx.ui.notify(`Roadmap: ${(error as Error).message}`, "error");
        return;
      }
      const requested = args.trim();
      let name: string | undefined;
      if (requested) {
        name = findPlan(board, requested)?.name;
        if (!name) {
          ctx.ui.notify(`No plan named "${requested}"`, "error");
          return;
        }
      } else {
        if (!ctx.hasUI) return;
        if (board.plans.length === 0) {
          ctx.ui.notify("No plans on the board", "info");
          return;
        }
        const choice = await pick(
          ctx,
          "Focus plan",
          board.plans.map((plan) => [
            `${plan.name} (${plan.section}, ${progress(plan)})`,
            plan.name,
          ]),
        );
        if (!choice) return;
        name = choice.value;
      }
      setFocus(ctx, name);
      ctx.ui.notify(`Focus: ${name}`, "info");
    },
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

      const choice = await pick<string | undefined>(ctx, "Mode", [
        [`${FREE}: normal settings`, undefined],
        ...[...modes].map(([name, mode]): [string, string] => [
          `${name}: ${mode.description}`,
          name,
        ]),
      ]);
      if (choice) switchTo(ctx, choice.value);
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
