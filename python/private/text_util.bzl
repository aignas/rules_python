# Copyright 2023 The Bazel Authors. All rights reserved.
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

"""Text manipulation utilities useful for repository rule writing."""

def _indent(text, indent = " " * 4):
    if "\n" not in text:
        return indent + text

    return "\n".join([indent + line for line in text.splitlines()])

def _render_alias(name, actual, *, visibility = None):
    args = [
        "name = \"{}\",".format(name),
        "actual = {},".format(actual),
    ]

    if visibility:
        args.append("visibility = {},".format(render.list(visibility)))

    return "\n".join([
        "alias(",
    ] + [_indent(arg) for arg in args] + [
        ")",
    ])

def _render_dict(d, *, key_repr = repr, value_repr = repr):
    return "\n".join([
        "{",
        _indent("\n".join([
            "{}: {},".format(key_repr(k), value_repr(v))
            for k, v in d.items()
        ])),
        "}",
    ])

def _render_select(selects, *, no_match_error = None, key_repr = repr, value_repr = repr, name = "select"):
    dict_str = _render_dict(selects, key_repr = key_repr, value_repr = value_repr) + ","

    if no_match_error:
        args = "\n".join([
            "",
            _indent(dict_str),
            _indent("no_match_error = {},".format(no_match_error)),
            "",
        ])
    else:
        args = "\n".join([
            "",
            _indent(dict_str),
            "",
        ])

    return "{}({})".format(name, args)

def _render_list(items):
    if not items:
        return "[]"

    if len(items) == 1:
        return "[{}]".format(repr(items[0]))

    return "\n".join([
        "[",
        _indent("\n".join([
            "{},".format(repr(item))
            for item in items
        ])),
        "]",
    ])

def _render_tuple(items):
    if not items:
        return "tuple()"

    if len(items) == 1:
        return "({},)".format(repr(items[0]))

    return "\n".join([
        "(",
        _indent("\n".join([
            "{},".format(repr(item))
            for item in items
        ])),
        ")",
    ])

def _config_setting(*, name, flag_values = None, constraint_values = None, **kwargs):
    lines = [
        "name = \"{}\",".format(name),
    ]
    if flag_values:
        lines.append(
            "flag_values = {},".format(
                _render_dict(flag_values),
            ),
        )
    if constraint_values:
        lines.append(
            "constraint_values = {},".format(
                _render_list(constraint_values),
            ),
        )
    return "\n".join([
        "config_setting(",
        _indent("\n".join(lines + [
            "{} = {},".format(k, repr(v))
            for k, v in kwargs.items()
        ])),
        ")",
    ])

def _is_python_config_setting(name, *, python_version, flag_values = None, constraint_values = None, **kwargs):
    lines = [
        "name = \"{}\",".format(name),
        "python_version = \"{}\",".format(python_version),
    ]
    if flag_values:
        lines.append(
            "flag_values = {},".format(
                _render_dict(flag_values),
            ),
        )
    if constraint_values:
        lines.append(
            "constraint_values = {},".format(
                _render_list(constraint_values),
            ),
        )

    return "\n".join([
        "is_python_config_setting(",
        _indent("\n".join(lines + [
            "{} = {},".format(k, repr(v))
            for k, v in kwargs.items()
        ])),
        ")",
    ])

render = struct(
    alias = _render_alias,
    dict = _render_dict,
    indent = _indent,
    list = _render_list,
    tuple = _render_tuple,
    select = _render_select,
    config_setting = _config_setting,
    is_python_config_setting = _is_python_config_setting,
)
