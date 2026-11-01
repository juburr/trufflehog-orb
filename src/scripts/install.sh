#!/bin/bash
#
# Installs TruffleHog for the install command: the Linux amd64 or arm64 build
# that matches this machine, verified against the checksum table in this file
# before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (TruffleHog only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing TruffleHog needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="trufflehog-orb"
TOOL_NAME="TruffleHog"
TOOL_BINARY="trufflehog"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="bin"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    printf 'trufflehog_%s_linux_%s.tar.gz\n' "$1" "$2"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order: GitHub Releases, or the download_base_url mirror in its
# place.
tool_asset_urls() {
    printf '%s/trufflesecurity/trufflehog/releases/download/v%s/%s\n' \
        "${TRUFFLEHOG_DOWNLOAD_BASE_URL:-https://github.com}" "$1" "$3"
}

# tool_archive_member VERSION ARCH: the binary's path inside the asset. The
# checksum table holds the SHA-512 of that file.
tool_archive_member() {
    printf 'trufflehog\n'
}

# tool_version BINARY: prints the installed version without using the
# network. --version exits while the flags are parsed, before TruffleHog's
# updater would call home; --no-update keeps it that way if that ever
# changes. The variables that make TruffleHog's process supervisor print
# their value and exit 0 in place of running are cleared.
tool_version() {
    env -u OVERSEER_BIN_CHECK -u GO_UPGRADE_BIN_CHECK -u OVERSEER_IS_SLAVE "$1" --no-update --version
}

# trufflehog_download_base_url: sets TRUFFLEHOG_DOWNLOAD_BASE_URL from the
# download_base_url parameter, which replaces https://github.com in the
# download URL, so the same file comes from an internal mirror such as
# Artifactory, Nexus or S3. The checksum table, not the mirror, decides what
# is installed.
trufflehog_download_base_url() {
    local authority
    TRUFFLEHOG_DOWNLOAD_BASE_URL=$(orb_subst "${PARAM_DOWNLOAD_BASE_URL:-}")
    TRUFFLEHOG_DOWNLOAD_BASE_URL=${TRUFFLEHOG_DOWNLOAD_BASE_URL%/}
    if [[ -z "${TRUFFLEHOG_DOWNLOAD_BASE_URL}" ]]; then
        return 0
    fi
    # Credentials in the URL would show in the log and on curl's command
    # line, so they are refused before the URL is printed anywhere.
    authority=${TRUFFLEHOG_DOWNLOAD_BASE_URL#*://}
    if [[ "${authority%%/*}" == *@* ]]; then
        orb_die "download_base_url must not hold credentials (user:password@ before the host): they would show in the log and on curl's command line."
    fi
    # Nor can a query or fragment, which can hold a token too, and would end
    # up in the middle of every download URL.
    if [[ "${TRUFFLEHOG_DOWNLOAD_BASE_URL}" == *[?#]* ]]; then
        orb_die "download_base_url must not have a query or fragment (? or #): it could hold a token, which would show in the log."
    fi
    if [[ ! "${TRUFFLEHOG_DOWNLOAD_BASE_URL}" =~ ^https://[^[:space:]\"\'\<\>\\]+$ ]]; then
        orb_die "download_base_url must be an https:// URL, not '${TRUFFLEHOG_DOWNLOAD_BASE_URL}'."
    fi
    orb_info "  download mirror:  ${TRUFFLEHOG_DOWNLOAD_BASE_URL} (in place of https://github.com)"
}

# tool_install: the shared single-binary install, from the mirror when one is
# given.
tool_install() {
    trufflehog_download_base_url
    orb_install_binary
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            # Like saving it, removing it is best-effort: a read-only cache
            # directory only means the download isn't cached.
            rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
#
# The table starts at 3.97.0. 3.99.5 was tagged but has no release assets.
declare -A sha512sums=(
    ["3.99.7/amd64"]="1e44a8efdc1667841de13d5d09a7740b4dcfdc5781b3031f9d7afbffac4ba6f68c05809b0aef7bb916234c17fd32cd24e68ef249058ea0744a5cc1c9ea590800"
    ["3.99.7/arm64"]="cb308721f2471b958476e4d8d2fe0ad1c58aee104f5b99ba35c391b0ead9e9078635e3e82363cb210fc26b1ec35cd2117e6833985b97a8018590e5a993760c54"
    ["3.99.6/amd64"]="ba809644a5e32f30935bf762fbca1e92ca85130d132fd7168cae6f8d7c6298edf7309873fa71eb7ac43e280fd6da6ec30283ab265e7676f043418c6cff9c7798"
    ["3.99.6/arm64"]="b52a6e0ee5d943f8bdc8a672df728d4d548159bd00812ece6c33047cfc76cb9b28fd8ea63b97ca2bc8f4faf31f6ab2968ccd23525d0a5d20018fa9e893d8bff8"
    ["3.99.4/amd64"]="8886ebde389d88e72784444efca3dd22dcb494815cc4f1358db97712bb796106ac4b95bc91428d007327d2604bb89a1480e990a34c7ef109f31e64f92c667803"
    ["3.99.4/arm64"]="61db3f62bc213b10b92201a65e409a5c13b67e0cd0294441a3df52808c8ffa4ce0485e2062140ab4b3827e2febb84df8be3658d4627bc5f9b6e0fa0a69341923"
    ["3.99.3/amd64"]="438bc31a5c3204380c937f5cfaedb004f8c649757a4b623b79167158b99f9ba6802e10eceb30b11070cadfd270dd35f06f461940ec5a228635dd2c0c2076929c"
    ["3.99.3/arm64"]="3393c276791de2bb47f7b91dd780a729bc0d9c533758931d18ac34979edc73c32ba329b90e850bdcd729f13bcb1300d8592837a16d7ca0087188711b6a2487ea"
    ["3.99.2/amd64"]="dc2d3f34c5f044f81218550fbbcd3a55bf3bafdeb84df325e88314ba3feed1d878e6f04ee00b893fd3508346a63be4c3ea0f939ff71c6863e90baa12d580f5de"
    ["3.99.2/arm64"]="d6ebe72e223963a639888b85b3f35b0560da0aacfb6de5ddd98588ca9d5c457e6dd2590a1fece6aee516c956b366a3a726e438b2e5ac9d4197549b194825cda0"
    ["3.99.1/amd64"]="aa7978a747b1fe2013ab71ce6ce40e28c500e99fabb585163773e14b4fb235fc47c2542b9377282870ae23247fb26e9303d4ec17ebd62391611528a0cf85d460"
    ["3.99.1/arm64"]="3dc2ab52c9dcb27511c839cbb66a71787940c82b4d31568f6cf74e73a2c4564cd9043cec9a175d7041927bc46e4c16efdb7f9852292d5d2b4422259e080b99c8"
    ["3.99.0/amd64"]="627ef10ada1ad9b6e546dff73b39c90803a9c36d2a0d76235fa6263724635dcba1b7aae860273f8096f75f13b82629cb403b341290e9a6b86889cd7d535174e4"
    ["3.99.0/arm64"]="84b7d8b16f7631767ff4384f7e5b6e097d37cd97c44ae02e7fe1921ce8f0ce44772746781dbbf3f6261aa508ea2de6c7c3ce81b0c823721c8a536090f54dbc72"
    ["3.98.1/amd64"]="ba25cd00cdc94249964bfd3db9b676f041c905fa2d43e044250ca3cb6275bdb214d04e5bab6ea0c60cd0ff678303a1b687c472c1c3e66181c22409278e78fb44"
    ["3.98.1/arm64"]="d1b9f34a04a52cba06f277af15bf66afa09bdc8c110165d3e8967ba94685c9ffa9bc851d396add154d6eb9915293d739c68a93fac6a2f56fd66eefec66266eac"
    ["3.98.0/amd64"]="2b4f4456a9e0fa3e83b5cf7996374011f0c5a13bd8d21a9afe3015afaff81f9dba7c12fb62a5936882f8791187882d724e27336c8fa7b4f6dbf02970bdd09205"
    ["3.98.0/arm64"]="cc2d192060d2f99caecc6944e16eb2caf791168b617fb033c405655b12aeb6eded10473ab118dabe30c59f817b874675a008fa2926bfd00605da3ce06383269d"
    ["3.97.9/amd64"]="f5d5816d1b23d9292f27de1a556e6e8cb86fde07c43822e5827a2da82943dbf5b25677c18c46295bb5de1a44a70c902f75990a7f0c3ccba7613566f79db9eca0"
    ["3.97.9/arm64"]="9d93a2944ee53302ba94bb9db27f1d6f0fd39e8e5010aa32e081703fcf40d80b6abdb3970539e20de7c2655df22bfa8bd7fba5af98e35c9efd1a21c786592ae1"
    ["3.97.8/amd64"]="5165c6757dd1f9f4aaaf750cb22408151d4c4c72c3baea3c9700d68d9a5390516272a7ae62711116f45524d64b152d128f7122c99a6a3a4412ef462b8166d78a"
    ["3.97.8/arm64"]="c3e602a223e5e9c20354a48418a74b25a99a669e290ae57b3b82d56e6b7faf769bd8641c48969ce1055352f2e3a4b0aa847e6e17ae59b7353f86ce5e16a3bdf8"
    ["3.97.7/amd64"]="81acd783dcc42abdd0bfdfc37fc78f53409ab4fcbe58ac08ce45b06c26882523155d7a67bde8c3c65b6eb5927da19b6fd1400235a4d9eec1a0c9532f23e03e6b"
    ["3.97.7/arm64"]="032f2fd57eae7fd06f408baee76663c6b1c14452e3a81ce69ab94f9b5522a6f55b92f7fa6d01007412e449d3e58bc8fc3e6d65553668208e962d5a0d30b35d1d"
    ["3.97.6/amd64"]="d3c1d70ed74776b5844e3e5db6c94465ab2cbbd42798da07af98d0f856846c4371439af24aacc1ac41bbd384a9331709fc72b6cf3535f83bbd95a2f84b898991"
    ["3.97.6/arm64"]="76d9d831b368457aa9e5494a502cd80235c117ffbf4ba88ab7391a4dce694df172bc7f317634b8c364f603a13688d5b8e2bd55fc3ec2634bb884417dfa514a20"
    ["3.97.5/amd64"]="6ea72b6449dc7eb4e501531c639f994e48612153613c40489f580904ae02550907454a6ac8077c3ef076143b3a2e9e50e3cf38278652d0a4398a24e4816fc272"
    ["3.97.5/arm64"]="9aeabf08e7ec859f4b4f5fefbc05fcb88986dce0f4b755a50eb265eb1c3484190f4ae21407cce6950553580a88060fe994c2fae27f4837dd55f53593d8ace5b0"
    ["3.97.4/amd64"]="ac43fca128aca90484cf911f5feff4a701d83a6906c7b46961bab5d8e8bc17b4382fc8071218bea58d02945a8b5b37ce2ca2f4d554842eb7eb4f41c96ea3286f"
    ["3.97.4/arm64"]="8d7b14b501083d8a599f2298ddfe56c35b577fb38aaf1b39b5b04fc558b207acadfc6bd287b857dec9508e21094213a9b4fa41adb57f65f4a31677f3bcf3b4b7"
    ["3.97.3/amd64"]="aae599d45b4d9fdf65780764ec832578a0433b0f89a6fc36d53dea452a1055b2bf8964c2ad56202c9fc08efecf9232a897c160b1742e04393580f43ed17a4b43"
    ["3.97.3/arm64"]="ddeda12d5598776ad2bfc8a2d695e2a00ecaae31354d8fd461fc832345353ff52b0fcd97d1f40cd12086e71c4244605e80827d6b5d1c82b9264d649f0a35e138"
    ["3.97.2/amd64"]="104bd13f606e5f980f4e21ea3b6349dd00f51da9b024165004832cd90a1e942d6dc236d4666b5e4001450945ca3ca543a0b6cf5e0a153f3e04d0c57e4eec74fe"
    ["3.97.2/arm64"]="502678af5c025607f766f26d710fb6d30358f7af98c361676e5034cbe4b0b1b65e48cf62f2a546dcc66e361a53e84a0261b3357dbd3237b1e33315e1d352bdca"
    ["3.97.1/amd64"]="26f670874f924072459e07ea52b7917991298f9cf9f512f395709ee03dd89108911976d2d126f57b083ce17860f91ee48519d131b2cbca811ef05cb2ac53dbee"
    ["3.97.1/arm64"]="55b730314e5db6817fac0e65d4200cf95208af846aaf666c4c7a3773fe71479e9dab9c04bbfbbbeba294c302a11ef68bf494033ea0424d2ece7fdb93f0e4ac1f"
    ["3.97.0/amd64"]="55cb5a7247c45b452a0391e5c384f1be91e5d9c93251c38d08165b2807940556a5a9d3d7810f1ead847a6a7582a4a394b2a13c294db460a631a8d299f1d304db"
    ["3.97.0/arm64"]="ae1e59814d29f396b6a3589b61261222ef8ccbe25105556dca4ecefe1aabf6167ab5f1e3b9e6302508f6815f210a9052a1179beb7aeb80a8830579baeedf782f"
)
# <<< checksum table <<<

orb_install_main
