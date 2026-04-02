#!/usr/bin/env bash
set -euxo pipefail

readonly QEMU_URL="https://github.com/CXLMemUring/qemu"
readonly TIGON_URL="https://github.com/CXLMemUring/tigon"

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
    if ! command -v ml >/dev/null 2>&1 && [[ -f /etc/profile.d/modules.sh ]]; then
        # shellcheck disable=SC1091
        source /etc/profile.d/modules.sh
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

is_git_submodule_path() {
    local path="$1"
    git ls-files --stage -- "$path" | awk '$1 == "160000" { found = 1 } END { exit(found ? 0 : 1) }'
}

ensure_repo_path() {
    local path="$1"
    local url="$2"

    if [[ -d "$path" ]]; then
        return 0
    fi

    if is_git_submodule_path "$path"; then
        git submodule sync -- "$path"
        git submodule update --init --recursive "$path"
        return 0
    fi

    mkdir -p "$(dirname "$path")"
    git clone "$url" "$path"
}

resolve_qemu_dir() {
    if [[ -d library/qemu ]]; then
        printf 'library/qemu\n'
        return 0
    fi

    ensure_repo_path lib/qemu "${QEMU_URL}"
    printf 'lib/qemu\n'
}

ensure_tigon_dir() {
    ensure_repo_path workloads/tigon "${TIGON_URL}"
}

build_qemu() {
    local qemu_dir
    qemu_dir="$(resolve_qemu_dir)"

    pushd "$qemu_dir"
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
    ensure_tigon_dir
    install_python_helpers
    build_qemu
}

main "$@"
