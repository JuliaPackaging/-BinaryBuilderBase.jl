abstract type AbstractBuildToolchain{C} end

struct CMake{C} <: AbstractBuildToolchain{C} end
struct Meson{C} <: AbstractBuildToolchain{C} end

c_compiler(::AbstractBuildToolchain{:clang}) = "clang"
cxx_compiler(::AbstractBuildToolchain{:clang}) = "clang++"
c_compiler(::AbstractBuildToolchain{:gcc}) = "gcc"
cxx_compiler(::AbstractBuildToolchain{:gcc}) = "g++"
fortran_compiler(::AbstractBuildToolchain) = "gfortran"

function cmake_arch(p::AbstractPlatform)
    if arch(p) == "powerpc64le"
        return "ppc64le"
    else
        return arch(p)
    end
end

function cmake_os(p::AbstractPlatform)
    if Sys.islinux(p)
        return "Linux"
    elseif Sys.isfreebsd(p)
        return "FreeBSD"
    elseif Sys.isapple(p)
        return "Darwin"
    elseif Sys.iswindows(p)
        return "Windows"
    end
end

function toolchain_file(bt::CMake, p::AbstractPlatform; is_host::Bool=false)
    target = triplet(p)
    aatarget = aatriplet(p)

    # CMake uses the setting of `HOST_SYSTEM_NAME` and `SYSTEM_NAME` to decide
    # whether the current build is a cross-compilation or not:
    # <https://cmake.org/cmake/help/latest/variable/CMAKE_CROSSCOMPILING.html>.
    # We want to have the host toolchain always setting `HOST_SYSTEM_NAME`, and
    # the target toolchain always setting `SYSTEM_NAME`.
    system_name_var = if is_host
        "CMAKE_HOST_SYSTEM_NAME"
    else
        "CMAKE_SYSTEM_NAME"
    end

    if Sys.isapple(p)
        darwin_ver = something(os_version(p), v"14.5.0")
        maj_ver = darwin_ver.major
        min_ver = darwin_ver.minor
        return """
        # CMake toolchain file for $(c_compiler(bt)) running on $(target)
        set($(system_name_var) $(cmake_os(p)))
        set(CMAKE_SYSTEM_PROCESSOR $(cmake_arch(p)))
        set(CMAKE_SYSTEM_VERSION $(maj_ver).$(min_ver))
        set(DARWIN_MAJOR_VERSION $(maj_ver))
        set(DARWIN_MINOR_VERSION $(min_ver))

        # Enable rpath support
        set(CMAKE_SHARED_LIBRARY_RUNTIME_C_FLAG "-Wl,-rpath,")

        set(CMAKE_SYSROOT /opt/$(aatarget)/$(aatarget)/sys-root)
        set(CMAKE_SYSTEM_FRAMEWORK_PATH
            \${CMAKE_SYSROOT}/System/Library/Frameworks
            \${CMAKE_SYSROOT}/System/Library/PrivateFrameworks
        )
        set(CMAKE_INSTALL_PREFIX \$ENV{prefix})

        set(CMAKE_C_COMPILER   /opt/bin/$(target)/$(aatarget)-$(c_compiler(bt)))
        set(CMAKE_CXX_COMPILER /opt/bin/$(target)/$(aatarget)-$(cxx_compiler(bt)))
        set(CMAKE_Fortran_COMPILER /opt/bin/$(target)/$(aatarget)-$(fortran_compiler(bt)))

        set(CMAKE_LINKER  /opt/bin/$(target)/$(aatarget)-ld)
        set(CMAKE_OBJCOPY /opt/bin/$(target)/$(aatarget)-objcopy)

        set(CMAKE_AR     /opt/bin/$(target)/$(aatarget)-ar)
        set(CMAKE_NM     /opt/bin/$(target)/$(aatarget)-nm)
        set(CMAKE_RANLIB /opt/bin/$(target)/$(aatarget)-ranlib)

        if( \$ENV{CC} MATCHES ccache )
            set_property(GLOBAL PROPERTY RULE_LAUNCH_COMPILE ccache)
        endif()
        """
    else
        return """
        # CMake toolchain file for $(c_compiler(bt)) running on $(target)
        set($(system_name_var) $(cmake_os(p)))
        set(CMAKE_SYSTEM_PROCESSOR $(cmake_arch(p)))

        set(CMAKE_SYSROOT /opt/$(aatarget)/$(aatarget)/sys-root/)
        set(CMAKE_INSTALL_PREFIX \$ENV{prefix})

        set(CMAKE_C_COMPILER   /opt/bin/$(target)/$(aatarget)-$(c_compiler(bt)))
        set(CMAKE_CXX_COMPILER /opt/bin/$(target)/$(aatarget)-$(cxx_compiler(bt)))
        set(CMAKE_Fortran_COMPILER /opt/bin/$(target)/$(aatarget)-$(fortran_compiler(bt)))

        set(CMAKE_LINKER  /opt/bin/$(target)/$(aatarget)-ld)
        set(CMAKE_OBJCOPY /opt/bin/$(target)/$(aatarget)-objcopy)

        set(CMAKE_AR     /opt/bin/$(target)/$(aatarget)-ar)
        set(CMAKE_NM     /opt/bin/$(target)/$(aatarget)-nm)
        set(CMAKE_RANLIB /opt/bin/$(target)/$(aatarget)-ranlib)

        if( \$ENV{CC} MATCHES ccache )
            set_property(GLOBAL PROPERTY RULE_LAUNCH_COMPILE ccache)
        endif()
        """
    end
end

meson_c_args(p::AbstractPlatform, envs::Dict{String,String}; is_host::Bool=false) =
    ["'-I$(envs[is_host ? "host_includedir" : "includedir"])'"]
meson_cxx_args(p::AbstractPlatform, envs::Dict{String,String}; is_host::Bool=false) = meson_c_args(p, envs; is_host)
meson_objc_args(p::AbstractPlatform, envs::Dict{String,String}; is_host::Bool=false) = push!(meson_c_args(p, envs; is_host), "'-x'", "'objective-c'")
meson_fortran_args(p::AbstractPlatform, envs::Dict{String,String}; is_host::Bool=false) = meson_c_args(p, envs; is_host)

function meson_c_link_args(p::AbstractPlatform, envs::Dict{String,String}; is_host::Bool=false)
    prefix, libdir = envs[is_host ? "host_prefix" : "prefix"], envs[is_host ? "host_libdir" : "libdir"]
    if arch(p) == "powerpc64le" && Sys.islinux(p)
        return ["'-L$(libdir)'", "'-Wl,-rpath-link,$(prefix)/lib64'"]
    else
        return ["'-L$(libdir)'"]
    end
end
meson_cxx_link_args(p::AbstractPlatform, envs::Dict{String,String}; is_host::Bool=false) = meson_c_link_args(p, envs; is_host)
meson_objc_link_args(p::AbstractPlatform, envs::Dict{String,String}; is_host::Bool=false) = meson_c_link_args(p, envs; is_host)
meson_fortran_link_args(p::AbstractPlatform, envs::Dict{String,String}; is_host::Bool=false) = meson_c_link_args(p, envs; is_host)

# We can run native programs only if the platform matches the default host
# platform, but when this is `x86_64-linux-musl` we can run executables for
# * i686-linux-gnu
# * x86_64-linux-gnu
# * x86_64-linux-musl
function meson_is_foreign(p::AbstractPlatform; is_host::Bool=false)
    is_host && return "false"
    if platforms_match(p, default_host_platform) ||
        (platforms_match(default_host_platform, Platform("x86_64", "linux"; libc="musl"))
         && Sys.islinux(p) && proc_family(p) == "intel" &&
             (libc(p) == "glibc" || (libc(p) == "musl" && arch(p) == "x86_64")))
        # Better to explicitly return the string we expect rather than
        # relying on the representation of the boolean values (even though
        # the result is the same)
        return "false"
    else
        return "true"
    end
end

# https://mesonbuild.com/Reference-tables.html#operating-system-names
meson_system(p::AbstractPlatform) = lowercase(cmake_os(p))

# https://github.com/mesonbuild/meson/blob/6e39dcad2fbd8d1c739e262b0e7b7d901cf1ce08/mesonbuild/environment.py#L412-L440
meson_cpu(p::AbstractPlatform) = cmake_arch(p)

# https://mesonbuild.com/Reference-tables.html#cpu-families
function meson_cpu_family(p::AbstractPlatform)
    if arch(p) == "powerpc64le"
        return "ppc64"
    elseif arch(p) == "i686"
        return "x86"
    elseif arch(p) == "x86_64"
        return "x86_64"
    elseif arch(p) == "aarch64"
        return "aarch64"
    elseif startswith(arch(p), "arm")
        return "arm"
    end
end

function toolchain_file(bt::Meson, p::AbstractPlatform, envs::Dict{String,String};
                        is_host::Bool=false)
    target = triplet(p)
    aatarget = aatriplet(p)

    return """
    [binaries]
    c = '/opt/bin/$(target)/$(aatarget)-$(c_compiler(bt))'
    cpp = '/opt/bin/$(target)/$(aatarget)-$(cxx_compiler(bt))'
    fortran = '/opt/bin/$(target)/$(aatarget)-$(fortran_compiler(bt))'
    objc = '/opt/bin/$(target)/$(aatarget)-cc'
    ar = '/opt/bin/$(target)/$(aatarget)-ar'
    ld = '/opt/bin/$(target)/$(aatarget)-ld'
    nm = '/opt/bin/$(target)/$(aatarget)-nm'
    strip = '/opt/bin/$(target)/$(aatarget)-strip'
    pkgconfig = '/usr/bin/pkg-config'

    [built-in options]
    c_args = [$(join(meson_c_args(p, envs; is_host), ", "))]
    cpp_args = [$(join(meson_cxx_args(p, envs; is_host), ", "))]
    fortran_args = [$(join(meson_fortran_args(p, envs; is_host), ", "))]
    objc_args = [$(join(meson_objc_args(p, envs; is_host), ", "))]
    c_link_args = [$(join(meson_c_link_args(p, envs; is_host), ", "))]
    cpp_link_args = [$(join(meson_cxx_link_args(p, envs; is_host), ", "))]
    fortran_link_args = [$(join(meson_fortran_link_args(p, envs; is_host), ", "))]
    objc_link_args = [$(join(meson_objc_link_args(p, envs; is_host), ", "))]
    prefix = '$(envs[is_host ? "host_prefix" : "prefix"])'

    [properties]
    needs_exe_wrapper = $(meson_is_foreign(p; is_host))
    cmake_toolchain_file = '$(envs[is_host ? "CMAKE_HOST_TOOLCHAIN" : "CMAKE_TARGET_TOOLCHAIN"])'
    cmake_defaults = false

    [build_machine]
    system = 'linux'
    cpu_family = 'x86_64'
    cpu = 'x86_64'
    endian = 'little'

    [host_machine]
    system = '$(meson_system(p))'
    cpu_family = '$(meson_cpu_family(p))'
    cpu = '$(meson_cpu(p))'
    endian = 'little'
    """
end

function generate_toolchain_files!(platform::AbstractPlatform, envs::Dict{String,String},
                                   toolchains_path::AbstractString;
                                   host_platform::AbstractPlatform = default_host_platform,
                                   )

    # Generate the files fot bot the host and the target platforms
    for p in unique((platform, host_platform))
        dir = joinpath(toolchains_path, triplet(p))
        mkpath(dir)

        for compiler in (:clang, :gcc)
            # Target toolchains
            if platforms_match(p, platform)
                write(joinpath(dir, "target_$(aatriplet(p))_$(compiler).cmake"), toolchain_file(CMake{compiler}(), p; is_host=false))
                write(joinpath(dir, "target_$(aatriplet(p))_$(compiler).meson"), toolchain_file(Meson{compiler}(), p, envs; is_host=false))
            end
            # Host toolchains
            if platforms_match(p, host_platform)
                write(joinpath(dir, "host_$(aatriplet(p))_$(compiler).cmake"), toolchain_file(CMake{compiler}(), p; is_host=true))
                write(joinpath(dir, "host_$(aatriplet(p))_$(compiler).meson"), toolchain_file(Meson{compiler}(), p, envs; is_host=true))
            end
        end

        symlink_if_exists(target, link) = ispath(joinpath(dir, target)) && symlink(target, link)

        # On FreeBSD and MacOS we actually want to default to clang, otherwise gcc
        if Sys.isbsd(p)
            symlink_if_exists("host_$(aatriplet(p))_clang.cmake", joinpath(dir, "host_$(aatriplet(p)).cmake"))
            symlink_if_exists("host_$(aatriplet(p))_clang.meson", joinpath(dir, "host_$(aatriplet(p)).meson"))
            symlink_if_exists("target_$(aatriplet(p))_clang.cmake", joinpath(dir, "target_$(aatriplet(p)).cmake"))
            symlink_if_exists("target_$(aatriplet(p))_clang.meson", joinpath(dir, "target_$(aatriplet(p)).meson"))
        else
            symlink_if_exists("host_$(aatriplet(p))_gcc.cmake", joinpath(dir, "host_$(aatriplet(p)).cmake"))
            symlink_if_exists("host_$(aatriplet(p))_gcc.meson", joinpath(dir, "host_$(aatriplet(p)).meson"))
            symlink_if_exists("target_$(aatriplet(p))_gcc.cmake", joinpath(dir, "target_$(aatriplet(p)).cmake"))
            symlink_if_exists("target_$(aatriplet(p))_gcc.meson", joinpath(dir, "target_$(aatriplet(p)).meson"))
        end
    end
end

function cargo_config_file!(dir::AbstractString)
    # Generate "${CARGO_HOME}/config.toml" file for Cargo where we give it the
    # linkers for all our targets
    open(joinpath(dir, "config.toml"), "w") do io
        write(io, """
        # Configuration file for `cargo`
        """)
        for platform in supported_platforms(; experimental=true)
            # Use `aatriplet` for the linker to match how the wrappers are
            # written in
            # https://github.com/JuliaPackaging/BinaryBuilderBase.jl/blob/30d056ef68f81dca9cb91ededcce6b68c6466b37/src/Runner.jl#L599.
            write(io, """
            [target.$(map_rust_target(platform))]
            linker = "$(aatriplet(platform))-gcc"
            """)
        end
    end
end
