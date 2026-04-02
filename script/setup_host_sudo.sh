#!/usr/bin/env bash
set -euxo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

check_rocky() {
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID}" != "rocky" ]]; then
        printf 'This script only supports Rocky Linux. Detected: %s\n' "${PRETTY_NAME}" >&2
        exit 1
    fi
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        printf 'Run this script as root.\n' >&2
        exit 1
    fi
}

install_packages() {
    dnf install -y epel-release dnf-plugins-core
    dnf config-manager --set-enabled crb || true
    dnf makecache
    dnf install -y \
        llvm-devel libbpf-devel clang-devel cxxopts-devel boost-devel fmt-devel spdlog-devel \
        glib2-devel libgcrypt-devel pixman-devel ninja-build debootstrap \
        libcap-ng-devel libslirp-devel libpmem-devel
}

main() {
    check_rocky
    check_root
    install_packages
}

main "$@"
