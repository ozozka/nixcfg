"""Unit tests for structural conversion, independent of upstream sources."""

import unittest

from convert import (
    NIX_FUNCTION,
    NIX_REMOVALS,
    capture,
    convert_query,
    decode_string,
    emacs_regexp,
    parse,
    patterns,
    render,
)


def forms(source):
    return [" ".join(map(render, pattern)) for pattern in patterns(parse(source))]


class ConversionTests(unittest.TestCase):
    def test_parser_strings_comments_and_nesting(self):
        source = '; ignored ( ]\n(node ["(;)" "\\""] (child)) @variable'
        self.assertEqual(forms(source), ['(node ["(;)" "\\""] (child)) @variable'])

    def test_parser_rejects_malformed_input(self):
        for source in ["(node]", "(node", '"unfinished', '"bad\\q"']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                parse(source)

    def test_only_capture_tokens_are_mapped(self):
        source = '(node "@variable.member" "; (#unknown!)") @variable.member'
        result = convert_query(source, "just")
        self.assertIn('"@variable.member" "; (#unknown!)"', result)
        self.assertIn("@font-lock-property-name-face", result)

    def test_capture_boundaries_and_order(self):
        expected = {
            "@function.builtin": "@font-lock-builtin-face",
            "@constant.character.escape": "@font-lock-escape-face",
            "@constant.character": "@font-lock-constant-face",
            "@constant.builtin.boolean": "@font-lock-constant-face",
            "@constant.builtin-other": "@constant.builtin-other",
            "@variable.parameter.builtin": "@font-lock-builtin-face",
            "@variable.parameter": "@font-lock-variable-name-face",
            "@variable.parameter.extra": "@variable.parameter.extra",
            "@punctuation": "@font-lock-delimiter-face",
            "@punctuation.bracket": "@punctuation.bracket",
            "@markup.heading.1": "@font-lock-doc-face",
            "@function": "@function",
            "@spell": None,
        }
        for source, target in expected.items():
            with self.subTest(source=source):
                self.assertEqual(capture(source), target)

    def test_any_of_values_are_literal_and_whole_string(self):
        source = r'((node) @keyword (#any-of? @keyword "a.b" "(x)|y" "a\\b" "q\"uote"))'
        result = parse(convert_query(source, "just"))[0]
        predicate = result.items[-1]
        self.assertEqual(predicate.items[:2], ["#match?", "@keyword"])
        self.assertEqual(
            decode_string(predicate.items[-1]),
            r"\`\(?:a\.b\|(x)|y\|a\\b\|" + 'q"uote' + r"\)\'",
        )

    def test_match_regexp_translation(self):
        self.assertEqual(emacs_regexp("^(foo|bar)$"), r"^\(?:foo\|bar\)$")
        self.assertEqual(emacs_regexp(r"[(|)]\(a\)\|b\."), r"[(|)](a)|b\.")
        source = '((node) @variable.member (#match? @variable.member "^(a|b)$"))'
        result = parse(convert_query(source, "typst"))[0]
        self.assertEqual(result.items[-1].items[1], "@font-lock-property-name-face")
        self.assertEqual(decode_string(result.items[-1].items[2]), r"^\(?:a\|b\)$")

    def test_unsupported_regexps_fail(self):
        for regexp in [r"\d+", "(?=a)", "a{2}", "[[:alpha:]]", "(a", "[a", "a\\"]:
            with self.subTest(regexp=regexp), self.assertRaises(ValueError):
                emacs_regexp(regexp)

    def test_predicates_fail_closed(self):
        for predicate in ["#unknown!", "#not-eq?", "#is-not?"]:
            with self.subTest(predicate=predicate), self.assertRaises(ValueError):
                convert_query(f'((node) @variable ({predicate} @variable "x"))', "just")

    def test_offset_removal_is_structural(self):
        source = "((node) @string (#offset! @string 0 1 0 -1)) (other) @comment"
        self.assertEqual(
            forms(convert_query(source, "just")), ["((node) @string)", "(other) @comment"]
        )

    def test_nix_rules_are_language_specific(self):
        source = "(variable_expression (identifier) @variable)"
        self.assertEqual(forms(convert_query(source, "just")), [source])
        with self.assertRaisesRegex(ValueError, "structure changed"):
            convert_query(source, "nix")

    def test_nix_removals_and_builtin_priority(self):
        source = (
            "\n".join(sorted(NIX_REMOVALS))
            + """
          ((identifier) @variable.builtin
            (#match? @variable.builtin "^(builtins|true)$")
            (#is-not? local))
          (inherit_from (identifier) @property)
        """
        )
        result = forms(convert_query(source, "nix"))
        self.assertEqual(result[0], "(inherit_from (identifier) @property)")
        self.assertIn("@font-lock-builtin-face", result[1])
        self.assertNotIn("#is-not?", result[1])
        self.assertEqual(result[-1], forms(NIX_FUNCTION)[0])
        with self.assertRaisesRegex(ValueError, "structure changed"):
            convert_query(source.replace("(identifier) @property", "(other) @property"), "nix")


if __name__ == "__main__":
    unittest.main()
