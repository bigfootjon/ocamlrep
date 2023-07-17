# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//:artifact_tset.bzl", "project_artifact_tset")
load("@prelude//:paths.bzl", "paths")
load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load("@prelude//cxx:linker.bzl", "get_rpath_origin")
load(
    "@prelude//linking:link_info.bzl",
    "LinkArgs",
    "LinkInfo",
    "unpack_link_args",
    "unpack_link_args_filelist",
)
load(":cxx_context.bzl", "get_cxx_toolchain_info")

def linker_map_args(ctx, linker_map) -> LinkArgs.type:
    linker_type = get_cxx_toolchain_info(ctx).linker_info.type
    if linker_type == "darwin":
        flags = [
            "-Xlinker",
            "-map",
            "-Xlinker",
            linker_map,
        ]
    elif linker_type == "gnu":
        flags = [
            "-Xlinker",
            "-Map",
            "-Xlinker",
            linker_map,
        ]
    else:
        fail("Linker type {} not supported".format(linker_type))
    return LinkArgs(flags = flags)

def map_link_args_for_dwo(dwo_dir: "output_artifact", links: ["LinkArgs"]) -> ["LinkArgs"]:
    """
    Takes LinkArgs, and if they enable the DWO output dir hack, returns updated
    args and a DWO dir as output. If they don't, just returns the args as-is.
    """

    # TODO(T110378131): Once we have first-class support for ThinLTO and
    # split-dwarf, we can move way from this hack and have the rules add this
    # parameter appropriately.  But, for now, to maintain compatibility for how
    # the macros setup ThinLTO+split-dwarf, use a macro hack to intercept when
    # we're setting an explicitly tracked dwo dir and pull into the explicit
    # tracking we do at the `LinkedObject` level.

    def adjust_flag(flag: "_arglike") -> "_arglike":
        if "HACK-OUTPUT-DWO-DIR" in repr(flag):
            return cmd_args(dwo_dir, format = "dwo_dir={}")
        else:
            return flag

    def adjust_link_info(link_info: LinkInfo.type) -> LinkInfo.type:
        return LinkInfo(
            name = link_info.name,
            linkables = link_info.linkables,
            pre_flags = [adjust_flag(x) for x in link_info.pre_flags],
            post_flags = [adjust_flag(x) for x in link_info.post_flags],
            external_debug_info = link_info.external_debug_info,
        )

    return [
        LinkArgs(
            tset = link.tset,
            flags = [adjust_flag(flag) for flag in link.flags] if link.flags != None else None,
            infos = [adjust_link_info(info) for info in link.infos] if link.infos != None else None,
        )
        for link in links
    ]

def make_link_args(
        ctx: "context",
        links: ["LinkArgs"],
        suffix = None,
        output_short_path: [str, None] = None,
        is_shared: [bool, None] = None,
        split_debug_output: ["artifact", None] = None,
        link_ordering: ["LinkOrdering", None] = None) -> ("_arglike", ["_hidden"], ["artifact", None]):
    """
    Merges LinkArgs. Returns the args, files that must be present for those
    args to work when passed to a linker, and optionally an artifact where DWO
    outputs will be written to.
    """
    suffix = "" if suffix == None else "-" + suffix
    args = cmd_args()
    hidden = []

    cxx_toolchain_info = get_cxx_toolchain_info(ctx)
    linker_info = cxx_toolchain_info.linker_info
    linker_type = linker_info.type

    # On Apple platforms, DWARF data is contained in the object files
    # and executables contains paths to the object files (N_OSO stab).
    #
    # By default, ld64 will use absolute file paths in N_OSO entries
    # which machine-dependent executables. Such executables would not
    # be debuggable on any host apart from the host which performed
    # the linking. Instead, we want produce machine-independent
    # hermetic executables, so we need to relativize those paths.
    #
    # This is accomplished by passing the `oso-prefix` flag to ld64,
    # which will strip the provided prefix from the N_OSO paths.
    #
    # The flag accepts a special value, `.`, which means it will
    # use the current workding directory. This will make all paths
    # relative to the parent of `buck-out`.
    #
    # Because all actions in Buck2 are run from the project root
    # and `buck-out` is always inside the project root, we can
    # safely pass `.` as the `-oso_prefix` without having to
    # write a wrapper script to compute it dynamically.
    if linker_type == "darwin":
        args.add(["-Wl,-oso_prefix,."])

    # Not all C/C++ codebases use split-DWARF. Apple uses dSYM files, instead.
    #
    # If we aren't going to use .dwo/.dwp files, avoid the codepath.
    # Historically we've seen that going down this path bloats
    # the memory usage of FBiOS by 12% (which amounts to Gigabytes.)
    #
    # Context: D36669131
    if split_debug_output != None and linker_info.type != "darwin":
        links = map_link_args_for_dwo(split_debug_output.as_output(), links)

    pdb_artifact = None
    if linker_info.is_pdb_generated and output_short_path != None:
        pdb_filename = paths.replace_extension(output_short_path, ".pdb")
        pdb_artifact = ctx.actions.declare_output(pdb_filename)
        hidden.append(pdb_artifact.as_output())

    for link in links:
        args.add(unpack_link_args(link, is_shared, link_ordering = link_ordering))

    filelists = filter(None, [unpack_link_args_filelist(link) for link in links])
    hidden.extend(filelists)
    if filelists:
        if linker_type == "gnu":
            fail("filelist populated for gnu linker")
        elif linker_type == "darwin":
            # On Darwin, filelist args _must_ come last as there's semantical difference
            # of the position.
            path = ctx.actions.write("filelist%s.txt" % suffix, filelists)
            args.add(["-Xlinker", "-filelist", "-Xlinker", path])
        else:
            fail("Linker type {} not supported".format(linker_type))

    return (args, [args] + hidden, pdb_artifact)

def shared_libs_symlink_tree_name(output: "artifact") -> str:
    return "__{}__shared_libs_symlink_tree".format(output.short_path)

# Returns a tuple of:
# - list of extra arguments,
# - list of files/directories that should be present for executable to be run successfully
# - optional shared libs symlink tree symlinked_dir action
def executable_shared_lib_arguments(
        actions: "actions",
        cxx_toolchain: CxxToolchainInfo.type,
        output: "artifact",
        shared_libs: {str: "LinkedObject"}) -> ([""], ["_arglike"], ["artifact", None]):
    extra_args = []
    runtime_files = []
    shared_libs_symlink_tree = None

    # Add external debug paths to runtime files, so that they're
    # materialized when the binary is built.
    runtime_files.extend(
        project_artifact_tset(
            actions = actions,
            infos = [shlib.external_debug_info for shlib in shared_libs.values()],
        ),
    )

    linker_type = cxx_toolchain.linker_info.type

    # Windows doesn't support rpath.
    if len(shared_libs) > 0 and linker_type != "windows":
        shared_libs_symlink_tree = actions.symlinked_dir(
            shared_libs_symlink_tree_name(output),
            {name: shlib.output for name, shlib in shared_libs.items()},
        )
        runtime_files.append(shared_libs_symlink_tree)
        rpath_reference = get_rpath_origin(linker_type)

        # We ignore_artifacts() here since we don't want the symlink tree to actually be there for the link.
        rpath_arg = cmd_args(shared_libs_symlink_tree, format = "-Wl,-rpath,{}/{{}}".format(rpath_reference)).relative_to(output, parent = 1).ignore_artifacts()
        extra_args.append(rpath_arg)

    return (extra_args, runtime_files, shared_libs_symlink_tree)

def cxx_link_cmd_parts(ctx: "context") -> ("RunInfo", "cmd_args"):
    toolchain = get_cxx_toolchain_info(ctx)

    # `toolchain_linker_flags` can either be a list of strings, `cmd_args` or `None`,
    # so we need to do a bit more work to satisfy the type checker
    toolchain_linker_flags = toolchain.linker_info.linker_flags
    if toolchain_linker_flags == None:
        toolchain_linker_flags = cmd_args()
    elif not type(toolchain_linker_flags) == "cmd_args":
        toolchain_linker_flags = cmd_args(toolchain_linker_flags)

    return toolchain.linker_info.linker, toolchain_linker_flags

# The command line for linking with C++
def cxx_link_cmd(ctx: "context") -> "cmd_args":
    linker, toolchain_linker_flags = cxx_link_cmd_parts(ctx)
    command = cmd_args(linker)
    command.add(toolchain_linker_flags)
    return command
