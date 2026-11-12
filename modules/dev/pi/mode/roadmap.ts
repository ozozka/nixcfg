/**
 * The roadmap board: finding, reading, and changing plans in Markdown.
 *
 * A board is a set of sibling headings named Backlog (optional), Plans, Active, and Completed.
 * It is searched in docs/roadmap.md, the Roadmap section of README.md, and a root todo.md; a
 * missing todo.md is created on the first save. Plans are headings one level below their
 * section, and their steps are `- [ ] **1. Title**` lines (ticked with `[x]`). Only these parts
 * are parsed; edits touch only the plan lines and the blank lines next to them. Changes return
 * a new Board; nothing is written until `saveBoard`.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

export interface Step {
  number: number;
  title: string;
  done: boolean;
  // Line index in the board file.
  line: number;
}

export type SectionName = "Backlog" | "Plans" | "Active" | "Completed";

export interface Plan {
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

export interface Board {
  path: string;
  // The file does not exist yet; saveBoard creates it.
  created: boolean;
  lines: string[];
  // Heading level of the board sections.
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
const SECTION_NAMES: readonly string[] = ["Backlog", "Plans", "Active", "Completed"];
const REQUIRED: SectionName[] = ["Plans", "Active", "Completed"];
const TODO_TEMPLATE = "# Todo\n\n## Backlog\n\n## Plans\n\n## Active\n\n## Completed\n";

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

// Parses the board in a file's lines, or returns undefined without one.
function parseBoard(path: string, lines: string[], created = false): Board | undefined {
  const all = headings(lines);
  const range = container(path, lines, all);
  if (!range) return undefined;
  const named = all.filter(
    (h) => h.line > range.start && h.line < range.end && SECTION_NAMES.includes(h.text),
  );
  if (named.length === 0) return undefined;
  const level = Math.min(...named.map((h) => h.level));
  const sections = new Map<SectionName, Range>();
  for (const heading of named.filter((h) => h.level === level)) {
    const end = sectionEnd(all, heading, range.end);
    sections.set(heading.text as SectionName, { start: heading.line, end });
  }
  if (!REQUIRED.every((name) => sections.has(name))) return undefined;

  const plans: Plan[] = [];
  for (const section of ["Plans", "Active"] as const) {
    const { start, end } = sections.get(section) as Range;
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
  return { path, created, lines, level, sections, plans };
}

// The project root: the nearest directory with .git (a directory or a worktree file).
export function projectRoot(cwd: string): string {
  const start = resolve(cwd);
  for (let directory = start; ; directory = dirname(directory)) {
    if (existsSync(join(directory, ".git"))) return directory;
    if (dirname(directory) === directory) return start;
  }
}

// Finds the board, or a new todo.md board to create. Throws when todo.md exists without one.
export function findBoard(cwd: string): Board {
  const root = projectRoot(cwd);
  const todo = join(root, "todo.md");
  for (const path of [join(root, "docs", "roadmap.md"), join(root, "README.md"), todo]) {
    if (!existsSync(path)) continue;
    const board = parseBoard(path, readFileSync(path, "utf8").split("\n"));
    if (board) return board;
  }
  if (existsSync(todo))
    throw new Error(
      "todo.md exists without a board (Plans, Active, and Completed sections); add them to it or a board to the roadmap",
    );
  return parseBoard(todo, TODO_TEMPLATE.split("\n"), true) as Board;
}

export function saveBoard(board: Board) {
  writeFileSync(board.path, board.lines.join("\n"));
}

function reparse(board: Board, lines: string[]): Board {
  const parsed = parseBoard(board.path, lines, board.created);
  if (!parsed) throw new Error("the board was lost while editing; nothing was written");
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

export function findPlan(board: Board, name: string): Plan | undefined {
  const wanted = name.trim().toLowerCase();
  return board.plans.find((plan) => plan.name.toLowerCase() === wanted);
}

// The plan to work on: the named one, else the first active one, else the only planned one.
export function currentPlan(board: Board, name?: string): Plan | undefined {
  if (name) return findPlan(board, name);
  const active = board.plans.find((plan) => plan.section === "Active");
  if (active) return active;
  const planned = board.plans.filter((plan) => plan.section === "Plans");
  return planned.length === 1 ? planned[0] : undefined;
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
export function writePlan(board: Board, name: string, content: string): Board {
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
export function startPlan(board: Board, plan: Plan): Board {
  if (plan.section === "Active") return board;
  const block = board.lines.slice(plan.start, contentEnd(board.lines, plan));
  const removed = reparse(board, splice(board.lines, plan.start, plan.end, []));
  const active = removed.sections.get("Active") as Range;
  return reparse(removed, appendToSection(removed.lines, active, block));
}

// Ticks a step, starting the plan first when it is still in Plans.
export function tickStep(board: Board, plan: Plan, number: number): Board {
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
export function completePlan(board: Board, plan: Plan, delivered: string[]): Board {
  const open = plan.steps.filter((step) => !step.done).map((step) => step.number);
  if (open.length > 0) throw new Error(`steps not ticked yet: ${open.join(", ")}`);
  const entries = delivered.map((line) => line.trim().replace(BULLET, "")).filter(Boolean);
  if (entries.length === 0) throw new Error("name at least one delivered capability");
  const block = entries.map((entry) => `- ${entry}`);
  const removed = reparse(board, splice(board.lines, plan.start, plan.end, []));
  const completed = removed.sections.get("Completed") as Range;
  const end = contentEnd(removed.lines, completed);
  const items = removed.lines
    .slice(completed.start + 1, end)
    .filter((line) => line.startsWith("- ") && !PLACEHOLDER.test(line));
  if (items.length === 0)
    return reparse(removed, appendToSection(removed.lines, completed, block));
  // Completed entries form one list: append directly after the last one.
  const lines = [...removed.lines.slice(0, end), ...block, ...removed.lines.slice(end)];
  return reparse(removed, lines);
}

export function planText(board: Board, plan: Plan): string {
  return board.lines.slice(plan.start, contentEnd(board.lines, plan)).join("\n");
}
