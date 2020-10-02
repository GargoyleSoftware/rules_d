# Copyright 2015 The Bazel Authors. All rights reserved
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""D rules for Bazel."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def a_filetype(ctx, files):
    if _is_windows(ctx):
        return [f for f in files if f.basename.endswith(".lib")]
    else:
        return [f for f in files if f.basename.endswith(".a")]

D_FILETYPE = [".d", ".di"]

ZIP_PATH = "/usr/bin/zip"

def _is_windows(ctx):
  return ctx.configuration.host_path_separator == ';'

def _relative(src_path, dest_path):
    """Returns the relative path from src_path to dest_path."""
    src_parts = src_path.split("/")
    dest_parts = dest_path.split("/")
    n = 0
    for src_part, dest_part in zip(src_parts, dest_parts):
        if src_part != dest_part:
            break
        n += 1

    relative_path = ""
    for _ in range(n, len(src_parts)):
        relative_path += "../"
    relative_path += "/".join(dest_parts[n:])

    return relative_path

def _files_directory(files):
    """Returns the shortest parent directory of a list of files."""
    dir = files[0].dirname
    for f in files:
        if len(dir) > len(f.dirname):
            dir = f.dirname
    return dir

def _d_toolchain(ctx):
    """Returns a struct containing info about the D toolchain.

    Args:
      ctx: The ctx object.

    Return:
      Struct containing the following fields:
        d_compiler_path: The path to the D compiler.
        link_flags: Linker (-L) flags for adding the standard library to the
            library search paths.
        import_flags: import (-I) flags for adding the standard library sources
            to the import paths.
    """

    d_compiler_path = ctx.file._d_compiler.path
    return struct(
        d_compiler_path = d_compiler_path,
        link_flags = [("-L/LIBPATH:" if _is_windows(ctx) else "-L-L") + ctx.files._d_stdlib[0].dirname],
        import_flags = [
            "-I" + _files_directory(ctx.files._d_stdlib_src),
            "-I" + _files_directory(ctx.files._d_runtime_import_src),
        ],
    )

def _format_version(name):
    """Formats the string name to be used in a --version flag."""
    return name.replace("-", "_")

def _build_compile_arglist(ctx, srcs, out, depinfo, extra_flags = []):
    """Returns a string containing the D compile command."""
    return (
        ["-Id", "-debug", "-w", "-g", "-m64"] +
        extra_flags + [
            "-of" + out.path,
            #"-I.",
        ] +
        ["-I%s/%s" % (ctx.label.package, im) for im in ctx.attr.imports] +
        ["-I%s" % im for im in depinfo.imports] +
        _d_toolchain(ctx).import_flags +
        ["-version=Have_%s" % _format_version(ctx.label.name)] +
        ["-version=%s" % v for v in ctx.attr.versions] +
        ["-version=%s" % v for v in depinfo.versions] +
        depinfo.dmd_args +
        srcs
        )


def _build_link_arglist(ctx, objs, out, depinfo):
    """Returns a string containing the D link command."""
    return (
        ["-of" + out.path] +
        ["-m64"] +
        [f.path for f in depset(transitive = [depinfo.libs, depinfo.transitive_libs]).to_list()] +
        _d_toolchain(ctx).link_flags +
        depinfo.lib_flags +
        depinfo.link_flags +
        (
          [
          # "-L/DEFAULTLIB:user32",
          # "-L/NODEFAULTLIB:libcmt",
          # "-L/DEFAULTLIB:msvcrt",
          ] if _is_windows(ctx) else [
          "-L-lstdc++",
          ]) +
        depinfo.dmd_args +
        objs
    )

def _setup_deps(ctx, deps, name, working_dir):
    """Sets up dependencies.

    Walks through dependencies and constructs the commands and flags needed
    for linking the necessary dependencies.

    Args:
      deps: List of deps labels from ctx.attr.deps.
      name: Name of the current target.
      working_dir: The output directory of the current target's output.

    Returns:
      Returns a struct containing the following fields:
        libs: List of Files containing the target's direct library dependencies.
        transitive_libs: List of Files containing all of the target's
            transitive libraries.
        d_srcs: List of Files representing D source files of dependencies that
            will be used as inputs for this target.
        versions: List of D versions to be used for compiling the target.
        imports: List of Strings containing input paths that will be passed
            to the D compiler via -I flags.
        link_flags: List of linker flags.
        lib_flags: List of library search flags.
        dynamic_libraries_for_runtime: depset of dynamic libraries to be copied
        dmd_args: Custom DMD args.
        data: data runfiles
        additional_linking_inputs: stuff that needs to be generated before linking
            but is not a library
    """
    windows = _is_windows(ctx)
    libs              = []
    transitive_libs   = []
    d_srcs            = []
    transitive_d_srcs = []
    versions          = []
    imports           = []
    link_flags        = ["-L%s" % (linkopt,) for linkopt in ctx.attr.linkopts]
    dynamic_libraries_for_runtime = []
    transitive_dynamic_libraries_for_runtime = []
    dmd_args = []
    data = []
    additional_linking_inputs = []
    for datum in ctx.attr.data:
        data.extend(datum.files.to_list())
    for dep in deps:
        if hasattr(dep, "d_lib"):
            # The dependency is a d_library.
            libs.append(dep.d_lib)
            transitive_libs.append(dep.transitive_libs)
            d_srcs += dep.d_srcs
            transitive_d_srcs.append(dep.transitive_d_srcs)
            versions += dep.versions + ["Have_%s" % _format_version(dep.label.name)]
            link_flags.extend(dep.link_flags)
            imports += ["%s/%s" % (dep.label.package, im) for im in dep.imports]
            transitive_dynamic_libraries_for_runtime.append(dep.dynamic_libraries_for_runtime)
            dmd_args.extend(dep.dmd_args)
            data.extend(dep.data)
            additional_linking_inputs.extend(dep.additional_linking_inputs)

        elif hasattr(dep, "d_srcs"):
            # The dependency is a d_source_library.
            d_srcs += dep.d_srcs
            transitive_d_srcs.append(dep.transitive_d_srcs)
            transitive_libs.append(dep.transitive_libs)
            link_flags += ["-L%s" % linkopt for linkopt in dep.linkopts]
            imports += ["%s/%s" % (dep.label.package, im) for im in dep.imports]
            versions += dep.versions
            transitive_dynamic_libraries_for_runtime.append(dep.dynamic_libraries_for_runtime)
            dmd_args.extend(dep.dmd_args)
            data.extend(dep.data)

        elif CcInfo in dep:
            # The dependency is a cc_library
            native_libs = a_filetype(ctx, _get_libs_for_static_executable(dep))
            libs.extend(native_libs)
            transitive_libs.append(depset(native_libs))
            link_flags += ["-L%s" % (f,) for f in dep[CcInfo].linking_context.user_link_flags]
            additional_linking_inputs.extend(dep[CcInfo].linking_context.additional_inputs.to_list())
            dynamic_libraries_for_runtime.extend(_get_dynamic_libraries_for_runtime(dep, True))
            # TODO: collect c/c++ data transitively
            #data.extend(dep[DefaultInfo].data_runfiles.files.to_list())

        else:
            fail("D targets can only depend on d_library, d_source_library, or " +
                 "cc_library targets.", "deps")
    dmd_args.extend([x for x in ctx.attr.dmd_args])

    return struct(
        libs = depset(libs),
        transitive_libs = depset(transitive = transitive_libs),
        d_srcs = depset(d_srcs).to_list(),
        transitive_d_srcs = depset(transitive = transitive_d_srcs),
        versions = versions,
        imports = depset(imports).to_list(),
        link_flags = depset(link_flags).to_list(),
        lib_flags = [],
        dynamic_libraries_for_runtime = depset(dynamic_libraries_for_runtime, transitive = transitive_dynamic_libraries_for_runtime),
        dmd_args = dmd_args,
        data = data,
        additional_linking_inputs = additional_linking_inputs,
    )

def _d_library_impl(ctx):
    """Implementation of the d_library rule."""
    d_lib = ctx.actions.declare_file((ctx.label.name + ".lib") if _is_windows(ctx) else ("lib" + ctx.label.name + ".a"))

    # Dependencies
    depinfo = _setup_deps(ctx, ctx.attr.deps, ctx.label.name, d_lib.dirname)

    # Build compile command.
    compile_args = _build_compile_arglist(
        ctx = ctx,
        srcs = [src.path for src in ctx.files.srcs],
        out = d_lib,
        depinfo = depinfo,
        extra_flags = ["-lib"],
    )

    compile_inputs = depset(
        ctx.files.srcs +
        depinfo.d_srcs +
        ctx.files._d_stdlib +
        ctx.files._d_stdlib_src +
        ctx.files._d_runtime_import_src,
        transitive = [
            depinfo.transitive_d_srcs,
        ],
    )

    ctx.actions.run(
        inputs = compile_inputs,
        tools = [ctx.file._d_compiler],
        outputs = [d_lib],
        mnemonic = "Dcompile",
        executable = ctx.file._d_compiler.path,
        arguments = compile_args,
        use_default_shell_env = True,
        progress_message = "Compiling D library " + ctx.label.name,
    )

    return struct(
        files = depset([d_lib]),
        d_srcs = ctx.files.srcs,
        transitive_d_srcs = depset(depinfo.d_srcs),
        transitive_libs = depset(transitive = [depinfo.libs, depinfo.transitive_libs]),
        link_flags = depinfo.link_flags,
        versions = ctx.attr.versions,
        imports = ctx.attr.imports,
        d_lib = d_lib,
        dynamic_libraries_for_runtime = depinfo.dynamic_libraries_for_runtime,
        dmd_args = depinfo.dmd_args,
        data = depinfo.data,
        additional_linking_inputs = depinfo.additional_linking_inputs,
    )

def _d_binary_impl_common(ctx, extra_flags = []):
    """Common implementation for rules that build a D binary."""
    name = ctx.label.name
    windows = _is_windows(ctx)
    if windows:
      name += ".exe"

    d_bin = ctx.actions.declare_file(name)
    d_obj = ctx.actions.declare_file(ctx.label.name + (".obj" if windows else ".o"))
    depinfo = _setup_deps(ctx, ctx.attr.deps, ctx.label.name, d_bin.dirname)

    # Build compile command
    compile_args = _build_compile_arglist(
        ctx = ctx,
        srcs = [src.path for src in ctx.files.srcs],
        depinfo = depinfo,
        out = d_obj,
        extra_flags = ["-c"] + extra_flags,
    )

    toolchain_files = (
        ctx.files._d_stdlib +
        ctx.files._d_stdlib_src +
        ctx.files._d_runtime_import_src
    )

    compile_inputs = depset(
        ctx.files.srcs + depinfo.d_srcs + toolchain_files,
        transitive = [depinfo.transitive_d_srcs],
    )
    ctx.actions.run(
        inputs = compile_inputs,
        tools = [ctx.file._d_compiler],
        outputs = [d_obj],
        mnemonic = "Dcompile",
        executable = ctx.file._d_compiler.path,
        arguments = compile_args,
        use_default_shell_env = True,
        progress_message = "Compiling D binary " + ctx.label.name,
    )

    # Build link command
    link_args = _build_link_arglist(
        ctx = ctx,
        objs = [d_obj.path],
        depinfo = depinfo,
        out = d_bin,
    )

    link_inputs = depset(
        [d_obj] + toolchain_files + depinfo.additional_linking_inputs,
        transitive = [depinfo.libs, depinfo.transitive_libs, depinfo.dynamic_libraries_for_runtime],
    )

    ctx.actions.run(
        inputs = link_inputs,
        tools = [ctx.file._d_compiler],
        outputs = [d_bin],
        mnemonic = "Dlink",
        executable = ctx.file._d_compiler.path,
        arguments = link_args,
        use_default_shell_env = True,
        progress_message = "Linking D binary " + ctx.label.name,
    )

    copied_dynamic_libraries_for_runtime = []
    for lib in depinfo.dynamic_libraries_for_runtime.to_list():
        copy = ctx.actions.declare_file(lib.basename)
        copied_dynamic_libraries_for_runtime.append(copy)
        ctx.actions.run_shell(
            inputs = [lib],
            outputs = [copy],
            mnemonic = "Dcopylib",
            command = 'cp -f "%s" "%s/%s"' % (lib.path, d_bin.dirname, lib.basename),
            use_default_shell_env = True,
            progress_message = "Copying Execution Dynamic Library " + lib.basename,
        )

    return struct(
        d_srcs = ctx.files.srcs,
        transitive_d_srcs = depset(depinfo.d_srcs),
        imports = ctx.attr.imports,
        executable = d_bin,
        runfiles = ctx.runfiles(files = copied_dynamic_libraries_for_runtime + depinfo.data),
    )

def _d_binary_impl(ctx):
    """Implementation of the d_binary rule."""
    return _d_binary_impl_common(ctx)

def _d_test_impl(ctx):
    """Implementation of the d_test rule."""
    return _d_binary_impl_common(ctx, extra_flags = ["-unittest"])

def _get_dynamic_libraries_for_runtime(dep, linking_statically):
    libraries = dep[CcInfo].linking_context.libraries_to_link.to_list()
    dynamic_libraries_for_runtime = []
    for lib in libraries:
        if lib.dynamic_library != None:
            #if lib.interface_library != None or not linking_statically or (lib.static_library == None and lib.pic_static_library == None):
            if not linking_statically or (lib.static_library == None and lib.pic_static_library == None):
                dynamic_libraries_for_runtime.append(lib.dynamic_library)
    return dynamic_libraries_for_runtime

def _get_libs_for_static_executable(dep):
    """
    Finds the libraries used for linking an executable statically.
    This replaces the old API dep.cc.libs
    Args:
      dep: Target
    Returns:
      A list of File instances, these are the libraries used for linking.
    """
    libraries_to_link = dep[CcInfo].linking_context.libraries_to_link.to_list()

    libs = []
    for library_to_link in libraries_to_link:
        if library_to_link.static_library != None:
            libs.append(library_to_link.static_library)
        elif library_to_link.pic_static_library != None:
            libs.append(library_to_link.pic_static_library)
        elif library_to_link.interface_library != None:
            libs.append(library_to_link.interface_library)
        elif library_to_link.dynamic_library != None:
            libs.append(library_to_link.dynamic_library)
    return libs

def _d_source_library_impl(ctx):
    """Implementation of the d_source_library rule."""
    transitive_d_srcs = []
    transitive_libs = []
    transitive_transitive_libs = []
    transitive_imports = depset()
    transitive_linkopts = depset()
    transitive_versions = depset()
    dynamic_libraries_for_runtime = []
    transitive_dynamic_libraries_for_runtime = []
    dmd_args = []
    data = []
    for datum in ctx.attr.data:
        data.extend(datum.files.to_list())
    for dep in ctx.attr.deps:
        if hasattr(dep, "d_srcs"):
            # Dependency is another d_source_library target.
            transitive_d_srcs.append(dep.d_srcs)
            transitive_imports = depset(dep.imports, transitive = [transitive_imports])
            transitive_linkopts = depset(dep.linkopts, transitive = [transitive_linkopts])
            transitive_versions = depset(dep.versions, transitive = [transitive_versions])
            transitive_transitive_libs.append(dep.transitive_libs)
            transitive_dynamic_libraries_for_runtime.append(dep.dynamic_libraries_for_runtime)
            dmd_args.extend(dep.dmd_args)
            data.extend(dep.data)

        elif CcInfo in dep:
            # Dependency is a cc_library target.
            native_libs = a_filetype(ctx, _get_libs_for_static_executable(dep))
            transitive_libs.extend(native_libs)
            dynamic_libraries_for_runtime.extend(_get_dynamic_libraries_for_runtime(dep, True))
            # TODO: collect c/c++ data transitively
            #data.extend(dep[DefaultInfo].data_runfiles.files.to_list())

        else:
            fail("d_source_library can only depend on other " +
                 "d_source_library or cc_library targets.", "deps")
    dmd_args.extend([x for x in ctx.attr.dmd_args])

    return struct(
        d_srcs = ctx.files.srcs,
        transitive_d_srcs = depset(transitive = transitive_d_srcs, order = "postorder"),
        transitive_libs = depset(transitive_libs, transitive = transitive_transitive_libs),
        imports = ctx.attr.imports + transitive_imports.to_list(),
        linkopts = ctx.attr.linkopts + transitive_linkopts.to_list(),
        versions = ctx.attr.versions + transitive_versions.to_list(),
        dynamic_libraries_for_runtime = depset(dynamic_libraries_for_runtime, transitive = transitive_dynamic_libraries_for_runtime),
        dmd_args = dmd_args,
        data = data,
    )

# TODO(dzc): Use ddox for generating HTML documentation.
def _d_docs_impl(ctx):
    """Implementation for the d_docs rule

      This rule runs the following steps to generate an archive containing
      HTML documentation generated from doc comments in D source code:
        1. Run the D compiler with the -D flags to generate HTML code
           documentation.
        2. Create a ZIP archive containing the HTML documentation.
    """
    d_docs_zip = ctx.outputs.d_docs
    docs_dir = d_docs_zip.dirname + "/_d_docs"
    objs_dir = d_docs_zip.dirname + "/_d_objs"

    target = struct(
        name = ctx.attr.dep.label.name,
        srcs = ctx.attr.dep.d_srcs,
        transitive_srcs = ctx.attr.dep.transitive_d_srcs,
        imports = ctx.attr.dep.imports,
    )

    # Build D docs command
    toolchain = _d_toolchain(ctx)
    doc_cmd = (
        [
            "set -e;",
            "rm -rf %s; mkdir -p %s;" % (docs_dir, docs_dir),
            "rm -rf %s; mkdir -p %s;" % (objs_dir, objs_dir),
            toolchain.d_compiler_path,
            "-c",
            "-D",
            "-Dd%s" % docs_dir,
            "-od%s" % objs_dir,
            "-I.",
        ] +
        ["-I%s/%s" % (ctx.label.package, im) for im in target.imports] +
        toolchain.import_flags +
        [src.path for src in target.srcs] +
        [
            "&&",
            "(cd %s &&" % docs_dir,
            ZIP_PATH,
            "-qR",
            d_docs_zip.basename,
            "$(find . -type f) ) &&",
            "mv %s/%s %s" % (docs_dir, d_docs_zip.basename, d_docs_zip.path),
        ]
    )

    toolchain_files = (
        ctx.files._d_stdlib +
        ctx.files._d_stdlib_src +
        ctx.files._d_runtime_import_src
    )
    ddoc_inputs = depset(target.srcs + toolchain_files, transitive = [target.transitive_srcs])
    ctx.actions.run_shell(
        inputs = ddoc_inputs,
        tools = [ctx.file._d_compiler],
        outputs = [d_docs_zip],
        mnemonic = "Ddoc",
        command = " ".join(doc_cmd),
        use_default_shell_env = True,
        progress_message = "Generating D docs for " + ctx.label.name,
    )

_d_common_attrs = {
    "srcs": attr.label_list(allow_files = D_FILETYPE),
    "imports": attr.string_list(),
    "linkopts": attr.string_list(),
    "versions": attr.string_list(),
    "deps": attr.label_list(),
    "data": attr.label_list(allow_files = True),
    "dmd_args": attr.string_list(),
}

_d_compile_attrs = {
    "_d_compiler": attr.label(
        default = Label("//d:dmd"),
        executable = True,
        allow_single_file = True,
        cfg = "host",
    ),
    "_d_runtime_import_src": attr.label(
        default = Label("//d:druntime-import-src"),
    ),
    "_d_stdlib": attr.label(
        default = Label("//d:libphobos2"),
    ),
    "_d_stdlib_src": attr.label(
        default = Label("//d:phobos-src"),
    ),
}

d_library = rule(
    _d_library_impl,
    attrs = dict(_d_common_attrs.items() + _d_compile_attrs.items()),
)

d_source_library = rule(
    _d_source_library_impl,
    attrs = _d_common_attrs,
)

d_binary = rule(
    _d_binary_impl,
    attrs = dict(_d_common_attrs.items() + _d_compile_attrs.items()),
    executable = True,
)

d_test = rule(
    _d_test_impl,
    attrs = dict(_d_common_attrs.items() + _d_compile_attrs.items()),
    executable = True,
    test = True,
)

_d_docs_attrs = {
    "dep": attr.label(mandatory = True),
}

d_docs = rule(
    _d_docs_impl,
    attrs = dict(_d_docs_attrs.items() + _d_compile_attrs.items()),
    outputs = {
        "d_docs": "%{name}-docs.zip",
    },
)

DMD_BUILD_FILE = """
package(default_visibility = ["//visibility:public"])

config_setting(
    name = "darwin",
    values = {"host_cpu": "darwin"},
)

config_setting(
    name = "k8",
    values = {"host_cpu": "k8"},
)

config_setting(
    name = "x64_windows",
    values = {"host_cpu": "x64_windows"},
)

filegroup(
    name = "dmd",
    srcs = select({
        ":darwin": ["dmd2/osx/bin/dmd"],
        ":k8": ["dmd2/linux/bin64/dmd"],
        ":x64_windows": ["dmd2/windows/bin64/dmd.exe"],
    }),
)

filegroup(
    name = "libphobos2",
    srcs = select({
        ":darwin": ["dmd2/osx/lib/libphobos2.a"],
        ":k8": [
            "dmd2/linux/lib64/libphobos2.a",
            "dmd2/linux/lib64/libphobos2.so",
        ],
        ":x64_windows": ["dmd2/windows/lib64/phobos64.lib"],
    }),
)

filegroup(
    name = "phobos-src",
    srcs = glob(["dmd2/src/phobos/**/*.*"]),
)

filegroup(
    name = "druntime-import-src",
    srcs = glob([
        "dmd2/src/druntime/import/*.*",
        "dmd2/src/druntime/import/**/*.*",
    ]),
)
"""

def d_repositories():
    http_archive(
        name = "dmd_linux_x86_64",
        urls = [
            "http://downloads.dlang.org/releases/2020/dmd.2.094.0.linux.tar.xz",
        ],
        sha256 = "b77f8fdd7f0415d418eac3192186b7f4aa2f80e67bc415191cdd416548451576",
        build_file_content = DMD_BUILD_FILE,
    )

    http_archive(
        name = "dmd_darwin_x86_64",
        urls = [
            "http://downloads.dlang.org/releases/2020/dmd.2.094.0.osx.tar.xz",
        ],
        sha256 = "2a9f437e0327fcf362a83ae50b2b17ad5e5a4ffbcdb33e6276f1db56ca870355",
        build_file_content = DMD_BUILD_FILE,
    )

    http_archive(
        name = "dmd_windows_x86_64",
        urls = [
            "http://downloads.dlang.org/releases/2020/dmd.2.094.0.windows.zip",
        ],
        sha256 = "a8f3677ba2797729cf9379f541b8ea1a355bab1bff5c372e9dd53cfe9717a104",
        build_file_content = DMD_BUILD_FILE,
    )
