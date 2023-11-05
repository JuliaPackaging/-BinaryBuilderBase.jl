## This file contains functionality related to the actual layout of the files
#  on disk.  Things like the name of where downloads are stored, and what
#  environment variables must be updated to, etc...
import Base: convert, joinpath, show
using SHA, CodecZlib, TOML, LibGit2_jll
import Bzip2_jll, Gzip_jll, Tar_jll, XZ_jll, Zstd_jll, unzip_jll
using JLLWrappers: pathsep, LIBPATH_env

export Prefix, bindir, libdirs, includedir, logdir, temp_prefix, package

"""
    temp_prefix(func::Function)

Create a temporary prefix, passing the prefix into the user-defined function so
that build/packaging operations can occur within the temporary prefix, which is
then cleaned up after all operations are finished.  If the path provided exists
already, it will be deleted.

Usage example:

    out_path = abspath("./libfoo")
    temp_prefix() do p
        # <insert build steps here>

        # tarball up the built package
        tarball_path, tarball_hash = package(p, out_path)
    end
"""
function temp_prefix(func::Function)
    # Helper function to create a docker-mountable temporary directory
    function _tempdir()
        @static if Sys.isapple()
            # Docker, on OSX at least, can only mount from certain locations by
            # default, so we ensure all our temporary directories live within
            # those locations so that they are accessible by Docker.
            return realpath("/tmp")
        else
            return realpath(tempdir())
        end
    end

    mktempdir(_tempdir()) do path
        prefix = Prefix(path)

        # Run the user function
        func(prefix)
    end
end

struct Prefix
    path::String

    """
        Prefix(path::AbstractString)

    A `Prefix` represents a binary installation location.
    """
    function Prefix(path::AbstractString)
        # Canonicalize immediately, create the overall prefix, then return
        path = abspath(path)
        mkpath(path)
        return new(path)
    end
end

# Make it easy to bandy about prefixes as paths.  There has got to be a better
# way to do this, but it's hackin' time, so just go with the flow.
joinpath(prefix::Prefix, args...) = joinpath(prefix.path, args...)
joinpath(s::AbstractString, prefix::Prefix, args...) = joinpath(s, prefix.path, args...)

convert(::Type{AbstractString}, prefix::Prefix) = prefix.path
show(io::IO, prefix::Prefix) = show(io, "Prefix($(prefix.path))")

"""
    bindir(prefix::Prefix)

Returns the binary directory for the given `prefix`.
"""
function bindir(prefix::Prefix)
    return joinpath(prefix, "bin")
end

"""
    libdirs(prefix::Prefix, platform = HostPlatform())

Returns the library directories for the given `prefix` (note that this differs
between unix systems and windows systems, and between 32- and 64-bit systems).
"""
function libdirs(prefix::Prefix, platform = HostPlatform())
    if Sys.iswindows(platform)
        return [joinpath(prefix, "bin")]
    else
        if wordsize(platform) == 64
            return [joinpath(prefix, "lib64"), joinpath(prefix, "lib")]
        else
            return [joinpath(prefix, "lib")]
        end
    end
end

"""
    includedir(prefix::Prefix)

Returns the include directory for the given `prefix`
"""
function includedir(prefix::Prefix)
    return joinpath(prefix, "include")
end

"""
    logdir(prefix::Prefix; subdir::AbstractString="")

Returns the logs directory for the given `prefix`.  If `subdir` is a non-empty string, that
directory it is appended to the logdir of the given `prefix`.
"""
function logdir(prefix::Prefix; subdir::AbstractString="")
    return strip_path_separator(joinpath(prefix, "logs", subdir))
end

"""
    package(prefix::Prefix, output_base::AbstractString,
            version::VersionNumber;
            platform::AbstractPlatform = HostPlatform(),
            verbose::Bool = false, force::Bool = false,
            filter = Returns(true))

Build a tarball of the `prefix`, storing the tarball at `output_base`, appending the version
number `version`, a platform-dependent suffix and a file extension.  If `platform` is not
given, defaults to current platform. Returns the full path to, the SHA256 hash and the git
tree SHA1 of the generated tarball.

The are additional keyword arguments:

* `verbose` controls whether to print information to screen,
* `force` makes the function overwrite an existing tarball with the same name
* `filter` is a 2-argument function which returns `true` if the given file or directory
  should be packaged, and `false` otherwise.  The arguments are `(prefix, path)`, where
  `prefix` is the directory where the prefix is stored, and `path` is the path, within the
  prefix, of the file or directory.  This keyword allows you to filter out from the tarball
  certain files or directories.
"""
function package(prefix::Prefix,
                 output_base::AbstractString,
                 version::VersionNumber;
                 platform::AbstractPlatform = HostPlatform(),
                 verbose::Bool = false,
                 force::Bool = false,
                 filter = Returns(true),
                 )
    # Calculate output path
    out_path = "$(output_base).v$(version).$(triplet(platform)).tar.gz"

    if isfile(out_path)
        if force
            if verbose
                @info("$(out_path) already exists, force-overwriting...")
            end
            rm(out_path; force=true)
        else
            msg = replace(strip("""
            $(out_path) already exists, refusing to package into it without
            `force` being set to `true`.
            """), "\n" => " ")
            error(msg)
        end
    end

    # Copy our build prefix into an Artifact
    tree_hash = create_artifact() do art_path
        for f in readdir(prefix.path)
            if !filter(prefix.path, f)
                continue
            end
            cp(joinpath(prefix.path, f), joinpath(art_path, f))
        end

        # Attempt to maintain permissions of original owning dir
        try
            chmod(art_path, stat(prefix.path).mode)
        catch e
            if verbose
                @warn("Could not chmod $(art_path):", e)
            end
        end
    end

    # Calculate git tree hash
    if verbose
        @info("Tree hash of contents of $(basename(out_path)): $(tree_hash)")
    end

    tarball_hash = archive_artifact(tree_hash, out_path; honor_overrides=false)
    if verbose
        @info("SHA256 of $(basename(out_path)): $(tarball_hash)")
    end

    return out_path, tarball_hash, tree_hash
end




function symlink_tree(src::AbstractString, dest::AbstractString)
    for (root, dirs, files) in walkdir(src)
        # Create all directories
        for d in dirs
            # If `d` is itself a symlink, recreate that symlink
            d_path = joinpath(root, d)
            dest_dir = joinpath(dest, relpath(root, src), d)
            if islink(d_path)
                if ispath(dest_dir)
                    # We can't overwrite an existing file on disk with a symlink
                    error("Symlink $(d) from artifact $(basename(src)) already exists on disk")
                end
                symlink(readlink(d_path), dest_dir)
            else
                if ispath(dest_dir) && !isdir(realpath(dest_dir))
                    # We can't create a directory if the destination exists and
                    # is not a directory or a symlink to a directory.
                    error("Directory $(d) from artifact $(basename(src)) already exists on disk and is not a directory")
                end
                mkpath(dest_dir)
            end
        end

        # Symlink all files
        for f in files
            src_file = joinpath(root, f)
            dest_file = joinpath(dest, relpath(root, src), f)
            if isfile(dest_file)
                # Ugh, destination file already exists.  If source and destination files
                # have the same size and SHA256 hash, just move on, otherwise issue a
                # warning.
                if filesize(src_file) == filesize(dest_file)
                    src_file_hash = open(io -> bytes2hex(sha256(io)), src_file, "r")
                    dest_file_hash = open(io -> bytes2hex(sha256(io)), dest_file, "r")
                    if src_file_hash == dest_file_hash
                        continue
                    end
                end
                # Find source artifact that this pre-existent destination file belongs to
                dest_artifact_source = realpath(dest_file)
                while occursin("artifacts", dest_artifact_source) && basename(dirname(dest_artifact_source)) != "artifacts"
                    dest_artifact_source = dirname(dest_artifact_source)
                end
                @warn("Symlink $(f) from artifact $(basename(src)) already exists in artifact $(basename(dest_artifact_source))")
            else
                # If it's already a symlink, copy over the exact symlink target
                if islink(src_file)
                    symlink(readlink(src_file), dest_file)
                else
                    # Otherwise, point it at the proper location
                    symlink(relpath(src_file, dirname(dest_file)), dest_file)
                end
            end
        end
    end
end

function unsymlink_tree(src::AbstractString, dest::AbstractString)
    for (root, dirs, files) in walkdir(src)
        # Unsymlink all symlinked directories, non-symlink directories will be culled in audit.
        for d in dirs
            dest_dir = joinpath(dest, relpath(root, src), d)
            if islink(dest_dir)
                rm(dest_dir)
            end
        end

        # Unsymlink all symlinked files
        for f in files
            dest_file = joinpath(dest, relpath(root, src), f)
            if islink(dest_file)
                rm(dest_file)
            end
        end
    end
end

function setup(source::SetupSource{GitSource}, targetdir, verbose)
    mkpath(targetdir)
    # Chop off the `.git-$(sha256(url))` at the end of the source.path (`.git` is optional).
    name = replace(basename(source.path), r"(\.git)?-[0-9a-fA-F]{64}$" => "")
    repo_dir = joinpath(targetdir, name)
    if verbose
        # Need to strip the trailing separator
        path = strip_path_separator(targetdir)
        @info "Checking $(basename(source.path)) out to $(basename(repo_dir))..."
    end
    LibGit2.with(LibGit2.clone(source.path, repo_dir)) do repo
        LibGit2.checkout!(repo, source.hash)
    end
end

function setup(source::SetupSource{ArchiveSource}, targetdir, verbose; tar_flags = verbose ? "xvof" : "xof")
    mkpath(targetdir)
    cd(targetdir) do
        if any(endswith(source.path, ext) for ext in tar_extensions)
            if verbose
                @info "Extracting tarball $(basename(source.path))..."
            end
            tar = Tar_jll.is_available() ? Tar_jll.tar() : `tar`
            # Add gzip, bzip2 & Co. to PATH.
            path = split(get(ENV, "PATH", ""), pathsep)
            libpath = split(get(ENV, LIBPATH_env, ""), pathsep)
            if Tar_jll.is_available()
                libpath = vcat(Tar_jll.LIBPATH_list, libpath)
            end
            if Bzip2_jll.is_available()
                path = vcat(joinpath(Bzip2_jll.artifact_dir, "bin"), path)
                libpath = vcat(Bzip2_jll.LIBPATH_list, libpath)
            end
            if Gzip_jll.is_available()
                path = vcat(dirname(Gzip_jll.gzip_path), path)
                libpath = vcat(Gzip_jll.LIBPATH_list, libpath)
            end
            if XZ_jll.is_available()
                path = vcat(dirname(XZ_jll.xz_path), path)
                libpath = vcat(XZ_jll.LIBPATH_list, libpath)
            end
            if Zstd_jll.is_available()
                path = vcat(dirname(Zstd_jll.zstd_path), path)
                libpath = vcat(XZ_jll.LIBPATH_list, libpath)
            end
            unique!(filter!(!isempty, path))
            unique!(filter!(!isempty, libpath))
            tar = addenv(tar, "PATH" => join(path, pathsep), LIBPATH_env => join(libpath, pathsep))
            # Unpack the tarball
            run(`$(tar) -$(tar_flags) $(source.path)`)
        elseif endswith(source.path, ".zip")
            if verbose
                @info "Extracting zipball $(basename(source.path))..."
            end
            if unzip_jll.is_available()
                run(`$(unzip_jll.unzip()) -q $(source.path)`)
            end
        elseif endswith(source.path, ".conda")
            if verbose
                @info "Extracting conda package $(basename(source.path))..."
            end
            # The .conda file contains an archive called pkg-*.tar.zst
            # Replace initial hash with pkg, and change the file extension to obtain the name
            pkg_name = replace(basename(source.path), r"^[a-z0-9]{64}-" => "pkg-", ".conda" => ".tar.zst")
            # First unzip the pkg tarball from .conda file
            if unzip_jll.is_available()
                run(`$(unzip_jll.unzip()) -q $(source.path) $(pkg_name)`)
            end
            # Second untar the pkg tarball
            pkg_source = SetupSource{ArchiveSource}(source.url, joinpath(targetdir, pkg_name), source.hash, source.target)
            # Run setup again to untar the pkg binaries
            setup(pkg_source, targetdir, verbose; tar_flags = tar_flags)
        else
            error("Unknown archive format")
        end
    end
end

function setup(source::SetupSource{FileSource}, target, verbose)
    if isdir(target)
        target = joinpath(target, basename(source.path))
    end
    if verbose
        @info "Copying $(basename(source.path)) in $(basename(target))..."
    end
    cp(source.path, target)
end

function setup(source::SetupSource{DirectorySource}, targetdir, verbose)
    mkpath(targetdir)
    # Need to strip the trailing separator also here
    srcpath = strip_path_separator(source.path)
    if verbose
        @info "Copying content of $(basename(srcpath)) in $(basename(targetdir))..."
    end
    for file_dir in readdir(srcpath)
        # Copy the content of the source directory to the destination
        cp(joinpath(srcpath, file_dir), joinpath(targetdir, basename(file_dir));
           follow_symlinks=source.follow_symlinks)
    end
end

function setup(source::PatchSource, targetdir, verbose)
    if verbose
        @info "Adding patch $(source.name)..."
    end
    patches_dir = joinpath(targetdir, "patches")
    mkdir(patches_dir)
    open(f->write(f, source.patch), joinpath(patches_dir, source.name), "w")
end

destdir(prefix, platform::AbstractPlatform) =
    joinpath(prefix, triplet(platform), "destdir")

"""
    setup_workspace(build_path::String, sources::Vector{SetupSource};
                    verbose::Bool = false)

Sets up a workspace within `build_path`, creating the directory structure
needed by further steps, unpacking the source within `build_path`, and defining
the environment variables that will be defined within the sandbox environment.

This method returns the `Prefix` to install things into, and the runner
that can be used to launch commands within this workspace.
"""
function setup_workspace(build_path::AbstractString, sources::Vector,
                         target_platform::AbstractPlatform,
                         host_platform::AbstractPlatform=default_host_platform;
                         verbose::Bool = false)
    # Use a random nonce to make detection of paths in embedded binary easier
    nonce = randstring()
    workspace = joinpath(build_path, nonce)
    mkdir(workspace)

    # We now set up two directories, one as a source dir, one as a dest dir
    srcdir = joinpath(workspace, "srcdir")
    target_destdir = destdir(workspace, target_platform)
    host_destdir = destdir(workspace, host_platform)
    metadir = joinpath(workspace, "metadir")
    mkpath.((srcdir, target_destdir, host_destdir, metadir))
    # Create the symlink /workspace/destdir -> /workspace/TARGET_TRIPLET/destdir
    # Necessary for compatibility with recipes that hardcode `/workspace/destdir` in them,
    # as well as `.pc` files that contain absolute paths to `/workspace/destdir/...`
    symlink("$(triplet(target_platform))/destdir", joinpath(workspace, "destdir"))

    # Setup all sources
    for source in sources
        if isa(source, SetupSource)
            target = joinpath(srcdir, source.target)
            # Trailing directory separator matters for `basename`, so let's strip it
            # to avoid confusion
            target = strip_path_separator(target)
            setup(source, target, verbose)
        else
            setup(source, srcdir, verbose)
        end
    end

    # Return the build prefix
    return Prefix(realpath(workspace))
end

"""
    collect_jll_uuids(manifest::Pkg.Types.Manifest, dependencies::Set{Base.UUID})

Return a `Set` of all JLL packages in the `manifest` with `dependencies` being
the list of direct dependencies of the environment.
"""
function collect_jll_uuids(manifest::Pkg.Types.Manifest, dependencies::Set{Base.UUID})
    jlls = copy(dependencies)
    for (uuid, pkg_entry) in manifest
        if uuid in jlls
            for (dep_name, dep_uuid) in pkg_entry.deps
                if endswith(dep_name, "_jll")
                    push!(jlls, dep_uuid)
                end
            end
        end
    end
    if jlls == dependencies
        return jlls
    else
        return collect_jll_uuids(manifest, jlls)
    end
end

"""
    get_tree_hash(tree::LibGit2.GitTree)

Given a `GitTree`, get the `GitHash` that identifies it.
"""
function get_tree_hash(tree::LibGit2.GitTree)
    oid_ptr = Ref(LibGit2.GitHash())
    oid_ptr = ccall((:git_tree_id, libgit2), Ptr{LibGit2.GitHash}, (Ptr{Cvoid},), tree.ptr)
    oid_ptr == C_NULL && throw("bad tree ID: $tree")
    return unsafe_load(oid_ptr)
end

"""
    get_commit_sha(url::String, tree_hash::Base.SHA1; verbose::Bool=false)

Find the latest git commit corresponding to the given git tree SHA1 for the remote
repository with the given `url`.  The repository is cached locally for quicker future
access.  If `verbose` is `true`, print to screen some debugging information.

The return value is the commit SHA as a `String`, if the corresponding revision is found,
`nothing` otherwise.
"""
function get_commit_sha(url::String, tree_hash::Base.SHA1; verbose::Bool=false)
    git_commit_sha = nothing
    dir = cached_git_clone(url; verbose)

    LibGit2.with(LibGit2.GitRepo(dir)) do repo
        LibGit2.with(LibGit2.GitRevWalker(repo)) do walker
            # The repo is cached, so locally it may be checking out an outdated commit.
            # Start the search from HEAD of the tracking upstream repo.
            try
                LibGit2.push!(walker, LibGit2.GitHash(LibGit2.peel(LibGit2.GitCommit, LibGit2.upstream(LibGit2.head(repo)))))
            catch
                @warn("Could not walk from origin branch!")
                LibGit2.push_head!(walker)
            end
            # For each commit in the git repo, check to see if its treehash
            # matches the one we're looking for.
            for oid in walker
                tree = LibGit2.peel(LibGit2.GitTree, LibGit2.GitCommit(repo, oid))
                if all(get_tree_hash(tree).val .== tree_hash.bytes)
                    git_commit_sha = LibGit2.string(oid)
                    break
                end
            end
        end
    end
    return git_commit_sha
end

"""
    get_addable_spec(name::AbstractString, version::VersionNumber)

Given a JLL name and registered version, return a `PackageSpec` that, when passed as a
`Dependency`, ensures that exactly that version will be installed.  Example usage:

    dependencies = [
        BuildDependency(get_addable_spec("LLVM_jll", v"9.0.1+0")),
    ]
"""
function get_addable_spec(name::AbstractString, version::VersionNumber;
                          ctx = Pkg.Types.Context(), verbose::Bool = false)
    # Zeroth, update the registry
    update_registry(verbose ? stdout : devnull)
    # First, resolve the UUID
    uuid = first(Pkg.Types.registry_resolve!(ctx.registries, Pkg.Types.PackageSpec(;name))).uuid

    # Next, determine the tree hash from the registry
    repo_urls = Set{String}()
    tree_hashes = Set{Base.SHA1}()
    for reg in ctx.registries
        if !haskey(reg, uuid)
            continue
        end

        pkg_info = registry_info(reg[uuid])
        if pkg_info.repo !== nothing
            push!(repo_urls, pkg_info.repo)
        end
        if pkg_info.version_info !== nothing
            if haskey(pkg_info.version_info, version)
                version_info = pkg_info.version_info[version]
                push!(tree_hashes, version_info.git_tree_sha1)
            end
        end
    end

    if isempty(tree_hashes)
        @error("Unable to find dependency!",
            name,
            version,
            registries=ctx.registries,
        )
        error("Unable to find dependency!")
    end
    if length(tree_hashes) != 1
        @error("Multiple treehashes found!",
            name,
            version,
            tree_hashes,
            registries=ctx.registries,
        )
        error("Multiple treehashes found!")
    end

    tree_hash_sha1 = first(tree_hashes)

    # Once we have a tree hash, turn that into a git commit sha
    git_commit_sha = nothing
    valid_url = nothing
    for url in repo_urls
        git_commit_sha = get_commit_sha(url, tree_hash_sha1; verbose)
        # Stop searching urls as soon as we find one
        if git_commit_sha !== nothing
            valid_url = url
            break
        end
    end

    if git_commit_sha === nothing
        @error("Unable to find revision for specified dependency!",
            name,
            version,
            tree_hash = bytes2hex(tree_hash_sha1.bytes),
            repo_urls,
        )
        error("Unable to find revision for specified dependency!")
    end

    return Pkg.Types.PackageSpec(
        name=name,
        uuid=uuid,
        #version=version,
        tree_hash=tree_hash_sha1,
        repo=Pkg.Types.GitRepo(rev=git_commit_sha, source=valid_url),
    )
end

# Helper function to install packages also in Julia v1.8
function Pkg_add(args...; kwargs...)
    @static if VERSION < v"1.8.0"
        Pkg.add(args...; kwargs...)
    else
        try
            Pkg.respect_sysimage_versions(false)
            Pkg.add(args...; kwargs...)
        finally
            Pkg.respect_sysimage_versions(true)
        end
    end
end

"""
    setup_dependencies(prefix::Prefix, dependencies::Vector{PackageSpec}, platform::AbstractPlatform; verbose::Bool = false)

Given a list of JLL package specifiers, install their artifacts into the build prefix.
The artifacts are installed into the global artifact store, then copied into a temporary location,
then finally symlinked into the build prefix.  This allows us to (a) save download bandwidth by not
downloading the same artifacts over and over again, (b) maintain separation in the event of
catastrophic containment failure, avoiding hosing the main system if a build script decides to try
to modify the dependent artifact files, and (c) keeping a record of what files are a part of
dependencies as opposed to the package being built, in the form of symlinks to a specific artifacts
directory.
"""
# During installation of the artifacts we may want to enforce the platform has specific
# properties, for example a non-empty "sanitize" tag.
function normalize_platform(p::Platform)
    new_p = deepcopy(p)
    new_p["sanitize"] = get(new_p.tags, "sanitize", "none")
    return new_p
end
# Fallback for other types, like `AnyPlatform`.
normalize_platform(p::AbstractPlatform) = p

function setup_dependencies(prefix::Prefix,
                            dependencies::Vector{PkgSpec},
                            platform::AbstractPlatform;
                            verbose::Bool = false)
    artifact_paths = String[]
    if isempty(dependencies)
        return artifact_paths
    end

    # We occasionally generate "illegal" package specs, where we provide both version and tree hash.
    # we trust the treehash over the version, so drop the version for any that exists here:
    function filter_redundant_version(p::PkgSpec)
        if p.version !== nothing && p.tree_hash !== nothing
            return Pkg.Types.PackageSpec(;name=p.name, tree_hash=p.tree_hash, repo=p.repo)
        end
        return p
    end
    dependencies = filter_redundant_version.(dependencies)
    dependencies_names = getname.(dependencies)

    # Get julia version specificity, if it exists, from the `Platform` object
    julia_version = nothing
    if haskey(platform, "julia_version")
        julia_version = VersionNumber(platform["julia_version"])
    end

    # We're going to create a project and install all dependent packages within
    # it, then create symlinks from those installed products to our build prefix
    mkpath(joinpath(prefix, triplet(platform), "artifacts"))
    deps_project = joinpath(prefix, triplet(platform), ".project")
    Pkg.activate(deps_project) do
        # Update registry first, in case the jll packages we're looking for have just been registered/updated
        ctx = Pkg.Types.Context(;julia_version)
        outs = verbose ? stdout : devnull
        update_registry(outs)

        # Add all dependencies.  Note: Pkg.add(ctx, deps) modifies in-place `deps` without
        # notice.  We need to `deepcopy` the argument to prevent it from modying our
        # dependencies from under our feet: <https://github.com/JuliaLang/Pkg.jl/issues/3112>.
        Pkg_add(ctx, deepcopy(dependencies); platform=platform, io=outs)

        # Ony Julia v1.6, `Pkg.add()` doesn't mutate `dependencies`, so we can't use the `UUID`
        # that was found during resolution there.  Instead, we'll make use of `ctx.env` to figure
        # out the UUIDs of all our packages.
        dependency_uuids = Set([uuid for (uuid, pkg) in ctx.env.manifest if pkg.name ∈ dependencies_names])

        # Some JLLs are also standard libraries that may be present in the manifest because
        # they were pulled by other stdlibs (e.g. through dependence on `Pkg`), not beacuse
        # they were actually required for this package. Filter them out if they're present
        # in the manifest but aren't direct dependencies or dependencies of other JLLS.
        installed_jll_uuids = collect_jll_uuids(ctx.env.manifest, dependency_uuids)
        installed_jlls = [
            Pkg.Types.PackageSpec(;
                name=pkg.name,
                uuid,
                tree_hash=pkg.tree_hash,
                path=pkg.path,
            ) for (uuid, pkg) in ctx.env.manifest if uuid ∈ installed_jll_uuids
        ]

        # Check for stdlibs lurking in the installed JLLs
        stdlib_pkgspecs = PackageSpec[]
        for dep in installed_jlls
            # If the dependency doesn't have a path yet and the `tree_hash` is
            # `nothing`, then this JLL is probably an stdlib.
            if dep.path === nothing && dep.tree_hash === nothing
                # Figure out what version this stdlib _should_ be at for this version
                dep.version = stdlib_version(dep.uuid, julia_version)

                # Interrogate the registry to determine the correct treehash
                Pkg.Operations.load_tree_hash!(ctx.registries, dep, nothing)

                # We'll still use `Pkg.add()` to install the version we want, even though
                # we've used the above two lines to figure out the treehash, so construct
                # an addable spec that will get the correct bits down on disk.
                push!(stdlib_pkgspecs, get_addable_spec(dep.name, dep.version; verbose))
            end
        end

        # Re-install stdlib dependencies, but this time with `julia_version = nothing`
        if !isempty(stdlib_pkgspecs)
            Pkg_add(ctx, stdlib_pkgspecs; io=outs, julia_version=nothing)
        end

        # Load their Artifacts.toml files
        for dep in installed_jlls
            name = getname(dep)
            # If the package has a path, use it, otherwise ask Pkg where it
            # should have been installed.
            dep_path = dep.path !== nothing ? dep.path : Pkg.Operations.find_installed(name, dep.uuid, dep.tree_hash)

            # Skip dependencies that didn't get installed?
            if dep_path === nothing
                @warn("Dependency $(name) not installed, despite our best efforts!")
                continue
            end

            # Load the Artifacts.toml file
            artifacts_toml = joinpath(dep_path, "Artifacts.toml")
            if !isfile(artifacts_toml)
                # Try `StdlibArtifacts.toml` instead
                artifacts_toml = joinpath(dep_path, "StdlibArtifacts.toml")
                if !isfile(artifacts_toml)
                    @warn("Dependency $(name) does not have an (Stdlib)Artifacts.toml in $(dep_path)!")
                    continue
                end
            end

            # If the artifact is available for the given platform, make sure it
            # is also installed.  It may not be the case for lazy artifacts or stdlibs.
            normalized_platform = normalize_platform(platform)
            meta = artifact_meta(name[1:end-4], artifacts_toml; platform=normalized_platform)
            if meta === nothing
                @warn("Dependency $(name) does not have a mapping for artifact $(name[1:end-4]) for platform $(triplet(platform))")
                continue
            end
            ensure_artifact_installed(name[1:end-4], meta, artifacts_toml; platform=normalized_platform)

            # Copy the artifact from the global installation location into this build-specific artifacts collection
            src_path = Pkg.Artifacts.artifact_path(Base.SHA1(meta["git-tree-sha1"]))
            dest_path = joinpath(prefix, triplet(platform), "artifacts", basename(src_path))
            rm(dest_path; force=true, recursive=true)
            cp(src_path, dest_path)

            # Keep track of our dep paths for later symlinking
            push!(artifact_paths, dest_path)
        end
    end

    # Symlink all the deps into the prefix
    for art_path in artifact_paths
        symlink_tree(art_path, destdir(prefix, platform))
    end

    # Return the artifact_paths so that we can clean them up later
    return artifact_paths
end

function cleanup_dependencies(prefix::Prefix, artifact_paths, platform)
    for art_path in artifact_paths
        # Unsymlink all destdirs within the prefix
        for dir in readdir(prefix.path; join=true)
            ddir = destdir(prefix, platform)
            if isdir(ddir)
                unsymlink_tree(art_path, ddir)
            end
        end
    end
end

"""
    compress_dir(dir::AbstractString;
                 compressor_stream = GzipCompressorStream,
                 level::Int = 9,
                 extension::AbstractString = ".gz",
                 verbose::Bool = false)

Compress all files in `dir` using the specified `compressor_stream` with
compression level equal to `level`, appending `extension` to the filenames.
Remove the original uncompressed files at the end.
"""
function compress_dir(dir::AbstractString;
                      compressor_stream = GzipCompressorStream,
                      level::Int = 9,
                      extension::AbstractString = ".gz",
                      verbose::Bool = false)
    if isdir(dir)
        if verbose
            @info "Compressing files in $(dir)"
        end
        for f in readdir(dir)
            filename = joinpath(dir, f)
            if isfile(filename)
                text = read(filename, String)
                stream = compressor_stream(open(filename * extension, "w"); level=level)
                write(stream, text)
                close(stream)
                rm(filename; force=true)
            end
        end
    end
end
