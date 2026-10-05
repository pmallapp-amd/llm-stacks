# meson.build for the xNVMe NVMe-KV NIXL plugin.
# Links against a pre-built libxnvme (shared lib) instead of a KV-patched
# SPDK/DPDK static archive set — see nvme-kv-plugin/meson.build for that
# comparison. libxnvme is a normal shared library (libxnvme.so + headers),
# so this build is much simpler than the SPDK plugin's static-archive dance.
#
# Required options:
#   -Dnixl_path=/usr/local/nixl     NIXL install prefix
#   -Dxnvme_incdir=/usr/local/include        libxnvme.h location
#   -Dxnvme_libdir=/usr/local/lib/x86_64-linux-gnu   libxnvme.so location
#   -Drocm_path=/opt/rocm           ROCm install prefix (staged VRAM_SEG support)
project('nixl-xnvme-kv-plugin', 'cpp',
    version: '0.1.0',
    default_options: ['cpp_std=c++17', 'buildtype=release'])

nixl_path    = get_option('nixl_path')
xnvme_incdir = get_option('xnvme_incdir')
xnvme_libdir = get_option('xnvme_libdir')
rocm_path    = get_option('rocm_path')
arch = host_machine.cpu_family()
nixl_lib_dir = nixl_path + '/lib/' + arch + '-linux-gnu'
plugin_install_dir = get_option('prefix') + '/lib/' + arch + '-linux-gnu/plugins'

nixl_dep = declare_dependency(
    include_directories: include_directories(
        nixl_path + '/include',
        nixl_path + '/include/backend',
        nixl_path + '/include/utils',
    ),
    link_args: [
        '-L' + nixl_lib_dir,
        '-lnixl',
        '-Wl,-rpath,' + nixl_lib_dir,
    ])

xnvme_dep = declare_dependency(
    include_directories: include_directories(xnvme_incdir),
    link_args: [
        '-L' + xnvme_libdir,
        '-lxnvme',
        '-Wl,-rpath,' + xnvme_libdir,
        # io_uring_cmd / io_uring backends' own deps (matches kv_bench_xnvme/Makefile).
        '-luring', '-laio', '-lpthread', '-ldl', '-lrt', '-lm',
    ])

thread_dep = dependency('threads')

# Staged VRAM_SEG support (hipMemcpy through a host staging buffer). Mirrors
# nvme-kv-plugin/meson.build's rocm_dep. Optional — disable with
# -Denable_vram=false on GPU-less hosts (e.g. .59).
enable_vram = get_option('enable_vram')
extra_deps = []
extra_cpp_args = []
extra_install_rpath = ''
if enable_vram
    extra_deps += declare_dependency(
        include_directories: include_directories(rocm_path + '/include'),
        link_args: [
            '-L' + rocm_path + '/lib',
            '-lamdhip64',
            '-Wl,-rpath,' + rocm_path + '/lib',
        ])
    extra_cpp_args += '-D__HIP_PLATFORM_AMD__'
    extra_install_rpath = ':' + rocm_path + '/lib'
else
    extra_cpp_args += '-DNIXL_XNVME_NO_VRAM'
endif

shared_library('plugin_XNVME_KV',
    'xnvme_kv_backend.cpp',
    'xnvme_kv_plugin.cpp',
    # '.' not 'src': sources and headers sit flat beside this meson.build.
    include_directories: [include_directories('.')],
    dependencies: [nixl_dep, xnvme_dep, thread_dep] + extra_deps,
    cpp_args: ['-fPIC', '-Wno-unused-function'] + extra_cpp_args,
    # absl symbols resolved at runtime from libnixl.so
    link_args: ['-Wl,--allow-shlib-undefined'],
    name_prefix: 'lib',
    install: true,
    install_dir: plugin_install_dir,
    install_rpath: nixl_lib_dir + ':' + xnvme_libdir + extra_install_rpath)
