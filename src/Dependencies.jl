using UUIDs

export Dependency, RuntimeDependency, BuildDependency, HostBuildDependency,
    is_host_dependency, is_target_dependency, is_build_dependency, is_runtime_dependency, is_top_level_dependency,
    filter_platforms


# Pkg.PackageSpec return different types in different Julia versions so...
const PkgSpec = typeof(Pkg.PackageSpec(name="dummy"))
const PKG_VERSIONS = Base.VERSION >= v"1.7-" ? Pkg.Versions : Pkg.Types


"""
An `AbstractDependency` is a binary dependency of the JLL package.  Dependencies
are installed to `\${prefix}` in the build environment.

Concrete subtypes of `AbstractDependency` are

* [`Dependency`](@ref): a JLL package that is necessary for to build the package
  and to load the generated JLL package.
* [`RuntimeDependency`](@ref): a JLL package that is necessary only at runtime.  Its
  artifact will not be installed in the prefix during the build.
* [`BuildDependency`](@ref): a JLL package that is necessary only to build the
  package.  This will not be a dependency of the generated JLL package.
* [`HostBuildDependency`](@ref): similar to `BuildDependency`, but it will
  install the artifact for the host platform, instead of that for the target
  platform.

Subtypes of `AbstractDependency` should define the following traits:

* [`is_host_dependency`](@ref)
* [`is_target_dependency`](@ref)
* [`is_build_dependency`](@ref)
* [`is_runtime_dependency`](@ref)
* [`is_top_level_dependency`][@ref]
"""
abstract type AbstractDependency end

"""
    is_host_dependency(dep::AbstractDependency) -> Bool

Return whether `dep` is a dependency of the host platform or not.
"""
is_host_dependency

"""
    is_target_dependency(dep::AbstractDependency) -> Bool

Return whether `dep` is a dependency of the target platform or not.
"""
is_target_dependency(dep::AbstractDependency) = !is_host_dependency(dep)

"""
    is_build_dependency(dep::AbstractDependency) -> Bool

Return whether `dep` is a build-time dependency or not.
"""
is_build_dependency

"""
    is_runtime_dependency(dep::AbstractDependency) -> Bool

Return whether `dep` is a runtime dependency or not.
"""
is_runtime_dependency

"""
    is_top_level_dependency(dep::AbstractDependency) -> Bool

Return wheter `dep` is a top-level dependency or not.
"""
is_top_level_dependency(dep::AbstractDependency) = false

"""
    Dependency(dep::Union{PackageSpec,String}, build_version::VersionNumber;
               compat::String, platforms::Vector{<:AbstractPlatform})

Define a binary dependency that is necessary to build the package and load the
generated JLL package.  The argument can be either a string with the name of the
JLL package or a `Pkg.PackageSpec`.

The optional positional argument `build_version` can be used to specify the
version of the dependency to be installed when building it.  If not specified,
the latest version of the package compatible with the environment will be
automatically chosen by the package resolver, unless `compat` is specified, see
below.

The keyword argument `compat` must be used to specify a string for use in the `Project.toml` of the generated Julia package.
If `build_version` is not passed, the minimum version compatible with the `compat` specifier is used as build version.

The optional keyword argument `platforms` is a vector of `AbstractPlatform`s
which indicates for which platforms the dependency should be used.  By default
`platforms=[AnyPlatform()]`, to mean that the dependency is compatible with all
platforms.

The optional keyword argument `top_level` denotates that this dependency is
platform independent. It implies that the `platforms` keyword argument is set
to `[AnyPlatform()]`. The primary use-case is for packages that hold information
about the platform selection using `Preferences`. Platform selection is cached
and in the case that no platform is available we need to be able to invalidate
said cache. Invalidation occurs through the package that owns the `Preferences`
data.
"""
struct Dependency <: AbstractDependency
    pkg::PkgSpec
    build_version::Union{VersionNumber,Nothing}
    compat::String  # semver string for use in Project.toml of the JLL
    platforms::Vector{<:AbstractPlatform}
    top_level::Bool
    function Dependency(pkg::PkgSpec, build_version = nothing; compat::String = "",
                        platforms::Vector{<:AbstractPlatform}=[AnyPlatform()],
                        top_level=false)
        if !isempty(compat)
            spec = PKG_VERSIONS.semver_spec(compat) # verify compat is valid
            if build_version === nothing
                # Since we usually want to build against the oldest compatible
                # version, if `build_version` isn't set but `compat` is, make it
                # default to the minimum compatible version.
                build_version = minimum(VersionNumber(rng.lower.t) for rng in spec.ranges)
            end
            if build_version ∉ spec
                throw(ArgumentError("build_version and compat for $(pkg) are incompatible"))
            end
            if pkg.version != PKG_VERSIONS.VersionSpec("*")
                compatible_p = pkg.version isa PKG_VERSIONS.VersionSpec ? !isempty(intersect(pkg.version, spec)) : (pkg.version in spec)
                compatible_p || throw(ArgumentError("""PackageSpec version and compat ("$(compat)") for $(pkg) are incompatible"""))
            end
        else
            throw(ArgumentError("""Dependency("$(getname(pkg))") must have a non-empty compat bound."""))
        end
        if top_level
            @warn("Dependency(\"$(getname(pkg))\") was defined as top-level but this is deprecated, use `RuntimeDependency` instead")
            if !(isempty(platforms) || all(p->p==AnyPlatform(), platforms))
                throw(ArgumentError("A top-level dependency can't be restricted to platforms."))
            end
        end
        new(pkg, build_version, compat, platforms, top_level)
    end
end
function Dependency(dep::AbstractString, build_version = nothing;
                    compat::String = "",
                    platforms::Vector{<:AbstractPlatform} = [AnyPlatform()],
                    top_level = false)
    return Dependency(PackageSpec(; name = dep), build_version; compat, platforms, top_level)
end
is_host_dependency(::Dependency) = false
is_build_dependency(::Dependency) = true
is_runtime_dependency(::Dependency) = true
is_top_level_dependency(dep::Dependency) = dep.top_level

"""
    RuntimeDependency(dep::Union{PackageSpec,String}; compat::String, platforms::Vector{<:AbstractPlatform}, top_level::Bool=false)

Define a binary dependency that is only listed as dependency of the generated JLL package,
but its artifact is not installed in the prefix during the build.  The `dep` argument can be
either a string with the name of the JLL package or a `Pkg.PackageSpec`.

The keyword argument `compat` must be used to specify a string for use in the `Project.toml` of the generated Julia package.

The optional keyword argument `platforms` is a vector of `AbstractPlatform`s which indicates
for which platforms the dependency should be used.  By default `platforms=[AnyPlatform()]`,
to mean that the dependency is compatible with all platforms.

The optional keyword argument `top_level` specifies whether the dependency should be use
only at the top-level of the generated JLL package, instead of inside each platform-specific
wrapper.  Using `top_level=true` is useful for packages needed for platform augmentation
(e.g. `MPIPreferences.jl`).
"""
struct RuntimeDependency <: AbstractDependency
    pkg::PkgSpec
    compat::String  # semver string for use in Project.toml of the JLL
    platforms::Vector{<:AbstractPlatform}
    top_level::Bool
    function RuntimeDependency(pkg::PkgSpec; compat::String = "",
                               platforms::Vector{<:AbstractPlatform}=[AnyPlatform()],
                               top_level::Bool=false)
        if !isempty(compat)
            spec = PKG_VERSIONS.semver_spec(compat) # verify compat is valid
            if pkg.version != PKG_VERSIONS.VersionSpec("*")
                compatible_p = pkg.version isa PKG_VERSIONS.VersionSpec ? !isempty(intersect(pkg.version, spec)) : (pkg.version in spec)
                compatible_p || throw(ArgumentError("""PackageSpec version and compat ("$(compat)") for $(pkg) are incompatible"""))
            end
        else
            throw(ArgumentError("""RuntimeDependency("$(getname(pkg))") must have a non-empty compat bound."""))
        end
        if top_level
            if !(isempty(platforms) || all(==(AnyPlatform()), platforms))
                throw(ArgumentError("A top-level dependency can't be restricted to platforms."))
            end
        end
        return new(pkg, compat, platforms, top_level)
    end
end
RuntimeDependency(name::AbstractString; compat::String = "", platforms::Vector{<:AbstractPlatform}=[AnyPlatform()], top_level::Bool=false) =
    RuntimeDependency(PackageSpec(; name); compat, platforms, top_level)
is_host_dependency(::RuntimeDependency) = false
is_build_dependency(::RuntimeDependency) = false
is_runtime_dependency(::RuntimeDependency) = true
is_top_level_dependency(dep::RuntimeDependency) = dep.top_level
# In some cases we may want to automatically convert a `RuntimeDependency` to a `Dependency`
Base.convert(::Type{Dependency}, dep::RuntimeDependency) =
    Dependency(dep.pkg; compat=dep.compat, platforms=dep.platforms, top_level=dep.top_level)

"""
    BuildDependency(dep::Union{PackageSpec,String}; platforms)

Define a binary dependency that is necessary only to build the package.  The
`dep` argument can be either a string with the name of the JLL package or a
`Pkg.PackageSpec`.

The optional keyword argument `platforms` is a vector of `AbstractPlatform`s
which indicates for which platforms the dependency should be used.  By default
`platforms=[AnyPlatform()]`, to mean that the dependency is compatible with all
platforms.
"""
struct BuildDependency <: AbstractDependency
    pkg::PkgSpec
    platforms::Vector{<:AbstractPlatform}
    BuildDependency(pkg::PkgSpec; platforms::Vector{<:AbstractPlatform}=[AnyPlatform()]) =
        new(pkg, platforms)
end
BuildDependency(dep::AbstractString; platforms::Vector{<:AbstractPlatform}=[AnyPlatform()]) =
    BuildDependency(PackageSpec(; name = dep); platforms)
is_host_dependency(::BuildDependency) = false
is_build_dependency(::BuildDependency) = true
is_runtime_dependency(::BuildDependency) = false

"""
    HostBuildDependency(dep::Union{PackageSpec,String}; platforms)

Define a binary dependency that is necessary only to build the package.
Different from the [`BuildDependency`](@ref), the artifact for the host
platform will be installed, instead of that for the target platform.

The `dep` argument can be either a string with the name of the JLL package or a
`Pkg.PackageSpec`.

The optional keyword argument `platforms` is a vector of `AbstractPlatform`s
which indicates for which platforms the dependency should be used.  By default
`platforms=[AnyPlatform()]`, to mean that the dependency is compatible with all
platforms.
"""
struct HostBuildDependency <: AbstractDependency
    pkg::PkgSpec
    platforms::Vector{<:AbstractPlatform}
    HostBuildDependency(pkg::PkgSpec; platforms::Vector{<:AbstractPlatform}=[AnyPlatform()]) =
        new(pkg, platforms)
end
HostBuildDependency(dep::AbstractString; platforms::Vector{<:AbstractPlatform}=[AnyPlatform()]) =
    HostBuildDependency(PackageSpec(; name = dep); platforms)
is_host_dependency(::HostBuildDependency) = true
is_build_dependency(::HostBuildDependency) = true
is_runtime_dependency(::HostBuildDependency) = false

getpkg(d::AbstractDependency) = d.pkg
function getpkg(d::Dependency)
    # A Dependency can have a separate build_version, so replace that here:
    pkg = d.pkg
    if d.build_version !== nothing
        pkg = deepcopy(pkg)
        pkg.version = PKG_VERSIONS.VersionSpec(d.build_version)
    end
    return pkg
end

getname(x::PkgSpec) = x.name
getname(x::AbstractDependency) = getname(getpkg(x))

"""
    filter_platforms(deps::AbstractVector{<:AbstractDependency}, p::AbstractPlatform)

Filter the dependencies `deps` which are compatible with platform `p`.
"""
filter_platforms(deps::AbstractVector{<:AbstractDependency}, p::AbstractPlatform) =
    [dep for dep in deps if any(x -> platforms_match(x, p), dep.platforms)]

# Wrapper around `Pkg.Types.registry_resolve!` which keeps the type of the
# dependencies.  TODO: improve this
function registry_resolve!(ctx, dependencies::Vector{<:AbstractDependency})
    resolved_dependencies = Pkg.Types.registry_resolve!(ctx.registries, getpkg.(dependencies))
    for idx in eachindex(dependencies)
        dependencies[idx] = typeof(dependencies[idx])(resolved_dependencies[idx];
                                                      compat=dependencies[idx].compat,
                                                      platforms=dependencies[idx].platforms)
    end
    return dependencies
end

# We only want to update the registry once per run
registry_updated = false
function update_registry(outs = stdout)
    global registry_updated
    if !registry_updated
        Pkg.Registry.update(
            [Pkg.RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106")];
            io=outs,
        )
        registry_updated = true
    end
end

function resolve_jlls(dependencies::Vector; ctx = Pkg.Types.Context(), outs=stdout)
    if isempty(dependencies)
        return true, Dependency[]
    end

    # Don't clobber caller
    dependencies = deepcopy(dependencies)

    # If all dependencies already have a UUID, return early
    if all(x->getpkg(x).uuid !== nothing, dependencies)
        return true, dependencies
    end

    # Resolve, returning the newly-resolved dependencies
    update_registry(outs)
    dependencies = registry_resolve!(ctx, dependencies)

    # But first, check to see if anything failed to resolve, and warn about it:
    all_resolved = true
    for dep in getpkg.(dependencies)
        if dep.uuid === nothing
            @warn("Unable to resolve $(getname(dep))")
            all_resolved = false
        end
    end
    return all_resolved, dependencies
end

# Add JSON serialization of dependencies
string_or_nothing(x) = isnothing(x) ? x : string(x)

major(v::VersionNumber) = v.major
minor(v::VersionNumber) = v.minor
patch(v::VersionNumber) = v.patch
major(v::Pkg.Types.VersionBound) = v.t[1]
minor(v::Pkg.Types.VersionBound) = v.t[2]
patch(v::Pkg.Types.VersionBound) = v.t[3]
__version(v::VersionNumber) = v
__version(v::PKG_VERSIONS.VersionSpec) = v.ranges[1].lower
version(d::AbstractDependency) = __version(getpkg(d).version)
version(d::Dependency) = __version(d.pkg.version)


getcompat(d::AbstractDependency) = ""
getcompat(d::Union{Dependency,RuntimeDependency}) = d.compat

for (type, type_descr) in ((Dependency, "dependency"), (RuntimeDependency, "runtimedependency"), (BuildDependency, "builddependency"), (HostBuildDependency, "hostdependency"))
    JSON.lower(d::type) = Dict("type" => type_descr,
                               "name" => d.pkg.name,
                               "uuid" => string_or_nothing(d.pkg.uuid),
                               "compat" => getcompat(d),
                               "version-major" => major(version(d)),
                               "version-minor" => minor(version(d)),
                               "version-patch" => patch(version(d)),
                               "platforms" => triplet.(d.platforms),
                               "top_level" => is_top_level_dependency(d),
                               )
end

# When deserialiasing the JSON file, the dependencies are in the form of
# dictionaries.  This function converts the dictionary back to the appropriate
# AbstractDependency.
function dependencify(d::Dict)
    if d["type"] in ("dependency", "runtimedependency", "builddependency", "hostdependency")
        uuid = isnothing(d["uuid"]) ? d["uuid"] : UUID(d["uuid"])
        compat = d["compat"]
        version = PKG_VERSIONS.VersionSpec(VersionNumber(d["version-major"], d["version-minor"], d["version-patch"]))
        version = version == PKG_VERSIONS.VersionSpec(v"0") ? PKG_VERSIONS.VersionSpec() : version
        spec = PackageSpec(; name = d["name"], uuid = uuid, version = version)
        platforms = parse_platform.(d["platforms"])
        top_level = d["top_level"]::Bool
        if d["type"] == "dependency"
            return Dependency(spec; compat, platforms, top_level)
        elseif d["type"] == "runtimedependency"
            return RuntimeDependency(spec; compat, platforms, top_level)
        elseif d["type"] == "builddependency"
            return BuildDependency(spec; platforms)
        elseif d["type"] == "hostdependency"
            return HostBuildDependency(spec; platforms)
        end
    end
    error("Cannot convert to dependency")
end
