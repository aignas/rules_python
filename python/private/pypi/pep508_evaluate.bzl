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
    STRING = "string",
    VAR = "var",
    OP = "op",
    NONE = "none",
)
_BRACKETS = "()"
_OPCHARS = "<>!=~"
_QUOTES = "'\""
_WSP = " \t"
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
    token = ""
    state = _STATE.NONE
    quote = ""

    # The trailing space terminates the last token.
    for char in (marker + " ").elems():
        if state == _STATE.STRING:
            # Anything can be in the string except for the quote that it was
            # started with.
            if char == quote:
                tokens.append('"{}"'.format(token))
                token = ""
                state = _STATE.NONE
            else:
                token += char
            continue

        if state == _STATE.VAR:
            if char.isalnum() or char in "_.":
                token += char
                continue

            if token == "in" and tokens and tokens[-1] == _NOT:
                tokens[-1] = "not in"
            else:
                tokens.append(token)
            token = ""
            state = _STATE.NONE
        elif state == _STATE.OP:
            if char in _OPCHARS:
                token += char
                continue

            tokens.append(token)
            token = ""
            state = _STATE.NONE

        if char in _QUOTES:
            state = _STATE.STRING
            quote = char
        elif char in _BRACKETS:
            tokens.append(char)
        elif char.isalnum():
            state = _STATE.VAR
            token = char
        elif char in _OPCHARS:
            state = _STATE.OP
            token = char
        elif char not in _WSP:
            return None, "Cannot parse '{}' in the marker: {}".format(char, marker)

    if state == _STATE.STRING:
        return None, "Unterminated string in the marker: {}".format(marker)

    return tokens, None

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

def evaluate(marker, *, env, strict = True, _fail = fail, **kwargs):
    """Evaluate the marker against a given env.

    Args:
        marker: {type}`str` The string marker to evaluate.
        env: {type}`dict[str, str]` The environment to evaluate the marker against.
        strict: {type}`bool` A setting to not fail on missing values in the env.
        _fail: Used for tests
        **kwargs: Extra kwargs to be passed to the expression evaluator.

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

    ast = _new_expr(marker = marker, **kwargs)
    for _ in range(len(tokens) * 2):
        if not tokens:
            break

        tokens = ast.parse(env = env, tokens = tokens, strict = strict)

    if not tokens:
        return ast.value()

    fail("Could not evaluate: {}".format(marker))

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

def _new_expr(
        *,
        marker,
        and_fn = _and_fn,
        or_fn = _or_fn,
        not_fn = _not_fn):
    # buildifier: disable=uninitialized
    self = struct(
        marker = marker,
        tree = [],
        parse = lambda **kwargs: _parse(self, **kwargs),
        value = lambda: _value(self),
        # This is a way for us to have a handle to the currently constructed
        # expression tree branch.
        current = lambda: self._current[-1] if self._current else None,
        _current = [],
        _and = and_fn,
        _or = or_fn,
        _not = not_fn,
    )
    return self

def _parse(self, *, env, tokens, strict = False):
    """The parse function takes the consumed tokens and returns the remaining."""
    token, remaining = tokens[0], tokens[1:]

    if token == "(":
        expr = _open_parenthesis(self)
    elif token == ")":
        expr = _close_parenthesis(self)
    elif token == _AND:
        expr = _and_expr(self)
    elif token == _OR:
        expr = _or_expr(self)
    elif token == _NOT:
        expr = _not_expr(self)
    else:
        expr = marker_expr(env = env, strict = strict, *tokens[:3])
        remaining = tokens[3:]

    _append(self, expr)
    return remaining

def _value(self):
    """Evaluate the expression tree"""
    if not self.tree:
        # Basic case where no marker should evaluate to True
        return True

    for _ in range(len(self.tree)):
        if len(self.tree) == 1:
            return self.tree[0]

        # Resolve all of the `or` expressions as it is safe to do now since all
        # `and` and `not` expressions have been taken care of by now.
        if getattr(self.tree[-2], "op", None) == _OR:
            current = self.tree.pop()
            self.tree[-1] = self.tree[-1].value(current)
        else:
            break

    fail("BUG: invalid state: {}".format(self.tree))

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

# Code to allowing to combine expressions with logical operators

def _append(self, value):
    if value == None:
        return

    current = self.current() or self
    op = getattr(value, "op", None)

    if op == _NOT:
        current.tree.append(value)
    elif op in [_AND, _OR]:
        value.append(current.tree[-1])
        current.tree[-1] = value
    elif not current.tree:
        current.tree.append(value)
    elif hasattr(current.tree[-1], "append"):
        current.tree[-1].append(value)
    elif hasattr(current.tree, "_append"):
        current.tree._append(value)
    else:
        fail("Cannot evaluate '{}' in '{}', current: {}".format(value, self.marker, current))

def _open_parenthesis(self):
    """Add an extra node into the tree to perform evaluate inside parenthesis."""
    self._current.append(_new_expr(
        marker = self.marker,
        and_fn = self._and,
        or_fn = self._or,
        not_fn = self._not,
    ))

def _close_parenthesis(self):
    """Backtrack and evaluate the expression within parenthesis."""
    value = self._current.pop().value()
    if type(value) == type(""):
        return "({})".format(value)
    else:
        return value

def _not_expr(self):
    """Add an extra node into the tree to perform an 'not' operation."""

    def _append(value):
        """Append a value to the not expression node.

        This codifies `not` precedence over `and` and performs backtracking to
        evaluate any `not` statements and forward the value to the first `and`
        statement if needed.
        """

        current = self.current() or self
        current.tree[-1] = self._not(value)

        for _ in range(len(current.tree)):
            if not len(current.tree) > 1:
                break

            op = getattr(current.tree[-2], "op", None)
            if op == None:
                pass
            elif op == _NOT:
                value = current.tree.pop()
                current.tree[-1] = self._not(value)
                continue
            elif op == _AND:
                value = current.tree.pop()
                current.tree[-1].append(value)
            elif op != _OR:
                fail("BUG: '{} not' compound is unsupported".format(current.tree[-1]))

            break

    return struct(
        op = _NOT,
        append = _append,
    )

def _and_expr(self):
    """Add an extra node into the tree to perform an 'and' operation"""
    maybe_value = [None]

    def _append(value):
        """Append a value to the and expression node.

        Here we backtrack, but we only evaluate the current `and` statement -
        all of the `not` statements will be by now evaluated and `or`
        statements need to be evaluated later.
        """
        if maybe_value[0] == None:
            maybe_value[0] = value
            return

        current = self.current() or self
        current.tree[-1] = self._and(maybe_value[0], value)

    return struct(
        op = _AND,
        append = _append,
        # private fields that help debugging
        _maybe_value = maybe_value,
    )

def _or_expr(self):
    """Add an extra node into the tree to perform an 'or' operation"""
    maybe_value = [None]

    def _append(value):
        """Append a value to the or expression node.

        Here we just append the extra values to the tree and the `or`
        statements will be evaluated in the _value() function.
        """
        if maybe_value[0] == None:
            maybe_value[0] = value
            return

        current = self.current() or self
        current.tree.append(value)

    return struct(
        op = _OR,
        value = lambda x: self._or(maybe_value[0], x),
        append = _append,
        # private fields that help debugging
        _maybe_value = maybe_value,
    )
