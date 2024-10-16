# Copyright 2024 The Bazel Authors. All rights reserved.
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
load("//python/private:semver.bzl", "semver")

def _valid(left, op, right, *, env):
    clean_left = left.strip(" \"'")
    clean_right = right.strip(" \"'")

    if clean_left not in env and clean_right not in env:
        fail("Got '{} {} {}', but only the following PEP508 env markers are supported: {}".format(left, op, right, env.keys()))

    return clean_left, clean_right

def _version(value, *, env):
    return semver(env.get(value, value)).key()

# Taken from
# https://peps.python.org/pep-0508/#grammar
#
# version_cmp   = wsp* '<' | '<=' | '!=' | '==' | '>=' | '>' | '~=' | '==='
VERSION_CMP = sorted(
    [
        i.strip(" '")
        for i in "'<' | '<=' | '!=' | '==' | '>=' | '>' | '~=' | '==='".split(" | ")
    ],
    key = lambda x: (-len(x), x),
)

_STATE = enum(
    STRING = "string",
    VAR = "var",
    OP = "op",
    NONE = "none",
)

def _cmp(left, op, right, *, env):
    left, right = _valid(left, op, right, env = env)
    op = op.strip()

    if op in VERSION_CMP:
        left = _version(left, env = env)
        right = _version(right, env = env)
        if op == "<":
            return left < right
        elif op == ">":
            return left > right
        elif op == "<=":
            return left <= right
        elif op == ">=":
            return left >= right
        elif op == "!=" or op == "~=":
            return left != right
        elif op == "==" or "===":
            return left == right
        else:
            fail("BUG: missed op for comparing versions: '{}'".format(op))
    else:
        fail("TODO")

def tokenize(value):
    """Tokenize the input string

    Args:
        value: {type}`str` The input to tokenize.

    Returns:
        The {type}`str` that is the list of recognized tokens that should be parsed.
    """
    if not value:
        return []

    tokens = []
    tmp = ""
    state = _STATE.NONE

    _BRACKETS = "()"
    _OPCHARS = "<>!="
    _QUOTES = "'\""
    char = ""

    for _ in range(2 * len(value)):
        char = value[0] if value else ""
        if not char:
            break

        if char in _BRACKETS:
            tokens.append(char)
            state = _STATE.NONE
        elif (
            (state == _STATE.STRING and char in _QUOTES) or
            (state == _STATE.VAR and not char.isalnum() and char != "_") or
            (state == _STATE.OP and char not in _OPCHARS)
        ):
            state = _STATE.NONE

            if tmp:
                tokens.append(tmp)
                tmp = ""

            continue
        elif state != _STATE.NONE:
            tmp += char
        elif char in _QUOTES:
            state = _STATE.STRING
        elif char.isalnum():
            state = _STATE.VAR
            tmp += char
        elif char in _OPCHARS:
            tmp += char
            state = _STATE.OP
        elif char == " ":
            state = _STATE.NONE
        else:
            fail("Unknown char: {}".format(char))

        if value:
            value = value[1:]
        else:
            break

    if tmp:
        tokens.append(tmp)

    return tokens

def _impl(ctx):
    current_env = {
        key: getattr(ctx.attr, "_" + key)[config_common.FeatureFlagInfo].value
        for key in [
            "implementation_name",
            "implementation_version",
            "os_name",
            "platform_machine",
            "platform_python_implementation",
            "platform_release",
            "platform_system",
            "platform_version",
            "python_full_version",
            "python_version",
            "sys_platform",
        ]
    }

    marker = ctx.attr.marker
    if current_env:
        tokens = tokenize(marker)

        value = None
        combine = None
        left, op, right = None, None, None
        take = False
        for _ in range(len(tokens)):
            if not tokens:
                break

            if take:
                take = False
            elif value == None:
                take = True
                continue
            elif tokens[0] == "or":
                if value:
                    tokens = []
                else:
                    take = True
                    combine = "or"
                    tokens = tokens[1:]
                continue
            elif tokens[0] == "and" and tokens[1] == "not":
                if value:
                    take = True
                    tokens = tokens[2:]
                    combine = "and not"
                else:
                    tokens = []
                continue
            elif tokens[0] == "and":
                if value:
                    take = True
                    tokens = tokens[1:]
                    combine = "and"
                else:
                    tokens = []
                continue
            else:
                fail("\n".join([
                    "TODO: processed '{}', but remaining: {}".format(marker, tokens),
                    "  value: {}".format(value),
                    "  combine: {}".format(combine),
                    "  left: {}".format(left),
                    "  op: {}".format(op),
                    "  right: {}".format(right),
                    "  take: {}".format(take),
                ]))

            left, op, right = tokens[0:3]
            tokens = tokens[3:]

            value = _cmp(left, op, right, env = current_env)
            if combine == "and not":
                value = not value

        if tokens:
            fail("BUG: unprocessed tokens: {}".format(tokens))

        value = "yes" if value else "no"
    else:
        value = ""

    return [config_common.FeatureFlagInfo(value = value)]

env_marker_feature_flag = rule(
    implementation = _impl,
    attrs = {
        "marker": attr.string(mandatory = True),
        # See https://peps.python.org/pep-0508
        "_implementation_name": attr.label(default = "//python/private/pypi:pep508_implementation_name"),
        "_implementation_version": attr.label(default = "//python/config_settings:python_version"),
        "_os_name": attr.label(default = "//python/private/pypi:pep508_os_name"),
        "_platform_machine": attr.label(default = "//python/private/pypi:pep508_platform_machine"),
        "_platform_python_implementation": attr.label(default = "//python/private/pypi:pep508_platform_python_implementation"),
        "_platform_release": attr.label(default = "//python/private/pypi:pep508_platform_release"),
        "_platform_system": attr.label(default = "//python/private/pypi:pep508_platform_system"),
        "_platform_version": attr.label(default = "//python/private/pypi:pep508_platform_version"),
        "_python_full_version": attr.label(default = "//python/config_settings:python_version"),
        "_python_version": attr.label(default = "//python/config_settings:python_version_major_minor"),
        "_sys_platform": attr.label(default = "//python/private/pypi:pep508_sys_platform"),
    },
)

def _impl_pep508_env(ctx):
    return [config_common.FeatureFlagInfo(value = ctx.attr.value)]

pep508_env = rule(
    implementation = _impl_pep508_env,
    attrs = {
        "value": attr.string(mandatory = True),
    },
)
