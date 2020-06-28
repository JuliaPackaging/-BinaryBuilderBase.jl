module BinaryBuilderBase

using Pkg, Pkg.BinaryPlatforms, Pkg.PlatformEngines, Pkg.Artifacts, Random, Libdl
using JSON, OutputCollectors

# Re-export useful stuff from Pkg:
export platform_key_abi, platform_dlext, valid_dl_path, arch, libc, compiler_abi,
       libgfortran_version, libstdcxx_version, cxxstring_abi, parse_dl_name_version,
       detect_libgfortran_version, detect_libstdcxx_version, detect_cxxstring_abi,
       call_abi, wordsize, triplet, select_platform, platforms_match,
       CompilerABI, Platform, UnknownPlatform, Linux, MacOS, Windows, FreeBSD

export AbstractSource, AbstractDependency, SetupSource, PatchSource,
    resolve_jlls, coerce_dependency, coerce_source, Runner,
    generate_compiler_wrappers!, preferred_runner, CompilerShard, UserNSRunner,
    DockerRunner, choose_shards, exeext, preferred_libgfortran_version,
    preferred_cxxstring_abi, gcc_version, available_gcc_builds, getversion,
    getpkg, replace_libgfortran_version, replace_cxxstring_abi, aatriplet,
    nbits, proc_family, storage_dir, extract_kwargs, extract_fields,
    download_source, setup_workspace, setup_dependencies, update_registry,
    getname, cleanup_dependencies, compress_dir, prepare_for_deletion,
    run_interactive, sourcify, dependencify, with_logfile, get_concrete_platform

include("compat.jl")

include("Sources.jl")
include("Dependencies.jl")
include("Prefix.jl")
include("Products.jl")
include("Platforms.jl")

include("Runner.jl")
include("Rootfs.jl")
include("squashfs_utils.jl")
include("UserNSRunner.jl")
include("DockerRunner.jl")

include("utils.jl")

# This is the location that all binary builder-related files are stored under.
# downloads, unpacked .tar.gz shards, mounted shards, ccache cache, etc....
function storage_dir(args::AbstractString...)
    global storage_cache
    dir = joinpath(storage_cache, args...)
    mkpath(dirname(dir))
    return dir
end
ccache_dir() = storage_dir("ccache")

# These globals store important information such as where we're downloading
# the rootfs to, and where we're unpacking it.  These constants are initialized
# by `__init__()` to allow for environment variable overrides from the user.
storage_cache = ""
const automatic_apple = Ref(false) # Can be modified in BinaryBuilder
use_squashfs = false
allow_ecryptfs = false
use_ccache = false
bootstrap_list = Symbol[]

function __init__()
    global runner_override, use_squashfs, automatic_apple, allow_ecryptfs
    global use_ccache, storage_cache

    # Pkg does this lazily; do it explicitly here.
    Pkg.PlatformEngines.probe_platform_engines!()

    # Allow the user to override the default value for `storage_dir`
    storage_cache = get(ENV, "BINARYBUILDER_STORAGE_DIR",
                        abspath(joinpath(@__DIR__, "..", "deps")))

    # If the user has signalled that they really want us to automatically
    # accept apple EULAs, do that.
    if get(ENV, "BINARYBUILDER_AUTOMATIC_APPLE", "") == "true"
        automatic_apple[] = true
    end

    # If the user has overridden our runner selection algorithms, honor that
    runner_override = lowercase(get(ENV, "BINARYBUILDER_RUNNER", ""))
    if runner_override == "unprivileged"
        runner_override = "userns"
    end
    if !(runner_override in ["", "userns", "privileged", "docker"])
        @warn("Invalid runner value $runner_override, ignoring...")
        runner_override = ""
    end

    # If the user has asked for squashfs mounting instead of tarball mounting,
    # use that here.  Note that on Travis, we default to using squashfs, unless
    # BINARYBUILDER_USE_SQUASHFS is set to "false", which overrides this
    # default. If we are not on Travis, we default to using tarballs and not
    # squashfs images as using them requires `sudo` access.
    if get(ENV, "BINARYBUILDER_USE_SQUASHFS", "") == "false"
        use_squashfs = false
    elseif get(ENV, "BINARYBUILDER_USE_SQUASHFS", "") == "true"
        use_squashfs = true
    else
        # If it hasn't been specified, but we're on Travis, default to "on"
        if get(ENV, "TRAVIS", "") == "true"
            use_squashfs = true
        end

        # If it hasn't been specified but we're going to use the docker runner,
        # then set `use_squashfs` to `true` here.
        if preferred_runner() == DockerRunner
            # Conversely, if we're dock'ing it up, don't use it.
            use_squashfs = false
        elseif runner_override == "privileged"
            # If we're forcing a privileged runner, go ahead and default to squashfs
            use_squashfs = true
        end
    end

    # If the user has signified that they want to allow mounting of ecryptfs
    # paths, then let them do so at their own peril.
    if get(ENV, "BINARYBUILDER_ALLOW_ECRYPTFS", "") == "true"
        allow_ecryptfs = true
    end

    # If the user has enabled `ccache` support, use it!
    if get(ENV, "BINARYBUILDER_USE_CCACHE", "false") == "true"
        use_ccache = true
    end
end


end # module BinaryBuilderBase
