/**
 * Question tool: asks the user one or more questions with options. One question shows a simple
 * option list; several show a tab bar with a Submit tab. Every question can allow a typed answer
 * ("Type something."). Vendored from the Pi questionnaire example.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  Editor,
  type EditorTheme,
  Key,
  matchesKey,
  Text,
  visibleWidth,
  wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import { type Static, Type } from "typebox";
import { reply } from "./lib/shared.ts";

const QuestionOptionSchema = Type.Object({
  value: Type.String({ description: "The value returned when selected" }),
  label: Type.String({ description: "Display label for the option" }),
  description: Type.Optional(
    Type.String({ description: "Optional description shown below label" }),
  ),
});

const QuestionSchema = Type.Object({
  id: Type.String({ description: "Unique identifier for this question" }),
  label: Type.Optional(
    Type.String({
      description: "Short label for the tab bar, e.g. 'Scope' (defaults to Q1, Q2)",
    }),
  ),
  prompt: Type.String({ description: "The full question text to display" }),
  options: Type.Array(QuestionOptionSchema, {
    description: "Available options to choose from",
  }),
  allowOther: Type.Optional(
    Type.Boolean({ description: "Allow 'Type something' option (default: true)" }),
  ),
});

const QuestionParams = Type.Object({
  questions: Type.Array(QuestionSchema, { description: "Questions to ask the user" }),
});

type RenderOption = Static<typeof QuestionOptionSchema> & { isOther?: boolean };
// A question with its defaults filled in.
type Question = Static<typeof QuestionSchema> & { label: string; allowOther: boolean };

interface Answer {
  id: string;
  value: string;
  label: string;
  wasCustom: boolean;
  index?: number;
}

interface QuestionResult {
  questions: Question[];
  answers: Answer[];
  cancelled: boolean;
}

const OTHER: RenderOption = { value: "__other__", label: "Type something.", isOther: true };

const errorResult = (message: string) =>
  reply<QuestionResult>(message, { questions: [], answers: [], cancelled: true });

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "question",
    label: "Question",
    description:
      "Ask one or more questions with selectable answers and optional custom input. One question uses a list; multiple questions use tabs.",
    parameters: QuestionParams,

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (ctx.mode !== "tui") {
        return errorResult("Error: UI not available (running in non-interactive mode)");
      }
      if (params.questions.length === 0) {
        return errorResult("Error: No questions provided");
      }

      const questions: Question[] = params.questions.map((q, i) => ({
        ...q,
        label: q.label || `Q${i + 1}`,
        allowOther: q.allowOther !== false,
      }));
      const isMulti = questions.length > 1;
      // The tab after the questions is Submit.
      const submitTab = questions.length;

      const result = await ctx.ui.custom<QuestionResult>((tui, theme, _kb, done) => {
        let currentTab = 0;
        let optionIndex = 0;
        // The question whose typed answer the editor is taking, if any.
        let typing: Question | undefined;
        let cachedLines: string[] | undefined;
        const answers = new Map<string, Answer>();

        const editorTheme: EditorTheme = {
          borderColor: (s) => theme.fg("accent", s),
          selectList: {
            selectedPrefix: (t) => theme.fg("accent", t),
            selectedText: (t) => theme.fg("accent", t),
            description: (t) => theme.fg("muted", t),
            scrollInfo: (t) => theme.fg("dim", t),
            noMatch: (t) => theme.fg("warning", t),
          },
        };
        const editor = new Editor(tui, editorTheme);

        function refresh() {
          cachedLines = undefined;
          tui.requestRender();
        }

        function submit(cancelled: boolean) {
          done({ questions, answers: [...answers.values()], cancelled });
        }

        function currentOptions(): RenderOption[] {
          const q = questions[currentTab];
          if (!q) return [];
          return q.allowOther ? [...q.options, OTHER] : q.options;
        }

        const allAnswered = () => questions.every((q) => answers.has(q.id));

        function moveTab(delta: number) {
          currentTab = (currentTab + delta + submitTab + 1) % (submitTab + 1);
          optionIndex = 0;
          refresh();
        }

        // One question submits at once; several move to the next tab (Submit after the last).
        function answer(value: Answer) {
          answers.set(value.id, value);
          if (isMulti) moveTab(1);
          else submit(false);
        }

        function stopTyping() {
          typing = undefined;
          editor.setText("");
        }

        editor.onSubmit = (value) => {
          if (!typing) return;
          const text = value.trim() || "(no response)";
          const id = typing.id;
          stopTyping();
          answer({ id, value: text, label: text, wasCustom: true });
        };

        function handleInput(data: string) {
          if (typing) {
            if (matchesKey(data, Key.escape)) stopTyping();
            else editor.handleInput(data);
            refresh();
            return;
          }

          if (isMulti) {
            if (matchesKey(data, Key.tab) || matchesKey(data, Key.right)) return moveTab(1);
            if (matchesKey(data, Key.shift("tab")) || matchesKey(data, Key.left))
              return moveTab(-1);
          }

          if (currentTab === submitTab) {
            if (matchesKey(data, Key.enter) && allAnswered()) submit(false);
            else if (matchesKey(data, Key.escape)) submit(true);
            return;
          }

          const options = currentOptions();
          if (matchesKey(data, Key.up) || matchesKey(data, Key.down)) {
            const delta = matchesKey(data, Key.up) ? -1 : 1;
            optionIndex = Math.max(0, Math.min(options.length - 1, optionIndex + delta));
            refresh();
            return;
          }

          const q = questions[currentTab];
          if (matchesKey(data, Key.enter) && q) {
            const option = options[optionIndex];
            if (option.isOther) {
              typing = q;
              editor.setText("");
              refresh();
              return;
            }
            const { value, label } = option;
            answer({ id: q.id, value, label, wasCustom: false, index: optionIndex + 1 });
            return;
          }

          if (matchesKey(data, Key.escape)) submit(true);
        }

        function render(width: number): string[] {
          if (cachedLines) return cachedLines;

          const lines: string[] = [];
          const renderWidth = Math.max(1, width);
          const q = questions[currentTab];
          const rule = theme.fg("accent", "─".repeat(renderWidth));

          // Wraps text after a prefix, indenting continuation lines to the prefix's width.
          function addWrapped(prefix: string, text: string) {
            const prefixWidth = visibleWidth(prefix);
            if (prefixWidth >= renderWidth) {
              lines.push(...wrapTextWithAnsi(prefix + text, renderWidth));
              return;
            }
            const indent = " ".repeat(prefixWidth);
            for (const [i, line] of wrapTextWithAnsi(text, renderWidth - prefixWidth).entries())
              lines.push(`${i === 0 ? prefix : indent}${line}`);
          }
          const line = (text: string) => addWrapped(" ", text);

          lines.push(rule);

          if (isMulti) {
            const tab = (text: string, active: boolean, color: "success" | "muted" | "dim") =>
              active ? theme.bg("selectedBg", theme.fg("text", text)) : theme.fg(color, text);
            const tabs = questions.map((question, i) => {
              const answered = answers.has(question.id);
              const text = ` ${answered ? "■" : "□"} ${question.label} `;
              return `${tab(text, i === currentTab, answered ? "success" : "muted")} `;
            });
            const submitText = tab(
              " ✓ Submit ",
              currentTab === submitTab,
              allAnswered() ? "success" : "dim",
            );
            line(`← ${tabs.join("")}${submitText} →`);
            lines.push("");
          }

          function renderOptions() {
            for (const [i, option] of currentOptions().entries()) {
              const selected = i === optionIndex;
              const editing = option.isOther === true && typing !== undefined;
              const prefix = selected ? theme.fg("accent", "> ") : "  ";
              const label = `${i + 1}. ${option.label}${editing ? " ✎" : ""}`;
              addWrapped(prefix, theme.fg(selected || editing ? "accent" : "text", label));
              if (option.description)
                addWrapped("     ", theme.fg("muted", option.description));
            }
          }

          if (typing && q) {
            line(theme.fg("text", q.prompt));
            lines.push("");
            renderOptions();
            lines.push("");
            line(theme.fg("muted", "Your answer:"));
            for (const editorLine of editor.render(Math.max(1, renderWidth - 2)))
              lines.push(` ${editorLine}`);
            lines.push("");
            line(theme.fg("dim", "Enter to submit • Esc to cancel"));
          } else if (currentTab === submitTab) {
            line(theme.fg("accent", theme.bold("Ready to submit")));
            lines.push("");
            for (const question of questions) {
              const given = answers.get(question.id);
              if (!given) continue;
              const prefix = given.wasCustom ? "(wrote) " : "";
              line(
                `${theme.fg("muted", `${question.label}: `)}${theme.fg("text", prefix + given.label)}`,
              );
            }
            lines.push("");
            if (allAnswered()) {
              line(theme.fg("success", "Press Enter to submit"));
            } else {
              const missing = questions
                .filter((question) => !answers.has(question.id))
                .map((question) => question.label)
                .join(", ");
              line(theme.fg("warning", `Unanswered: ${missing}`));
            }
          } else if (q) {
            line(theme.fg("text", q.prompt));
            lines.push("");
            renderOptions();
          }

          lines.push("");
          if (!typing) {
            const help = isMulti
              ? "Tab/←→ navigate • ↑↓ select • Enter confirm • Esc cancel"
              : "↑↓ navigate • Enter select • Esc cancel";
            line(theme.fg("dim", help));
          }
          lines.push(rule);

          cachedLines = lines;
          return lines;
        }

        return {
          render,
          invalidate: () => {
            cachedLines = undefined;
          },
          handleInput,
        };
      });

      if (result.cancelled) return reply("User cancelled the questions", result);

      const answerLines = result.answers.map((a) => {
        const label = questions.find((q) => q.id === a.id)?.label || a.id;
        return a.wasCustom
          ? `${label}: user wrote: ${a.label}`
          : `${label}: user selected: ${a.index}. ${a.label}`;
      });
      return reply(answerLines.join("\n"), result);
    },

    renderCall(args, theme, _context) {
      const questions = args.questions ?? [];
      const count = questions.length;
      const labels = questions.map((q) => q.label || q.id).join(", ");
      let text = theme.fg("toolTitle", theme.bold("question "));
      text += theme.fg("muted", `${count} question${count !== 1 ? "s" : ""}`);
      if (labels) text += theme.fg("dim", ` (${labels})`);
      return new Text(text, 0, 0);
    },

    renderResult(result, _options, theme, _context) {
      const details = result.details as QuestionResult | undefined;
      if (!details) {
        const text = result.content[0];
        return new Text(text?.type === "text" ? text.text : "", 0, 0);
      }
      if (details.cancelled) return new Text(theme.fg("warning", "Cancelled"), 0, 0);
      const lines = details.answers.map((a) => {
        const shown = a.wasCustom
          ? `${theme.fg("muted", "(wrote) ")}${a.label}`
          : a.index
            ? `${a.index}. ${a.label}`
            : a.label;
        return `${theme.fg("success", "✓ ")}${theme.fg("accent", a.id)}: ${shown}`;
      });
      return new Text(lines.join("\n"), 0, 0);
    },
  });
}
