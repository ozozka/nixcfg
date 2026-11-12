/**
 * Roadmap tool: plans on a Markdown board, the project's own when it has a compatible one,
 * otherwise a private board in .git. Shows the focused plan's progress below the editor,
 * sends notices for ticked steps and completed plans, and reminds the agent of the focused
 * plan after compaction.
 */
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, join, relative, resolve } from "node:path";
import { StringEnum } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  type ExtensionContext,
  withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { type Static, Type } from "typebox";
import { projectRoot, reply, sendNotice } from "./lib/shared.ts";

export interface Step {
  number: number;
  title: string;
  done: boolean;
  // Line index in the board file.
  line: number;
}

type SectionName = "Status" | "Limitations" | "Backlog" | "Plans" | "Active" | "Completed";

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

const NEWLINE = /[\r\n]/;
const HEADING = /^(#{1,6})\s+(.*?)\s*#*\s*$/;
const FENCE = /^ {0,3}(`{3,}|~{3,})(.*)$/;
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
const ROADMAP_TEMPLATE = `# Roadmap\n\n${SECTION_NAMES.map((name) => `## ${name}`).join("\n\n")}\n`;

function headings(lines: string[]): Heading[] {
  const found: Heading[] = [];
  let fenced: { marker: string; length: number } | undefined;
  for (const [line, text] of lines.entries()) {
    const fence = FENCE.exec(text);
    if (fence) {
      if (!fenced) fenced = { marker: fence[1][0], length: fence[1].length };
      else if (
        fence[1][0] === fenced.marker &&
        fence[1].length >= fenced.length &&
        !fence[2].trim()
      )
        fenced = undefined;
      continue;
    }
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
  if (!isReadme(path)) {
    const title = all[0];
    return title && { start: title.line, end: sectionEnd(all, title, lines.length) };
  }
  const roadmaps = all.filter((h) => h.text.toLowerCase() === "roadmap");
  const roadmap = roadmaps.length === 1 ? roadmaps[0] : undefined;
  return roadmap && { start: roadmap.line, end: sectionEnd(all, roadmap, lines.length) };
}

// Only complete, unambiguous boards are writable; no section repair or creation.
export function parseBoard(path: string, lines: string[]): Board | undefined {
  const all = headings(lines);
  const range = container(path, lines, all);
  if (!range) return undefined;
  const inside = all.filter((h) => h.line > range.start && h.line < range.end);
  const named = inside.filter((h) => SECTION_NAMES.includes(h.text as SectionName));
  const parent = isReadme(path) ? all.find((h) => h.line === range.start) : all[0];
  if (!parent || named.length !== SECTION_NAMES.length) return undefined;
  const level = parent.level + 1;
  if (
    named.some(
      (heading, index) => heading.level !== level || heading.text !== SECTION_NAMES[index],
    )
  )
    return undefined;
  const sections = new Map<SectionName, Range>();
  for (const heading of named)
    sections.set(heading.text as SectionName, {
      start: heading.line,
      end: sectionEnd(all, heading, range.end),
    });

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
  if (new Set(plans.map((plan) => plan.name.toLowerCase())).size !== plans.length)
    return undefined;
  return { path, lines, container: range, level, sections, plans };
}

// A new board file: the six sections under a Roadmap heading.
export function newBoard(path: string): Board {
  return parseBoard(path, ROADMAP_TEMPLATE.split("\n")) as Board;
}

function reparse(board: Board, lines: string[]): Board {
  const parsed = parseBoard(board.path, lines);
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

// The plan to work on: the named one, else the session's focus, else the only active one.
export function currentPlan(board: Board, name?: string, focus?: string): Plan | undefined {
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
export function writePlan(board: Board, name: string, content: string): Board {
  const title = name.trim();
  if (!title || NEWLINE.test(title) || title.startsWith("#"))
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
  if (entries.some((entry) => NEWLINE.test(entry)))
    throw new Error("delivered entries must be one line");
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
export function addBacklog(board: Board, idea: string): Board {
  const entry = idea.trim().replace(BULLET, "");
  if (!entry || NEWLINE.test(entry)) throw new Error("the idea needs one line of text");
  return appendItems(board, "Backlog", [entry]);
}

export function planText(board: Board, plan: Plan): string {
  return board.lines.slice(plan.start, contentEnd(board.lines, plan)).join("\n");
}

// Storage: the project's compatible board, otherwise a private board in the repository's
// common git directory (shared by its worktrees, never tracked). Reads never create files.

export interface Location {
  board: Board;
  // How results name the board, e.g. docs/roadmap.md or .git/roadmap.md.
  label: string;
  // File content before the action; undefined when the file does not exist yet.
  original?: string;
}

const GITDIR = /^gitdir:\s*(.+)$/m;

// The git directory shared by all worktrees, or undefined outside a repository.
function gitCommonDir(root: string): string | undefined {
  const dotGit = join(root, ".git");
  if (!existsSync(dotGit)) return undefined;
  if (statSync(dotGit).isDirectory()) return dotGit;
  // A worktree: .git names its own git directory, whose commondir file names the shared one.
  const match = GITDIR.exec(readFileSync(dotGit, "utf8"));
  if (!match) return undefined;
  const gitDir = resolve(root, match[1].trim());
  const common = join(gitDir, "commondir");
  return existsSync(common) ? resolve(gitDir, readFileSync(common, "utf8").trim()) : gitDir;
}

export function projectBoard(root: string): Board | undefined {
  for (const name of ["docs/roadmap.md", "README.md"]) {
    const path = join(root, name);
    if (!existsSync(path)) continue;
    const board = parseBoard(path, readFileSync(path, "utf8").split("\n"));
    if (board) return board;
  }
  return undefined;
}

export function locate(root: string): Location {
  const project = projectBoard(root);
  if (project)
    return {
      board: project,
      label: relative(root, project.path),
      original: project.lines.join("\n"),
    };
  const gitDir = gitCommonDir(root);
  if (!gitDir) return { board: newBoard(""), label: "no board (not a git repository)" };
  const path = join(gitDir, "roadmap.md");
  const label = relative(root, path);
  if (!existsSync(path)) return { board: newBoard(path), label };
  const original = readFileSync(path, "utf8");
  const board = parseBoard(path, original.split("\n"));
  // Never repair: a local board edited into an invalid shape must be fixed by hand.
  if (!board) throw new Error(`${label} is not a valid roadmap board; fix it by hand`);
  return { board, label, original };
}

export function save(location: Location, board: Board): void {
  if (!board.path) throw new Error("not a git repository; there is nowhere to store a board");
  // Refuse to overwrite a board changed or created by someone else during the action.
  const current = existsSync(board.path) ? readFileSync(board.path, "utf8") : undefined;
  if (current !== location.original)
    throw new Error("the board changed during this action; retry");
  writeFileSync(board.path, board.lines.join("\n"));
}

// Pi adapter

// The session remembers only which plan it works on; the board file holds everything else.
const ENTRY = "roadmap-focus";
const DESCRIPTION = `Manage plans with show, backlog (idea), write (plan and content), focus (plan), tick (step), and complete (delivered summaries).

Use an existing board with Status, Limitations, Backlog, Plans, Active, and Completed in docs/roadmap.md or README.md's Roadmap section; otherwise use the private .git/roadmap.md, created on the first change. Never create or repair project files.

Plan content is bullets with a \`- **Steps**:\` group and consecutive checkbox steps: \`  - [ ] **1. Title**: details\`. Other bullet groups are optional. Ticking starts a plan; completing requires all steps ticked.`;
const Params = Type.Object({
  action: StringEnum(["show", "backlog", "write", "focus", "tick", "complete"] as const),
  plan: Type.Optional(
    Type.String({
      description:
        "Plan name; write and focus need it, the others default to the focused plan (or the only active one)",
    }),
  ),
  content: Type.Optional(
    Type.String({
      description: "write: the plan body in the plan format, without its heading",
    }),
  ),
  idea: Type.Optional(Type.String({ description: "backlog: the idea, one line" })),
  step: Type.Optional(Type.Number({ description: "tick: the step number" })),
  delivered: Type.Optional(
    Type.Array(Type.String(), {
      description: "complete: one Completed line per delivered capability",
    }),
  ),
});

const progress = (plan: { steps: { done: boolean }[] }) =>
  `${plan.steps.filter((step) => step.done).length}/${plan.steps.length}`;

interface Focus {
  root: string;
  focus?: string;
}

// The focus recorded on this branch for this project.
function restore(ctx: ExtensionContext): Focus {
  const root = projectRoot(ctx.cwd);
  let state: Focus = { root };
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "custom" || entry.customType !== ENTRY) continue;
    const saved = entry.data as Focus | undefined;
    if (saved?.root === root) state = saved;
  }
  return state;
}

// Pure action dispatch: storage is committed only after every validation succeeds.
function act(
  board: Board,
  params: Static<typeof Params>,
  focus?: string,
): {
  board: Board;
  message: string;
  focus?: string;
  notice?: { message: string; final?: boolean };
} {
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
      const selected = currentPlan(board, params.plan, focus);
      const overview =
        board.plans
          .map((plan) => `${plan.name} (${plan.section}, ${progress(plan)})`)
          .join("\n") || "No plans on the board.";
      return {
        board,
        focus,
        message: overview + (selected ? `\n\n${planText(board, selected)}` : ""),
      };
    }
    case "focus": {
      if (!params.plan) throw new Error("focus needs plan");
      const plan = target();
      return {
        board,
        focus: plan.name,
        message: `Focused plan "${plan.name}" (${progress(plan)}).`,
      };
    }
    case "backlog": {
      if (!params.idea) throw new Error("backlog needs idea");
      return { board: addBacklog(board, params.idea), focus, message: "Added to Backlog." };
    }
    case "write": {
      if (!(params.plan && params.content)) throw new Error("write needs plan and content");
      return {
        board: writePlan(board, params.plan, params.content),
        focus: params.plan,
        message: `Plan "${params.plan}" written and focused.`,
      };
    }
    case "tick": {
      if (params.step === undefined) throw new Error("tick needs step");
      const plan = target();
      const next = tickStep(board, plan, params.step);
      const updated = currentPlan(next, plan.name) as NonNullable<
        ReturnType<typeof currentPlan>
      >;
      const message = `Step ${params.step} ticked (${progress(updated)}).`;
      return { board: next, focus: plan.name, message, notice: { message } };
    }
    case "complete": {
      const plan = target();
      const message = `Plan "${plan.name}" completed.`;
      return {
        board: completePlan(board, plan, params.delivered ?? []),
        focus: focus?.toLowerCase() === plan.name.toLowerCase() ? undefined : focus,
        message,
        notice: { message, final: true },
      };
    }
  }
}

export default function (pi: ExtensionAPI) {
  function widget(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;
    try {
      const { board } = locate(projectRoot(ctx.cwd));
      const plan = currentPlan(board, undefined, restore(ctx).focus);
      const next = plan?.steps.find((step) => !step.done);
      const theme = ctx.ui.theme;
      ctx.ui.setWidget(
        "roadmap",
        plan && next
          ? [
              `${theme.bold(plan.name)} ${theme.fg("muted", progress(plan))}`,
              ...plan.steps.map((step) => {
                const mark = step.done ? "✔" : step === next ? "◆" : "⬦";
                return `${theme.bold(theme.fg(step.done ? "success" : "warning", mark))} ${theme.bold(`${step.number}. ${step.title}`)}`;
              }),
            ]
          : undefined,
        { placement: "belowEditor" },
      );
    } catch (error) {
      ctx.ui.notify(`Roadmap: ${String(error)}`, "warning");
    }
  }

  function execute(params: Static<typeof Params>, location: Location, ctx: ExtensionContext) {
    const state = restore(ctx);
    const result = act(location.board, params, state.focus);
    if (result.board !== location.board) save(location, result.board);
    if (result.focus !== state.focus)
      pi.appendEntry(ENTRY, { root: state.root, focus: result.focus });
    if (result.notice) sendNotice(pi, result.notice);
    widget(ctx);
    return reply(`Board: ${location.label}\n${result.message}`, { board: location.label });
  }

  pi.on("session_start", (_event, ctx) => widget(ctx));
  pi.on("session_tree", (_event, ctx) => widget(ctx));
  pi.on("agent_settled", (_event, ctx) => widget(ctx));
  pi.on("session_compact", (_event, ctx) => {
    const { board } = locate(projectRoot(ctx.cwd));
    const plan = currentPlan(board, undefined, restore(ctx).focus);
    if (!plan?.steps.some((step) => !step.done)) return;
    pi.sendMessage(
      {
        customType: "roadmap-reminder",
        content: `Roadmap plan from before compaction:\n${planText(board, plan)}`,
        display: false,
      },
      { deliverAs: ctx.isIdle() ? "nextTurn" : "steer" },
    );
  });

  pi.registerTool({
    name: "roadmap",
    label: "Roadmap",
    description: DESCRIPTION,
    parameters: Params,
    async execute(_id, params, _signal, _update, ctx) {
      try {
        const root = projectRoot(ctx.cwd);
        // Locate inside the queue, so concurrent actions see each other's writes.
        const key = locate(root).board.path || root;
        return await withFileMutationQueue(key, () =>
          Promise.resolve(execute(params, locate(root), ctx)),
        );
      } catch (error) {
        const message = (error as Error).message;
        return reply(`Error: ${message}. The board was not changed.`, { error: message }, true);
      }
    },
    renderCall(args, theme) {
      return new Text(
        theme.fg("toolTitle", theme.bold(`roadmap ${args.action} `)) +
          theme.fg("muted", args.plan ?? "current plan"),
        0,
        0,
      );
    },
    renderResult(result, _options, theme) {
      const details = result.details as { error?: string };
      const first = result.content[0];
      return new Text(
        theme.fg(details.error ? "error" : "muted", first?.type === "text" ? first.text : ""),
        0,
        0,
      );
    },
  });

  pi.registerCommand("roadmap", {
    description: "Focus a roadmap plan: /roadmap [name]",
    handler: async (args, ctx) => {
      let name = args.trim();
      if (!name) {
        if (!ctx.hasUI) return;
        const { board } = locate(projectRoot(ctx.cwd));
        name =
          (await ctx.ui.select(
            "Focus plan",
            board.plans.map((plan) => plan.name),
          )) ?? "";
      }
      if (!name) return;
      try {
        execute({ action: "focus", plan: name }, locate(projectRoot(ctx.cwd)), ctx);
      } catch (error) {
        ctx.ui.notify(`Roadmap: ${String(error)}`, "error");
      }
    },
  });
}
