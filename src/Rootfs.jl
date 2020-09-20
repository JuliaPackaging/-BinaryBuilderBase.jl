export supported_platforms, expand_gfortran_versions, expand_cxxstring_abis, expand_microarchitectures

import Pkg.Artifacts: load_artifacts_toml, ensure_all_artifacts_installed

# This is a type that encompasses a shard; it makes it easy to pass it around,
# get its download url, extraction url, mounting url, etc...
struct CompilerShard
    # Something like "RootFS", or "GCCBootstrap"
    name::String
    
    # Something like v"7.1.0"
    version::VersionNumber

    # Things like Windows(:x86_64; compiler_abi=CompilerABI(libgfortran_version=v"3"))
    target::Union{Nothing,Platform}

    # Usually `Linux(:x86_64, libc=:musl)`, with the NOTABLE exception of `Rust`
    host::Platform
    
    # :unpacked or :squashfs.  Possibly more in the future.
    archive_type::Symbol

    function CompilerShard(name, version, host, archive_type; target = nothing)
        # Ensure we have the right archive type
        if !(archive_type in (:squashfs, :unpacked))
            error("Invalid archive type '$(archive_type)'")
        end

        # If host or target are unparsed, parse them:
        if isa(host, AbstractString)
            host = platform_key_abi(host)
        end
        if isa(target, AbstractString)
            target = platform_key_abi(target)
        end

        # Ensure the platforms have no ABI portion (that is only used
        # by higher-level things to choose e.g. which version of GCC
        # to use, but once we're at this level we only care about the
        # larger-scale things, not the ABI).
        host = abi_agnostic(host)
        if target !== nothing
            target = abi_agnostic(target)
        end

        # Construct our shiny new CompilerShard object
        return new(name, version, target, host, archive_type)
    end
end

"""
    abi_agnostic(p::Platform)

Strip out the CompilerABI portion of a Platform, making it "ABI agnostic".
"""
function abi_agnostic(p::P) where {P <: Platform}
    return P(arch(p); libc=libc(p), call_abi=call_abi(p))
end

"""
    artifact_name(cs::CompilerShard)

Return the bound artifact name for a particular shard.
"""
function artifact_name(cs::CompilerShard)
    target_str = ""
    if cs.target != nothing
        target_str = "-$(triplet(cs.target))"

        # Julia <1.4 calls it `arm-linux-gnu`, but we prefer `armv7l-linux-gnu`
        target_str = replace(target_str, "-arm-linux" => "-armv7l-linux")
    end
    ext = Dict(:squashfs => "squashfs", :unpacked => "unpacked")[cs.archive_type]
    return "$(cs.name)$(target_str).v$(cs.version).$(triplet(cs.host)).$(ext)"
end

# The inverse of `artifact_name(cs)`
function CompilerShard(art_name::String)
    m = match(r"^([^-]+)(?:-(.+))?\.(v[\d\.]+(?:-[^\.]+)?)\.([^0-9].+-.+)\.(\w+)", art_name)
    if m === nothing
        error("Unable to parse '$(art_name)'")
    end
    return CompilerShard(
        m.captures[1],
        VersionNumber(m.captures[3]),
        m.captures[4],
        Symbol(m.captures[5]);
        target=m.captures[2]
    )
end

const ALL_SHARDS = Ref{Union{Vector{CompilerShard},Nothing}}(nothing)
function all_compiler_shards()
    if ALL_SHARDS[] === nothing
        artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
        artifact_dict = load_artifacts_toml(artifacts_toml)

        ALL_SHARDS[] = CompilerShard[]
        for name in keys(artifact_dict)
            cs = try
                CompilerShard(name)
            catch
                continue
            end
            push!(ALL_SHARDS[], cs)
        end
    end
    return ALL_SHARDS[]
end

"""
    shard_path(cs::CompilerShard)

Return the path to this shard on-disk; for unpacked shards, this is a directory.
For squashfs shards, this is a file.  This will not cause a shard to be downloaded.
"""
function shard_path(cs::CompilerShard)
    if cs.shard_type == :squashfs
        mutable_artifacts_toml = joinpath(dirname(@__DIR__), "MutableArtifacts.toml")
        artifacts_dict = artifact_meta(
            artifact_name(cs),
            artifacts_toml;
            platform=something(cs.target, cs.host),
        )
    end

    artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
    artifacts_dict = artifact_meta(
        artifact_name(cs),
        artifacts_toml;
        platform=something(cs.target, cs.host),
    )
    if artifacts_dict == nothing
        error("CompilerShard $(artifact_name(cs)) not registered in Artifacts.toml!")
    end
    
    return artifact_path(artifacts_dict["git-tree-sha1"])
end

"""
    map_target(cs::CompilerShard)

Return the location this compiler shard should be mounted at.  We basically
analyze the name and platform of this shard and return a path based on that.
"""
function map_target(cs::CompilerShard)
    if lowercase(cs.name) == "rootfs"
        return "/"
    elseif lowercase(cs.name) == "rusttoolchain"
        # We override RustToolchain because they all have to sit in the same location
        return "/opt/$(aatriplet(cs.host))/$(cs.name)-$(cs.version)-$(aatriplet(cs.target)))"
    else
        return joinpath("/opt", aatriplet(something(cs.target, cs.host)), "$(cs.name)-$(cs.version)")
    end
end

function mount_path(cs::CompilerShard, build_prefix::AbstractString)
    if cs.archive_type == :squashfs
        return joinpath(build_prefix, ".mounts", artifact_name(cs))
    else
        name = artifact_name(cs)
        artifacts_toml = joinpath(@__DIR__, "..", "Artifacts.toml")
        hash = artifact_hash(name, artifacts_toml; platform=cs.host)
        if hash === nothing
            error("Unable to find artifact $(name) within $(artifacts_toml)")
        end
        return artifact_path(hash)
    end
end

"""
    accept_apple_sdk(ins::IO, outs::IO) -> Bool

Ask the user whether they accept the terms of the macOS SDK, and return a
boolean with their choice.  Write messages to `outs`, read input from `ins`.
"""
function accept_apple_sdk(ins::IO, outs::IO)
    msg = strip("""
                Apple restricts distribution and usage of the macOS SDK, a necessary
                component to build software for macOS targets.  Please read the Apple
                and Xcode SDK agreement for more information on the restrictions and
                legal terms you agree to when using the SDK to build software for Apple
                operating systems: https://images.apple.com/legal/sla/docs/xcode.pdf.
                """)
    printstyled(outs, msg, bold=true)
    println(outs)
    while true
        print(outs, "Would you like to download and use the macOS SDK? [y/N]: ")
        answer = lowercase(strip(readline(ins)))
        if answer == "y" || answer == "yes"
            return true
        elseif answer == "n" || answer == "no"
            return false
        else
            println(outs, "Unrecognized answer. Answer `y` or `n`.")
        end
    end
end

"""
    mount(cs::CompilerShard, build_prefix::String)

Mount a compiler shard, if possible.  Uses `run()` so will error out if
something goes awry.  Note that this function only does something when
using a `.squashfs` shard, with a UserNS or Docker runner, on Linux.
All other combinations of shard archive type, runner and platform result
in a no-op from this function.
"""
function mount(cs::CompilerShard, build_prefix::AbstractString; verbose::Bool = false)
    # Before doing anything with a MacOS shard, make sure the user knows that
    # they must accept the Xcode EULA.  This will be skipped if either the
    # environment variable BINARYBUILDER_AUTOMATIC_APPLE has been set to `true`
    # or if the SDK has been downloaded in the past.
    if typeof(cs.target) <: MacOS && !isfile(enable_apple_file()) && !macos_sdk_already_installed()
        if !isinteractive()
            msg = strip("""
            This is not an interactive Julia session, so we will not prompt you
            to download and install the macOS SDK.  Because you have not agreed
            to the Xcode license terms, we will not be able to build for MacOS.
            Please read the Apple and Xcode SDK agreement for more information
            on the restrictions and legal terms you agree to when using the SDK
            to build software: https://images.apple.com/legal/sla/docs/xcode.pdf.
            Should you then wish to agree to them, you can do so by setting the
            environment variable BINARYBUILDER_AUTOMATIC_APPLE to `true` and then
            restarting this computation.
            """)
            @error(msg)
            error("macOS SDK not installable")
        else
            if !accept_apple_sdk(stdin, stdout)
                error("macOS SDK not installable")
            end
        end
    end

    # Ensure this artifact is on-disk; hard to mount it if it's not installed
    artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
    ensure_artifact_installed(artifact_name(cs), artifacts_toml; platform=cs.host, verbose=true)

    # Easy out if we're not Linux with a UserNSRunner trying to use a .squashfs
    if !Sys.islinux() || (preferred_runner() != UserNSRunner &&
                          preferred_runner() != DockerRunner) ||
                         cs.archive_type != :squashfs
        # We'll just give back the artifact path in this case
        return mount_path(cs, build_prefix)
    end

    # If it's already mounted, also just return the mount path
    if is_mounted(cs, build_prefix)
        return mount_path(cs, build_prefix)
    end

    # Ensure that we've got a UID-appropriate .squashfs
    squashfs_path = generate_per_uid_squashfs(cs; verbose=verbose)

    # Signal to the user what's going on, since this might require sudo.
    mpath = mount_path(cs, build_prefix)
    if verbose
        @debug("Mounting $(squashfs_path) to $(mpath)")
    end

    # If the destination directory does not already exist, create it
    mkpath(mpath)

    # Run the mountaining
    run(`$(sudo_cmd()) mount $(squashfs_path) $(mpath) -o ro,loop`)

    # Give back the mount path
    return mpath
end

"""
    is_mounted(cs::CompilerShard, build_prefix::String)

Return true if the given shard is mounted.  Uses `run()` so will error out if
something goes awry.
"""
function is_mounted(cs::CompilerShard, build_prefix::AbstractString)
    return success(`mountpoint $(mount_path(cs, build_prefix))`)
end

"""
    unmount(cs::CompilerShard, build_prefix::String)

Unmount a compiler shard from a given build prefix, if possible.  Uses `run()`
so will error out if something goes awry.  Note that this function only does
something when using a squashfs shard on Linux.  All other combinations of
shard archive type and platform result in a no-op.
"""
function unmount(cs::CompilerShard, build_prefix::String; verbose::Bool = false, fail_on_error::Bool = false)
    # Only try to unmount if it's mounted
    if Sys.islinux() && is_mounted(cs, build_prefix)
        mpath = mount_path(cs, build_prefix)
        if verbose
            @debug("Unmounting $(mpath)`")
        end
        try
            cmd = `$(sudo_cmd()) umount $(mpath)`
            run(cmd, verbose ? (devnull, stdout, stderr) : (devnull, devnull, devnull))

            # Remove mountpoint directory
            rm(mpath; force=true, recursive=false)
        catch e
            # By default we don't error out if this unmounting fails
            if e isa InterruptException || fail_on_error
                rethrow(e)
            end
        end
    end
end

"""
    macos_sdk_already_installed()

Returns `true` if any piece of the MacOS SDK is already installed.
"""
function macos_sdk_already_installed()
    # Get all compiler shards we know about
    css = all_compiler_shards()
    macos_artifact_names = artifact_name.(filter(cs -> isa(cs.target, MacOS), css))

    host_platform = Linux(:x86_64; libc=:musl)
    artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
    macos_artifact_hashes = artifact_hash.(macos_artifact_names, artifacts_toml; platform=host_platform)

    # The Rust shards will return `nothing` above (so we filter them out here) since they
    # are TECHNICALLY `Linux(:x86_64; libc=:glibc)`-hosted.  Whatever. You need to download
    # one of the `PlatformSupport` shards for this anyway, so we don't really care.
    macos_artifact_hashes = filter(x -> x != nothing, macos_artifact_hashes)

    # Return `true` if _any_ of these artifacts exist on-disk:
    return any(artifact_exists.(macos_artifact_hashes))
end

function select_closest_version(preferred::VersionNumber, versions::Vector{VersionNumber})
    ver_to_tuple(v) = (Int(v.major), Int(v.minor), Int(v.patch))
    preferred = ver_to_tuple(preferred)
    closest_idx = findmin([abs.(preferred .- ver_to_tuple(v)) for v in versions])[2]
    return versions[closest_idx]
end

abstract type CompilerBuild end

struct GCCBuild <: CompilerBuild
    version::VersionNumber
    abi::CompilerABI
end
GCCBuild(v::VersionNumber) = GCCBuild(v, CompilerABI())

struct LLVMBuild <: CompilerBuild
    version::VersionNumber
    abi::CompilerABI
end
LLVMBuild(v::VersionNumber) = LLVMBuild(v, CompilerABI())

getversion(c::CompilerBuild) = c.version
getabi(c::CompilerBuild) = c.abi

const available_gcc_builds = [
    GCCBuild(v"4.8.5", CompilerABI(libgfortran_version = v"3", libstdcxx_version = v"3.4.19", cxxstring_abi = :cxx03)),
    GCCBuild(v"5.2.0", CompilerABI(libgfortran_version = v"3", libstdcxx_version = v"3.4.21", cxxstring_abi = :cxx11)),
    GCCBuild(v"6.1.0", CompilerABI(libgfortran_version = v"3", libstdcxx_version = v"3.4.22", cxxstring_abi = :cxx11)),
    GCCBuild(v"7.1.0", CompilerABI(libgfortran_version = v"4", libstdcxx_version = v"3.4.23", cxxstring_abi = :cxx11)),
    GCCBuild(v"8.1.0", CompilerABI(libgfortran_version = v"5", libstdcxx_version = v"3.4.25", cxxstring_abi = :cxx11)),
    GCCBuild(v"9.1.0", CompilerABI(libgfortran_version = v"5", libstdcxx_version = v"3.4.26", cxxstring_abi = :cxx11)),
    GCCBuild(v"11-iains", CompilerABI(libgfortran_version = v"5", libstdcxx_version = v"3.4.26", cxxstring_abi = :cxx11)),
]
const available_llvm_builds = [
    LLVMBuild(v"6.0.1"),
    LLVMBuild(v"7.1.0"),
    LLVMBuild(v"8.0.1"),
    LLVMBuild(v"9.0.1"),
]

"""
    gcc_version(p::Platform, , GCC_builds::Vector{GCCBuild})

Returns the closest matching GCC version number for the given particular
platform, from the given set of options.  The compiler ABI and the
microarchitecture of the platform will be taken into account.  If no match is
found, returns an empty list.

This method assumes that the compiler ABI of the platform represents a platform
that binaries will be run on, and thus versions are always rounded down; e.g. if
the platform supports a `libstdc++` version that corresponds to `GCC 5.1.0`, but
the only GCC versions available to be picked from are `4.8.5` and `5.2.0`, it
will return `4.8.5`, as binaries compiled with that version will run on this
platform, whereas binaries compiled with `5.2.0` may not.
"""
function gcc_version(p::Platform, GCC_builds::Vector{GCCBuild})
    cabi = compiler_abi(p)
    # First, filter by libgfortran version.
    if libgfortran_version(cabi) !== nothing
        GCC_builds = filter(b -> libgfortran_version(getabi(b)) == libgfortran_version(cabi), GCC_builds)
    end

    # Next, filter by libstdc++ GLIBCXX symbol version.  Note that this
    # mapping is conservative; it is often the case that we return a
    # version that is slightly lower than what is actually installed on
    # a system.  See https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html
    # for the whole list, as well as many other interesting factoids.
    if libstdcxx_version(cabi) !== nothing
        GCC_builds = filter(b -> libstdcxx_version(getabi(b)) <= libstdcxx_version(cabi), GCC_builds)
    end

    # Finally, enforce cxxstring_abi guidelines.  It is possible to build
    # :cxx03 binaries on GCC 5+, (although increasingly rare) so the only
    # filtering we do is that if the platform is explicitly :cxx11, we
    # disallow running on < GCC 5.
    if cxxstring_abi(cabi) !== nothing && cxxstring_abi(cabi) === :cxx11
        GCC_builds = filter(b -> getversion(b) >= v"5", GCC_builds)
    end

    # Filter the possible GCC versions depending on the microarchitecture
    if march(p) !== nothing
        if march(p) in ("avx", "avx2")
            # "sandybridge" and "haswell" introduced in GCC v4.9.0:
            # https://www.gnu.org/software/gcc/gcc-4.9/changes.html
            GCC_builds = filter(b -> getversion(b) >= v"4.9", GCC_builds)
        elseif march(p) == "avx512"
            # "skylake-avx512" introduced in GCC v6.1:
            # https://www.gnu.org/software/gcc/gcc-6/changes.html
            GCC_builds = filter(b -> getversion(b) >= v"6.1", GCC_builds)
        elseif march(p) == "thunderx2"
            # "thunderx2t99" introduced in GCC v7.1:
            # https://www.gnu.org/software/gcc/gcc-7/changes.html
            GCC_builds = filter(b -> getversion(b) >= v"7.1", GCC_builds)
        elseif march(p) in ("neon", "vfp4", "carmel")
            # "+aes" and "+sha2" extensions for aarch64 introduced in GCC v8:
            # https://www.gnu.org/software/gcc/gcc-8/changes.html
            GCC_builds = filter(b -> getversion(b) >= v"8.1", GCC_builds)
        end
    end

    return getversion.(GCC_builds)
end

function select_gcc_version(p::Platform,
             GCC_builds::Vector{GCCBuild} = available_gcc_builds,
             preferred_gcc_version::VersionNumber = getversion(GCC_builds[1]),
         )
    # Determine which GCC build we're going to match with this CompilerABI:
    GCC_builds = gcc_version(p, GCC_builds)

    if isempty(GCC_builds)
        error("Impossible CompilerABI constraints $(cabi)!")
    end

    # Otherwise, choose the version that is closest to our preferred version
    return select_closest_version(preferred_gcc_version, GCC_builds)
end


"""
    choose_shards(p::Platform; rootfs_build, ps_build, GCC_builds,
                               LLVM_builds, archive_type)

This method chooses, given a `Platform`, which shards to download, extract and
mount, returning a list of `CompilerShard` objects.  At the moment, this always
consists of four shards, but that may not always be the case.
"""
function choose_shards(p::Platform;
            compilers::Vector{Symbol} = [:c],
            rootfs_build::VersionNumber=v"2020.08.19",
            ps_build::VersionNumber=v"2020.08.19",
            GCC_builds::Vector{GCCBuild}=available_gcc_builds,
            LLVM_builds::Vector{LLVMBuild}=available_llvm_builds,
            Rust_build::VersionNumber=v"1.18.3",
            Go_build::VersionNumber=v"1.13",
            archive_type::Symbol = (use_squashfs ? :squashfs : :unpacked),
            bootstrap_list::Vector{Symbol} = bootstrap_list,
            # Because GCC has lots of compatibility issues, we always default to
            # the earliest version possible.
            preferred_gcc_version::VersionNumber = getversion(GCC_builds[1]),
            # Because LLVM doesn't have compatibility issues, we always default
            # to the newest version possible.
            preferred_llvm_version::VersionNumber = getversion(LLVM_builds[end]),
        )

    # Our host platform is x86_64-linux-musl
    host_platform = Linux(:x86_64; libc=:musl)

    make_gcc_shard(GCC_build, target) = CompilerShard("GCCBootstrap", GCC_build, host_platform, archive_type; target=target)

    this_platform_GCC_builds = filter(GCC_builds) do GCC_build
        make_gcc_shard(getversion(GCC_build), p) in all_compiler_shards() &&
        make_gcc_shard(getversion(GCC_build), host_platform) in all_compiler_shards()
    end

    GCC_build = select_gcc_version(p, this_platform_GCC_builds, preferred_gcc_version)
    LLVM_build = select_closest_version(preferred_llvm_version, getversion.(LLVM_builds))

    shards = CompilerShard[]
    if isempty(bootstrap_list)
        append!(shards, [
            CompilerShard("Rootfs", rootfs_build, host_platform, archive_type),
            # Shards for the target architecture
            CompilerShard("PlatformSupport", ps_build, host_platform, archive_type; target=p),
        ])

        platform_match(a, b) = ((typeof(a) <: typeof(b)) && (arch(a) == arch(b)) && (libc(a) == libc(b)))
        if :c in compilers
            append!(shards, [
                make_gcc_shard(GCC_build, p),
                CompilerShard("LLVMBootstrap", LLVM_build, host_platform, archive_type),
            ])
            # If we're not building for the host platform, then add host shard for host tools
            if !platform_match(p, host_platform)
                append!(shards, [
                    CompilerShard("PlatformSupport", ps_build, host_platform, archive_type; target=host_platform),
                    make_gcc_shard(GCC_build, host_platform)
                ])
            end
        end

        if :rust in compilers
            # Our rust base shard is technically x86_64-linux-gnu, not x86_64-linux-musl, since rust is broken  when hosted on `musl`:
            Rust_host = Linux(:x86_64; libc=:glibc)
            append!(shards, [
                CompilerShard("RustBase", Rust_build, Rust_host, archive_type),
                CompilerShard("RustToolchain", Rust_build, Rust_host, archive_type; target=p),
            ])

            if !platform_match(p, Rust_host)
                push!(shards, CompilerShard("RustToolchain", Rust_build, Rust_host, archive_type; target=Rust_host))

                # We have to add these as well for access to linkers and whatnot for Rust.  Sigh.
                push!(shards, CompilerShard("PlatformSupport", ps_build, host_platform, archive_type; target=Rust_host))
                push!(shards, make_gcc_shard(GCC_build, Rust_host))
            end
            if !platform_match(p, host_platform)
                push!(shards, CompilerShard("RustToolchain", Rust_build, Rust_host, archive_type; target=host_platform))
            end
        end

        if :go in compilers
            push!(shards, CompilerShard("Go", Go_build, host_platform, archive_type))
        end
    else
        function find_latest_version(name)
            versions = [cs.version for cs in all_compiler_shards()
                if cs.name == name && cs.archive_type == archive_type && (something(cs.target, p) == p)
            ]
            isempty(versions) && error("No latest shard found for $name")
            return maximum(versions)
        end

        if :rootfs in bootstrap_list
            push!(shards, CompilerShard("Rootfs", find_latest_version("Rootfs"), host_platform, archive_type))
        end
        if :platform_support in bootstrap_list
            for target in supported_platforms()
                push!(shards, CompilerShard("PlatformSupport", find_latest_version("PlatformSupport"), host_platform, archive_type; target=target))
            end
        end
        if :glibc in bootstrap_list
            for target in supported_platforms()
                push!(shards, make_gcc_shard(GCC_build, target))
            end
        end
    end
    return shards
end

# XXX: we want AnyPlatform to look like `x86_64-linux-musl` in the build environment.
choose_shards(::AnyPlatform; kwargs...) = choose_shards(Linux(:x86_64, libc=:musl); kwargs...)

"""
    supported_platforms(;exclude::Union{Vector{<:Platform},Function}=x->false)

Return the list of supported platforms as an array of `Platform`s.  These are the platforms we
officially support building for, if you see a mapping in `get_shard_hash()` that isn't
represented here, it's probably because that platform is still considered "in beta".

Platforms can be excluded from the list by specifying an array of platforms to `exclude` i.e.
`supported_platforms(exclude=[Windows(:i686),Windows(:x86_64)])`
or a function that returns true for exclusions i.e.
```
islin(x) = typeof(x) == Linux
supported_platforms(exclude=islin)
```
"""
function supported_platforms(;exclude::Union{Vector{<:Platform},Function}=x->false)
    exclude_platforms!(platforms, exclude::Function) = filter(!exclude, platforms)
    exclude_platforms!(platforms, exclude::Vector{<:Platform}) = filter!(!in(exclude), platforms)
    standard_platforms = [
        # glibc Linuces
        Linux(:i686),
        Linux(:x86_64),
        Linux(:aarch64),
        Linux(:armv7l),
        Linux(:powerpc64le),

        # musl Linuces
        Linux(:i686, libc=:musl),
        Linux(:x86_64, libc=:musl),
        Linux(:aarch64, libc=:musl),
        Linux(:armv7l, libc=:musl),

        # BSDs
        MacOS(:x86_64),
        FreeBSD(:x86_64),

        # Windows
        Windows(:i686),
        Windows(:x86_64),
    ]
    return exclude_platforms!(standard_platforms,exclude)
end

function replace_libgfortran_version(p::Platform, libgfortran_version::VersionNumber)
    new_cabi = CompilerABI(compiler_abi(p); libgfortran_version=libgfortran_version)
    return typeof(p)(arch(p); libc=libc(p), call_abi=call_abi(p), compiler_abi=new_cabi)
end

function replace_cxxstring_abi(p::Platform, cxxstring_abi::Symbol)
    new_cabi = CompilerABI(compiler_abi(p), cxxstring_abi=cxxstring_abi)
    return typeof(p)(arch(p); libc=libc(p), call_abi=call_abi(p), compiler_abi=new_cabi)
end

replace_libgfortran_version(ep::ExtendedPlatform, libgfortran_version::VersionNumber) =
    ExtendedPlatform(replace_libgfortran_version(ep.p, libgfortran_version), ep.ext)
replace_cxxstring_abi(ep::ExtendedPlatform, cxxstring_abi::Symbol) =
    ExtendedPlatform(replace_cxxstring_abi(ep.p, cxxstring_abi), ep.ext)

"""
    expand_gfortran_versions(p::Platform)

Given a `Platform`, returns an array of `Platforms` with a spread of identical
entries with the exception of the `gfortran_version` member of the `CompilerABI`
struct within the `Platform`.  This is used to take, for example, a list of
supported platforms and expand them to include multiple GCC versions for
the purposes of ABI matching.  If the given `Platform` already specifies a
GCC version (as opposed to `nothing`) only that `Platform` is returned.
"""
function expand_gfortran_versions(p::Platform)
    # If this platform cannot be expanded, then exit out fast here.
    if libgfortran_version(compiler_abi(p)) != nothing
        return [p]
    end

    # Otherwise, generate new versions!
    libgfortran_versions = [v"3", v"4", v"5"]
    return replace_libgfortran_version.(Ref(p), libgfortran_versions)
end
function expand_gfortran_versions(ps::Vector{<:Platform})
    return Platform[p for p in Iterators.flatten(expand_gfortran_versions.(ps))]
end

"""
    expand_cxxstring_abis(p::Platform; skip_freebsd_macos::Bool=true)

Given a `Platform`, returns an array of `Platforms` with a spread of identical
entries with the exception of the `cxxstring_abi` member of the `CompilerABI`
struct within the `Platform`.  This is used to take, for example, a list of
supported platforms and expand them to include multiple GCC versions for
the purposes of ABI matching.

If the given `Platform` already specifies a GCC version (as opposed to
`nothing`) only that `Platform` is returned.  If `skip_freebsd_macos` is `true`,
FreeBSD and MacOS platforms are left as they are.
"""
function expand_cxxstring_abis(p::Platform; skip_freebsd_macos::Bool=true)
    # If this platform cannot be expanded, then exit out fast here.
    if cxxstring_abi(compiler_abi(p)) !== nothing || (skip_freebsd_macos && Sys.isbsd(p))
        return [p]
    end

    # Otherwise, generate new versions!
    gcc_versions = [:cxx03, :cxx11]
    return replace_cxxstring_abi.(Ref(p), gcc_versions)
end
function expand_cxxstring_abis(ps::Vector{<:Platform}; kwargs...)
    return Platform[p for p in Iterators.flatten(expand_cxxstring_abis.(ps; kwargs...))]
end

# This function is used only by `expand_microarchitectures`, but can probably be
# useful in some occasions.
"""
    supported_microarchitectures(p::Platform)

Return a vector with the list of supported microarchitectures for the given
platform, an empty vector if there are any.  If `p` is an
[`ExtendedPlatform`](@ref) which already specifies a microarchitecture, returns
a 1-element vector containing only that one.
"""
function supported_microarchitectures(p::Platform)
    this_march = march(p)
    if p isa ExtendedPlatform && this_march !== nothing
        return [this_march]
    elseif !isa(p, AnyPlatform) && arch(p) in keys(ARCHITECTURE_FLAGS)
        # Sort the entries, for deterministic output
        return sort(collect(keys(ARCHITECTURE_FLAGS[arch(p)])))
    else
        return String[]
    end
end

"""
    expand_microarchitectures(p::Platform)

Given a `Platform`, returns a vector of `Platforms` with a spread of identical
`ExtendedPlatform` entries with the exception of the microarchitectures.  If the
given `Platform` is already an `ExtendedPlatform` with a `march` feature, only
that platform is returned.

Currently, only platforms with architecture `x86_64`, `amrv7l` or `aarch64` have
supported microarchitectures.  If the architecture of the platform does not have
supported microarchitectures, a 1-element vector containing the given platform
is returned.

```jldoctest
julia> using BinaryBuilderBase

julia> expand_microarchitectures(FreeBSD(:x86_64))
4-element Array{Platform,1}:
 ExtendedPlatform(FreeBSD(:x86_64); march="avx")
 ExtendedPlatform(FreeBSD(:x86_64); march="avx2")
 ExtendedPlatform(FreeBSD(:x86_64); march="avx512")
 ExtendedPlatform(FreeBSD(:x86_64); march="x86_64")

julia> expand_microarchitectures(Linux(:armv7l))
3-element Array{Platform,1}:
 ExtendedPlatform(Linux(:armv7l, libc=:glibc, call_abi=:eabihf); march="armv7l")
 ExtendedPlatform(Linux(:armv7l, libc=:glibc, call_abi=:eabihf); march="neon")
 ExtendedPlatform(Linux(:armv7l, libc=:glibc, call_abi=:eabihf); march="vfp4")

julia> expand_microarchitectures(Linux(:aarch64))
3-element Array{Platform,1}:
 ExtendedPlatform(Linux(:aarch64, libc=:glibc); march="armv8")
 ExtendedPlatform(Linux(:aarch64, libc=:glibc); march="carmel")
 ExtendedPlatform(Linux(:aarch64, libc=:glibc); march="thunderx2")

julia> expand_microarchitectures(Windows(:i686))
1-element Array{Windows,1}:
 Windows(:i686)
```
"""
function expand_microarchitectures(p::Platform)
    if p isa ExtendedPlatform && march(p) !== nothing
        # Nothing to expand if this has already a `march` entry
        return [p]
    end
    marchs = supported_microarchitectures(p)
    if length(marchs) > 0
        return Platform[ExtendedPlatform(p; march=march) for march in marchs]
    else
        return [p]
    end
end

"""
    expand_microarchitectures(ps::Vector{<:Platform})

Expand all platforms in the given vector with the supported microarchitectures.

```jldoctest
julia> using BinaryBuilderBase

julia> expand_microarchitectures(filter!(p -> p isa Linux && libc(p) == :glibc, supported_platforms()))
12-element Array{Platform,1}:
 Linux(:i686, libc=:glibc)
 ExtendedPlatform(Linux(:x86_64, libc=:glibc); march="avx")
 ExtendedPlatform(Linux(:x86_64, libc=:glibc); march="avx2")
 ExtendedPlatform(Linux(:x86_64, libc=:glibc); march="avx512")
 ExtendedPlatform(Linux(:x86_64, libc=:glibc); march="x86_64")
 ExtendedPlatform(Linux(:aarch64, libc=:glibc); march="armv8")
 ExtendedPlatform(Linux(:aarch64, libc=:glibc); march="carmel")
 ExtendedPlatform(Linux(:aarch64, libc=:glibc); march="thunderx2")
 ExtendedPlatform(Linux(:armv7l, libc=:glibc, call_abi=:eabihf); march="armv7l")
 ExtendedPlatform(Linux(:armv7l, libc=:glibc, call_abi=:eabihf); march="neon")
 ExtendedPlatform(Linux(:armv7l, libc=:glibc, call_abi=:eabihf); march="vfp4")
 Linux(:powerpc64le, libc=:glibc)
```
"""
expand_microarchitectures(ps::Vector{<:Platform}) = Platform[p for p in Iterators.flatten(expand_microarchitectures.(ps))]

"""
    preferred_libgfortran_version(platform::Platform, shard::CompilerShard;
                                  gcc_builds::Vector{GCCBuild} = available_gcc_builds)

Return the libgfortran version preferred by the given platform or GCCBootstrap shard.
"""
function preferred_libgfortran_version(platform::Platform, shard::CompilerShard;
                                       gcc_builds::Vector{GCCBuild} = available_gcc_builds)
    # Some input validation
    if shard.name != "GCCBootstrap"
        error("Shard must be `GCCBootstrap`")
    end
    if arch(shard.target) != arch(platform) || libc(shard.target) != libc(platform)
        error("Incompatible platform and shard target")
    end

    if libgfortran_version(compiler_abi(platform)) != nothing
        # Here we can't use `shard.target` because the shard always has the
        # target as ABI-agnostic, thus we have also to ask for the platform.
        return libgfortran_version(compiler_abi(platform))
    else
        idx = findfirst(b -> getversion(b) == shard.version, available_gcc_builds)
        if isnothing(idx)
            error("The shard doesn't match any version of the available GCC builds")
        else
            return libgfortran_version(getabi(gcc_builds[idx]))
        end
    end
end

"""
    preferred_cxxstring_abi(platform::Platform, shard::CompilerShard;
                            gcc_builds::Vector{GCCBuild} = available_gcc_builds)

Return the C++ string ABI preferred by the given platform or GCCBootstrap shard.
"""
function preferred_cxxstring_abi(platform::Platform, shard::CompilerShard;
                                 gcc_builds::Vector{GCCBuild} = available_gcc_builds)
    # Some input validation
    if shard.name != "GCCBootstrap"
        error("Shard must be `GCCBootstrap`")
    end
    if arch(shard.target) != arch(platform) || libc(shard.target) != libc(platform)
        error("Incompatible platform and shard target")
    end

    if cxxstring_abi(compiler_abi(platform)) != nothing
        # Here we can't use `shard.target` because the shard always has the
        # target as ABI-agnostic, thus we have also to ask for the platform.
        return cxxstring_abi(compiler_abi(platform))
    else
        idx = findfirst(b -> getversion(b) == shard.version, available_gcc_builds)
        if isnothing(idx)
            error("The shard doesn't match any version of the available GCC builds")
        else
            return cxxstring_abi(getabi(gcc_builds[idx]))
        end
    end
end

"""
    download_all_shards(; verbose::Bool=false)

Helper function to download all shards/helper binaries so that no matter what
happens, you don't need an internet connection to build your precious, precious
binaries.
"""
function download_all_artifacts(; verbose::Bool = false)
    artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
    # First, download all the "normal" shards, then all the rust shards (this will become
    # less clunky once Rust actually supports hosting on `musl`)
    host_platform = Linux(:x86_64; libc=:musl)
    Rust_host = Linux(:x86_64; libc=:glibc)
    for platform in (host_platform, Rust_host)    
        ensure_all_artifacts_installed(
            artifacts_toml;
            include_lazy=true,
            verbose=verbose,
            platform=host_platform
        )
    end
end

_sudo_cmd = nothing
function sudo_cmd()
    global _sudo_cmd

    # Use cached value if we've already run this
    if _sudo_cmd != nothing
        return _sudo_cmd
    end

    if getuid() == 0
        # If we're already root, don't use any kind of sudo program
        _sudo_cmd = ``
    elseif success(`sudo -V`)
        # If `sudo` is available, use that
        _sudo_cmd = `sudo`
    else
        # Fall back to `su` if all else fails
        _sudo_cmd = `su root -c`
    end
    return _sudo_cmd
end

"""
    shard_mappings(shards::Vector{CompilerShard})

Return the default mappings for a set of compiler shards
"""
function shard_mappings(shards::Vector{CompilerShard})
    mappings = Pair{String,String}[]
    for shard in shards
        # No mapping for the main rootfs shard
        if lowercase(shard.name) == "rootfs"
            continue
        end

        # For everything else, map it into its proper place
        push!(mappings, mount_path(shard) => map_target(shard))
    end

    # Reverse mapping order, because `sandbox` reads them backwards
    reverse!(mappings)
    return mappings
end

function mount_shards(ur::Runner; verbose::Bool = false)
    mount.(ur.shards, ur.workspace_root; verbose=verbose)
end
function unmount_shards(ur::Runner; verbose::Bool = false)
    unmount.(ur.shards, ur.workspace_root; verbose=verbose)

    # Remove `mounts` if it's empty
    try
        rm(joinpath(ur.workspace_root, ".mounts"))
    catch
    end
end



"""
    create_and_bind_mutable_artifact!(f::Function, art_name::String)

Create (and bind) an artifact to `MutableArtifacts.toml` in one fell swoop.
Used in things like .squashfs UID remapping and BB wizard state serialization.
"""
function create_and_bind_mutable_artifact!(f::Function, art_name::String)
    mutable_artifacts_toml = joinpath(dirname(@__DIR__), "MutableArtifacts.toml")
    art_hash = create_artifact(f)
    bind_artifact!(mutable_artifacts_toml, art_name, art_hash; force=true)
end

"""
    get_mutable_artifact_path(art_name::String)

Convenience wrapper to get an artifact bound within `MutableArtifacts.toml`.
Returns `nothing` if artifact not bound yet.
"""
function get_mutable_artifact_path(art_name::String)
    mutable_artifacts_toml = joinpath(dirname(@__DIR__), "MutableArtifacts.toml")
    hash = artifact_hash(art_name, mutable_artifacts_toml)
    if hash === nothing
        return nothing
    end

    return artifact_path(hash)
end
