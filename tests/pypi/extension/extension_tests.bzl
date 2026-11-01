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

""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@rules_testing//lib:truth.bzl", "subjects")
load("//python/private:pyproject_utils.bzl", "resolve_dependency_groups")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:extension.bzl", "build_config", "default_platforms", "parse_modules")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:platform.bzl", _plat = "platform")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:pyproject_packages.bzl", "dependency_graph_from_uv_lock", "dependency_group_selection", "merge_dependency_graphs", "packages_from_dependency_groups", "testonly_packages_from_graph")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:whl_config_setting.bzl", "whl_config_setting")  # buildifier: disable=bzl-visibility
load("//tests/support/mocks:mocks.bzl", "mocks")
load(":pip_parse.bzl", _configure = "configure", _parse = "pip_parse")

_tests = []

def _pypi_mock_mctx(*modules, os_name = "unittest", arch_name = "exotic", environ = {}, read = None, mock_files = {}):
    _ = read  # @unused
    return mocks.mctx(
        modules = list(modules),
        os_name = os_name,
        arch_name = arch_name,
        environ = environ,
        mock_files = {
            "requirements.txt": """\
simple==0.0.1 \
    --hash=sha256:deadbeef \
    --hash=sha256:deadbaaf""",
        } | mock_files,
    )

def _default(
        *,
        arch_name = None,
        auth_patterns = None,
        config_settings = None,
        default_hub = "",
        env = None,
        index_url = None,
        marker = None,
        netrc = None,
        os_name = None,
        platform = None,
        pyproject_toml = None,
        unified_hub_requirements_bzl = False,
        whl_platform_tags = None,
        whl_abi_tags = None):
    return struct(
        arch_name = arch_name,
        auth_patterns = auth_patterns or {},
        config_settings = config_settings,
        default_hub = default_hub,
        env = env or {},
        index_url = index_url or "",
        marker = marker or "",
        netrc = netrc,
        os_name = os_name,
        platform = platform,
        pyproject_toml = pyproject_toml,
        unified_hub_requirements_bzl = unified_hub_requirements_bzl,
        whl_abi_tags = whl_abi_tags or [],
        whl_platform_tags = whl_platform_tags or [],
    )

# The default value for the default platforms tags use in `_mod`.
_default_tags_default = [
    _default(
        platform = "{}_{}{}".format(os, cpu, freethreaded),
        os_name = os,
        arch_name = cpu,
        config_settings = [
            "@platforms//os:{}".format(os),
            "@platforms//cpu:{}".format(cpu),
        ],
        whl_abi_tags = ["cp{major}{minor}t"] if freethreaded else ["abi3", "cp{major}{minor}"],
        whl_platform_tags = whl_platform_tags,
    )
    for (os, cpu, freethreaded), whl_platform_tags in {
        ("linux", "x86_64", ""): ["linux_x86_64", "manylinux_*_x86_64"],
        ("linux", "x86_64", "_freethreaded"): ["linux_x86_64", "manylinux_*_x86_64"],
        ("linux", "aarch64", ""): ["linux_aarch64", "manylinux_*_aarch64"],
        ("osx", "aarch64", ""): ["macosx_*_arm64"],
        ("windows", "aarch64", ""): ["win_arm64"],
    }.items()
]

def _dep(*, name, extra_targets = []):
    return struct(
        name = name,
        extra_targets = extra_targets,
    )

def _mod(*, name, default = _default_tags_default, parse = [], override = [], whl_mods = [], dep = [], configure = [], is_root = True):
    return struct(
        name = name,
        tags = struct(
            parse = parse,
            override = override,
            whl_mods = whl_mods,
            default = default,
            dep = dep,
            configure = configure,
        ),
        is_root = is_root,
    )

def _parse_modules(env, **kwargs):
    return env.expect.that_struct(
        parse_modules(**kwargs),
        attrs = dict(
            declared_deps = subjects.dict,
            default_hub = subjects.str,
            exposed_packages = subjects.dict,
            exposed_venvs = subjects.dict,
            hub_group_map = subjects.dict,
            hub_whl_map = subjects.dict,
            testonly_packages = subjects.dict,
            unified_hub_requirements_bzl = subjects.bool,
            whl_libraries = subjects.dict,
            whl_mods = subjects.dict,
        ),
    )

def _build_config(env, **kwargs):
    return env.expect.that_struct(
        build_config(
            enable_pipstar_extract = True,
            **kwargs
        ),
        attrs = dict(
            auth_patterns = subjects.dict,
            netrc = subjects.str,
            platforms = subjects.dict,
        ),
    )

def _test_simple(env):
    pypi = _parse_modules(
        env,
        module_ctx = _pypi_mock_mctx(
            _mod(
                name = "rules_python",
                parse = [
                    _parse(
                        hub_name = "pypi",
                        python_version = "3.15",
                        simpleapi_skip = ["simple"],
                        requirements_lock = "requirements.txt",
                    ),
                ],
            ),
            os_name = "linux",
            arch_name = "x86_64",
        ),
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    pypi.exposed_packages().contains_exactly({"pypi": ["simple"]})
    pypi.hub_group_map().contains_exactly({"pypi": {}})
    pypi.hub_whl_map().contains_exactly({"pypi": {
        "simple": {
            "pypi_315_simple": [
                whl_config_setting(
                    version = "3.15",
                ),
            ],
        },
    }})
    pypi.whl_libraries().contains_exactly({
        "pypi_315_simple": {
            "config_load": "@pypi//:config.bzl",
            "dep_template": "@pypi//{name}:{target}",
            "python_interpreter_target": "unit_test_interpreter_target",
            "requirement": "simple==0.0.1 --hash=sha256:deadbeef --hash=sha256:deadbaaf",
        },
    })
    pypi.whl_mods().contains_exactly({})

_tests.append(_test_simple)

def _test_pip_parse_pyproject_toml(env):
    # pip.parse() reads the version from pyproject.toml's requires-python when
    # python_version is not set explicitly. Verify it works both when the
    # toolchain was registered by full version (python_3_15_19_host) and when
    # registered by minor version (python_3_15_host).
    for available_interpreters in [
        {"python_3_15_19_host": "unit_test_interpreter_target"},
        {"python_3_15_host": "unit_test_interpreter_target"},
    ]:
        pypi = _parse_modules(
            env,
            module_ctx = _pypi_mock_mctx(
                _mod(
                    name = "rules_python",
                    parse = [
                        _parse(
                            hub_name = "pypi",
                            pyproject_toml = "pyproject.toml",
                            simpleapi_skip = ["simple"],
                            requirements_lock = "requirements.txt",
                        ),
                    ],
                ),
                os_name = "linux",
                arch_name = "x86_64",
                mock_files = {
                    "pyproject.toml": "[project]\nrequires-python = \"==3.15.19\"\n",
                },
            ),
            available_interpreters = available_interpreters,
            minor_mapping = {"3.15": "3.15.19"},
        )

        # Resolves identically to passing python_version = "3.15.19" explicitly:
        # the full version drives interpreter selection, hub naming uses major.minor.
        pypi.exposed_packages().contains_exactly({"pypi": ["simple"]})
        pypi.hub_whl_map().contains_exactly({"pypi": {
            "simple": {
                "pypi_315_simple": [
                    whl_config_setting(
                        version = "3.15",
                    ),
                ],
            },
        }})
        pypi.whl_libraries().contains_exactly({
            "pypi_315_simple": {
                "config_load": "@pypi//:config.bzl",
                "dep_template": "@pypi//{name}:{target}",
                "python_interpreter_target": "unit_test_interpreter_target",
                "requirement": "simple==0.0.1 --hash=sha256:deadbeef --hash=sha256:deadbaaf",
            },
        })

_tests.append(_test_pip_parse_pyproject_toml)

def _test_simple_isolated(env):
    """Simulate `isolate = True` with parse_modules.

    No pip.default tags, but requirements parsing still produces the expected
    hub output.
    """
    pypi = _parse_modules(
        env,
        module_ctx = _pypi_mock_mctx(
            _mod(
                name = "my_module",
                default = [],  # no platform tags
                parse = [
                    _parse(
                        hub_name = "pypi",
                        python_version = "3.15",
                        simpleapi_skip = ["simple"],
                        requirements_lock = "requirements.txt",
                    ),
                ],
            ),
            os_name = "linux",
            arch_name = "x86_64",
        ),
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    pypi.exposed_packages().contains_exactly({"pypi": ["simple"]})
    pypi.hub_group_map().contains_exactly({"pypi": {}})
    pypi.hub_whl_map().contains_exactly({"pypi": {
        "simple": {
            "pypi_315_simple": [
                whl_config_setting(
                    version = "3.15",
                ),
            ],
        },
    }})
    pypi.whl_libraries().contains_exactly({
        "pypi_315_simple": {
            "config_load": "@pypi//:config.bzl",
            "dep_template": "@pypi//{name}:{target}",
            "python_interpreter_target": "unit_test_interpreter_target",
            "requirement": "simple==0.0.1 --hash=sha256:deadbeef --hash=sha256:deadbaaf",
        },
    })
    pypi.whl_mods().contains_exactly({})

_tests.append(_test_simple_isolated)

def _test_build_pipstar_platform(env):
    config = _build_config(
        env,
        module_ctx = _pypi_mock_mctx(
            _mod(
                name = "rules_python",
                default = [
                    _default(
                        platform = "myplat",
                        os_name = "linux",
                        arch_name = "x86_64",
                        config_settings = [
                            "@platforms//os:linux",
                            "@platforms//cpu:x86_64",
                        ],
                    ),
                    _default(),
                    _default(
                        platform = "myplat2",
                        os_name = "linux",
                        arch_name = "x86_64",
                        config_settings = [
                            "@platforms//os:linux",
                            "@platforms//cpu:x86_64",
                        ],
                    ),
                    _default(platform = "myplat2"),
                    _default(
                        netrc = "my_netrc",
                        auth_patterns = {"foo": "bar"},
                    ),
                ],
            ),
        ),
    )
    config.auth_patterns().contains_exactly({"foo": "bar"})
    config.netrc().equals("my_netrc")
    config.platforms().contains_exactly({
        "myplat": struct(
            name = "myplat",
            os_name = "linux",
            arch_name = "x86_64",
            config_settings = [
                "@platforms//os:linux",
                "@platforms//cpu:x86_64",
            ],
            env = {"implementation_name": "cpython"},
            marker = "",
            whl_abi_tags = ["none", "abi3", "cp{major}{minor}"],
            whl_platform_tags = ["any"],
        ),
    } | {
        name: _plat(**values)
        for name, values in default_platforms().items()
    })

_tests.append(_test_build_pipstar_platform)

def _test_multiple_default_tags(env):
    """Test that multiple pip.default tags do not trigger duplicate default hub failures.

    Only when multiple tags explicitly define default_hub should it fail.
    """
    pypi = _parse_modules(
        env,
        module_ctx = _pypi_mock_mctx(
            _mod(
                name = "rules_python",
                default = _default_tags_default + [
                    _default(platform = "extra_custom_platform"),
                ],
                parse = [
                    _parse(
                        hub_name = "pypi",
                        python_version = "3.15",
                        simpleapi_skip = ["simple"],
                        requirements_lock = "requirements.txt",
                    ),
                ],
            ),
            os_name = "linux",
            arch_name = "x86_64",
        ),
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )
    pypi.exposed_packages().contains_exactly({"pypi": ["simple"]})

_tests.append(_test_multiple_default_tags)

def _test_name_collision_no_env(env):
    """Test that a hub named 'pypi' is NOT renamed when the env var is not set."""
    pypi = _parse_modules(
        env,
        module_ctx = _pypi_mock_mctx(
            _mod(
                name = "rules_python",
                parse = [
                    _parse(
                        hub_name = "pypi",
                        python_version = "3.15",
                        simpleapi_skip = ["simple"],
                        requirements_lock = "requirements.txt",
                    ),
                ],
            ),
            os_name = "linux",
            arch_name = "x86_64",
            environ = {},  # Env var NOT set
        ),
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    # The hub name remains 'pypi'
    pypi.exposed_packages().contains_exactly({"pypi": ["simple"]})
    pypi.default_hub().equals(None)

_tests.append(_test_name_collision_no_env)

def _test_name_collision_with_env(env):
    """Test that a hub named 'pypi' is silently renamed to module_name_pypi and routed as default_hub when the env var is set."""
    pypi = _parse_modules(
        env,
        module_ctx = _pypi_mock_mctx(
            _mod(
                name = "rules_python",
                parse = [
                    _parse(
                        hub_name = "pypi",
                        python_version = "3.15",
                        simpleapi_skip = ["simple"],
                        requirements_lock = "requirements.txt",
                    ),
                ],
            ),
            os_name = "linux",
            arch_name = "x86_64",
            environ = {"RULES_PYTHON_PYPI_HUB_RESERVED": "1"},
        ),
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    # The hub name is renamed to 'rules_python_pypi'
    pypi.exposed_packages().contains_exactly({"rules_python_pypi": ["simple"]})

    # It is used as the default_hub
    pypi.default_hub().equals("rules_python_pypi")

_tests.append(_test_name_collision_with_env)

def _test_default_hub_precedence(env):
    """Test that pip.default(default_hub = ...) has precedence over the fallback renamed default hub."""
    pypi = _parse_modules(
        env,
        module_ctx = _pypi_mock_mctx(
            _mod(
                name = "rules_python",
                default = _default_tags_default + [
                    _default(
                        platform = "extra_custom_platform",
                        default_hub = "other_pypi",
                    ),
                ],
                parse = [
                    _parse(
                        hub_name = "pypi",
                        python_version = "3.15",
                        simpleapi_skip = ["simple"],
                        requirements_lock = "requirements.txt",
                    ),
                    _parse(
                        hub_name = "other_pypi",
                        python_version = "3.15",
                        simpleapi_skip = ["simple"],
                        requirements_lock = "requirements.txt",
                    ),
                ],
            ),
            os_name = "linux",
            arch_name = "x86_64",
            environ = {"RULES_PYTHON_PYPI_HUB_RESERVED": "1"},
        ),
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    # The hub named 'pypi' is renamed to 'rules_python_pypi'
    pypi.exposed_packages().contains_exactly({
        "other_pypi": ["simple"],
        "rules_python_pypi": ["simple"],
    })

    # But the default_hub remains 'other_pypi' because pip.default has higher precedence!
    pypi.default_hub().equals("other_pypi")

_tests.append(_test_default_hub_precedence)

def _parse_unified_hub_requirements_bzl(env, *modules):
    return _parse_modules(
        env,
        module_ctx = _pypi_mock_mctx(
            os_name = "linux",
            arch_name = "x86_64",
            *modules
        ),
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

def _unified_hub_requirements_bzl_mod(name, is_root, unified_hub_requirements_bzl):
    return _mod(
        name = name,
        is_root = is_root,
        default = _default_tags_default + [
            _default(unified_hub_requirements_bzl = unified_hub_requirements_bzl),
        ],
        parse = [
            _parse(
                hub_name = name + "_pypi",
                python_version = "3.15",
                simpleapi_skip = ["simple"],
                requirements_lock = "requirements.txt",
            ),
        ],
    )

def _test_unified_hub_requirements_bzl_off_by_default(env):
    pypi = _parse_unified_hub_requirements_bzl(
        env,
        _unified_hub_requirements_bzl_mod("root", is_root = True, unified_hub_requirements_bzl = False),
    )
    pypi.unified_hub_requirements_bzl().equals(False)

_tests.append(_test_unified_hub_requirements_bzl_off_by_default)

def _test_unified_hub_requirements_bzl_root_opt_in(env):
    pypi = _parse_unified_hub_requirements_bzl(
        env,
        _unified_hub_requirements_bzl_mod("root", is_root = True, unified_hub_requirements_bzl = True),
    )
    pypi.unified_hub_requirements_bzl().equals(True)

_tests.append(_test_unified_hub_requirements_bzl_root_opt_in)

def _test_unified_hub_requirements_bzl_ignored_outside_root(env):
    """Only the root module decides whether the unified hub gets a requirements.bzl."""
    pypi = _parse_unified_hub_requirements_bzl(
        env,
        _unified_hub_requirements_bzl_mod("root", is_root = True, unified_hub_requirements_bzl = False),
        _unified_hub_requirements_bzl_mod("rules_python", is_root = False, unified_hub_requirements_bzl = True),
    )
    pypi.unified_hub_requirements_bzl().equals(False)

_tests.append(_test_unified_hub_requirements_bzl_ignored_outside_root)

def _test_extension_dep(env):
    pypi = _parse_modules(
        env,
        module_ctx = _pypi_mock_mctx(
            _mod(
                name = "my_module",
                dep = [
                    _dep(
                        name = "declared-pkg",
                        extra_targets = ["declared-alias"],
                    ),
                ],
            ),
            os_name = "linux",
            arch_name = "x86_64",
        ),
        available_interpreters = {},
        minor_mapping = {},
    )

    pypi.declared_deps().contains_exactly({"declared_pkg": {"declared-alias": None}})
    pypi.exposed_packages().contains_exactly({})
    pypi.hub_group_map().contains_exactly({})
    pypi.hub_whl_map().contains_exactly({})
    pypi.whl_libraries().contains_exactly({})
    pypi.whl_mods().contains_exactly({})

_tests.append(_test_extension_dep)

def _test_extension_dep_coexists_with_concrete_hub(env):
    pypi = _parse_modules(
        env,
        module_ctx = _pypi_mock_mctx(
            _mod(
                name = "my_module",
                parse = [
                    _parse(
                        hub_name = "pypi_a",
                        python_version = "3.15",
                        simpleapi_skip = ["simple"],
                        requirements_lock = "requirements.txt",
                    ),
                ],
                dep = [
                    _dep(
                        name = "simple",
                        extra_targets = ["extra-target"],
                    ),
                ],
            ),
            os_name = "linux",
            arch_name = "x86_64",
        ),
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    pypi.declared_deps().contains_exactly({"simple": {"extra-target": None}})
    pypi.exposed_packages().contains_exactly({"pypi_a": ["simple"]})
    pypi.hub_group_map().contains_exactly({"pypi_a": {}})
    pypi.hub_whl_map().contains_exactly({"pypi_a": {
        "simple": {
            "pypi_a_315_simple": [
                whl_config_setting(
                    version = "3.15",
                ),
            ],
        },
    }})
    pypi.whl_libraries().contains_exactly({
        "pypi_a_315_simple": {
            "config_load": "@pypi_a//:config.bzl",
            "dep_template": "@pypi_a//{name}:{target}",
            "python_interpreter_target": "unit_test_interpreter_target",
            "requirement": "simple==0.0.1 --hash=sha256:deadbeef --hash=sha256:deadbaaf",
        },
    })
    pypi.whl_mods().contains_exactly({})

_tests.append(_test_extension_dep_coexists_with_concrete_hub)

def _test_default_index_setting(env):
    def mock_simpleapi_download(*_, attr, **_kwargs):
        digest_in_lock_file = "sha256:deadbeef"
        return {
            "simple": struct(
                whls = {
                    digest_in_lock_file: struct(
                        yanked = None,
                        filename = "simple-0.0.1-py3-none-any.whl",
                        digest = digest_in_lock_file,
                        url = "file://simple-0.0.1-py3-none-any.whl",
                    ),
                },
                sdists = {},
                hashes_by_version = {},
                index_url = attr.index_url,
            ),
        }

    for test in [
        struct(
            modules = [
                _mod(
                    name = "my_module",
                    parse = [
                        _parse(
                            hub_name = "pypi_a",
                            python_version = "3.15",
                            requirements_lock = "requirements.txt",
                        ),
                    ],
                ),
            ],
            want_index_url = "https://pypi.org/simple",
        ),
        struct(
            modules = [
                _mod(
                    name = "my_module",
                    default = [
                        _default(
                            index_url = "https://pypi.internal.org/simple",
                        ),
                    ],
                    parse = [
                        _parse(
                            hub_name = "pypi_a",
                            python_version = "3.15",
                            requirements_lock = "requirements.txt",
                        ),
                    ],
                ),
            ],
            want_index_url = "https://pypi.internal.org/simple",
        ),
        struct(
            modules = [
                _mod(
                    name = "my_module",
                    default = [
                        _default(
                            index_url = "https://pypi.internal.org/simple",
                        ),
                    ],
                    parse = [
                        _parse(
                            hub_name = "pypi_a",
                            python_version = "3.15",
                            requirements_lock = "requirements_with_index_url.txt",
                        ),
                    ],
                ),
            ],
            # We want the file to have lower precedence than our default if the
            # `my_module` is setting the default.
            want_index_url = "https://pypi.internal.org/simple",
        ),
    ]:
        pypi = _parse_modules(
            env,
            module_ctx = _pypi_mock_mctx(
                os_name = "linux",
                arch_name = "x86_64",
                mock_files = {
                    "requirements.txt": """\
simple==0.0.1 \
    --hash=sha256:deadbeef \
    --hash=sha256:deadbaaf""",
                    "requirements_with_index_url.txt": """\
--index-url="https://pypi.org/simple"

simple==0.0.1 \
    --hash=sha256:deadbeef \
    --hash=sha256:deadbaaf""",
                },
                *test.modules
            ),
            available_interpreters = {
                "python_3_15_host": "unit_test_interpreter_target",
            },
            minor_mapping = {"3.15": "3.15.19"},
            simpleapi_download = mock_simpleapi_download,
        )

        pypi.whl_libraries().contains_exactly({
            "pypi_a_315_simple_py3_none_any_deadbeef": {
                "config_load": "@pypi_a//:config.bzl",
                "dep_template": "@pypi_a//{name}:{target}",
                "filename": "simple-0.0.1-py3-none-any.whl",
                "index_url": test.want_index_url,
                "integrity": "sha256-3q2+7w==",
                "requirement": "simple==0.0.1",
                "urls": ["file://simple-0.0.1-py3-none-any.whl"],
            },
        })

_tests.append(_test_default_index_setting)

_CONFIGURE_REQUIREMENTS = """\
simple==0.0.1 \
    --hash=sha256:deadbeef \
    --hash=sha256:deadbaaf
other-pkg==0.0.2 \
    --hash=sha256:deadbeef \
    --hash=sha256:deadbaaf
transitive-pkg==0.0.3 \
    --hash=sha256:deadbeef \
    --hash=sha256:deadbaaf
"""

_CONFIGURE_PYPROJECT = """\
[project]
dependencies = ["simple"]

[project.optional-dependencies]
other = ["other-pkg"]

[dependency-groups]
dev = ["other-pkg"]
missing = ["not-in-hub"]
test = ["simple"]
all = [
    {include-group = "dev"},
    {include-group = "test"},
]
"""

def _configure_mock_mctx(*modules, mock_files = {}):
    return _pypi_mock_mctx(
        os_name = "linux",
        arch_name = "x86_64",
        mock_files = {
            "default_pyproject.toml": """\
[project]
dependencies = ["other-pkg"]
""",
            "pyproject.toml": _CONFIGURE_PYPROJECT,
            "requirements.txt": _CONFIGURE_REQUIREMENTS,
        } | mock_files,
        *modules
    )

def _configure_parse_modules(env, *modules):
    return _parse_modules(
        env,
        module_ctx = _configure_mock_mctx(*modules),
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

def _configure_parse(*, hub_name = "pypi_a", pyproject_toml = None):
    return _parse(
        hub_name = hub_name,
        pyproject_toml = pyproject_toml,
        python_version = "3.15",
        simpleapi_skip = ["simple", "other-pkg", "transitive-pkg"],
        requirements_lock = "requirements.txt",
    )

def _test_resolve_dependency_groups(env):
    pyproject = struct(
        dependencies = ["main-pkg"],
        optional_dependencies = {"Docs": ["docs-pkg"]},
        dependency_groups = {
            "cycle_a": [{"include-group": "cycle_b"}],
            "cycle_b": [{"include-group": "cycle_a"}],
            "dev": [
                "dev-pkg",
                {"include-group": "test"},
            ],
            "test": ["test-pkg"],
        },
    )

    got = resolve_dependency_groups(
        pyproject,
        ["default", "optional:docs", "group:dev", "dev"],
    )
    env.expect.that_collection(got).contains_exactly([
        "main-pkg",
        "docs-pkg",
        "dev-pkg",
        "test-pkg",
        "dev-pkg",
        "test-pkg",
    ]).in_order()

    failures = []
    resolve_dependency_groups(pyproject, ["cycle_a"], _fail = failures.append)
    env.expect.that_collection(failures).contains_exactly([
        "Cyclic dependency group include: cycle_a -> cycle_b -> cycle_a",
    ])

    failures = []
    resolve_dependency_groups(pyproject, ["missing"], _fail = failures.append)
    env.expect.that_collection(failures).contains_exactly([
        "Unknown dependency group 'missing'. Available dependency groups: cycle_a, cycle_b, dev, test; optional dependency groups: docs",
    ])

_tests.append(_test_resolve_dependency_groups)

def _test_packages_from_dependency_groups(env):
    mctx = _pypi_mock_mctx(
        mock_files = {
            "pyproject.toml": """\
[project]
dependencies = ["Simple", "other-pkg>=1.0"]

[dependency-groups]
dev = ["other.pkg", "missing-pkg"]
all = [
    {include-group = "dev"},
]
""",
        },
    )

    got = packages_from_dependency_groups(
        mctx,
        "pyproject.toml",
        ["default", "all"],
    )
    env.expect.that_collection(got).contains_exactly([
        "missing_pkg",
        "other_pkg",
        "simple",
    ]).in_order()

_tests.append(_test_packages_from_dependency_groups)

def _test_dependency_group_selection_wildcards(env):
    pyproject = struct(
        dependencies = ["main-pkg"],
        optional_dependencies = {
            "Docs": ["docs-pkg"],
            "Grpc": ["grpc-pkg"],
        },
        dependency_groups = {
            "dev": ["dev-pkg", "shared-pkg"],
            "test": ["test-pkg", "shared-pkg"],
        },
    )

    got = dependency_group_selection(pyproject, ["*"])
    env.expect.that_collection(got.packages).contains_exactly([
        "dev_pkg",
        "docs_pkg",
        "grpc_pkg",
        "main_pkg",
        "shared_pkg",
        "test_pkg",
    ]).in_order()
    env.expect.that_collection(got.testonly_packages).contains_exactly([])
    env.expect.that_bool(got.transitive).equals(False)

    got = dependency_group_selection(pyproject, ["optional:*"])
    env.expect.that_collection(got.packages).contains_exactly([
        "docs_pkg",
        "grpc_pkg",
    ]).in_order()

    got = dependency_group_selection(pyproject, ["group:*"])
    env.expect.that_collection(got.packages).contains_exactly([
        "dev_pkg",
        "shared_pkg",
        "test_pkg",
    ]).in_order()

    # The later specific entry overrides the wildcard for group:dev.
    # shared-pkg is also selected by the non-testonly group:dev, so it stays
    # non-testonly.
    got = dependency_group_selection(pyproject, ["*;testonly", "group:dev"])
    env.expect.that_collection(got.testonly_packages).contains_exactly([
        "docs_pkg",
        "grpc_pkg",
        "main_pkg",
        "test_pkg",
    ]).in_order()

    got = dependency_group_selection(pyproject, ["*", "group:test;testonly"])
    env.expect.that_collection(got.testonly_packages).contains_exactly([
        "test_pkg",
    ]).in_order()

    # A later "*" resets earlier specific overrides.
    got = dependency_group_selection(pyproject, ["group:dev;testonly", "*"])
    env.expect.that_collection(got.testonly_packages).contains_exactly([])

    # A package selected by both a testonly and a non-testonly group stays
    # non-testonly.
    got = dependency_group_selection(pyproject, ["group:dev", "group:test;testonly"])
    env.expect.that_collection(got.testonly_packages).contains_exactly([
        "test_pkg",
    ])

    got = dependency_group_selection(pyproject, ["optional:*;testonly"])
    env.expect.that_collection(got.testonly_packages).contains_exactly([
        "docs_pkg",
        "grpc_pkg",
    ]).in_order()

    # A later group:* resets earlier group-specific overrides.
    got = dependency_group_selection(pyproject, ["group:dev;testonly", "group:*"])
    env.expect.that_collection(got.testonly_packages).contains_exactly([])

    got = dependency_group_selection(pyproject, ["default", "transitive"])
    env.expect.that_bool(got.transitive).equals(True)
    env.expect.that_bool(got.transitive_testonly).equals(False)

    got = dependency_group_selection(pyproject, ["transitive;testonly", "default"])
    env.expect.that_bool(got.transitive).equals(True)
    env.expect.that_bool(got.transitive_testonly).equals(True)

    failures = []
    got = dependency_group_selection(pyproject, ["default;unknown"], _fail = failures.append)
    env.expect.that_collection(got.packages).contains_exactly([])
    env.expect.that_collection(failures).contains_exactly([
        "Invalid dependency group specifier 'default;unknown': the only supported modifier is 'testonly'",
    ])

_tests.append(_test_dependency_group_selection_wildcards)

def _test_dependency_graph_from_uv_lock(env):
    mctx = _pypi_mock_mctx(
        mock_files = {
            "uv.lock": """\
[[package]]
name = "Foo"
version = "1.0.0"
dependencies = [{name = "Bar"}]

[[package]]
name = "bar"
version = "1.0.0"

[package.optional-dependencies]
extra = [{name = "Baz"}]
""",
        },
    )

    got = dependency_graph_from_uv_lock(mctx, "uv.lock")
    env.expect.that_dict(got).contains_exactly({
        "bar": ["baz"],
        "foo": ["bar"],
    })

    got = merge_dependency_graphs([
        {"foo": ["bar"]},
        {
            "bar": ["baz"],
            "foo": ["baz"],
        },
    ])
    env.expect.that_dict(got).contains_exactly({
        "bar": ["baz"],
        "foo": ["bar", "baz"],
    })

_tests.append(_test_dependency_graph_from_uv_lock)

def _test_testonly_packages_from_graph(env):
    graph = {
        "prod": ["shared", "prod-only"],
        "shared": [],
        "test": ["shared", "test-only"],
    }

    got = testonly_packages_from_graph(
        [
            "orphan",
            "prod",
            "prod-only",
            "shared",
            "test",
            "test-only",
        ],
        roots = ["prod", "test"],
        testonly_roots = ["test"],
        graph = graph,
    )

    env.expect.that_collection(got).contains_exactly([
        "test",
        "test-only",
    ]).in_order()

_tests.append(_test_testonly_packages_from_graph)

def _test_configure_dependency_groups(env):
    pypi = _configure_parse_modules(
        env,
        _mod(
            name = "rules_python",
            default = _default_tags_default + [
                _default(pyproject_toml = "pyproject.toml"),
            ],
            parse = [_configure_parse()],
            configure = [
                # The default dependency_groups is ["*"], which selects all
                # packages listed in pyproject.toml but not transitive_pkg.
                _configure(hub_name = "pypi_a", venv = "venv_default"),
                _configure(hub_name = "pypi_a", venv = "venv_dev", dependency_groups = ["dev"]),
                _configure(hub_name = "pypi_a", venv = "venv_group", dependency_groups = ["group:dev"]),
                _configure(hub_name = "pypi_a", venv = "venv_optional", dependency_groups = ["optional:other"]),
                _configure(hub_name = "pypi_a", venv = "venv_bare_optional", dependency_groups = ["other"]),
                _configure(hub_name = "pypi_a", venv = "venv_all", dependency_groups = ["all"]),
                _configure(hub_name = "pypi_a", venv = "venv_missing", dependency_groups = ["default", "missing"]),
            ],
        ),
    )

    pypi.exposed_venvs().contains_exactly({
        "venv_all": struct(hub = "pypi_a", packages = ["other_pkg", "simple"], testonly_packages = []),
        "venv_bare_optional": struct(hub = "pypi_a", packages = ["other_pkg"], testonly_packages = []),
        "venv_default": struct(hub = "pypi_a", packages = ["other_pkg", "simple"], testonly_packages = []),
        "venv_dev": struct(hub = "pypi_a", packages = ["other_pkg"], testonly_packages = []),
        "venv_group": struct(hub = "pypi_a", packages = ["other_pkg"], testonly_packages = []),
        "venv_missing": struct(hub = "pypi_a", packages = ["simple"], testonly_packages = []),
        "venv_optional": struct(hub = "pypi_a", packages = ["other_pkg"], testonly_packages = []),
    })

    # The concrete hub is not filtered when the venv has a different name.
    pypi.exposed_packages().contains_exactly({
        "pypi_a": ["other_pkg", "simple", "transitive_pkg"],
    })

_tests.append(_test_configure_dependency_groups)

def _test_configure_union_same_venv(env):
    pypi = _configure_parse_modules(
        env,
        _mod(
            name = "rules_python",
            default = _default_tags_default + [
                _default(pyproject_toml = "pyproject.toml"),
            ],
            parse = [_configure_parse()],
            configure = [
                _configure(hub_name = "pypi_a", venv = "venv", dependency_groups = ["test"]),
                _configure(hub_name = "pypi_a", venv = "venv", dependency_groups = ["dev"]),
            ],
        ),
    )

    pypi.exposed_venvs().contains_exactly({
        "venv": struct(hub = "pypi_a", packages = ["other_pkg", "simple"], testonly_packages = []),
    })

_tests.append(_test_configure_union_same_venv)

def _test_configure_venv_same_as_hub(env):
    pypi = _configure_parse_modules(
        env,
        _mod(
            name = "rules_python",
            default = _default_tags_default + [
                _default(pyproject_toml = "pyproject.toml"),
            ],
            parse = [_configure_parse()],
            configure = [
                _configure(hub_name = "pypi_a", venv = "pypi_a", dependency_groups = ["test"]),
            ],
        ),
    )

    pypi.exposed_venvs().contains_exactly({
        "pypi_a": struct(hub = "pypi_a", packages = ["simple"], testonly_packages = []),
    })

    # There is no separate repository, so the concrete hub is filtered instead.
    pypi.exposed_packages().contains_exactly({"pypi_a": ["simple"]})

_tests.append(_test_configure_venv_same_as_hub)

def _test_configure_venv_defaults_to_hub_name(env):
    pypi = _configure_parse_modules(
        env,
        _mod(
            name = "rules_python",
            default = _default_tags_default + [
                _default(pyproject_toml = "pyproject.toml"),
            ],
            parse = [_configure_parse()],
            configure = [
                _configure(hub_name = "pypi_a", dependency_groups = ["test"]),
            ],
        ),
    )

    pypi.exposed_venvs().contains_exactly({
        "pypi_a": struct(hub = "pypi_a", packages = ["simple"], testonly_packages = []),
    })
    pypi.exposed_packages().contains_exactly({"pypi_a": ["simple"]})

_tests.append(_test_configure_venv_defaults_to_hub_name)

def _test_configure_pyproject_from_parse(env):
    pypi = _configure_parse_modules(
        env,
        _mod(
            name = "rules_python",
            parse = [_configure_parse(pyproject_toml = "pyproject.toml")],
            configure = [
                _configure(hub_name = "pypi_a", venv = "venv"),
            ],
        ),
    )

    pypi.exposed_venvs().contains_exactly({
        "venv": struct(hub = "pypi_a", packages = ["other_pkg", "simple"], testonly_packages = []),
    })

_tests.append(_test_configure_pyproject_from_parse)

def _test_configure_pyproject_precedence(env):
    # pip.default() takes precedence over the hub's pip.parse().
    pypi = _configure_parse_modules(
        env,
        _mod(
            name = "rules_python",
            default = _default_tags_default + [
                _default(pyproject_toml = "default_pyproject.toml"),
            ],
            parse = [_configure_parse(pyproject_toml = "pyproject.toml")],
            configure = [
                _configure(hub_name = "pypi_a", venv = "venv_default"),
                _configure(
                    hub_name = "pypi_a",
                    venv = "venv_tag",
                    pyproject_toml = "pyproject.toml",
                ),
            ],
        ),
    )

    pypi.exposed_venvs().contains_exactly({
        "venv_default": struct(hub = "pypi_a", packages = ["other_pkg"], testonly_packages = []),
        "venv_tag": struct(hub = "pypi_a", packages = ["other_pkg", "simple"], testonly_packages = []),
    })

_tests.append(_test_configure_pyproject_precedence)

def _test_configure_unknown_hub_fails(env):
    failures = []
    pypi = parse_modules(
        module_ctx = _configure_mock_mctx(
            _mod(
                name = "rules_python",
                parse = [_configure_parse()],
                configure = [
                    _configure(hub_name = "unknown", venv = "venv"),
                ],
            ),
        ),
        _fail = failures.append,
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    env.expect.that_bool(pypi == None).equals(True)
    env.expect.that_collection(failures).contains_exactly([
        "pip.configure() refers to unknown hub 'unknown'. Available hubs: pypi_a",
    ])

_tests.append(_test_configure_unknown_hub_fails)

def _test_configure_venv_conflicts_with_hub_fails(env):
    failures = []
    pypi = parse_modules(
        module_ctx = _configure_mock_mctx(
            _mod(
                name = "rules_python",
                parse = [
                    _configure_parse(hub_name = "pypi_a"),
                    _configure_parse(hub_name = "pypi_b"),
                ],
                configure = [
                    _configure(hub_name = "pypi_a", venv = "pypi_b"),
                ],
            ),
        ),
        _fail = failures.append,
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    env.expect.that_bool(pypi == None).equals(True)
    env.expect.that_collection(failures).contains_exactly([
        "pip.configure() venv 'pypi_b' conflicts with the existing hub of the same name",
    ])

_tests.append(_test_configure_venv_conflicts_with_hub_fails)

def _test_configure_venv_conflicts_with_unified_hub_fails(env):
    failures = []
    pypi = parse_modules(
        module_ctx = _configure_mock_mctx(
            _mod(
                name = "rules_python",
                parse = [_configure_parse()],
                configure = [
                    _configure(hub_name = "pypi_a", venv = "pypi"),
                ],
            ),
        ),
        _fail = failures.append,
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    env.expect.that_bool(pypi == None).equals(True)
    env.expect.that_collection(failures).contains_exactly([
        "pip.configure() venv 'pypi' conflicts with the automatically generated unified hub",
    ])

_tests.append(_test_configure_venv_conflicts_with_unified_hub_fails)

def _test_configure_same_venv_different_hubs_fails(env):
    failures = []
    pypi = parse_modules(
        module_ctx = _configure_mock_mctx(
            _mod(
                name = "rules_python",
                default = _default_tags_default + [
                    _default(pyproject_toml = "pyproject.toml"),
                ],
                parse = [
                    _configure_parse(hub_name = "pypi_a"),
                    _configure_parse(hub_name = "pypi_b"),
                ],
                configure = [
                    _configure(hub_name = "pypi_a", venv = "venv"),
                    _configure(hub_name = "pypi_b", venv = "venv"),
                ],
            ),
        ),
        _fail = failures.append,
        available_interpreters = {
            "python_3_15_host": "unit_test_interpreter_target",
        },
        minor_mapping = {"3.15": "3.15.19"},
    )

    env.expect.that_bool(pypi == None).equals(True)
    env.expect.that_collection(failures).contains_exactly([
        "pip.configure() venv 'venv' is used with both hub 'pypi_a' and hub 'pypi_b'",
    ])

_tests.append(_test_configure_same_venv_different_hubs_fails)

def _test_configure_no_pyproject_exposes_all(env):
    # Without a pyproject.toml there are no dependency groups to select, so
    # the venv falls back to exposing every package in the hub, including
    # transitive packages. This fallback should be removed once pyproject.toml
    # is mandatory.
    pypi = _configure_parse_modules(
        env,
        _mod(
            name = "rules_python",
            parse = [_configure_parse()],
            configure = [
                _configure(hub_name = "pypi_a", venv = "venv"),
            ],
        ),
    )

    pypi.exposed_venvs().contains_exactly({
        "venv": struct(hub = "pypi_a", packages = ["other_pkg", "simple", "transitive_pkg"], testonly_packages = []),
    })

_tests.append(_test_configure_no_pyproject_exposes_all)

def extension_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
