import Base: strip
abstract type Runner; end

export default_host_platform

const AnyRedirectable = Union{Base.AbstractCmd, Base.TTY, IOStream, IOBuffer}

# Host platform _must_ match the C++ string ABI of the binaries we get from the
# repositories.  Note: when preferred_gcc_version=v"4" we can't really build for
# that C++ string ABI :-(
"""
    default_host_platform

The default host platform in the build environment.
"""
const default_host_platform = Platform("x86_64", "linux"; libc="musl", cxxstring_abi="cxx11")

function nbits(p::AbstractPlatform)
    if arch(p) in ("i686", "armv6l", "armv7l")
        return 32
    elseif arch(p) in ("x86_64", "aarch64", "powerpc64le", "riscv64")
        return 64
    else
        error("Unknown bitwidth for architecture $(arch(p))")
    end
end

function proc_family(p::AbstractPlatform)
    if arch(p) in ("x86_64", "i686")
        return "intel"
    elseif arch(p) in ("armv6l", "armv7l", "aarch64")
        return "arm"
    elseif arch(p) == "powerpc64le"
        return "power"
    elseif arch(p) == "riscv64"
        return "riscv"
    else
        error("Unknown processor family for architecture $(arch(p))")
    end
end

# Convert platform to a triplet, but strip out the ABI parts.
# Also translate `armvXl` -> `arm` for now, since that's what most
# compiler toolchains call it.  :(
function aatriplet(p::AbstractPlatform)
    t = triplet(abi_agnostic(p))
    t = replace(t, "armv7l" => "arm")
    t = replace(t, "armv6l" => "arm")
    return t
end
# We want AnyPlatform to look like `default_host_platform` in the build environment.
aatriplet(p::AnyPlatform) = aatriplet(default_host_platform)

function ld_library_path(target::AbstractPlatform,
                         host::AbstractPlatform,
                         prefix::String="",
                         host_libdir::String="";
                         csl_paths::Bool=true,
                         host_lib64::Bool=nbits(host)==64)
    # Helper for generating the library include path for a target.  MacOS, as usual,
    # puts things in slightly different place.
    function target_lib_dir(p::AbstractPlatform)
        t = aatriplet(p)
        if Sys.isapple(p)
            return "/opt/$(t)/$(t)/lib:/opt/$(t)/lib"
        else
            return "/opt/$(t)/$(t)/lib64:/opt/$(t)/$(t)/lib"
        end
    end

    # Let's start
    paths = String[]

    # If requested, start with our CSL libraries for target/host, but only for architectures
    # that can natively run within this environment
    if csl_paths
        append!(paths,
                unique("/usr/lib/csl-$(libc(p))-$(arch(p))" for p in (host, target) if Sys.islinux(p) && proc_family(p) == "intel"),
                )
    end

    push!(paths,
          # Then add default system paths
          "/usr/local/lib64:/usr/local/lib:/usr/lib64:/usr/lib",
          # Add our loader directories
          "/lib64:/lib",
          )

    if !isempty(host_libdir)
        push!(paths,
              # Libdir of the host platform, to run programs in `HostBuildDependency`
              host_libdir,
              )
        if host_lib64
            # Include `${host_prefix}/lib64` too.
            push!(paths, "$(host_libdir)64")
        end
    end

    push!(paths,
          # Add our target/host-specific library directories for compiler support libraries
          target_lib_dir(host),
          target_lib_dir(target),
          )

    # Finally, add dependencies in the prefix
    if !isempty(prefix)
        push!(paths,
              "$(prefix)/lib64:$(prefix)/lib",
              )
    end

    return join(paths, ":")
end

function macos_version(kernel_version::Integer)
    # See https://en.wikipedia.org/wiki/Darwin_(operating_system)#Release_history
    kernel_to_macos = Dict(
        12 => "10.8",
        13 => "10.9",
        14 => "10.10",
        15 => "10.11",
        16 => "10.12",
        17 => "10.13",
        18 => "10.14",
        19 => "10.15",
        20 => "11.0",
        21 => "12.0",
    )
    return get(kernel_to_macos, kernel_version, nothing)
end
function macos_version(p::AbstractPlatform)
    if os(p) != "macos"
        return nothing
    end

    # If no `os_version` is specified in `p`, default to the oldest we support in the Julia world,
    # which is `10.8`, but if it is actually specified, then set that corresponding value.
    #version = something(os_version(p), v"14.0.0")

    # Eventually, we'll take this in `os_version(p)`, but not just yet.  We need to fix the paths
    # to the compiler shards first, since right now they have `14` at the end
    version = something(os_version(p), v"14.0.0")
    return macos_version(version.major)
end

# Platforms for which Clang should be the default compiler.
prefer_clang(p::AbstractPlatform) =
    Sys.isbsd(p) || sanitize(p) in ("memory", "memory_origins", "address")

# Add the string ABI define
function add_cxx_abi(p::AbstractPlatform, flags::Vector{String})
    if cxxstring_abi(p) == "cxx11"
        push!(flags, "-D_GLIBCXX_USE_CXX11_ABI=1")
    elseif cxxstring_abi(p) == "cxx03"
        push!(flags, "-D_GLIBCXX_USE_CXX11_ABI=0")
    end
end

"""
    generate_compiler_wrappers!(platform::AbstractPlatform; bin_path::AbstractString,
                                host_platform::AbstractPlatform = $(repr(default_host_platform)),
                                compilers::Vector{Symbol} = [:c],
                                allow_unsafe_flags::Bool = false,
                                lock_microarchitecture::Bool = true,
                                gcc_version::Union{Nothing,VersionNumber}=nothing,
                                clang_version::Union{Nothing,VersionNumber}=nothing,
                                clang_use_lld::Bool = false,
                                )

We generate a set of compiler wrapper scripts within our build environment to force all
build systems to honor the necessary sets of compiler flags to build for our systems.
Note that while `platform_envs()` sets many environment variables, those values are
intended to be optional/overridable.  These values, while still overridable by directly
invoking a compiler binary directly (e.g. /opt/{target}/bin/{target}-gcc), are much more
difficult to override, as the flags embedded in these wrappers are absolutely necessary,
and even simple programs will not compile without them.
"""
function generate_compiler_wrappers!(platform::AbstractPlatform; bin_path::AbstractString,
                                     host_platform::AbstractPlatform = default_host_platform,
                                     compilers::Vector{Symbol} = [:c],
                                     allow_unsafe_flags::Bool = false,
                                     lock_microarchitecture::Bool = true,
                                     bootstrap::Bool = !isempty(bootstrap_list),
                                     gcc_version::Union{Nothing,VersionNumber}=nothing,
                                     clang_version::Union{Nothing,VersionNumber}=nothing,
                                     clang_use_lld::Bool = false,
                                     )
    # Wipe that directory out, in case it already had compiler wrappers
    rm(bin_path; recursive=true, force=true)
    mkpath(bin_path)

    # Early-exit if we're bootstrapping
    if bootstrap
        return
    end

    target = aatriplet(platform)
    host_target = aatriplet(host_platform)


    function wrapper(io::IO,
                     prog::String;
                     # Flags that are always prepended
                     flags::Vector{String} = String[],
                     # Flags that are prepended if we think we're compiling (e.g. no `-x assembler`)
                     compile_only_flags::Vector = String[],
                     # Flags that are postpended if we think we're linking (e.g. no `-c`)
                     link_only_flags::Vector = String[],
                     allow_ccache::Bool = true,
                     no_soft_float::Bool = false,
                     hash_args::Bool = false,
                     extra_cmds::String = "",
                     env::Dict{String,String} = Dict{String,String}(),
                     unsafe_flags = String[])
        write(io, """
        #!/bin/bash
        # This compiler wrapper script brought into existence by `generate_compiler_wrappers!()`

        if [ "x\${SUPER_VERBOSE}" = "x" ]; then
            vrun() { "\$@"; }
        else
            vrun() { echo -e "\\e[96m\$@\\e[0m" >&2; "\$@"; }
        fi

        ARGS=( "\$@" )
        PRE_FLAGS=()
        POST_FLAGS=()
        """)

        # Sometimes we need to look at the hash of our arguments
        if hash_args
            write(io, """
            ARGS_HASH="\$(echo -n "\$*" | sha1sum | cut -c1-8)"
            """)
        end

        # If we're given always-prepend flags, include them
        if !isempty(flags)
            println(io)
            for cf in flags
                println(io, "PRE_FLAGS+=( $cf )")
            end
            println(io)
        end

        # If we're given compile-only flags, include them only if `-x assembler` is not provided
        if !isempty(compile_only_flags)
            println(io)
            println(io, "if [[ \" \${ARGS[@]} \" != *' -x assembler '* ]]; then")
            for cf in compile_only_flags
                println(io, "    PRE_FLAGS+=( $cf )")
            end
            println(io, "fi")
            println(io)
        end

        # If we're given link-only flags, include them only if `-c` or other link-disablers are not provided.
        if !isempty(link_only_flags)
            println(io)
            println(io, "if [[ \" \${ARGS[@]} \" != *' -c '* ]] && [[ \" \${ARGS[@]} \" != *' -E '* ]] && [[ \" \${ARGS[@]} \" != *' -M '* ]] && [[ \" \${ARGS[@]} \" != *' -fsyntax-only '* ]]; then")
            for lf in link_only_flags
                println(io, "    POST_FLAGS+=( $lf )")
            end
            println(io, "fi")
            println(io)
        end

        # If we're given both -fsanitize= and -Wl,--no-undefined, then try turning
        # the latter into a warning rather than an error.
        if sanitize(platform) != nothing
            println(io, """
            if  [[ " \${ARGS[@]} " == *"-Wl,--no-undefined"* ]]; then
                PRE_FLAGS+=("-Wl,--warn-unresolved-symbols")
            fi
            """)
        end

        # Insert extra commands from the user (usually some kind of conditional setting
        # of PRE_FLAGS and POST_FLAGS)
        println(io)
        write(io, extra_cmds)
        println(io)

        for (name, val) in env
            write(io, "export $(name)=\"$(val)\"\n")
        end

        # TODO: improve this check
        if lock_microarchitecture
            write(io, raw"""
                      if [[ " ${ARGS[@]} " == *"-march="* ]]; then
                          echo "BinaryBuilder: Cannot force an architecture via -march" >&2
                          exit 1
                      fi
                      """)
            println(io)
        end

        if no_soft_float
            write(io, raw"""
                      if [[ " ${ARGS[@]} " == *"-mfloat-abi=soft"* ]]; then
                          echo "BinaryBuilder: ${target} platform does not support soft-float ABI (-mfloat-abi=soft)" >&2
                          exit 1
                      fi
                      """)
            println(io)
        end

        if length(unsafe_flags) >= 1
            write(io, """
            if [[ "\${ARGS[@]}" =~ \"$(join(unsafe_flags, "\"|\""))\" ]]; then
                echo -e \"BinaryBuilder error: You used one or more of the unsafe flags: $(join(unsafe_flags, ", "))\\nThis is not allowed, please remove all unsafe flags from your build script to continue.\" >&2
                exit 1
            fi
            """)
            println(io)
        end

        if allow_ccache
            write(io, """
            if [[ \${USE_CCACHE} == "true" ]]; then
                CCACHE="ccache"
            fi
            """)
        end
        write(io, """
        vrun \${CCACHE} $(prog) "\${PRE_FLAGS[@]}" "\${ARGS[@]}" "\${POST_FLAGS[@]}"
        """)
    end

    # Helper invocations
    target_tool(io::IO, tool::String, args...; kwargs...) = wrapper(io, "/opt/$(target)/bin/$(target)-$(tool)", args...; kwargs...)
    llvm_tool(io::IO, tool::String, args...; kwargs...) = wrapper(io, "/opt/$(host_target)/bin/llvm-$(tool)", args...; kwargs...)

    # For now this is required for Clang, since apple spells aarch64 as "arm64".
    # Should probably be fixed upstream, but will do for now
    clang_target_triplet(p::AbstractPlatform) = replace(aatriplet(p), "aarch64" => "arm64")

    function clang_flags!(p::AbstractPlatform, flags::Vector{String} = String[]; iscxx::Bool = false)
        # Focus the clang targeting laser
        append!(flags, [
            # Set the `target` for `clang` so it generates the right kind of code
            "-target $(clang_target_triplet(p))",
            # Set our sysroot to the platform-specific location, dropping compiler ABI annotations
            "--sysroot=/opt/$(aatriplet(p))/$(aatriplet(p))/sys-root",
        ])
        if !Sys.isbsd(p)
            add_cxx_abi(p, flags)
            if iscxx
                append!(flags, [
                    # Link with libstdc++ when compiling c++ on non-BSDs
                    "-stdlib=libstdc++"
            ])
            end
        end
        if Sys.islinux(p)
            # Find GCC toolchain
            gcc_toolchain_flag = if !isnothing(gcc_version) && !isnothing(clang_version) && (clang_version >= v"16")
                "--gcc-install-dir=/opt/$(aatriplet(p))/lib/gcc/$(aatriplet(p))/$(gcc_version)"
            else
                # This helps MSAN C++ compiler finding the target toolchain, rather than the host one:
                # <https://github.com/JuliaPackaging/Yggdrasil/pull/7872#issuecomment-1913141689>.
                "--gcc-toolchain=/opt/$(aatriplet(p))"
            end
            append!(flags, [gcc_toolchain_flag])
        end
        if Sys.iswindows(p)
            windows_cflags!(p, flags)
        end
        return flags
    end

    function min_macos_version_flags()
        # Ask compilers to compile for a minimum macOS version, targeting that SDK.
        return ("-mmacosx-version-min=\${MACOSX_DEPLOYMENT_TARGET}", "-Wl,-sdk_version,\${MACOSX_DEPLOYMENT_TARGET}")
    end

    function add_system_includedir(flags::Vector{String})
        # GCC 4.8.5 for musl and clang on FreeBSD do not have `SYSROOT/usr/local` (which
        # in our build environments is a symlink to $includedir = "$(prefix)/include")
        # in the default list of include search directories. As a result, quite some
        # builders that work fine everywhere else need to add something like
        # `-I${includedir}` to their CPPFLAGS.
        #
        # To remove this annoyance, we simply add it here. We use `-isystem` instead
        # of `-I` to mimic how this dir is treated on other operating systems. It
        # is still not a perfect match, as the order of the default search directories
        # differs, but this should not matter in practice.
        #
        # See also https://github.com/JuliaPackaging/Yggdrasil/issues/3949 and
        # https://github.com/JuliaPackaging/Yggdrasil/pull/3969 for further details.
        append!(flags, ["-isystem", raw"${includedir}"])
    end

    function sanitize_compile_flags!(p::AbstractPlatform, flags::Vector{String})
        if sanitize(p) !== nothing
            if sanitize(p) == "memory"
                append!(flags, ["-fsanitize=memory"])
            elseif sanitize(p) == "memory_origins"
                append!(flags, ["-fsanitize=memory", "-fsanitize-memory-track-origins", "-fno-omit-frame-pointer"])
            elseif sanitize(p) == "address"
                append!(flags, ["-fsanitize=address"])
            elseif sanitize(p) == "thread"
                append!(flags, ["-fsanitize=thread"])
            end
        end
    end

    function sanitize_link_flags!(p::AbstractPlatform, flags::Vector{String})
        san = sanitize(p)
        if sanitize(p) !== nothing
            if sanitize(p) == "memory"
                append!(flags, ["-fsanitize=memory"])
            elseif sanitize(p) == "memory_origins"
                append!(flags, ["-fsanitize=memory", "-fsanitize-memory-track-origins", "-fno-omit-frame-pointer"])
            elseif sanitize(p) == "address"
                append!(flags, ["-fsanitize=address"])
            elseif sanitize(p) == "thread"
                append!(flags, ["-fsanitize=thread"])
            end
        end
    end

    function clang_compile_flags!(p::AbstractPlatform, flags::Vector{String} = String[])
        if lock_microarchitecture
            append!(flags, get_march_flags(arch(p), march(p), "clang"))
        end

        append!(flags, [
            # We add `-Wno-unused-command-line-argument` so that if someone does something like
            # `clang -Werror -o foo a.o b.o`, it doesn't complain due to the fact that that is using
            # `clang` as a linker (and we have no real way to detect that in the wrapper), which
            # will cause `clang` to complain about compiler flags being passed in.
            "-Wno-unused-command-line-argument",
            # We need to override the typical C++ include search paths, because it always includes
            # the toolchain C++ headers first.  Valentin tracked this down to:
            # https://github.com/llvm/llvm-project/blob/0378f3a90341d990236c44f297b923a32b35fab1/clang/lib/Driver/ToolChains/Darwin.cpp#L1944-L1978
            "-nostdinc++",
            # For systems other than macOS this directory doesn't exist out-of-the-box in our
            # toolchain, but you can put in there the headers of the C++ standard library for libc++
            # from LLLVMLibcxx_jll.  This must come before GCC header files (added below).
            "-isystem /opt/$(aatriplet(p))/$(aatriplet(p))/sys-root/usr/include/c++/v1",
        ])

        if Sys.isapple(p)
            macos_version_flags = clang_use_lld ? (min_macos_version_flags()[1],) : min_macos_version_flags()
            append!(flags, String[
                macos_version_flags...,
            ])
        end

        sanitize_compile_flags!(p, flags)
        if Sys.isfreebsd(p)
            add_system_includedir(flags)
        end

        if !Sys.isbsd(p)
            # GCC header files
            if !isnothing(gcc_version)
                append!(flags, [
                    "-isystem /opt/$(aatriplet(p))/$(aatriplet(p))/include/c++/$(gcc_version)",
                    "-isystem /opt/$(aatriplet(p))/$(aatriplet(p))/include/c++/$(gcc_version)/$(aatriplet(p))",
                    "-isystem /opt/$(aatriplet(p))/$(aatriplet(p))/include/c++/$(gcc_version)/backward",
                ])
            end
            # MinGW header files
            if Sys.iswindows(p)
                append!(flags, [
                    "-isystem /opt/$(aatriplet(p))/$(aatriplet(p))/include",
                ])
            end
        end

        if Sys.iswindows(p) && nbits(p) == 32
            push!(flags, "-fsjlj-exceptions")
        end
        return flags
    end

    function clang_link_flags!(p::AbstractPlatform, flags::Vector{String} = String[])
        # On macos and freebsd, we must pass in the `/lib` directory for some reason
        if Sys.isbsd(p)
            push!(flags, "-L/opt/$(aatriplet(p))/$(aatriplet(p))/lib")
        end
        # For MacOS and FreeBSD, we don't set `-rtlib`, and FreeBSD is special-cased within the LLVM source tree
        # to not allow for -gcc-toolchain, which means that we have to manually add the location of libgcc_s.  LE SIGH.
        # We do that here, so that we don't get "unused argument" warnings all over the place.
        # https://github.com/llvm-mirror/clang/blob/f3b7928366f63b51ffc97e74f8afcff497c57e8d/lib/Driver/ToolChains/FreeBSD.cpp
        # For everything else, we provide `-rtlib=libgcc` because clang-builtins are broken (pending Valentin-based-magic),
        # and we also need to provide `-stdlib=libstdc++` to match Julia on these platforms.
        if !Sys.isbsd(p)
            append!(flags, [
                # Use libgcc as the C runtime library
                "-rtlib=libgcc"
            ])
            if !isnothing(gcc_version)
                append!(flags, String["-L/opt/$(aatriplet(p))/lib/gcc/opt/$(aatriplet(p))/lib/gcc",
                                    "-L/opt/$(aatriplet(p))/$(aatriplet(p))/lib",
                                    "-L/opt/$(aatriplet(p))/lib/gcc/$(aatriplet(p))/$(gcc_version)",
                                    "-L/opt/$(aatriplet(p))/$(aatriplet(p))/sys-root/lib",])
            end
        end
        # we want to use a particular linker with clang.  But we want to avoid warnings about unused
        # flags when just compiling, so we put it into "linker-only flags".
        if !clang_use_lld #Clang with 16 or above is setup to use lld by default
            push!(flags, "-fuse-ld=$(aatriplet(p))")
        end
        if Sys.isfreebsd(p) && clang_use_lld
            push!(flags, "-L/opt/$(aatriplet(p))/$(aatriplet(p))/sys-root/usr/local/lib")
        end
        sanitize_link_flags!(p, flags)

        # On macos, we need to pass `-headerpad_max_install_names` so that we have lots of space
        # for `install_name_tool` shenanigans during audit fixups.
        if Sys.isapple(p)
            push!(flags, "-headerpad_max_install_names")
        end
        return flags
    end


    function macos_gcc_flags!(p::AbstractPlatform, flags::Vector{String} = String[])
        # On macOS, if we're on an old GCC, the default -syslibroot that gets
        # passed to the linker isn't calculated correctly, so we have to manually set it.
        if gcc_version.major in (4, 5)
            push!(flags, "-Wl,-syslibroot,/opt/$(aatriplet(p))/$(aatriplet(p))/sys-root")
        end
        append!(flags, min_macos_version_flags())
        return flags
    end

    function windows_cflags!(p::AbstractPlatform, flags::Vector{String} = String[])
        # Declare that we are Windows 10 (0x0A00)
        # https://learn.microsoft.com/en-us/cpp/porting/modifying-winver-and-win32-winnt?view=msvc-170
        append!(flags, [
            "-DWINVER=0x0A00",
            "-D_WIN32_WINNT=0x0A00",
        ])
        return flags
    end

    function gcc_flags!(p::AbstractPlatform, flags::Vector{String} = String[])
        # Force proper cxx11 string ABI usage w00t w00t!
        add_cxx_abi(p, flags)

        # Simulate some of the `__OSX_AVAILABLE()` macro usage that is broken in GCC
        if Sys.isapple(p) && something(os_version(p), v"14") < v"16"
            # Disable usage of `clock_gettime()`
            push!(flags, "-D_DARWIN_FEATURE_CLOCK_GETTIME=0")
        end

        # Use hash of arguments to provide consistent, unique random seed
        push!(flags, "-frandom-seed=0x\${ARGS_HASH}")

        if Sys.isapple(p)
            macos_gcc_flags!(p, flags)
        end

        if Sys.iswindows(p)
            windows_cflags!(p, flags)
        end

        return flags
    end

    function gcc_compile_flags!(p::AbstractPlatform, flags::Vector{String} = String[])
        if Sys.islinux(p) || Sys.isfreebsd(p)
            # Help GCCBootstrap find its own libraries under
            # `/opt/${target}/${target}/lib{,64}`.  Note: we need to push them directly in
            # the wrappers before any additional arguments because we want this path to have
            # precedence over anything else.  In this way for example we avoid libraries
            # from `CompilerSupportLibraries_jll` in `${libdir}` are picked up by mistake.
            dir = "/opt/$(aatriplet(p))/$(aatriplet(p))/lib" * (nbits(p) == 32 ? "" : "64")
            append!(flags, ("-L$(dir)", "-Wl,-rpath-link,$(dir)"))
        end
        if lock_microarchitecture
            append!(flags, get_march_flags(arch(p), march(p), "gcc"))
        end
        sanitize_compile_flags!(p, flags)
        if libc(platform) == "musl" && gcc_version in (v"4.8.5", v"5.2.0")
            add_system_includedir(flags)
        end
        return flags
    end

    function gcc_link_flags!(p::AbstractPlatform, flags::Vector{String} = String[])
        # Inclusion of `/lib64` on `powerpc64le` was fixed in GCC 8+.
        if arch(p) == "powerpc64le" && Sys.islinux(p) && 4 <= gcc_version.major <= 7
            append!(flags, String[
                "-L/opt/$(aatriplet(p))/$(aatriplet(p))/sys-root/lib64",
                "-Wl,-rpath-link,/opt/$(aatriplet(p))/$(aatriplet(p))/sys-root/lib64",
            ])
        elseif Sys.isapple(p)
            push!(flags, "-headerpad_max_install_names")
        elseif Sys.iswindows(p) && gcc_version ≥ v"5"
            # Do not embed timestamps, for reproducibility:
            # https://github.com/JuliaPackaging/BinaryBuilder.jl/issues/1232
            push!(flags, "-Wl,--no-insert-timestamp")
        end
        sanitize_link_flags!(p, flags)
        return flags
    end

    function gcc_unsafe_flags!(p::AbstractPlatform, flags::Vector{String} = String[])
        if !allow_unsafe_flags
            return String["-Ofast", "-ffast-math", "-funsafe-math-optimizations"]
        end
        return String[]
    end

    function gcc_wrapper(io::IO, tool::String, p::AbstractPlatform, allow_ccache::Bool = true)
        return wrapper(io,
            "/opt/$(aatriplet(p))/bin/$(aatriplet(p))-$(tool)";
            flags=gcc_flags!(p),
            compile_only_flags=gcc_compile_flags!(p),
            link_only_flags=gcc_link_flags!(p),
            unsafe_flags=gcc_unsafe_flags!(p),
            hash_args = true,
            allow_ccache,
            no_soft_float=arch(p) in ("armv6l", "armv7l"),
            # Override `LD_LIBRARY_PATH` to avoid external settings mess it up.
            env=Dict("LD_LIBRARY_PATH"=>ld_library_path(platform, host_platform; csl_paths=false)),
        )
    end

    function clang_wrapper(io::IO, tool::String, p::AbstractPlatform, iscxx::Bool)
        flags = clang_flags!(p, iscxx=iscxx)
        return wrapper(io,
            "/opt/$(host_target)/bin/$(tool)";
            flags=flags,
            compile_only_flags=clang_compile_flags!(p),
            link_only_flags=clang_link_flags!(p),
            no_soft_float=arch(p) in ("armv6l", "armv7l"),
            # Override `LD_LIBRARY_PATH` to avoid external settings mess it up.
            env=Dict("LD_LIBRARY_PATH"=>ld_library_path(platform, host_platform; csl_paths=false)),
        )
    end

    # C/C++/Fortran
    gcc(io::IO, p::AbstractPlatform)      = gcc_wrapper(io, "gcc", p)
    gxx(io::IO, p::AbstractPlatform)      = gcc_wrapper(io, "g++", p)
    gfortran(io::IO, p::AbstractPlatform) = gcc_wrapper(io, "gfortran", p, false)

    clang(io::IO, p::AbstractPlatform)    = clang_wrapper(io, "clang", p, false)
    clangxx(io::IO, p::AbstractPlatform)  = clang_wrapper(io, "clang++", p, true)

    # Our general `cc`  points to `gcc` for most systems, but `clang` for MacOS and FreeBSD,
    # unless we're building for msan, which gcc does not support or asan, which gcc does
    # support, but is claimed to be incompatbile with the LLVM version (that we use for our
    # JIT-generated code)
    function cc(io::IO, p::AbstractPlatform)
        if prefer_clang(p)
            return clang(io, p)
        else
            return gcc(io, p)
        end
    end
    function cxx(io::IO, p::AbstractPlatform)
        if prefer_clang(p)
            return clangxx(io, p)
        else
            return gxx(io, p)
        end
    end
    fc(io::IO, p::AbstractPlatform) = gfortran(io, p)

    # Go stuff where we build an environment mapping each time we invoke `go-${target}`
    function GOOS(p::AbstractPlatform)
        if os(p) == "macos"
            return "darwin"
        end
        return os(p)
    end
    function GOARCH(p::AbstractPlatform)
        arch_mapping = Dict(
            "armv6l" => "arm",
            "armv7l" => "arm",
            "aarch64" => "arm64",
            "x86_64" => "amd64",
            "i686" => "386",
            "powerpc64le" => "ppc64le",
            "riscv64" => "riscv64",
        )
        return arch_mapping[arch(p)]
    end
    function go(io::IO, p::AbstractPlatform)
        env = Dict(
            "GOOS" => GOOS(p),
            "GOROOT" => "/opt/$(host_target)/go",
            "GOARCH" => GOARCH(p),
        )
        return wrapper(io, "/opt/$(host_target)/go/bin/go"; env=env, allow_ccache=false)
    end
    gofmt(io::IO, p::AbstractPlatform) = wrapper(io, "/opt/$(host_target)/go/bin/gofmt"; allow_ccache=false)

    # Rust stuff
    function rust_flags!(p::AbstractPlatform, flags::Vector{String} = String[])
        if Sys.islinux(p)
            push!(flags, "-Clinker=$(aatriplet(p))-gcc")

            # Add aarch64 workaround https://github.com/rust-lang/rust/issues/46651#issuecomment-402850885
            if arch(p) == "aarch64" && libc(p) == "musl"
                push!(flags, "-C link-arg=-lgcc")
            end
        elseif Sys.iswindows(p)
            # Rust on i686 mingw32 can't deal with exceptions
            # https://github.com/rust-lang/rust/issues/12859
            if arch(p) == "i686"
                push!(flags, "-C panic=abort")
            end
        end
        return flags
    end
    function rustc(io::IO, p::AbstractPlatform)
        extra_cmds = """
        if [[ " \${ARGS[@]} " == *'--target'* ]]; then
            if ! [[ " \${ARGS[@]} " =~ --target(=| )$(map_rust_target(p)) ]]; then
                echo "Attempting to invoke targeted 'rustc' wrapper with a different target! (Expected $(map_rust_target(p)))" >&2
                echo "args: \${ARGS[@]}" >&2
                exit 1
            fi
        else
            PRE_FLAGS+=( '--target=$(map_rust_target(p))' )
        fi
        """
        wrapper(io, "/opt/$(host_target)/bin/rustc"; flags=rust_flags!(p), allow_ccache=false, extra_cmds=extra_cmds)
    end
    rustup(io::IO, p::AbstractPlatform) = wrapper(io, "/opt/$(host_target)/bin/rustup"; allow_ccache=false)
    cargo(io::IO, p::AbstractPlatform) = wrapper(io, "/opt/$(host_target)/bin/cargo"; allow_ccache=false)

    # Meson REQUIRES that `CC`, `CXX`, etc.. are set to the host utils.  womp womp.
    function meson(io::IO, p::AbstractPlatform)
        # Ugh, we need the path to `host_prefix`, let's quickly generate our
        # environment variables.
        host_prefix = platform_envs(p, ""; host_platform=default_host_platform)["host_prefix"]

        meson_env = Dict(
            # TODO: still needed?  See
            # https://mesonbuild.com/Release-notes-for-0-54-0.html#environment-variables-with-cross-builds
            "AR"     => "$(host_target)-ar",
            "CC"     => "$(host_target)-cc",
            "CXX"    => "$(host_target)-c++",
            "FC"     => "$(host_target)-f77",
            "LD"     => "$(host_target)-ld",
            "NM"     => "$(host_target)-nm",
            "OBJC"   => "$(host_target)-cc",
            "RANLIB" => "$(host_target)-ranlib",
            # Needed to find pkg-config files for the host: https://mesonbuild.com/Reference-tables.html#environment-variables-per-machine
            "PKG_CONFIG_PATH_FOR_BUILD" => "$(host_prefix)/lib/pkgconfig:$(host_prefix)/lib64/pkgconfig:$(host_prefix)/share/pkgconfig",
        )
        wrapper(io, "/usr/bin/meson"; allow_ccache=false, env=meson_env)
    end

    # Patchelf needs some page-alignment on aarch64 and ppc64le forced into its noggin
    # https://github.com/JuliaPackaging/BinaryBuilder.jl/commit/cce4f8fdbb16425d245ab87a50f60d1a16d04948
    function patchelf(io::IO, p::AbstractPlatform)
        extra_cmds = ""
        if Sys.islinux(p) && arch(p) in ("aarch64", "powerpc64le")
            extra_cmds = raw"""
            if [[ " ${ARGS[@]} " != *'--page-size'* ]]; then
                PRE_FLAGS+=( '--page-size' '65536' )
            fi
            """
        end
        wrapper(io, "/usr/bin/patchelf"; allow_ccache=false, extra_cmds=extra_cmds)
    end

    # We pass `-D` to all `ar` invocations (unless `-U` is explicitly passed) for reproducibility
    function ar(io::IO, p::AbstractPlatform)
        ar_name = string(aatriplet(p), "-ar")
        if Sys.isapple(p)
            ar_name = "llvm-ar"
        end
        extra_cmds = raw"""
        if [[ " ${ARGS[0]} " =~ --* ]]; then
            # do nothing, it's probably --version or something
            true
        elif [[ " ${ARGS[0]} " != *'U'* ]]; then
            # Eliminate the `u` option, as it's incompatible with `D` and is just an optimization
            if [[ " ${ARGS[0]} " == *'u'* ]]; then
                ARGS[0]=$(echo "${ARGS[0]}" | tr -d u)
            fi

            # Add -D for "Deterministic mode"
            ARGS[0]="${ARGS[0]}D"
        else
            echo "Non-reproducibility alert: This 'ar' invocation uses the '-U' flag which embeds timestamps." >&2
            echo "ar flags: ${ARGS[@]}" >&2
            echo "Continuing build, but please repent." >&2
        fi
        """
        wrapper(io, string("/opt/", aatriplet(p), "/bin/", ar_name); allow_ccache=false, extra_cmds=extra_cmds)
    end

    function ranlib(io::IO, p::AbstractPlatform)
        if !Sys.isapple(p)
            ranlib_name = string(aatriplet(p), "-ranlib")
            extra_cmds = raw"""
            if [[ " ${ARGS[@]} " =~ "-[hHvVt]*U" ]]; then
                echo "Non-reproducibility alert: This `ranlib` invocation uses the `-U` flag which embeds timestamps." >&2
                echo "ranlib flags: ${ARGS[@]}" >&2
                echo "Continuing build, but please repent." >&2
            else
                PRE_FLAGS+=( '-D' )
            fi
            """
        else
            # llvm-ranlib is always reproducible
            ranlib_name = "llvm-ranlib"
            extra_cmds = ""
        end
        wrapper(io, string("/opt/", aatriplet(p), "/bin/", ranlib_name); allow_ccache=false, extra_cmds=extra_cmds)
    end

    function dlltool(io::IO, p::AbstractPlatform)
        extra_cmds = raw"""
        PRE_FLAGS+=( --temp-prefix /tmp/dlltool-${ARGS_HASH} )
        """
        wrapper(io, string("/opt/", aatriplet(p), "/bin/", string(aatriplet(p), "-dlltool")); allow_ccache=false, extra_cmds=extra_cmds, hash_args=true)
    end

    lld_generic(io::IO, p::AbstractPlatform) =
        return wrapper(io, "/opt/$(host_target)/bin/lld"; env=Dict("LD_LIBRARY_PATH"=>ld_library_path(platform, host_platform; csl_paths=false)), allow_ccache=false,)
    function lld(io::IO, p::AbstractPlatform)
        return wrapper(io,
            "/opt/$(host_target)/bin/$(lld_string(p))";
            env=Dict("LD_LIBRARY_PATH"=>ld_library_path(platform, host_platform; csl_paths=false)), allow_ccache=false,
        )
    end
    # Write out a bunch of common tools
    for tool in (:cpp, :ld, :nm, :libtool, :objcopy, :objdump, :otool,
                 :strip, :install_name_tool, :dlltool, :windres, :winmc, :lipo)
        @eval $(tool)(io::IO, p::AbstractPlatform) = $(wrapper)(io, string("/opt/", aatriplet(p), "/bin/", aatriplet(p), "-", $(string(tool))); allow_ccache=false)
    end
    as(io::IO, p::AbstractPlatform) =
        wrapper(io, string("/opt/", aatriplet(p), "/bin/", aatriplet(p), "-as");
                allow_ccache=false,
                # At the moment `as` for `aarch64-apple-darwin` is `clang-8`, which can't deal with
                # `MACOSX_DEPLOYMENT_TARGET=11.0`, so we pretend to be on 10.16.  Note: a better check would be
                # `VersionNumber(macos_version(p)) ≥ v"11"`, but sometimes `p` may not have `os_version` set, leading to
                # an error.  TODO: remove this hack and create `as` wrapper together with the tools above when we
                # upgrade `as` to a newer version of Clang.
                env=(Sys.isapple(p) && arch(p) == "aarch64") ? Dict("MACOSX_DEPLOYMENT_TARGET"=>"10.16") : Dict{String,String}())

    # c++filt is hard to write in symbols
    function cxxfilt(io::IO, p::AbstractPlatform)
        if Sys.isapple(p)
            # We must use `llvm-cxxfilt` on MacOS
            path = "/opt/$(aatriplet(p))/bin/llvm-cxxfilt"
        else
            path = "/opt/$(aatriplet(p))/bin/$(aatriplet(p))-c++filt"
        end
        return wrapper(io, path; allow_ccache=false)
    end

    function dsymutil(io::IO, p::AbstractPlatform)
        if !Sys.isapple(p)
            # Nobody except macOS has a `dsymutil`
            return (io, p) -> nothing
        end

        return wrapper(io, "/opt/$(aatriplet(p))/bin/dsymutil"; allow_ccache=false)
    end

    function readelf(io::IO, p::AbstractPlatform)
        if Sys.isapple(p)
            # macOS doesn't have a readelf
            return (io, p) -> nothing
        end
        return wrapper(io, "/opt/$(aatriplet(p))/bin/$(aatriplet(p))-readelf"; allow_ccache=false)
    end

    function write_wrapper(wrappergen, p, fname)
        file_path = joinpath(bin_path, triplet(p), fname)
        mkpath(dirname(file_path))
        open(io -> Base.invokelatest(wrappergen, io, p), file_path, "w")
        chmod(file_path, 0o775)
    end

    ## Generate compiler wrappers for both our host and our target.
    for p in unique((host_platform, platform))
        t = aatriplet(p)

        # Generate `:c` compilers
        if :c in compilers
            write_wrapper(cc, p, "$(t)-cc")
            write_wrapper(cxx, p, "$(t)-c++")

            # Generate `gcc`, `g++`, `clang` and `clang++`
            write_wrapper(gcc, p, "$(t)-gcc")
            write_wrapper(gxx, p, "$(t)-g++")
            write_wrapper(clang, p, "$(t)-clang")
            write_wrapper(clangxx, p, "$(t)-clang++")

            # Someday, you will be split out
            write_wrapper(gfortran, p, "$(t)-f77")
            write_wrapper(gfortran, p, "$(t)-gfortran")

            # Binutils
            write_wrapper(ar, p, "$(t)-ar")
            write_wrapper(as, p, "$(t)-as")
            write_wrapper(cpp, p, "$(t)-cpp")
            write_wrapper(cxxfilt, p, "$(t)-c++filt")
            write_wrapper(ld, p, "$(t)-ld")
            # ld wrappers for clang's `-fuse-ld=$(target)`
            if Sys.isapple(p)
                write_wrapper(ld, p, "ld64.$(t)")
            else
                write_wrapper(ld, p, "ld.$(t)")
            end
            write_wrapper(lld,p,"$(t)-$(lld_string(p))")
            write_wrapper(lld_generic, p, "$(t)-lld")
            write_wrapper(nm, p, "$(t)-nm")
            write_wrapper(libtool, p, "$(t)-libtool")
            write_wrapper(objcopy, p, "$(t)-objcopy")
            write_wrapper(objdump, p, "$(t)-objdump")
            write_wrapper(ranlib, p, "$(t)-ranlib")
            write_wrapper(readelf, p, "$(t)-readelf")
            write_wrapper(strip, p, "$(t)-strip")

            # Special mac stuff
            if Sys.isapple(p)
                write_wrapper(install_name_tool, p, "$(t)-install_name_tool")
                write_wrapper(lipo, p, "$(t)-lipo")
                write_wrapper(dsymutil, p, "$(t)-dsymutil")
                write_wrapper(otool, p, "$(t)-otool")
            end

            # Special Windows stuff
            if Sys.iswindows(p)
                write_wrapper(dlltool, p, "$(t)-dlltool")
                write_wrapper(windres, p, "$(t)-windres")
                write_wrapper(winmc, p, "$(t)-winmc")
            end
        end

        # Generate go stuff
        if :go in compilers
            write_wrapper(go, p, "$(t)-go")
            write_wrapper(gofmt, p, "$(t)-gofmt")
        end

        # Misc. utilities
        write_wrapper(patchelf, p, "$(t)-patchelf")
    end

    # Rust stuff doesn't use the normal "host" platform, it uses x86_64-linux-gnu, so we always have THREE around,
    # because clever build systems like `meson` ask Rust what its native system is, and it truthfully answers
    # `x86_64-linux-gnu`, while other build systems might say `x86_64-linux-musl` with no less accuracy.  So for
    # safety, we just ship all three all the time.
    if :rust in compilers
        for p in unique((platform, host_platform))
            t = aatriplet(p)
            write_wrapper(rustc, p, "$(t)-rustc")
            write_wrapper(rustup, p, "$(t)-rustup")
            write_wrapper(cargo, p, "$(t)-cargo")
        end
    end

    # Write a single wrapper for `meson`
    write_wrapper(meson, host_platform, "meson")

    default_tools = [
        # Misc. utilities from RootFS
        "patchelf",
    ]

    if :c in compilers
        # Binutils
        append!(default_tools,
                ("ar", "as", "c++filt", "ld", "nm", "libtool", "objcopy", "ranlib", "readelf", "strip"))

        if Sys.isapple(platform)
            append!(default_tools, ("dsymutil", "lipo", "otool", "install_name_tool"))
        elseif Sys.iswindows(platform)
            append!(default_tools, ("dlltool", "windres", "winmc"))
        end
        append!(default_tools, ("cc", "c++", "cpp", "f77", "gfortran", "gcc", "clang", "g++", "clang++", "lld", lld_string(platform)))
    end
    if :rust in compilers
        append!(default_tools, ("rustc","rustup","cargo"))
    end
    if :go in compilers
        append!(default_tools, ("go", "gofmt"))
    end
    # Create symlinks for default compiler invocations, invoke target toolchain
    for tool in default_tools
        symlink("$(target)-$(tool)", joinpath(bin_path, triplet(platform), tool))
    end

    # Generate other fake system-specific tools.
    if os(platform) == "macos"
        # `sw_vers -productVersion` is needed to make CMake correctly initialise the macOS
        # platform, ref: <https://github.com/JuliaPackaging/Yggdrasil/pull/4403>.  In the
        # future we may add more arguments, see
        # <https://www.unix.com/man-page/osx/1/sw_vers/> for reference.
        product_version = macos_version(platform)
        product_name = VersionNumber(product_version) < v"10.12" ? "Mac OS X" : "macOS"
        sw_vers_path = joinpath(bin_path, triplet(platform), "sw_vers")
        write(sw_vers_path, """
              #!/bin/sh
              if [[ -z "\${@}" ]]; then
                  echo "ProductName:    $(product_name)"
                  echo "ProductVersion: $(product_version)"
              elif [[ "\${@}" == "-productName" ]]; then
                  echo "$(product_name)"
              elif [[ "\${@}" == "-productVersion" ]]; then
                  echo "$(product_version)"
              fi
              """)
        chmod(sw_vers_path, 0o775)

        # `xcrun` is another macOS-specific tool, which is occasionally needed to run some
        # commands, for example for the CGO linker.  Ref:
        # <https://github.com/JuliaPackaging/Yggdrasil/pull/2962>.
        xcrun_path = joinpath(bin_path, triplet(platform), "xcrun")
        write(xcrun_path, """
              #!/bin/sh
              exec "\${@}"
              """)
        chmod(xcrun_path, 0o775)
    end
end

# Translation mappers for our target names to cargo-compatible ones.  See
# https://doc.rust-lang.org/rustc/platform-support.html
map_rust_arch(p::AbstractPlatform) =
    replace(replace(arch(p), "armv7l" => "armv7"), "armv6l" => "arm")
function map_rust_target(p::AbstractPlatform)
    if Sys.isapple(p)
        return "$(map_rust_arch(p))-apple-darwin"
    elseif Sys.isfreebsd(p)
        return "$(map_rust_arch(p))-unknown-freebsd"
    elseif Sys.iswindows(p)
        return "$(map_rust_arch(p))-pc-windows-gnu"
    else
        libc_str = libc(p) == "glibc" ? "gnu" : libc(p)
        call_abi_str = something(call_abi(p), "")
        return "$(map_rust_arch(p))-unknown-linux-$(libc_str)$(call_abi_str)"
    end
end

# Match
# https://github.com/JuliaPackaging/Yggdrasil/blob/c58c5abe64e177bc6ed6aa775aff1fefbfe85517/0_RootFS/gcc_common.jl#L342-L352
function map_musl_arch(p::AbstractPlatform)
    if arch(p) == "i686"
        return "i386"
    elseif startswith(arch(p), "arm")
        return "armhf"
    else
        return arch(p)
    end
end

"""
    platform_envs(platform::AbstractPlatform, src_name::AbstractString;
                  host_platform = default_host_platform,
                  bootstrap::Bool=!isempty(bootstrap_list),
                  compilers::Vector{Symbol}=[:c],
                  rust_version::Union{Nothing,VersionNumber}=nothing,
                  verbose::Bool = false,
                  )

Given a `platform` and a `src_name`, generate a `Dict` mapping representing all
the environment variables to be set within the build environment to force
compiles toward the defined target architecture.  Examples of things set are
`PATH`, `CC`, `RANLIB`, as well as nonstandard things like `target`.

Accepted keyword arguments are:

* `host_platform`: the platform of the host system,
* `bootstraop`: if `true`, only basic environment variables will be generated,
* `compilers`: list of compilers, some environment variables will be generated
  only if the relevant compilers are used (e.g., for Go and Rust),
* `rust_version`: version of the Rust toolchain, needed to set the environment
  variable `RUSTUP_TOOLCHAIN`,
* `verbose`: holds the value of the `V` and `VERBOSE` environment variables.
"""
function platform_envs(platform::AbstractPlatform, src_name::AbstractString;
                       host_platform = default_host_platform,
                       bootstrap::Bool=!isempty(bootstrap_list),
                       compilers::Vector{Symbol}=[:c],
                       rust_version::Union{Nothing,VersionNumber}=nothing,
                       verbose::Bool = false,
                       )
    global use_ccache

    # Convert platform to a triplet, but strip out the ABI parts
    target = aatriplet(platform)
    host_target = aatriplet(host_platform)

    # Prefix, libdir, etc...
    prefix = "/workspace/destdir"
    host_prefix = "/workspace/$(triplet(host_platform))/destdir"
    if Sys.iswindows(platform)
        libdir = "$(prefix)/bin"
    else
        libdir = "$(prefix)/lib"
    end
    if Sys.iswindows(host_platform)
        host_libdir = "$(host_prefix)/bin"
    else
        host_libdir = "$(host_prefix)/lib"
    end

    if get(stdout, :color, false)
        PS1 = string(
            raw"\[",
            Base.text_colors[:light_blue],
            raw"\]",
            "sandbox",
            raw"\[",
            Base.text_colors[:normal],
            raw"\]",
            ":",
            raw"\[",
            Base.text_colors[:yellow],
            raw"\]",
            raw"${PWD//$WORKSPACE/$\{WORKSPACE\}}",
            raw"\[",
            Base.text_colors[:normal],
            raw"\]",
            raw" \$ ",
        )
    else
        PS1 = raw"sandbox:${PWD//$WORKSPACE/$\{WORKSPACE\}} $ "
    end

    # Number of parallel jobs to use for builds
    nproc = "$(get(ENV, "BINARYBUILDER_NPROC", Sys.CPU_THREADS))"

    # Base mappings
    mapping = Dict(
        # Platform information (we save a `bb_target` because sometimes `target` gets
        # overwritten in `./configure`, and we want tools like `uname` to still see it)
        "bb_target" => target,
        "target" => target,
        # Also give people access to the full `-cxxYY` and `-libgfortranX` triplet if they really want it
        "bb_full_target" => triplet(platform),
        "rust_target" => map_rust_target(platform),
        "rust_host" => map_rust_target(host_platform),
        "nproc" => nproc,
        "nbits" => string(nbits(platform)),
        "proc_family" => string(proc_family(platform)),
        "dlext" => platform_dlext(platform),
        "exeext" => platform_exeext(platform),
        "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
        "MACHTYPE" => aatriplet(default_host_platform),

        # Set location parameters
        "WORKSPACE" => "/workspace",
        "prefix" => prefix,
        "bindir" => "$(prefix)/bin",
        "libdir" => libdir,
        "includedir" => "$(prefix)/include",

        # Set variables for the host prefix
        "host_prefix" => host_prefix,
        "host_bindir" => "$(host_prefix)/bin",
        "host_libdir" => host_libdir,
        "host_includedir" => "$(host_prefix)/include",

        # Fancyness!
        "USER" => get(ENV, "USER", "julia"),
        # Docker filters out `PS1` so we route around it
        "HIDDEN_PS1" => PS1,
        "VERBOSE" => "$(verbose)",
        "V" => "$(verbose)",
        "HISTFILE"=>"/meta/.bash_history",
        "TERM" => "screen",
        "SRC_NAME" => src_name,
        # The environment inherits the `SHELL` variable from the host, but some
        # tools refer to this variable, make it consistent with our environment
        "SHELL" => "/bin/bash",
    )

    # If we're bootstrapping, that's it, quit out.
    if bootstrap
        return mapping
    end

    function GOARM(p::AbstractPlatform)
        # See https://github.com/golang/go/wiki/GoArm#supported-architectures
        if arch(p) == "armv6l"
            return "6"
        elseif arch(p) == "armv7l"
            return "7"
        else
            return ""
        end
    end

    # Go stuff
    if :go in compilers
        merge!(mapping, Dict(
            "GO" => "go",
            "GOCACHE" => "/workspace/.gocache",
            "GOPATH" => "/workspace/.gopath",
            "GOARM" => GOARM(platform),
        ))
    end

    # Rust stuff
    if :rust in compilers
        merge!(mapping, Dict(
            "RUSTC" => "rustc",
            "CARGO" => "cargo",
            "CARGO_BUILD_JOBS" => nproc,
            "CARGO_BUILD_TARGET" => map_rust_target(platform),
            "CARGO_HOME" => "/opt/$(host_target)",
            "RUSTUP_HOME" => "/opt/$(host_target)",
            # `TARGET` and `HOST` are needed in some build systems:
            # <https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-build-scripts>.
            "TARGET" => map_rust_target(platform),
            "HOST" => map_rust_target(host_platform),
        ))
        if rust_version !== nothing
            merge!(mapping, Dict(
                "RUSTUP_TOOLCHAIN" => "$(rust_version)-$(map_rust_target(host_platform))",
            ))
        end
    end

    merge!(mapping, Dict(
        "PATH" => join((
            # First things first, our compiler wrappers trump all
            "/opt/bin/$(triplet(platform))",
            # Allow users to use things like x86_64-linux-gnu here
            "/opt/$(target)/bin",
            # Also wrappers for the host
            "/opt/bin/$(triplet(host_platform))",
            "/opt/$(host_target)/bin",
            # Default alpine PATH
            mapping["PATH"],
            # Host tools, installed as `HostBuildDependency`
            mapping["host_bindir"],
            # Finally, dependency tools
            mapping["bindir"],
        ), ":"),

        "LD_LIBRARY_PATH" => ld_library_path(platform, host_platform, prefix, host_libdir),

        # Default mappings for some tools
        "CC" => "cc",
        "CXX" => "c++",
        "FC" => "gfortran",

        # We conditionally add on some compiler flags; we'll cull empty ones at the end
        "USE_CCACHE" => "$(use_ccache[])",
        "LLVM_TARGET" => target,
        "LLVM_HOST_TARGET" => host_target,

        # Let the user parameterize their scripts for toolchain locations
        "CMAKE_HOST_TOOLCHAIN" => "/opt/toolchains/$(triplet(host_platform))/host_$(host_target).cmake",
        "CMAKE_TARGET_TOOLCHAIN" => "/opt/toolchains/$(triplet(platform))/target_$(target).cmake",
        "MESON_HOST_TOOLCHAIN" => "/opt/toolchains/$(triplet(host_platform))/host_$(host_target).meson",
        "MESON_TARGET_TOOLCHAIN" => "/opt/toolchains/$(triplet(platform))/target_$(target).meson",

        # We should always be looking for packages already in the prefix
        "PKG_CONFIG_PATH" => "$(prefix)/lib/pkgconfig:$(prefix)/lib64/pkgconfig:$(prefix)/share/pkgconfig",
        "PKG_CONFIG_SYSROOT_DIR" => prefix,

        # ccache options
        "CCACHE_COMPILERCHECK" => "content",

        # Things to help us step closer to reproducible builds; eliminate timestamp
        # variability within our binaries.
        "SOURCE_DATE_EPOCH" => "0",
        "ZERO_AR_DATE" => "1",
    ))

    # If we're on macOS, we give a hint to things like `configure` that they should use this as the linker
    if Sys.isapple(platform)
        mapping["LD"] = "/opt/bin/$(triplet(platform))/ld"
        mapping["MACOSX_DEPLOYMENT_TARGET"] = macos_version(platform)
    end

    # There is no broad agreement on what host compilers should be called,
    # so we set all the environment variables that we've seen them called
    # and hope for the best.
    for host_map in (tool -> "HOST$(tool)", tool -> "$(tool)_FOR_BUILD", tool -> "BUILD_$(tool)", tool -> "$(tool)_BUILD")
        # Use full path to avoid collisions when the target is similar to the
        # host (e.g., `x86_64-linux-musl-cxx03` and `x86_64-linux-musl-cxx11`)
        host_bin_dir = "/opt/bin/$(triplet(host_platform))"

        # First, do the simple tools where it's just X => $(host_target)-x:
        for tool in ("AR", "AS", "LD", "LIPO", "NM", "RANLIB", "READELF", "OBJCOPY", "OBJDUMP", "STRIP")
            mapping[host_map(tool)] = "$(host_bin_dir)/$(host_target)-$(lowercase(tool))"
        end

        # Next, the more custom tool mappings
        for (env_name, tool) in (
            "CC" => "$(host_bin_dir)/$(host_target)-gcc",
            "CXX" => "$(host_bin_dir)/$(host_target)-g++",
            "DSYMUTIL" => "dsymutil",
            "FC" => "$(host_bin_dir)/$(host_target)-gfortran"
           )
            mapping[host_map(env_name)] = tool
        end
    end

    if :rust in compilers
        mapping["HOST_CC"] = mapping["HOSTCC"]
    end

    # There is no easy way to automatically determine the version of glibc for
    # all platforms, but some build systems want to know it.  Let's emulate with
    # the `GNU_LIBC_VERSION` environment variable what `getconf
    # GNU_LIBC_VERSION` would return, if it worked.
    if libc(platform) === "glibc"
        # This should be kept in sync with the version of glibc used in
        # https://github.com/JuliaPackaging/Yggdrasil/blob/master/0_RootFS/gcc_sources.jl
        if arch(platform) in ("armv7l", "aarch64")
            mapping["GNU_LIBC_VERSION"] = "glibc 2.19"
        elseif arch(platform) in ("x86_64", "i686",  "powerpc64le")
            mapping["GNU_LIBC_VERSION"] = "glibc 2.17"
        elseif arch(platform) in ("riscv64",)
            mapping["GNU_LIBC_VERSION"] = "glibc 2.35"
        end
    end

    return mapping
end

const runner_override = Ref("")
function preferred_runner()
    global runner_override
    if !isempty(runner_override[])
        if runner_override[] in ("userns", "privileged")
            return UserNSRunner
        elseif runner_override[] in ("docker",)
            return DockerRunner
        end
    end

    @static if Sys.islinux()
        return UserNSRunner
    else
        return DockerRunner
    end
end

"""
    runshell(platform::AbstractPlatform = HostPlatform())

Launch an interactive shell session within the user namespace, with environment
setup to target the given `platform`.
"""
function runshell(platform::AbstractPlatform = HostPlatform(); kwargs...)
    runshell(preferred_runner(), platform; kwargs...)
end

function runshell(r::Runner, args...; kwargs...)
    run_interactive(r, `/bin/bash -l`, args...; kwargs...)
end

function runshell(::Type{R}, platform::AbstractPlatform = HostPlatform(); verbose::Bool=false,kwargs...) where {R <: Runner}
    return runshell(R(pwd(); cwd="/workspace/", platform=platform, verbose=verbose, kwargs...); verbose=verbose)
end

# The runners constructors share a large part of their setup.  This function reduces
# duplication by having bringing the common parts in one place.
function runner_setup!(workspaces, mappings, workspace_root, verbose, kwargs, platform,
                       src_name, extra_env, compiler_wrapper_path, toolchains_path, shards)
    # Check to make sure we're not going to try and bindmount within an
    # encrypted directory, as that triggers kernel bugs
    check_encryption(workspace_root; verbose=verbose)

    # Extract compilers argument
    compilers = extract_kwargs(kwargs, (:compilers,))

    if isnothing(shards)
        # Choose the shards we're going to mount
        shards::Vector{CompilerShard} = choose_shards(platform; compilers..., extract_kwargs(kwargs, (:preferred_gcc_version,:preferred_llvm_version,:bootstrap_list))...)
    end
    # Determine version of Rust toolchain
    rb = filter(s -> s.name == "RustBase", shards)
    rust_version = length(rb) == 1 ? only(rb).version : nothing

    # Determine version of GCC toolchain.
    gcc = filter(s -> s.name == "GCCBootstrap" && platforms_match(s.target, platform), shards)
    gcc_version = length(gcc) == 1 ? only(gcc).version : nothing

    clang = filter(s -> s.name == "LLVMBootstrap", shards)
    clang_version = length(clang) == 1 ? only(clang).version : nothing
    clang_use_lld = let
        kw = collect(extract_kwargs(kwargs, (:clang_use_lld,)))
        # Default `clang_use_lld` to `true` if not specified.
        value = isone(length(kw)) ? last(only(kw)) : true
        # The user can ask for using `lld` as linker with Clang, but we can
        # actually use it only under certain conditions.
        value && (!isnothing(gcc_version) && !isnothing(clang_version) && clang_version >= v"16" && gcc_version >= v"6")
    end
    # Construct environment variables we'll use from here on out
    platform::Platform = get_concrete_platform(platform; compilers..., extract_kwargs(kwargs, (:preferred_gcc_version,:preferred_llvm_version))...)
    envs::Dict{String,String} = merge(platform_envs(platform, src_name; rust_version, verbose, compilers...), extra_env)

    # JIT out some compiler wrappers, add it to our mounts
    generate_compiler_wrappers!(platform; bin_path=compiler_wrapper_path, gcc_version, clang_version, clang_use_lld, compilers..., extract_kwargs(kwargs, (:allow_unsafe_flags,:lock_microarchitecture))...)
    push!(workspaces, compiler_wrapper_path => "/opt/bin")

    if isempty(bootstrap_list)
        # Generate CMake and Meson files, only if we are not bootstrapping
        generate_toolchain_files!(platform, envs, toolchains_path; clang_use_lld=clang_use_lld)
        push!(workspaces, toolchains_path => "/opt/toolchains")

        # Generate directory where to write Cargo config files
        if isone(length(collect(compilers))) && :rust in collect(compilers)[1].second
            cargo_dir = mktempdir()
            cargo_config_file!(cargo_dir, platform)
            # Add to the list of mappings a subdirectory of ${CARGO_HOME}, whose content
            # will be put in ${CARGO_HOME}.
            push!(mappings, cargo_dir => "$(envs["CARGO_HOME"])/nonce")
        end
    end

    if libc(platform) == "musl"
        # Libraries that link to Musl C library need `libc.musl-<ARCH>.so.1`.  However in
        # our Musl toolchains we have only `libc.so` in `${sys_root}/usr/lib`, so here we
        # create a symlink `libc.musl-<ARCH>.so.1` -> `libc.so` until we fix this directly in
        # the compiler shards.
        dir = mktempdir()
        sysroot_libdir = joinpath(dir, "$(aatriplet(platform))/sys-root/usr/lib")
        mkpath(sysroot_libdir)
        symlink("libc.so", joinpath(sysroot_libdir, "libc.musl-$(map_musl_arch(platform)).so.1"))
        push!(mappings, dir => "/opt/$(aatriplet(platform))/nonce")
    end

    # the workspace_root is always a workspace, and we always mount it first
    insert!(workspaces, 1, workspace_root => "/workspace")

    # If we're enabling ccache, then mount in a read-writeable volume at /root/.ccache
    if use_ccache[]
        if !isdir(ccache_dir())
            mkpath(ccache_dir())
        end
        push!(workspaces, ccache_dir() => "/root/.ccache")
    end

    return platform, envs, shards
end
