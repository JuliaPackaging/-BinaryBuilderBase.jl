using Test
using Pkg, Base.BinaryPlatforms
using BinaryBuilderBase
using BinaryBuilderBase: getname, getpkg, dependencify, destdir, PKG_VERSIONS, get_addable_spec, cached_git_clone
using JSON
using LibGit2
using ObjectFile
using ConstructionBase

# Define equality between dependencies, in order to carry out the tests below.
# In some cases we want to test that only the PackageSpec match, instead of the full struct.
Base.:(==)(a::D, b::D) where {D<:AbstractDependency} = getproperties(a) == getproperties(b)
Base.isapprox(a::D, b::D)  where {D<:AbstractDependency} = getpkg(a) == getpkg(b)

function with_temp_project(f::Function)
    mktempdir() do dir
        Pkg.activate(dir) do
            f(dir)
        end
    end
end

function test_setup_dependencies(prefix, dependencies, platform)
    if VERSION >= v"1.11.0-"
        # A warning is issued in Julia v1.11:
        # <https://github.com/JuliaPackaging/BinaryBuilderBase.jl/issues/358>.
        setup_dependencies(prefix, dependencies, platform)
    else
        @test_logs setup_dependencies(prefix, dependencies, platform)
    end
end

@testset "Dependencies" begin
    name = "Foo_jll"
    dep = Dependency(PackageSpec(; name = name); compat="0", platforms=supported_platforms(; experimental=true, exclude=!Sys.isapple))
    @test Dependency(name; compat="0") ≈ dep
    @test !is_host_dependency(dep)
    @test is_target_dependency(dep)
    @test is_build_dependency(dep)
    @test is_runtime_dependency(dep)
    @test !is_top_level_dependency(dep)
    @test getname(dep) == name
    @test getname(PackageSpec(; name = name)) == name
    @test getpkg(dep) == PackageSpec(; name = name, version = PKG_VERSIONS.VersionSpec(v"0"))
    @test getcompat(dep) == "0"

    build_version = v"1.2.3"
    dep_buildver = Dependency(PackageSpec(; name = name), build_version; compat = "~1.2")
    @test Dependency(name, build_version; compat="~1.2") == dep_buildver
    @test getname(dep_buildver) == name
    @test getpkg(dep_buildver) == PackageSpec(; name = name, version = PKG_VERSIONS.VersionSpec(build_version))
    @test getcompat(dep_buildver) == "~1.2"

    # the same but with platforms argument
    dep_buildver = Dependency(PackageSpec(; name = name), build_version; compat = "~1.2", platforms=[Platform("x86_64", "linux"; cxxstring_abi="cxx11")])
    @test Dependency(name, build_version; compat="~1.2") ≈ dep_buildver
    @test getname(dep_buildver) == name
    @test getpkg(dep_buildver) == PackageSpec(; name = name, version = PKG_VERSIONS.VersionSpec(build_version))
    @test getcompat(dep_buildver) == "~1.2"

    # the same but only with compat specifier
    dep_compat = Dependency(PackageSpec(; name); compat = "2, ~$(build_version)")
    @test Dependency(name, build_version; compat="2, ~$(build_version)") ≈ dep_compat
    @test getname(dep_compat) == name
    @test getpkg(dep_compat) == PackageSpec(; name, version = PKG_VERSIONS.VersionSpec(build_version))
    @test getcompat(dep_compat) == "2, ~$(build_version)"

    # if build_version and compat don't match, an error should be thrown
    @test_throws ArgumentError Dependency(PackageSpec(; name = name), build_version; compat = "2.0")

    # Runtime dependencies without compat bounds should throw an error
    @test_throws ArgumentError Dependency(name)
    @test_throws ArgumentError RuntimeDependency(name)

    run_dep = RuntimeDependency(PackageSpec(; name); compat="3.14")
    @test RuntimeDependency(name; compat="3.14") ≈ run_dep
    @test !is_host_dependency(run_dep)
    @test is_target_dependency(run_dep)
    @test !is_build_dependency(run_dep)
    @test is_runtime_dependency(run_dep)
    @test !is_top_level_dependency(run_dep)
    @test getname(run_dep) == name
    @test getname(PackageSpec(; name)) == name
    @test getpkg(run_dep) == PackageSpec(; name)
    @test getcompat(run_dep) == "3.14"
    # We should be able to convert a `Vector{RuntimeDependency}` to `Vector{Dependency}`
    @test Dependency[RuntimeDependency(name; compat="~1.8", platforms=[Platform("aarch64", "macos"; cxxstring_abi="cxx03")])] ==
        [Dependency(name; compat="~1.8", platforms=[Platform("aarch64", "macos"; cxxstring_abi="cxx03")])]
    @test @test_logs((:warn, r"was defined as top-level"), Dependency[RuntimeDependency(name; compat="1", top_level=true)]) ==
        [@test_logs((:warn, r"was defined as top-level"), Dependency(name; compat="1", top_level=true))]
    # If the version in the PackageSpec and the compat don't match, an error should be thrown
    @test_throws ArgumentError RuntimeDependency(PackageSpec(; name, version=v"1.2.3"); compat = "2.0")

    build_name = "Foo_headers_jll"
    build_dep = BuildDependency(PackageSpec(; name = build_name))
    @test BuildDependency(build_name) == build_dep
    @test !is_host_dependency(build_dep)
    @test is_target_dependency(build_dep)
    @test is_build_dependency(build_dep)
    @test !is_runtime_dependency(build_dep)
    @test !is_top_level_dependency(build_dep)
    @test getname(build_dep) == build_name
    @test getname(PackageSpec(; name = build_name)) == build_name
    @test getpkg(build_dep) == PackageSpec(; name = build_name)

    host_name = "Patchelf_jll"
    host_dep = HostBuildDependency(PackageSpec(; name = host_name))
    @test HostBuildDependency(host_name) == host_dep
    @test is_host_dependency(host_dep)
    @test !is_target_dependency(host_dep)
    @test is_build_dependency(host_dep)
    @test !is_runtime_dependency(host_dep)
    @test !is_top_level_dependency(host_dep)
    @test getname(host_dep) == host_name
    @test getname(PackageSpec(; name = host_name)) == host_name
    @test getpkg(host_dep) == PackageSpec(; name = host_name)

    top_level_name = "MPIPreferences"
    @test_logs (:warn, r"deprecated") @test_throws ArgumentError Dependency(PackageSpec(; name=top_level_name); compat="0", platforms=supported_platforms(; exclude=!Sys.isapple), top_level=true)
    @test_throws ArgumentError RuntimeDependency(PackageSpec(; name=top_level_name); compat="1", platforms=supported_platforms(; exclude=!Sys.isapple), top_level=true)

    top_level_dep = @test_logs (:warn, r"deprecated") Dependency(PackageSpec(; name = top_level_name); compat="1", top_level=true)
    @test is_top_level_dependency(top_level_dep)
    top_level_dep = RuntimeDependency(PackageSpec(; name = top_level_name); compat="1", top_level=true)
    @test is_top_level_dependency(top_level_dep)

    @testset "Filter dependencies by platform" begin
        @test filter_platforms([dep, dep_buildver, dep_compat], Platform("x86_64", "linux"; cxxstring_abi="cxx03")) == [dep_compat]
        @test filter_platforms([dep, dep_buildver, dep_compat], Platform("x86_64", "macos")) == [dep, dep_compat]
    end

    @testset "JSON (de)serialization" begin
        jdep = JSON.lower(dep)
        @test jdep == Dict("type" => "dependency", "name" => name, "uuid" => nothing, "compat" => "0", "version-major" => 0x0, "version-minor" => 0x0, "version-patch" => 0x0, "platforms" => ["x86_64-apple-darwin", "aarch64-apple-darwin"], "top_level" => false)
        @test dependencify(jdep) == dep

        jrun_dep = JSON.lower(run_dep)
        @test jrun_dep == Dict("type" => "runtimedependency", "name" => name, "uuid" => nothing, "compat" => "3.14", "version-major" => 0x0, "version-minor" => 0x0, "version-patch" => 0x0, "platforms" => ["any"], "top_level" => false)
        @test dependencify(jrun_dep) == run_dep

        jdep_buildver = JSON.lower(dep_buildver)
        @test jdep_buildver == Dict("type" => "dependency", "name" => name, "uuid" => nothing, "compat" => "~1.2", "version-major" => 0x0, "version-minor" => 0x0, "version-patch" => 0x0, "platforms" => ["x86_64-linux-gnu-cxx11"], "top_level" => false)
        # the build_version is currently not serialized, so the following test fails
        @test dependencify(jdep_buildver) == dep_buildver broken=true

        jbuild_dep = JSON.lower(build_dep)
        @test jbuild_dep == Dict("type" => "builddependency", "name" => build_name, "uuid" => nothing, "compat" => "", "version-major" => 0x0, "version-minor" => 0x0, "version-patch" => 0x0, "platforms" => ["any"], "top_level" => false)
        @test dependencify(jbuild_dep) == build_dep

        jhost_dep = JSON.lower(host_dep)
        @test jhost_dep == Dict("type" => "hostdependency", "name" => host_name, "uuid" => nothing, "compat" => "", "version-major" => 0x0, "version-minor" => 0x0, "version-patch" => 0x0, "platforms" => ["any"], "top_level" => false)
        @test dependencify(jhost_dep) == host_dep

        full_dep = Dependency(PackageSpec(; name = "Baz_jll", uuid = "00000000-1111-2222-3333-444444444444", version = PKG_VERSIONS.VersionSpec("3.1.4")); compat="3")
        jfull_dep = JSON.lower(full_dep)
        @test jfull_dep == Dict("type" => "dependency", "name" => "Baz_jll", "uuid" => "00000000-1111-2222-3333-444444444444", "compat" => "3", "version-major" => 0x3, "version-minor" => 0x1, "version-patch" => 0x4, "platforms" => ["any"], "top_level" => false)
        @test dependencify(jfull_dep) == full_dep
        @test_throws ErrorException dependencify(Dict("type" => "git"))

        jtop_level_dep = JSON.lower(top_level_dep)
        @test jtop_level_dep == Dict("type" => "runtimedependency", "name" => "MPIPreferences", "uuid" => nothing, "compat" => "1", "version-major" => 0x0, "version-minor" => 0x0, "version-patch" => 0x0, "platforms" => ["any"], "top_level" => true)
        @test dependencify(jtop_level_dep) == top_level_dep
    end

    @testset "Setup" begin
        @test BinaryBuilderBase.get_addable_spec("LLVM_jll", v"13.0.0+2") ==
            PackageSpec(
                name="LLVM_jll",
                uuid="86de99a1-58d6-5da7-8064-bd56ce2e322c",
                tree_hash=Base.SHA1("83481d62501cf2ef22bed745dbcedc4e75fa6e95"),
                version=PKG_VERSIONS.VersionSpec("*"),
                repo=Pkg.Types.GitRepo(
                    source="https://github.com/JuliaBinaryWrappers/LLVM_jll.jl.git",
                    rev="2772761b330d51146ace3125b26acdad0df4f30f",
                ),
            )

        with_temp_project() do dir
            prefix = Prefix(dir)
            dependencies = [
                Dependency("Zlib_jll"; compat="1.2.12")
            ]
            platform = HostPlatform()
            ap = test_setup_dependencies(prefix, getpkg.(dependencies), platform)
            @test "libz." * platform_dlext(platform) in readdir(last(libdirs(Prefix(destdir(dir, platform)))))
            @test sort!(readdir(joinpath(destdir(dir, platform), "include"))) == ["zconf.h", "zlib.h"]

            # Since Julia v1.9 Zlib_jll doesn't have logs directory at all
            @static if VERSION < v"1.9-DEV"
                zlib_log_files = if os(platform) == "macos"
                    ["Zlib.log.gz", "fix_identity_mismatch_libz.1.2.12.dylib.log.gz", "ldid_libz.1.2.12.dylib.log.gz"]
                else
                    ["Zlib.log.gz"]
                end
                zlib_log_dir = @static if VERSION ≥ v"1.7.3"
                    joinpath(destdir(dir, platform), "logs", "Zlib")
                else
                    joinpath(destdir(dir, platform), "logs")
                end
                @test sort!(readdir(zlib_log_dir)) == zlib_log_files
            end

            # Make sure the directories are emptied by `cleanup_dependencies`
            @test_nowarn cleanup_dependencies(prefix, ap, platform)
            @test readdir(joinpath(destdir(dir, platform), "include")) == []
            # Since Julia v1.7.3 we use builds of Zlib which have logs in
            # subdirectories of `${prefix}/logs`, so those subdirectories are
            # left there empty, cannot be removed by `cleanup_dependencies`.
            @test readdir(joinpath(destdir(dir, platform), "logs")) == [] broken=VERSION≥v"1.7.3"
        end

        # Setup a dependency of a JLL package which is also a standard library
        with_temp_project() do dir
            prefix = Prefix(dir)
            dependencies = [
                Dependency("LibCURL_jll"; compat="7.73, 8")
            ]
            platform = HostPlatform()
            ap = test_setup_dependencies(prefix, getpkg.(dependencies), platform)
            @test "libcurl." * platform_dlext(platform) in readdir(last(libdirs(Prefix(destdir(dir, platform)))))
            @test "curl.h" in readdir(joinpath(destdir(dir, platform), "include", "curl"))
            @test "libssh2." * platform_dlext(platform) in readdir(last(libdirs(Prefix(destdir(dir, platform)))))

            # Make sure the directories are emptied by `cleanup_dependencies`
            @test_nowarn cleanup_dependencies(prefix, ap, platform)
            # This shuld be empty, but the `curl/` directory is left here, empty
            @test readdir(joinpath(destdir(dir, platform), "include")) == [] broken=true
            # Since Julia v1.7.3 we use builds of LibCURL and its dependencies which have logs
            # in subdirectories of `${prefix}/logs`, so we have the same problem as above:
            # those subdirectories are left there empty, cannot be removed by
            # `cleanup_dependencies`.
            @test readdir(joinpath(destdir(dir, platform), "logs")) == [] broken=VERSION≥v"1.7.3"
        end

        # Setup a dependency that doesn't have a mapping for the given platform
        with_temp_project() do dir
            prefix = Prefix(dir)
            dependencies = [
                Dependency("LibOSXUnwind_jll"; compat="0.0.7")
            ]
            platform = Platform("i686", "linux"; libc="musl")
            # `match_mode=:any` is a workaround for
            # <https://github.com/JuliaPackaging/BinaryBuilderBase.jl/issues/358>.
            @test_logs (:warn, r"Dependency LibOSXUnwind_jll does not have a mapping for artifact LibOSXUnwind for platform i686-linux-musl") match_mode=(VERSION >= v"1.11.0-" ? :any : :all) begin
                setup_dependencies(prefix, getpkg.(dependencies), platform)
            end
            @test "destdir" ∉ readdir(dirname(destdir(dir, platform)))
        end

        # Test setup of dependencies that depend on the Julia version
        with_temp_project() do dir
            prefix = Prefix(dir)
            dependencies = [Dependency("GMP_jll"; compat="6.1.2")]
            platform = Platform("x86_64", "linux"; julia_version=v"1.5")

            # Test that a particular version of GMP is installed
            @test !isempty(test_setup_dependencies(prefix, getpkg.(dependencies), platform))
            @test isfile(joinpath(destdir(dir, platform), "lib", "libgmp.so.10.3.2"))
        end

        # Next, test on Julia v1.6
        with_temp_project() do dir
            prefix = Prefix(dir)
            dependencies = [Dependency("GMP_jll"; compat="6.2.1")]
            platform = Platform("x86_64", "linux"; julia_version=v"1.6")

            # Test that a particular version of GMP is installed
            test_setup_dependencies(prefix, getpkg.(dependencies), platform)
            @test isfile(joinpath(destdir(dir, platform), "lib", "libgmp.so.10.4.0"))
        end

        # Next, build a set of dependencies that are not instantiatable as-is:
        with_temp_project() do dir
            prefix = Prefix(dir)
            dependencies = [
                 Dependency("GMP_jll"; compat="6.1.2"),
                 Dependency("MPFR_jll"; compat="4.1.0"),
            ]

            # Test that this is not instantiatable with either Julia v1.5 or v1.6
            platform = Platform("x86_64", "linux"; julia_version=v"1.5")
            @test_throws Pkg.Resolve.ResolverError setup_dependencies(prefix, getpkg.(dependencies), platform)
            platform = Platform("x86_64", "linux"; julia_version=v"1.6")
            @test_throws Pkg.Resolve.ResolverError setup_dependencies(prefix, getpkg.(dependencies), platform)

            # If we don't give a `julia_version`, then we are FULLY UNSHACKLED.
            platform = Platform("x86_64", "linux")
            test_setup_dependencies(prefix, getpkg.(dependencies), platform)
            @test isfile(joinpath(destdir(dir, platform), "lib", "libgmp.so.10.3.2"))
            @test isfile(joinpath(destdir(dir, platform), "lib", "libmpfr.so.6.1.0"))
        end

        # Dependency as a local directory
        for remote_url in (
            "https://github.com/JuliaBinaryWrappers/HelloWorldC_jll.jl",
            "ssh://git@github.com/JuliaBinaryWrappers/HelloWorldC_jll.jl"
        )
            for progressbar in (true, false)
                with_temp_project() do dir
                    mktempdir() do pkgdir
                        prefix = Prefix(dir)
                        # Clone if necessary the remote repository and check out its
                        # working directory in a temporary space.
                        cache_dir = cached_git_clone(remote_url; progressbar)
                        LibGit2.with(LibGit2.clone(cache_dir, pkgdir)) do repo
                            LibGit2.checkout!(repo, "c7f2e95d9c04e218931c14954ecd31ebde72cca5")
                        end
                        dependencies = [
                            PackageSpec(
                                name="HelloWorldC_jll",
                                path=pkgdir,
                            ),
                        ]
                        platform = Platform("x86_64", "linux"; libc="glibc")
                        test_setup_dependencies(prefix, dependencies, platform)
                        @test readdir(joinpath(destdir(dir, platform), "bin")) == ["hello_world"]
                    end
                end
            end
        end

        # Dependency as a remote repository
        with_temp_project() do dir
            prefix = Prefix(dir)
            dependencies = [
                PackageSpec(
                    name="HelloWorldC_jll",
                    url="https://github.com/JuliaBinaryWrappers/HelloWorldC_jll.jl",
                    rev="c7f2e95d9c04e218931c14954ecd31ebde72cca5",
                ),
            ]
            platform = Platform("x86_64", "linux"; libc="glibc")
            test_setup_dependencies(prefix, dependencies, platform)
            @test readdir(joinpath(destdir(dir, platform), "bin")) == ["hello_world"]
        end

        @testset "Sanitize" begin
            with_temp_project() do dir
                prefix = Prefix(dir)
                dependencies = [
                    get_addable_spec("Zlib_jll", v"1.2.12+4")
                ]
                platform = Platform("x86_64", "linux")
                test_setup_dependencies(prefix, dependencies, platform)
                readmeta(joinpath(destdir(dir, platform), "lib", "libz.so")) do ohs
                    foreach(ohs) do oh
                        symbols = symbol_name.(Symbols(oh))
                        # The platform didn't specify the sanitizer, the library shouldn't contain
                        # "asan", "msan", or "tsan" symbols
                        @test !any(contains("asan_"), symbols)
                        @test !any(contains("msan_"), symbols)
                        @test !any(contains("tsan_"), symbols)
                    end
                end
            end
            with_temp_project() do dir
                prefix = Prefix(dir)
                dependencies = [
                    get_addable_spec("Zlib_jll", v"1.2.12+4")
                ]
                platform = Platform("x86_64", "linux"; sanitize="memory")
                test_setup_dependencies(prefix, dependencies, platform)
                readmeta(joinpath(destdir(dir, platform), "lib", "libz.so")) do ohs
                    foreach(ohs) do oh
                        symbols = symbol_name.(Symbols(oh))
                        # Make sure the library contains only "msan" symbols
                        @test !any(contains("asan_"), symbols)
                        @test any(contains("msan_"), symbols)
                        @test !any(contains("tsan_"), symbols)
                    end
                end
            end
        end
    end
end

@testset "resolve_jlls" begin
    # Deps given by (name,uuid)::PackageSpec
    dependencies = [Dependency(PackageSpec(name="OpenSSL_jll", uuid="458c3c95-2e84-50aa-8efc-19380b2a3a95"); compat="3.0.3"),]
    truefalse, resolved_deps = resolve_jlls(dependencies)
    @test truefalse
    @test all(x->getpkg(x).uuid !== nothing, resolved_deps)
    # Deps given by combination of name::String, name::PackageSpec and (name,uuid)::PackageSpec
    dependencies = [
        Dependency("Zlib_jll"; compat="1.2.13"),
        Dependency(PackageSpec(name="Bzip2_jll"); compat="1.0.8"),
        Dependency(PackageSpec(name="OpenSSL_jll", uuid="458c3c95-2e84-50aa-8efc-19380b2a3a95"); compat="3.0.3"),
    ]
    truefalse, resolved_deps = resolve_jlls(dependencies)
    @test truefalse
    @test all(x->getpkg(x).uuid !== nothing, resolved_deps)
end
