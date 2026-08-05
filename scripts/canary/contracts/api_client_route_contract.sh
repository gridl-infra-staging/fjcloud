#!/usr/bin/env bash
# Local route contract for hand-written web API client call sites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

usage() {
	cat >&2 <<EOF
usage: $0 [<openapi-json> <client-file>...]
EOF
	exit 2
}

if [[ "$#" -eq 0 ]]; then
	OPENAPI_JSON="$REPO_ROOT/docs/reference/openapi.json"
	CLIENT_FILES=(
		"$REPO_ROOT/web/src/lib/api/migration_client.ts"
		"$REPO_ROOT/web/src/lib/api/client.ts"
	)
	INTERFACE_SOURCE_MODE="production-types"
elif [[ "$#" -ge 2 ]]; then
	OPENAPI_JSON="$1"
	shift
	CLIENT_FILES=("$@")
	INTERFACE_SOURCE_MODE="embedded-fixtures"
else
	usage
fi

if [[ ! -f "$OPENAPI_JSON" ]]; then
	printf 'missing OpenAPI JSON: %s\n' "$OPENAPI_JSON" >&2
	exit 2
fi

for client_file in "${CLIENT_FILES[@]}"; do
	if [[ ! -f "$client_file" ]]; then
		printf 'missing client file: %s\n' "$client_file" >&2
		exit 2
	fi
done

python3 - "$REPO_ROOT" "$OPENAPI_JSON" "$INTERFACE_SOURCE_MODE" "${CLIENT_FILES[@]}" <<'PY'
from dataclasses import dataclass
from pathlib import Path
import ast
import json
import re
import sys

HTTP_METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"}

# client_paths.ts is the single owner of the `/indexes/...` prefix shape. The
# checker resolves these path-builder call expressions by reading their bodies
# from that file; it never hardcodes the prefix. A path-builder relied on here
# but missing from client_paths.ts is a loud SystemExit, never a silent skip.
REQUIRED_PATH_BUILDERS = ("indexPath", "experimentPath", "dictionaryPath")
PATH_BUILDER_NAMES = frozenset(REQUIRED_PATH_BUILDERS)

# Routes registered by the API but deliberately absent from the customer-facing
# OpenAPI (docs/reference/openapi.json). Keyed on exact method + normalized path.
# OpenAPI remains the sole documented-route source; this is the single explicit
# exemption owner, not a second route parser. Widening it is a deliberate edit.
ROUTE_EXEMPTIONS = {
    ("GET", "/internal/regions"): (
        "internal service-to-service route gated by x-internal-key; omitted from "
        "OpenAPI by design (infra/api/src/router.rs:41-44 internal_routes, nested "
        'at infra/api/src/router/route_assembly.rs .nest("/internal"))'
    ),
}


class UnsupportedRouteExpression(ValueError):
    pass


@dataclass(frozen=True)
class ClientRoute:
    path: str
    placeholder_segment_indexes: frozenset[int]


def load_provider_literals(provider_path, source):
    match = re.search(r"\bSOURCE_PROVIDERS\s*=\s*(\[[^\]]*\])\s+as\s+const", source, re.S)
    if not match:
        raise SystemExit(f"unable to extract SOURCE_PROVIDERS from {provider_path}")
    providers = ast.literal_eval(match.group(1))
    if not providers or not all(isinstance(provider, str) for provider in providers):
        raise SystemExit(f"SOURCE_PROVIDERS must be a non-empty string array in {provider_path}")
    return providers


def normalize_openapi_path(path):
    return re.sub(r"\{[^/{}]+\}", "{}", path)


def load_openapi_routes(openapi_path):
    with open(openapi_path, encoding="utf-8") as handle:
        spec = json.load(handle)
    routes = {}
    for raw_path, methods in spec.get("paths", {}).items():
        if not isinstance(methods, dict):
            continue
        normalized_path = normalize_openapi_path(raw_path)
        routes.setdefault(normalized_path, set())
        for method in methods:
            upper_method = method.upper()
            if upper_method in HTTP_METHODS:
                routes[normalized_path].add(upper_method)
    components = spec.get("components")
    if not isinstance(components, dict):
        components = {}
    schemas = components.get("schemas")
    if not isinstance(schemas, dict):
        schemas = {}
    return routes, schemas


def openapi_path_matches_client_route(openapi_path, client_route):
    openapi_segments = openapi_path.split("/")
    client_segments = client_route.path.split("/")
    if len(openapi_segments) != len(client_segments):
        return False
    for index, (openapi_segment, client_segment) in enumerate(
        zip(openapi_segments, client_segments)
    ):
        if openapi_segment == client_segment:
            continue
        if openapi_segment == "{}" and index in client_route.placeholder_segment_indexes:
            continue
        return False
    return True


def documented_methods_for_route(client_route, documented_routes):
    exact_methods = documented_routes.get(client_route.path)
    if exact_methods is not None:
        return exact_methods

    matching_methods = set()
    for openapi_path, methods in documented_routes.items():
        if openapi_path_matches_client_route(openapi_path, client_route):
            matching_methods.update(methods)
    return matching_methods or None


def find_matching_paren(source, open_index, context="this.api(...) call"):
    depth = 0
    quote = None
    template_expression_depth = 0
    escaped = False
    for index in range(open_index, len(source)):
        char = source[index]
        if quote:
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if quote == "`" and source.startswith("${", index):
                template_expression_depth += 1
                continue
            if quote == "`" and char == "}" and template_expression_depth:
                template_expression_depth -= 1
                continue
            if char == quote and template_expression_depth == 0:
                quote = None
            continue
        if char in "'\"`":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError(f"unclosed {context}")


def split_arguments(argument_source):
    arguments = []
    start = 0
    depth = 0
    structural_source = mask_typescript_non_code(argument_source)
    for index, char in enumerate(structural_source):
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            arguments.append(strip_typescript_comments(argument_source[start:index]).strip())
            start = index + 1
    tail = strip_typescript_comments(argument_source[start:]).strip()
    if tail:
        arguments.append(tail)
    return arguments


def lexical_region(source, start, terminator):
    index = start + 1
    escaped = False
    while index < len(source):
        char = source[index]
        index += 1
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == terminator:
            break
    return index


def regex_region(source, start):
    index = start + 1
    escaped = False
    in_character_class = False
    while index < len(source):
        char = source[index]
        if char in "\r\n":
            return None
        index += 1
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == "[":
            in_character_class = True
        elif char == "]":
            in_character_class = False
        elif char == "/" and not in_character_class:
            while index < len(source) and source[index].isalpha():
                index += 1
            return index
    return None


def append_lexical_region(output, source, start, end, should_mask):
    if should_mask:
        output.extend("\n" if char == "\n" else " " for char in source[start:end])
    else:
        output.extend(source[start:end])


# Non-whitespace, non-identifier, non-structural sentinel that records a masked
# literal's presence without being parseable as a field name or a delimiter.
LITERAL_PRESENCE_MARKER = "~"


def mask_typescript_non_code(
    source,
    *,
    mask_literals=True,
    mask_regex=True,
    preserve_literal_presence=False,
):
    masked = []
    index = 0
    regex_can_start = True
    regex_prefix_keywords = {
        "await", "case", "delete", "in", "instanceof", "new", "of",
        "return", "throw", "typeof", "void", "yield",
    }
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if char == "/" and next_char == "/":
            end = source.find("\n", index + 2)
            end = len(source) if end == -1 else end
            append_lexical_region(masked, source, index, end, True)
            index = end
            continue
        if char == "/" and next_char == "*":
            close = source.find("*/", index + 2)
            end = len(source) if close == -1 else close + 2
            append_lexical_region(masked, source, index, end, True)
            index = end
            continue
        if char in "'\"`":
            end = lexical_region(source, index, char)
            append_lexical_region(masked, source, index, end, mask_literals)
            if mask_literals and preserve_literal_presence:
                # Keep one inert token so newline-delimited type parsing can
                # distinguish a masked literal from no type content at all.
                # Every structural character inside the literal stays masked.
                # The marker must be non-whitespace (so `skip_type_annotation`
                # counts it as a type token) yet must NOT match IDENTIFIER_PATTERN
                # or any structural delimiter, so a masked quoted property name
                # is never read back as a phantom identifier field.
                masked[index] = LITERAL_PRESENCE_MARKER
            index = end
            regex_can_start = False
            continue
        if char == "/" and regex_can_start:
            end = regex_region(source, index)
            if end is not None:
                append_lexical_region(masked, source, index, end, mask_regex)
                index = end
                regex_can_start = False
                continue
        if char.isalpha() or char in "_$":
            end = index + 1
            while end < len(source) and (source[end].isalnum() or source[end] in "_$"):
                end += 1
            token = source[index:end]
            masked.extend(token)
            index = end
            regex_can_start = token in regex_prefix_keywords
            continue
        masked.append(char)
        index += 1
        if char.isspace():
            continue
        if char.isdigit() or char in ")]}":
            regex_can_start = False
        elif char == ".":
            regex_can_start = False
        else:
            regex_can_start = True
    return "".join(masked)


def find_matching_brace(code_source, open_index):
    depth = 0
    for index in range(open_index, len(code_source)):
        char = code_source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError("unclosed exported TypeScript interface")


IDENTIFIER_PATTERN = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")


def read_identifier(code_source, index):
    match = IDENTIFIER_PATTERN.match(code_source, index)
    if match is None:
        return None, index
    return match.group(0), match.end()


def skip_whitespace(code_source, index):
    while index < len(code_source) and code_source[index].isspace():
        index += 1
    return index


def find_matching_delimiter(code_source, open_index, open_char, close_char, context):
    depth = 0
    for index in range(open_index, len(code_source)):
        char = code_source[index]
        if char == open_char:
            depth += 1
        elif char == close_char:
            depth -= 1
            if depth == 0:
                return index
    raise ValueError(f"unclosed {context}")


def skip_angle_type_parameters(code_source, index):
    index = skip_whitespace(code_source, index)
    if index >= len(code_source) or code_source[index] != "<":
        return index
    close_index = find_matching_delimiter(
        code_source,
        index,
        "<",
        ">",
        "interface method type parameter list",
    )
    return skip_whitespace(code_source, close_index + 1)


def skip_type_annotation(code_body, index):
    brace_depth = 0
    bracket_depth = 0
    paren_depth = 0
    angle_depth = 0
    saw_type_token = False
    while index < len(code_body):
        char = code_body[index]
        at_top_level = (
            brace_depth == 0
            and bracket_depth == 0
            and paren_depth == 0
            and angle_depth == 0
        )
        # `;` and `,` are explicit member delimiters. A newline ends the
        # annotation only after a type token, including the inert token kept
        # for a masked literal. This preserves types placed on the line after
        # `:` while preventing a literal-only type from swallowing the next
        # semicolon-free member.
        if at_top_level and (char in ";," or (char == "\n" and saw_type_token)):
            return index + 1
        if not char.isspace():
            saw_type_token = True
        if char == "{":
            brace_depth += 1
        elif char == "}" and brace_depth > 0:
            brace_depth -= 1
        elif char == "[":
            bracket_depth += 1
        elif char == "]" and bracket_depth > 0:
            bracket_depth -= 1
        elif char == "(":
            paren_depth += 1
        elif char == ")" and paren_depth > 0:
            paren_depth -= 1
        elif char == "<":
            angle_depth += 1
        elif char == ">" and angle_depth > 0:
            angle_depth -= 1
        index += 1
    return index


def depth_zero_interface_properties(code_body):
    properties = set()
    brace_depth = 0
    index = 0
    while index < len(code_body):
        char = code_body[index]
        if char == "{":
            brace_depth += 1
            index += 1
            continue
        if char == "}":
            brace_depth -= 1
            index += 1
            continue
        if brace_depth != 0:
            index += 1
            continue
        if char == "[":
            close_bracket = find_matching_delimiter(
                code_body,
                index,
                "[",
                "]",
                "interface index signature",
            )
            cursor = skip_whitespace(code_body, close_bracket + 1)
            if cursor < len(code_body) and code_body[cursor] == ":":
                index = skip_type_annotation(code_body, cursor + 1)
            else:
                index = close_bracket + 1
            continue

        identifier, identifier_end = read_identifier(code_body, index)
        if identifier is None:
            index += 1
            continue
        property_name = identifier
        cursor = identifier_end
        if identifier == "readonly":
            # `readonly` is a contextual keyword, not a reserved identifier.
            # Treat it as a modifier only when another identifier follows;
            # otherwise a legal field literally named `readonly` must still
            # participate in schema parity.
            modifier_cursor = skip_whitespace(code_body, cursor)
            readonly_target, readonly_target_end = read_identifier(
                code_body, modifier_cursor
            )
            if readonly_target is not None:
                property_name = readonly_target
                cursor = readonly_target_end
            else:
                cursor = modifier_cursor
        cursor = skip_whitespace(code_body, cursor)
        if cursor < len(code_body) and code_body[cursor] == "?":
            cursor = skip_whitespace(code_body, cursor + 1)
        cursor = skip_angle_type_parameters(code_body, cursor)
        if cursor < len(code_body) and code_body[cursor] == "(":
            properties.add(property_name)
            close_paren = find_matching_paren(
                code_body,
                cursor,
                "interface method parameter list",
            )
            index = skip_type_annotation(code_body, close_paren + 1)
            continue
        if cursor < len(code_body) and code_body[cursor] == ":":
            properties.add(property_name)
            index = skip_type_annotation(code_body, cursor + 1)
            continue
        index = identifier_end
    return properties


def find_interface_body_open(code_source, header_start):
    # The header between the interface name and the body brace may contain a
    # generic parameter list or extends clause whose type arguments include
    # object types (e.g. `<T extends { id: string }>`). Those braces belong to
    # the header, not the interface body, so skip anything nested inside
    # balanced angle brackets and only accept a `{` seen at angle-depth zero as
    # the real body opening.
    angle_depth = 0
    index = header_start
    while index < len(code_source):
        char = code_source[index]
        if char == "<":
            angle_depth += 1
        elif char == ">":
            if angle_depth > 0:
                angle_depth -= 1
        elif char == "{" and angle_depth == 0:
            return index
        index += 1
    raise ValueError("exported TypeScript interface missing body")


def exported_interfaces(source):
    code_source = mask_typescript_non_code(
        source,
        preserve_literal_presence=True,
    )
    declaration_pattern = re.compile(
        r"\bexport\s+interface\s+([A-Za-z_$][A-Za-z0-9_$]*)\b"
    )
    interfaces = []
    search_at = 0
    while True:
        match = declaration_pattern.search(code_source, search_at)
        if match is None:
            return interfaces
        open_index = find_interface_body_open(code_source, match.end())
        close_index = find_matching_brace(code_source, open_index)
        body = code_source[open_index + 1:close_index]
        interfaces.append((match.group(1), depth_zero_interface_properties(body)))
        search_at = close_index + 1


def strip_typescript_comments(source):
    return mask_typescript_non_code(source, mask_literals=False, mask_regex=False)


def find_call_open_paren(code_source, member_end):
    index = member_end
    while index < len(code_source) and code_source[index].isspace():
        index += 1
    if index < len(code_source) and code_source[index] == "<":
        depth = 0
        while index < len(code_source):
            char = code_source[index]
            if char == "<":
                depth += 1
            elif char == ">":
                depth -= 1
                if depth == 0:
                    index += 1
                    break
            index += 1
        if depth != 0:
            return None
        while index < len(code_source) and code_source[index].isspace():
            index += 1
    if index >= len(code_source) or code_source[index] != "(":
        return None
    return index


def is_true_this_receiver(code_source, this_index):
    previous_index = this_index - 1
    if previous_index < 0:
        return True
    previous_character = code_source[previous_index]
    if previous_character.isalnum() or previous_character in "_$":
        return False
    if not previous_character.isspace():
        return previous_character != "."
    while previous_index >= 0 and code_source[previous_index].isspace():
        previous_index -= 1
    return previous_index < 0 or code_source[previous_index] != "."


def extract_api_calls(client_path):
    source = client_path.read_text(encoding="utf-8")
    code_source = mask_typescript_non_code(source)
    calls = []
    search_at = 0
    while True:
        api_index = code_source.find("this.api", search_at)
        if api_index == -1:
            return calls
        if not is_true_this_receiver(code_source, api_index):
            search_at = api_index + len("this.api")
            continue
        open_index = find_call_open_paren(code_source, api_index + len("this.api"))
        if open_index is None:
            search_at = api_index + len("this.api")
            continue
        close_index = find_matching_paren(code_source, open_index)
        line = source.count("\n", 0, api_index) + 1
        calls.append((line, split_arguments(source[open_index + 1:close_index])))
        search_at = close_index + 1


def unquote_literal(expression):
    expression = expression.strip()
    if len(expression) < 2 or expression[0] not in "'\"`" or expression[-1] != expression[0]:
        return None
    return expression[1:-1]


def parse_builder_parameters(parameter_source):
    parameters = []
    for raw in split_arguments(parameter_source):
        raw = raw.strip()
        if not raw:
            continue
        structural = mask_typescript_non_code(raw)
        default = None
        depth = 0
        for index, char in enumerate(structural):
            if char in "([{":
                depth += 1
            elif char in ")]}":
                depth -= 1
            elif char == "=" and depth == 0:
                following = structural[index + 1] if index + 1 < len(structural) else ""
                preceding = structural[index - 1] if index else ""
                # A default assignment `=`, not `=>`, `==`, `<=`, `>=`, or `!=`.
                if following != "=" and preceding not in "=!<>":
                    default = raw[index + 1:].strip()
                    raw = raw[:index]
                    break
        name_match = re.match(r"\s*([A-Za-z_$][A-Za-z0-9_$]*)", raw)
        if name_match is None:
            raise SystemExit(f"unable to parse path-builder parameter: {raw!r}")
        parameters.append((name_match.group(1), default))
    return parameters


def parse_path_builders(client_paths_source):
    structural = mask_typescript_non_code(client_paths_source)
    builders = {}
    for match in re.finditer(
        r"\bexport\s+function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(", structural
    ):
        name = match.group(1)
        open_paren = match.end() - 1
        close_paren = find_matching_delimiter(
            structural, open_paren, "(", ")", f"path builder {name} parameters"
        )
        parameter_source = client_paths_source[open_paren + 1:close_paren]
        brace_open = structural.index("{", close_paren)
        brace_close = find_matching_delimiter(
            structural, brace_open, "{", "}", f"path builder {name} body"
        )
        body_structural = structural[brace_open + 1:brace_close]
        return_match = re.search(r"\breturn\b", body_structural)
        if return_match is None:
            continue
        return_start = brace_open + 1 + return_match.end()
        semicolon = structural.index(";", return_start)
        return_expression = client_paths_source[return_start:semicolon].strip()
        builders[name] = (parse_builder_parameters(parameter_source), return_expression)
    return builders


def load_path_builders(client_paths_path):
    try:
        source = client_paths_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"unable to read path-builder owner: {client_paths_path}: {exc}")
    builders = parse_path_builders(source)
    missing = [name for name in REQUIRED_PATH_BUILDERS if name not in builders]
    if missing:
        raise SystemExit(
            f"path builder(s) {missing} missing from {client_paths_path}; "
            "the route contract relies on them to resolve /indexes/... call sites"
        )
    return builders


def find_interpolation_close(source, brace_open):
    depth = 0
    index = brace_open
    while index < len(source):
        char = source[index]
        if char in "'\"`":
            index = lexical_region(source, index, char)
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise UnsupportedRouteExpression("unterminated ${...} in route path expression")


def previous_significant_char(pieces):
    stripped = "".join(pieces).rstrip()
    return stripped[-1] if stripped else ""


def substitute_builder_parameters(source, bindings):
    pieces = []
    index = 0
    while index < len(source):
        char = source[index]
        if char in "'\"":
            end = lexical_region(source, index, char)
            pieces.append(source[index:end])
            index = end
            continue
        if char == "`":
            pieces.append("`")
            index += 1
            while index < len(source):
                inner = source[index]
                if inner == "\\":
                    pieces.append(source[index:index + 2])
                    index += 2
                    continue
                if inner == "`":
                    pieces.append("`")
                    index += 1
                    break
                if source.startswith("${", index):
                    close = find_interpolation_close(source, index + 1)
                    expression = source[index + 2:close]
                    pieces.append("${")
                    pieces.append(substitute_builder_parameters(expression, bindings))
                    pieces.append("}")
                    index = close + 1
                    continue
                pieces.append(inner)
                index += 1
            continue
        if char.isalpha() or char in "_$":
            end = index + 1
            while end < len(source) and (source[end].isalnum() or source[end] in "_$"):
                end += 1
            token = source[index:end]
            if token in bindings and previous_significant_char(pieces) != ".":
                pieces.append(bindings[token])
            else:
                pieces.append(token)
            index = end
            continue
        pieces.append(char)
        index += 1
    return "".join(pieces)


def parse_builder_call(expression, builders):
    match = re.match(r"([A-Za-z_$][A-Za-z0-9_$]*)\s*\(", expression)
    if match is None or match.group(1) not in PATH_BUILDER_NAMES:
        return None
    name = match.group(1)
    open_paren = match.end() - 1
    close_paren = find_matching_paren(expression, open_paren, f"{name}(...) call")
    if expression[close_paren + 1:].strip():
        raise UnsupportedRouteExpression(
            f"unsupported trailing content after {name}(...) in route path"
        )
    arguments = split_arguments(expression[open_paren + 1:close_paren])
    return name, arguments


def bind_builder_arguments(name, parameters, arguments):
    if len(arguments) > len(parameters):
        raise UnsupportedRouteExpression(
            f"{name}(...) received more arguments than declared parameters"
        )
    bindings = {}
    for position, (parameter_name, default) in enumerate(parameters):
        if position < len(arguments) and arguments[position].strip():
            bindings[parameter_name] = arguments[position].strip()
        elif default is not None:
            bindings[parameter_name] = default
        else:
            raise UnsupportedRouteExpression(
                f"{name}(...) missing required argument for '{parameter_name}'"
            )
    return bindings


def flatten_template_literal(template_literal, builders):
    body = template_literal[1:]
    if body.endswith("`"):
        body = body[:-1]
    pieces = []
    index = 0
    while index < len(body):
        char = body[index]
        if char == "\\":
            pieces.append(body[index + 1:index + 2])
            index += 2
            continue
        if body.startswith("${", index):
            close = find_interpolation_close(body, index + 1)
            expression = body[index + 2:close]
            pieces.append(flatten_route_expression(expression, builders))
            index = close + 1
            continue
        pieces.append(char)
        index += 1
    return "".join(pieces)


def flatten_route_expression(expression, builders):
    expression = expression.strip()
    if not expression:
        return ""
    if expression[0] in "'\"":
        literal = unquote_literal(expression)
        return literal if literal is not None else ""
    if expression[0] == "`":
        return flatten_template_literal(expression, builders)
    call = parse_builder_call(expression, builders)
    if call is not None:
        name, arguments = call
        parameters, return_expression = builders[name]
        bindings = bind_builder_arguments(name, parameters, arguments)
        substituted = substitute_builder_parameters(return_expression, bindings)
        return flatten_route_expression(substituted, builders)
    # Any other expression (a runtime variable, pathSegment(...), or a query
    # builder call) is a dynamic interpolation. Emit it in ${...} form so the
    # downstream template expander classifies it.
    return "${" + " ".join(expression.split()) + "}"


def resolve_path_expression(path_expression, builders):
    # client_paths.ts builders (indexPath/experimentPath/dictionaryPath) are call
    # expressions, not string literals. Resolve them to the equivalent template
    # literal the client requests at runtime so the existing matcher can compare
    # them. Plain string/template-literal path arguments pass through unchanged.
    expression = path_expression.strip()
    match = re.match(r"([A-Za-z_$][A-Za-z0-9_$]*)\s*\(", expression)
    if match is None or match.group(1) not in PATH_BUILDER_NAMES:
        return expression
    return "`" + flatten_route_expression(expression, builders) + "`"


def expand_template(template, providers):
    # Client-only query builders contribute a `?query` suffix that OpenAPI does
    # not own, so they normalize away to "" regardless of a literal `?`.
    query_builders = ("buildQueryString", "this.analyticsQuery")
    routes = [template]
    query_start = template.find("?")
    for match in re.finditer(r"\$\{([^{}]+)\}", template):
        expression = match.group(1)
        normalized_expression = " ".join(expression.strip().split())
        token = "${" + expression + "}"
        if re.fullmatch(r"pathSegment\(\s*sourceProvider\s*\)", normalized_expression):
            replacements = providers
        elif re.fullmatch(r"pathSegment\([^)]*\)", normalized_expression):
            replacements = ["{}"]
        elif any(
            re.fullmatch(re.escape(builder) + r"\(.*\)", normalized_expression)
            for builder in query_builders
        ):
            replacements = [""]
        elif query_start != -1 and match.start() > query_start:
            replacements = [""]
        elif normalized_expression == "query" and match.end() == len(template):
            replacements = [""]
        else:
            raise UnsupportedRouteExpression(
                f"unsupported template interpolation in route path: {token}"
            )
        routes = [route.replace(token, replacement) for route in routes for replacement in replacements]
    return routes


def placeholder_segment_indexes(path_template):
    indexes = set()
    for index, segment in enumerate(path_template.split("/")):
        interpolation = re.fullmatch(r"\$\{([^{}]+)\}", segment)
        if not interpolation:
            continue
        normalized_expression = " ".join(interpolation.group(1).strip().split())
        if re.fullmatch(r"pathSegment\([^)]*\)", normalized_expression):
            indexes.add(index)
    return frozenset(indexes)


def normalize_client_routes(path_expression, providers, builders):
    resolved_expression = resolve_path_expression(path_expression, builders)
    template = unquote_literal(resolved_expression)
    if template is None:
        return []
    path_template = template.split("?", 1)[0]
    placeholder_indexes = placeholder_segment_indexes(path_template)
    literal_path_content = re.sub(r"\$\{[^{}]+\}", "", path_template)
    if "{" in literal_path_content or "}" in literal_path_content:
        raise UnsupportedRouteExpression("literal braces in client route path are not allowed")
    expanded_routes = expand_template(template, providers)
    normalized_routes = []
    for route in expanded_routes:
        # OpenAPI owns path keys only; client-only query builders do not affect
        # this route contract.
        route = route.split("?", 1)[0]
        # pathSegment(sourceProvider) expands from SOURCE_PROVIDERS. Other
        # pathSegment(...) calls compare positionally against OpenAPI
        # placeholders, so parameter names cannot create false mismatches.
        normalized_routes.append(ClientRoute(normalize_openapi_path(route), placeholder_indexes))
    return sorted(set(normalized_routes), key=lambda route: route.path)


def method_literal(method_expression):
    method = unquote_literal(method_expression)
    if method is not None:
        return method.upper()
    return None


def callsite_routes(client_path, providers, builders):
    extracted = extract_api_calls(client_path)
    callsites = []
    unsupported = []
    for line, arguments in extracted:
        if len(arguments) < 2:
            unsupported.append((line, "expected method and path arguments"))
            continue
        method = method_literal(arguments[0])
        if method is None:
            unsupported.append((line, "method argument must be a string literal"))
            continue
        try:
            routes = normalize_client_routes(arguments[1], providers, builders)
        except UnsupportedRouteExpression as exc:
            unsupported.append((line, str(exc)))
            continue
        if not routes:
            unsupported.append((line, "path argument must be a string or template literal"))
            continue
        for route in routes:
            callsites.append((method, route, str(client_path), line))
    return extracted, callsites, unsupported


def display_path(repo_root, path):
    try:
        return path.resolve().relative_to(repo_root.resolve()).as_posix()
    except ValueError:
        return str(path)


def append_interface_schema_violations(interfaces, schemas, violations):
    checked = 0
    skipped = 0
    for interface_name, typescript_fields in interfaces:
        # Identical interface/schema names are the convention and sole join owner.
        schema = schemas.get(interface_name)
        if schema is None:
            skipped += 1
            continue
        checked += 1
        properties = schema.get("properties", {}) if isinstance(schema, dict) else {}
        schema_fields = set(properties) if isinstance(properties, dict) else set()
        # This contract intentionally compares field names only; optionality,
        # nullability, and value types remain owned by their respective formats.
        typescript_only = sorted(typescript_fields - schema_fields)
        schema_only = sorted(schema_fields - typescript_fields)
        if typescript_only or schema_only:
            violations.append(
                f"interface/schema field mismatch: {interface_name} "
                f"TS-only={typescript_only} schema-only={schema_only}"
            )

    total = len(interfaces)
    if total == 0:
        violations.append("no exported TypeScript interfaces found for schema contract")
    elif checked == 0:
        violations.append("interface/schema field check checked == 0; refusing vacuous success")
    return checked, skipped, total


def main():
    repo_root = Path(sys.argv[1])
    openapi_path = Path(sys.argv[2])
    interface_source_mode = sys.argv[3]
    client_paths = [Path(value) for value in sys.argv[4:]]
    production_types_path = repo_root / "web/src/lib/api/types_algolia_migration.ts"
    try:
        production_types_source = production_types_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(
            f"unable to read SOURCE_PROVIDERS owner: {production_types_path}: {exc}"
        )
    providers = load_provider_literals(production_types_path, production_types_source)
    builders = load_path_builders(repo_root / "web/src/lib/api/client_paths.ts")
    documented_routes, schemas = load_openapi_routes(openapi_path)
    violations = []
    exemption_notes = []

    call_site_total = 0
    normalized_route_total = 0
    unsupported_total = 0
    route_violation_total = 0
    exemptions_applied = 0

    # Production routes and interfaces have distinct owners. Explicit fixture
    # invocations intentionally embed both concerns in their supplied clients.
    if interface_source_mode == "production-types":
        interface_sources = [production_types_source]
    else:
        interface_sources = [path.read_text(encoding="utf-8") for path in client_paths]
    interfaces = [
        interface
        for source in interface_sources
        for interface in exported_interfaces(source)
    ]

    for client_path in client_paths:
        extracted, callsites, unsupported = callsite_routes(client_path, providers, builders)
        call_site_total += len(extracted)
        normalized_route_total += len(callsites)
        unsupported_total += len(unsupported)
        if not extracted:
            violations.append(
                f"no this.api(...) call sites found in {display_path(repo_root, client_path)}"
            )
            continue
        source_file = display_path(repo_root, client_path)
        for line, reason in unsupported:
            violations.append(f"unsupported this.api(...) call: {reason} at {source_file}:{line}")
        for method, route, _source_file, line in callsites:
            documented_methods = documented_methods_for_route(route, documented_routes)
            if documented_methods is not None and method not in documented_methods:
                documented = ",".join(sorted(documented_methods))
                violations.append(
                    f"method mismatch: {method} {route.path} at {source_file}:{line} "
                    f"(documented methods: {documented})"
                )
                route_violation_total += 1
            elif documented_methods is None:
                exemption_reason = ROUTE_EXEMPTIONS.get((method, route.path))
                if exemption_reason is not None:
                    exemptions_applied += 1
                    exemption_notes.append(
                        f"route exemption applied: {method} {route.path} at "
                        f"{source_file}:{line} — {exemption_reason}"
                    )
                else:
                    violations.append(
                        f"undocumented route: {method} {route.path} at {source_file}:{line}"
                    )
                    route_violation_total += 1

    checked, skipped, total = append_interface_schema_violations(
        interfaces, schemas, violations
    )
    for note in exemption_notes:
        print(note)
    for violation in violations:
        print(violation)
    print(f"interface/schema field check: checked={checked} skipped={skipped} total={total}")
    raw_route_hit_total = route_violation_total + exemptions_applied
    print(
        "route contract denominator: "
        f"client_files={len(client_paths)} "
        f"call_sites={call_site_total} "
        f"normalized_routes={normalized_route_total} "
        f"unsupported={unsupported_total} "
        f"raw_hits={raw_route_hit_total} "
        f"triaged_real={route_violation_total} "
        f"triaged_false_positive={exemptions_applied} "
        f"route_violations={route_violation_total} "
        f"exemptions={exemptions_applied}"
    )
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
