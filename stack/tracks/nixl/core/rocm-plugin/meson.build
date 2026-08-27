# meson.build for the AMD ROCm NIXL plugin.
# Builds libplugin_AMD_ROCM.so against an installed upstream NIXL.
#
# Required options:
#   -Dnixl_path=/usr/local/nixl   NIXL install prefix
#   -Drocm_path=/opt/rocm         ROCm install prefix
#
# Output is installed to <prefix>/lib/x86_64-linux-gnu/plugins/
# so that NIXL's dlopen scan picks it up when
#   NIXL_PLUGIN_DIR=<prefix>/lib/x86_64-linux-gnu/plugins
project('nixl-rocm-plugin', 'cpp',
    version: '0.1.0',
    default_options: ['cpp_std=c++17', 'buildtype=release'])


nixl_path = get_option('nixl_path')
rocm_path = get_option('rocm_path')
arch = host_machine.cpu_family()
nixl_lib_dir = nixl_path + '/lib/' + arch + '-linux-gnu'
plugin_install_dir = get_option('prefix') + '/lib/' + arch + '-linux-gnu/plugins'

nixl_dep = declare_dependency(
    include_directories: include_directories(
        nixl_path + '/include',
        nixl_path + '/include/backend',
        nixl_path + '/include/utils',      # for common/nixl_log.h
    ),
    link_args: [
        '-L' + nixl_lib_dir,
        '-lnixl',
        '-Wl,-rpath,' + nixl_lib_dir,
    ])

rocm_dep = declare_dependency(
    include_directories: include_directories(
        rocm_path + '/include',
    ),
    link_args: [
        '-L' + rocm_path + '/lib',
        '-lamdhip64',
        '-Wl,-rpath,' + rocm_path + '/lib',
    ])

uring_dep = dependency('liburing')

shared_library('plugin_AMD_ROCM',
    'src/rocm_backend.cpp',
    'src/rocm_plugin.cpp',
    include_directories: include_directories('src'),
    dependencies: [nixl_dep, rocm_dep, uring_dep],
    cpp_args: ['-fPIC', '-Wno-unused-function', '-D__HIP_PLATFORM_AMD__'],
    name_prefix: 'lib',
    install: true,
    install_dir: plugin_install_dir,
    install_rpath: nixl_lib_dir + ':' + rocm_path + '/lib')
