#!/usr/bin/env bash
set -euxo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
qemu_prefix="${QEMU_PREFIX:-${HOME}/.local/ocean/qemu}"
cd "${repo_root}"

warn() {
    printf '[setup_host] warning: %s\n' "$*" >&2
}

check_rocky() {
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID}" != "rocky" ]]; then
        printf 'This script only supports Rocky Linux. Detected: %s\n' "${PRETTY_NAME}" >&2
        exit 1
    fi
}

load_gcc_toolchain() {
    if ! command -v ml >/dev/null 2>&1; then
        if [[ -f /etc/profile.d/modules.sh ]]; then
            # shellcheck disable=SC1091
            source /etc/profile.d/modules.sh
        fi
    fi

    if ! command -v ml >/dev/null 2>&1; then
        warn "Environment modules are unavailable. Load gcc/15.2.0 before running this script."
        return
    fi

    ml load gcc/15.2.0
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"
}

install_python_helpers() {
    python3 -m pip install --user --upgrade tomli gdown
}

init_submodules() {
    git submodule sync -- lib/qemu workloads/tigon || true
    git submodule update --init --recursive lib/qemu workloads/tigon
}

build_qemu() {
    pushd lib/qemu
    mkdir -p build
    pushd build
    CC="${CC:-gcc}" CXX="${CXX:-g++}" ../configure --prefix="${qemu_prefix}" --target-list=x86_64-softmmu --enable-debug --enable-libpmem --enable-slirp
    make -j"$(nproc)"
    make install
    popd
    popd

    printf 'QEMU installed under %s. Add %s/bin to PATH or set QEMU_BINARY explicitly.\n' "${qemu_prefix}" "${qemu_prefix}"
}

main() {
    check_rocky
    load_gcc_toolchain
    init_submodules
    install_python_helpers
    build_qemu
}

main "$@"
