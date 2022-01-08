## This file contains functionality related to the actual layout of the files
#  on disk.  Things like the name of where downloads are stored, and what
#  environment variables must be updated to, etc...
import Base: convert, joinpath, show
using SHA, CodecZlib, TOML

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

# This is the default prefix that things get saved to, it is initialized within
# __init__() on first module load.
global_prefix = nothing
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
            verbose::Bool = false, force::Bool = false)

Build a tarball of the `prefix`, storing the tarball at `output_base`,
appending a version number, a platform-dependent suffix and a file extension.
If no platform is given, defaults to current platform. Returns the full path to,
the SHA256 hash and the git tree SHA1 of the generated tarball.
"""
function package(prefix::Prefix,
                 output_base::AbstractString,
                 version::VersionNumber;
                 platform::AbstractPlatform = HostPlatform(),
                 verbose::Bool = false,
                 force::Bool = false)
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
    # Chop off the `.git` at the end of the source.path
    name = basename(source.path)
    if endswith(name, ".git")
        name = name[1:end-4]
    end
    repo_dir = joinpath(targetdir, name)
    if verbose
        # Need to strip the trailing separator
        path = strip_path_separator(targetdir)
        @info "Cloning $(basename(source.path)) to $(basename(repo_dir))..."
    end
    LibGit2.with(LibGit2.clone(source.path, repo_dir)) do repo
        LibGit2.checkout!(repo, source.hash)
    end
end

function setup(source::SetupSource{ArchiveSource}, targetdir, verbose; tar_flags = verbose ? "xvof" : "xof")
    mkpath(targetdir)
    # Extract with host tools because it is _much_ faster on e.g. OSX.
    # If this becomes a compatibility problem, we'll just have to install
    # our own `tar` and `unzip` through BP as dependencies for BB.
    cd(targetdir) do
        if any(endswith(source.path, ext) for ext in tar_extensions)
            if verbose
                @info "Extracting tarball $(basename(source.path))..."
            end
            run(`tar -$(tar_flags) $(source.path)`)
        elseif endswith(source.path, ".zip")
            if verbose
                @info "Extracting zipball $(basename(source.path))..."
            end
            run(`unzip -q $(source.path)`)
        else
            error("Unknown archive format")
        end
    end
end

function setup(source::SetupSource{FileSource}, target, verbose)
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
function setup_dependencies(prefix::Prefix, dependencies::Vector{PkgSpec}, platform::AbstractPlatform; verbose::Bool = false)
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

        # Add all dependencies
        Pkg.add(ctx, dependencies; platform=platform, io=outs)

        # Some JLLs are also standard libraries that may be present in the manifest because
        # they were pulled by other stdlibs (e.g. through dependence on `Pkg`), not beacuse
        # they were actually required for this package. Filter them out if they're present
        # in the manifest but aren't direct dependencies or dependencies of other JLLS.
        installed_jll_uuids = collect_jll_uuids(ctx.env.manifest, Set(getfield.(dependencies, :uuid)))
        installed_jlls = [
            Pkg.Types.PackageSpec(;
                name=pkg.name,
                uuid,
                tree_hash=pkg.tree_hash,
            ) for (uuid, pkg) in ctx.env.manifest if uuid ∈ installed_jll_uuids
        ]

        # From here on out, we're using `julia_version=nothing` to install stdlib dependencies
        ctx = Pkg.Types.Context!(ctx; julia_version=nothing)
        stdlib_jlls = false
        for dep in installed_jlls
            # First, figure out if this JLL was treated as a stdlib:
            if dep.tree_hash === nothing
                # If it was, we need to figure out the package version for the requested
                # julia version, then figure out the treehash
                dep.version = stdlib_version(dep.uuid, julia_version)
                Pkg.Operations.load_tree_hash!(ctx.registries, dep, nothing)

                # Directly update the pre-existing `PackageEntry`, so that we can directly
                # call `Operations.download_*()` functions, which bypasses resolution
                ctx.env.manifest[dep.uuid].tree_hash = dep.tree_hash
                stdlib_jlls = true
            end
        end

        # Re-install stdlib dependencies, but this time with `julia_version = nothing`
        # Note that we directly use `Pkg.Operations.download_{source,artifacts}()`, so
        # that we can dodge the resolution machinery in Pkg, which will do things like
        # treat `v1.2.12+1` and `v1.2.12+2` the same, and always choose the latter.
        # This wouldn't be an issue, except that we really really want to tell the
        # difference between those two versions.
        if stdlib_jlls
            Pkg.Operations.download_source(ctx)
            Pkg.Operations.download_artifacts(ctx.env; julia_version=ctx.julia_version, verbose)
        end

        # Load their Artifacts.toml files
        for dep in installed_jlls
            name = getname(dep)
            dep_path = Pkg.Operations.find_installed(name, dep.uuid, dep.tree_hash)

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
            meta = artifact_meta(name[1:end-4], artifacts_toml; platform=platform)
            if meta === nothing
                @warn("Dependency $(name) does not have a mapping for artifact $(name[1:end-4]) for platform $(triplet(platform))")
                continue
            end
            ensure_artifact_installed(name[1:end-4], meta, artifacts_toml; platform=platform)

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
