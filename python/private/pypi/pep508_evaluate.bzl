# Copyright 2025 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""This module is for implementing PEP508 in starlark as FeatureFlagInfo
"""

load("//python/private:enum.bzl", "enum")
load("//python/private:version.bzl", "version")

# The expression parsing and resolution for the PEP508 is below
#

_STATE = enum(
    VAR = "var",
    OP = "op",
    NONE = "none",
)
_BRACKETS = "()"
_OPCHARS = "<>!=~"
_NON_VERSION_VAR_NAMES = [
    "implementation_name",
    "os_name",
    "platform_machine",
    "platform_python_implementation",
    "platform_system",
    "platform_version",
    "sys_platform",
    "extra",
]

# The variables that are compared as versions if the other side of the
# expression is a valid version specifier.
_VERSION_VAR_NAMES = [
    "implementation_version",
    "platform_release",
    "python_full_version",
    "python_version",
]

# The deprecated names that are still found in the metadata of old packages, see
# https://packaging.python.org/en/latest/specifications/dependency-specifiers/#environment-markers
_VAR_NAME_ALIASES = {
    "os.name": "os_name",
    "platform.machine": "platform_machine",
    "platform.python_implementation": "platform_python_implementation",
    "platform.version": "platform_version",
    "python_implementation": "platform_python_implementation",
    "sys.platform": "sys_platform",
}
_AND = "and"
_OR = "or"
_NOT = "not"

# The variables that are valid in the markers, but that we cannot evaluate yet.
_UNSUPPORTED_VAR_NAMES = [
    "dependency_groups",
    "extras",
]
_OPERATORS = ["!=", "<", "<=", "==", "===", ">", ">=", "in", "not in", "~="]
_ENV_ALIASES = "_aliases"

def tokenize(marker):
    """Tokenize the input string.

    The output will have double-quoted values (i.e. the quoting will be normalized) and all of the whitespace will be trimmed.

    Args:
        marker: {type}`str` The input to tokenize.

    Returns:
        The {type}`str` that is the list of recognized tokens that should be parsed.
    """
    tokens, err = _tokenize(marker)
    if err:
        fail(err)

    return tokens

def _tokenize(marker):
    """Tokenize the marker.

    Returns:
        A tuple of the list of tokens and an error message, where one of them is None.
    """
    tokens = []
    rest = marker

    # Find the strings, because anything can be in them, and tokenize what is
    # between them. Each iteration handles one string, which is at least 2 chars.
    for _ in range(len(marker) // 2 + 1):
        double = rest.find('"')
        single = rest.find("'")
        if double < 0 and single < 0:
            break

        if single < 0 or (double >= 0 and double < single):
            start, quote = double, '"'
        else:
            start, quote = single, "'"

        end = rest.find(quote, start + 1)
        if end < 0:
            return None, "Unterminated string in the marker: {}".format(marker)

        err = _tokenize_unquoted(rest[:start], tokens)
        if err:
            return None, "{} in the marker: {}".format(err, marker)

        tokens.append('"{}"'.format(rest[start + 1:end]))
        rest = rest[end + 1:]

    err = _tokenize_unquoted(rest, tokens)
    if err:
        return None, "{} in the marker: {}".format(err, marker)

    return tokens, None

def _tokenize_unquoted(text, tokens):
    """Tokenize the text that does not have strings.

    Args:
        text: {type}`str` The text to tokenize.
        tokens: {type}`list[str]` The list to append the tokens to.

    Returns:
        {type}`str | None` the error message if the text is invalid.
    """
    for word in text.replace("(", " ( ").replace(")", " ) ").replace("\t", " ").split(" "):
        if not word:
            continue
        elif word in _BRACKETS or not word.strip(_OPCHARS):
            tokens.append(word)
        elif word[0].isalnum() and word.replace("_", "").replace(".", "").isalnum():
            if word == "in" and tokens and tokens[-1] == _NOT:
                tokens[-1] = "not in"
            else:
                tokens.append(word)
        else:
            # The slow path for when the variables and the operators are not
            # separated by whitespace, e.g. `os_name=="posix"`.
            err = _tokenize_word(word, tokens)
            if err:
                return err

    return None

def _tokenize_word(word, tokens):
    """Tokenize a word that has variables and operators without whitespace between them."""
    token = ""
    state = _STATE.NONE

    # The trailing space terminates the last token.
    for char in (word + " ").elems():
        if state == _STATE.VAR:
            if char.isalnum() or char in "_.":
                token += char
                continue

            if token == "in" and tokens and tokens[-1] == _NOT:
                tokens[-1] = "not in"
            else:
                tokens.append(token)
            state = _STATE.NONE
        elif state == _STATE.OP:
            if char in _OPCHARS:
                token += char
                continue

            tokens.append(token)
            state = _STATE.NONE

        if char.isalnum():
            state = _STATE.VAR
            token = char
        elif char in _OPCHARS:
            state = _STATE.OP
            token = char
        elif char != " ":
            return "Cannot parse '{}'".format(char)

    return None

def _syntax_error(marker, tokens, env):
    """Check that the tokens form a valid expression.

    Args:
        marker: {type}`str` The marker for the error messages.
        tokens: {type}`list[str]` The tokens of the marker.
        env: {type}`dict[str, str]` The environment, the variables that are in
            it can be used in the marker in addition to the ones from the spec.

    Returns:
        {type}`str | None` the error message if the marker is invalid.
    """
    depth = 0
    want_operand = True
    skip = 0
    for i, token in enumerate(tokens):
        if skip:
            skip -= 1
        elif not want_operand:
            if token == ")":
                depth -= 1
            elif token in [_AND, _OR]:
                want_operand = True
            else:
                return "Expected 'and', 'or' or ')' before '{}' in the marker: {}".format(token, marker)
        elif token == "(":
            depth += 1
        elif token == ")" and i > 0 and tokens[i - 1] == "(":
            # NOTE: this is not in the spec, but it is how we represent an
            # expression that is always true in the partially evaluated markers.
            depth -= 1
            want_operand = False
        elif token == _NOT:
            # NOTE: this is not in the spec, but the partially evaluated markers
            # may have it.
            pass
        else:
            err = _expr_syntax_error(tokens[i:i + 3], env)
            if err:
                return "{} in the marker: {}".format(err, marker)
            skip = 2
            want_operand = False

        if depth < 0:
            return "Unbalanced ')' in the marker: {}".format(marker)

    if tokens and want_operand:
        return "Unexpected end of the marker: {}".format(marker)
    if depth:
        return "Unbalanced '(' in the marker: {}".format(marker)

    return None

def _expr_syntax_error(expr, env):
    """Check `<variable> <operator> <string>` or `<string> <operator> <variable>`."""
    if len(expr) != 3 or expr[1] not in _OPERATORS:
        return "Expected '<variable> <operator> <string>' at '{}'".format(" ".join(expr))

    left, _, right = expr
    left_is_str = left.startswith('"')
    if left_is_str == right.startswith('"'):
        return "Expected a variable and a quoted string at '{}'".format(" ".join(expr))

    var_name = right if left_is_str else left
    var_name = _VAR_NAME_ALIASES.get(var_name, var_name)
    if not (
        var_name in _VERSION_VAR_NAMES or
        var_name in _NON_VERSION_VAR_NAMES or
        var_name in _UNSUPPORTED_VAR_NAMES or
        var_name in env
    ):
        return "Unknown variable '{}'".format(var_name)

    return None

def evaluate(marker, *, env, strict = True, _fail = fail):
    """Evaluate the marker against a given env.

    Args:
        marker: {type}`str` The string marker to evaluate.
        env: {type}`dict[str, str]` The environment to evaluate the marker against.
        strict: {type}`bool` A setting to not fail on missing values in the env.
        _fail: Used for tests

    Returns:
        The {type}`bool | str` If the marker is compatible with the given env. If strict is
        `False`, then the output type is `str` which will represent the remaining
        expression that has not been evaluated.
    """
    tokens, err = _tokenize(marker)
    if not err:
        err = _syntax_error(marker, tokens, env)
    if err:
        return _fail(err)

    # The tokens are known to be a valid expression at this point, so we can
    # evaluate them in a single pass. Starlark does not have recursion, hence
    # there is a stack with a frame for each open parenthesis. Because `not`
    # binds tighter than `and`, which binds tighter than `or`, a frame is:
    # * The value of the `or` operands that we have seen so far.
    # * The value of the `and` operands that we have seen since the last `or`.
    # * The number of `not` to apply to the next operand.
    frame = [None, None, 0]
    stack = [frame]
    skip = 0
    for i, token in enumerate(tokens):
        if skip:
            skip -= 1
            continue
        elif token == _AND:
            continue
        elif token == _OR:
            frame[0] = _frame_value(frame)
            frame[1] = None
            continue
        elif token == _NOT:
            frame[2] += 1
            continue
        elif token == "(":
            frame = [None, None, 0]
            stack.append(frame)
            continue
        elif token == ")":
            value = _frame_value(stack.pop())
            if type(value) == type(""):
                value = "({})".format(value)
            frame = stack[-1]
        else:
            value = marker_expr(token, tokens[i + 1], tokens[i + 2], env = env, strict = strict)
            skip = 2

        for _ in range(frame[2]):
            value = _not_fn(value)
        frame[2] = 0
        frame[1] = value if frame[1] == None else _and_fn(frame[1], value)

    return _frame_value(frame)

def _frame_value(frame):
    """Return the value of what has been evaluated in the frame so far."""
    or_value, and_value, _ = frame
    if and_value == None:
        # No marker and `()` evaluate to True.
        return True
    elif or_value == None:
        return and_value
    else:
        return _or_fn(or_value, and_value)

_STRING_REPLACEMENTS = {
    "!=": "neq",
    "(": "_",
    ")": "_",
    "<": "lt",
    "<=": "lteq",
    "==": "eq",
    "===": "eeq",
    ">": "gt",
    ">=": "gteq",
    "not in": "not_in",
    "~=": "cmp",
}

def to_string(marker):
    return "_".join([
        _STRING_REPLACEMENTS.get(t, t)
        for t in tokenize(marker)
    ]).replace("\"", "")

def _and_fn(x, y):
    """Our custom `and` evaluation function.

    Allow partial evaluation if one of the values is a string, return the
    string value because that means that `marker_expr` was set to
    `strict = False` and we are only evaluating what we can.
    """
    if not (x and y):
        return False

    x_is_str = type(x) == type("")
    y_is_str = type(y) == type("")
    if x_is_str and y_is_str:
        return "{} and {}".format(x, y)
    elif x_is_str:
        return x
    else:
        return y

def _or_fn(x, y):
    """Our custom `or` evaluation function.

    Allow partial evaluation if one of the values is a string, return the
    string value because that means that `marker_expr` was set to
    `strict = False` and we are only evaluating what we can.
    """
    x_is_str = type(x) == type("")
    y_is_str = type(y) == type("")

    if x_is_str and y_is_str:
        return "{} or {}".format(x, y) if x and y else ""
    elif x_is_str:
        return "" if y else x
    elif y_is_str:
        return "" if x else y
    else:
        return x or y

def _not_fn(x):
    """Our custom `not` evaluation function.

    Allow partial evaluation if the value is a string.
    """
    if type(x) == type(""):
        return "not {}".format(x)
    else:
        return not x

def marker_expr(left, op, right, *, env, strict = True):
    """Evaluate a marker expression

    Args:
        left: {type}`str` the env identifier or a value quoted in `"`.
        op: {type}`str` the operation to carry out.
        right: {type}`str` the env identifier or a value quoted in `"`.
        strict: {type}`bool` if false, only evaluates the values that are present
            in the environment, otherwise returns the original expression.
            If true, then it fails if the variable is not in the environment.
        env: {type}`dict[str, str]` the `env` to substitute `env` identifiers in
            the `<left> <op> <right>` expression. Note, if `env` has a key
            "_aliases", then we will do normalization so that we can ensure
            that e.g. `aarch64` evaluation in the `platform_machine` works the
            same way irrespective if the marker uses `arm64` or `aarch64` value
            in the expression.

    Returns:
        {type}`bool` if the expression evaluation result or {type}`str` if the expression
        could not be evaluated.
    """
    left_is_str = left.startswith('"')
    var_name = right if left_is_str else left
    var_name = _VAR_NAME_ALIASES.get(var_name, var_name)
    if var_name not in env:
        if not strict:
            return "{} {} {}".format(left, op, right)

        fail("The variable '{}' is not in the environment, cannot evaluate: {} {} {}".format(
            var_name,
            left,
            op,
            right,
        ))

    value = left if left_is_str else right
    value = value[1:-1]
    if _ENV_ALIASES in env:
        # Normalize the literal value using per-variable normalization
        # functions. This handles platform aliases (e.g. arm64 -> aarch64)
        # and PEP 685 extra name normalization (e.g. db-backend -> db_backend).
        value = env.get(_ENV_ALIASES, {}).get(var_name, lambda x: x)(value)

    if left_is_str:
        left, right = value, env[var_name]
    else:
        left, right = env[var_name], value

    if var_name in _VERSION_VAR_NAMES:
        return _version_expr(left, op, right)
    elif var_name in _NON_VERSION_VAR_NAMES:
        return _env_expr(left, op, right)
    else:
        # Do not fail here, just evaluate the expression to False.
        return False

def _env_expr(left, op, right):
    """Evaluate a string comparison expression"""
    if op == "==":
        return left == right
    elif op == "!=":
        return left != right
    elif op == "in":
        return left in right
    elif op == "not in":
        return left not in right
    elif op in ["<", ">"]:
        # The ordered comparison is only defined for versions, which means
        # that only the equality can be checked.
        return False
    elif op in ["<=", ">="]:
        return left == right
    else:
        return fail("unsupported op: '{}' {} '{}'".format(left, op, right))

_VERSION_OPERATORS = {
    "!=": version.is_ne,
    "<": version.is_lt,
    "<=": version.is_le,
    "==": version.is_eq,
    ">": version.is_gt,
    ">=": version.is_ge,
    "~=": version.is_compatible,
}

def _parse_specifier(op, value):
    """Parse the version of a version specifier.

    Returns:
        The parsed version or None if `<op><value>` is not a valid version specifier.
    """
    if op not in _VERSION_OPERATORS:
        return None

    spec = version.parse(value)
    if spec == None:
        return None

    if op in ["==", "!="]:
        return spec

    # Only the equality can be used with prefix matching or local versions.
    if spec.is_prefix or spec.local:
        return None

    if op == "~=" and len(spec.release) < 2:
        return None

    return spec

def _version_expr(left, op, right):
    """Evaluate a version comparison expression"""
    if op == "===" and not [c for c in " \t\n;)".elems() if c in right.strip()]:
        # https://packaging.python.org/en/latest/specifications/version-specifiers/#arbitrary-equality
        return left.strip().lower() == right.strip().lower()

    spec = _parse_specifier(op, right)
    if spec == None:
        # Per spec, if it is not a valid version specifier, then fallback to
        # the string comparison.
        return _env_expr(left, op, right)

    candidate = version.parse(left)
    if candidate == None or candidate.is_prefix:
        # Something that is not a version cannot match a version specifier.
        return False

    return _VERSION_OPERATORS[op](candidate, spec)
