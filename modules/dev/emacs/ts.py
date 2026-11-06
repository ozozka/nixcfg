"""Adapt pinned upstream highlight queries for Emacs treesit-x.

This is deliberately not a general query/regexp translator. Unknown predicates
and regexp constructs, or changes to required Nix patterns, fail the build so
upstream changes require review. Balanced query forms are parsed before mapping
captures and predicates; strings and comments are never substituted.

Languages, source paths and build dependencies belong to ts.nix. This
standard-library converter runs only at build time; mode definitions live in
my-modes.el.
"""

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Group:
    opening: str
    items: list


def parse(source: str) -> list:
    """Read balanced query forms, preserving string tokens and ignoring comments."""
    root = []
    stack = [(None, root)]
    pos = 0
    while pos < len(source):
        char = source[pos]
        if char.isspace():
            pos += 1
        elif char == ";":
            end = source.find("\n", pos)
            pos = len(source) if end == -1 else end + 1
        elif char in "([":
            group = Group(char, [])
            stack[-1][1].append(group)
            stack.append((char, group.items))
            pos += 1
        elif char in ")]":
            if len(stack) == 1 or stack[-1][0] != {")": "(", "]": "["}[char]:
                raise ValueError(f"unmatched {char!r} at offset {pos}")
            stack.pop()
            pos += 1
        elif char == '"':
            start = pos
            pos += 1
            while pos < len(source):
                if source[pos] == "\\":
                    pos += 2
                elif source[pos] == '"':
                    pos += 1
                    break
                else:
                    pos += 1
            else:
                raise ValueError(f"unterminated string at offset {start}")
            token = source[start:pos]
            decode_string(token)
            stack[-1][1].append(token)
        else:
            end = pos + 1
            while (
                end < len(source) and not source[end].isspace() and source[end] not in '()[];"'
            ):
                end += 1
            stack[-1][1].append(source[pos:end])
            pos = end
    if len(stack) != 1:
        raise ValueError("unclosed query form")
    return root


def render(node) -> str:
    if isinstance(node, str):
        return node
    closing = ")" if node.opening == "(" else "]"
    return node.opening + " ".join(map(render, node.items)) + closing


def decode_string(token: str) -> str:
    if not isinstance(token, str) or not token.startswith('"'):
        raise ValueError(f"expected a query string, got {token!r}")
    return json.loads(token)


def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def literal_regexp(value: str) -> str:
    """Quote a literal for Emacs, where bare parentheses and bars are literal."""
    return re.sub(r"([\\.\^$*+?\[\]])", r"\\\1", value)


def emacs_regexp(value: str) -> str:
    """Translate only the regexp subset used by these upstream queries."""
    result = []
    pos = 0
    in_class = False
    depth = 0
    while pos < len(value):
        char = value[pos]
        if char == "\\":
            pos += 1
            if pos == len(value) or value[pos] not in r"\.^$*+?[]()|/-":
                raise ValueError(f"unsupported regexp escape in {value!r}")
            escaped = value[pos]
            result.append(escaped if escaped in "()|/" and not in_class else "\\" + escaped)
        elif in_class:
            # POSIX/nested classes and escaped class syntax need separate handling.
            if char == "[":
                raise ValueError(f"unsupported nested regexp class in {value!r}")
            result.append(char)
            if char == "]":
                in_class = False
        elif char == "[":
            in_class = True
            result.append(char)
        elif char == "(":
            if value[pos + 1 : pos + 2] == "?":
                raise ValueError(f"unsupported regexp group in {value!r}")
            depth += 1
            result.append(r"\(?:")
        elif char == ")":
            depth -= 1
            if depth < 0:
                raise ValueError(f"unbalanced regexp in {value!r}")
            result.append(r"\)")
        elif char == "|":
            result.append(r"\|")
        elif char in "{}":
            raise ValueError(f"unsupported regexp repetition in {value!r}")
        else:
            result.append(char)
        pos += 1
    if in_class or depth:
        raise ValueError(f"unbalanced regexp in {value!r}")
    return "".join(result)


# Exact names take precedence over prefix families. Remaining standard captures
# are intentionally left for Emacs treesit-generic-mode-font-lock-map.
# Builtin functions use font-lock-builtin-face, not the nonexistent
# font-lock-function-face used by the old configuration.
FACES = {
    "attribute.builtin": "builtin",
    "constant.numeric": "number",
    "constant.character.escape": "escape",
    "constant.character": "constant",
    "function.builtin": "builtin",
    "function.call": "function-call",
    "function.method": "function-name",
    "keyword.operator": "operator",
    "number.float": "number",
    "string.documentation": "doc",
    "string.escape": "escape",
    "type.builtin": "builtin",
    "variable.member": "property-name",
    "variable.builtin": "builtin",
    "variable.parameter.builtin": "builtin",
    "variable.parameter": "variable-name",
    "label": "constant",
    "punctuation": "delimiter",
}


def capture(token: str) -> str | None:
    name = token[1:]
    if name in {"embedded", "none", "spell"}:
        return None
    face = FACES.get(name)
    if face is None:
        for prefix, family_face in [
            ("constant.builtin", "constant"),
            ("keyword.", "keyword"),
            ("string.special.", "string"),
            ("markup.", "doc"),
        ]:
            if name == prefix or name.startswith(
                prefix if prefix.endswith(".") else prefix + "."
            ):
                face = family_face
                break
    return f"@font-lock-{face}-face" if face else token


def transform(node, language: str):
    if isinstance(node, str):
        return capture(node) if node.startswith("@") else node
    items = node.items
    head = items[0] if items and isinstance(items[0], str) else ""
    if head.startswith("#"):
        if language == "nix" and items == ["#is-not?", "local"]:
            # Emacs has no upstream locals tracking. This deliberately broadens
            # builtin matching to shadowed names; preserve the previous behavior.
            return None
        if head == "#offset!":
            # Font-lock highlights complete nodes, without upstream offsets.
            return None
        if head not in {"#match?", "#any-of?"}:
            raise ValueError(f"unsupported predicate {head}")
        if len(items) < 3 or not isinstance(items[1], str) or not items[1].startswith("@"):
            raise ValueError(f"invalid predicate {render(node)}")
        target = capture(items[1])
        if target is None:
            raise ValueError(f"predicate refers to discarded capture {items[1]}")
        if head == "#any-of?":
            # Match literal alternatives as whole strings using an Emacs regexp.
            alternatives = [literal_regexp(decode_string(item)) for item in items[2:]]
            regexp = r"\`\(?:" + r"\|".join(alternatives) + r"\)\'"
        else:
            if len(items) != 3:
                raise ValueError(f"invalid predicate {render(node)}")
            regexp = emacs_regexp(decode_string(items[2]))
        return Group("(", ["#match?", target, quote(regexp)])
    converted = [transform(item, language) for item in items]
    return Group(node.opening, [item for item in converted if item is not None])


# Keep Nix-specific adaptations here, alongside builtin-priority handling in
# convert_query. Required patterns are checked so upstream changes cannot silently
# alter these configuration-specific choices.
NIX_REMOVALS = {
    "(select_expression attrpath: (attrpath (identifier)) @property)",
    "(binding attrpath: (attrpath (identifier)) @property)",
    "(identifier) @property",
    "(identifier) @variable",
    "(variable_expression (identifier) @variable)",
}
# Emacs's non-overriding fontification lets enclosing string/path captures mask
# interpolation code. Capture only literal regions; interpolation children then
# use the ordinary Nix rules, including nested strings and escapes.
NIX_REPLACEMENTS = {
    "[(string_expression) (indented_string_expression)] @string": """
(string_fragment) @string
(string_expression "\\\"" @string)
(indented_string_expression "''" @string)
""",
    "[(path_expression) (hpath_expression) (spath_expression)] @string.special.path": """
(path_fragment) @string.special.path
(spath_expression) @string.special.path
""",
}
NIX_FUNCTION = """(binding
  attrpath: (attrpath attr: (identifier) @font-lock-function-name-face)
  expression: (function_expression))"""


def patterns(nodes: list) -> list[list]:
    """Keep each top-level form together with its captures/quantifiers."""
    result = []
    for node in nodes:
        if isinstance(node, Group):
            result.append([node])
        elif result:
            result[-1].append(node)
        else:
            raise ValueError(f"unexpected top-level token {node!r}")
    return result


def convert_query(source: str, language: str) -> str:
    output = []
    priority = []
    removed = set()
    replaced = set()
    for pattern in patterns(parse(source)):
        original = " ".join(map(render, pattern))
        if language == "nix" and original in NIX_REMOVALS:
            removed.add(original)
            continue
        if language == "nix" and original in NIX_REPLACEMENTS:
            replaced.add(original)
            pattern = parse(NIX_REPLACEMENTS[original])
        converted = [transform(node, language) for node in pattern]
        text = " ".join(render(node) for node in converted if node is not None)
        # Only Nix's variable builtins need to override later property captures.
        if language == "nix" and original.startswith("((identifier) @variable.builtin "):
            priority.append(text)
        else:
            output.append(text)
    if language == "nix":
        if removed != NIX_REMOVALS or replaced != NIX_REPLACEMENTS.keys() or len(priority) != 1:
            raise ValueError(
                "Nix query structure changed; review removals, replacements and builtin priority"
            )
        output.extend(priority)
        output.append(NIX_FUNCTION)
    return "; Generated by emacs-ts; do not edit.\n\n" + "\n\n".join(output) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("language")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        result = convert_query(args.source.read_text(encoding="utf-8"), args.language)
    except ValueError as error:
        parser.exit(1, f"{args.language}: {args.source}: {error}\n")
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    args.destination.write_text(result, encoding="utf-8")


if __name__ == "__main__":
    main()
