#!/bin/bash
#
# Prints checksum table entries for a TruffleHog release, ready to paste into
# the sha512sums table in install.sh. A development helper: the orb never
# runs it.
#
#   src/scripts/install_hash.sh -v <version> [-a "<arch> ..."] [-c <checksum>]
#
#   -a  architectures to hash (default: every one install.sh supports)
#   -c  a checksum for the asset from another official source, as
#       SHA-256:<hex> or SHA1:<hex>, for a release whose published checksums
#       don't cover it (verify_upstream finds nothing); or NONE to add an
#       entry that is not anchored to any published checksum. -c never
#       overrides a failure to fetch or verify what TruffleHog did publish:
#       re-run once the source is reachable.
#
# Each asset is checked against what the TruffleHog project published for the
# release before its entry is printed (see verify_upstream). Entries go to
# stdout and everything else to stderr, so the output can be pasted as is.
# Needs cosign 2 (the releases carry a detached signature and certificate,
# which cosign 2 verifies against the transparency log) and openssl besides
# the shared logic's tools.

set -euo pipefail

# >>> upstream verification >>>
# A release whose checksums were signed fewer than this many days ago is
# refused, so a compromise has time to come to light before the release
# reaches the table. Set TRUFFLEHOG_MIN_RELEASE_AGE_DAYS=0 to add a newer
# release after checking TruffleHog's advisories for it.
TRUFFLEHOG_MIN_RELEASE_AGE_DAYS=${TRUFFLEHOG_MIN_RELEASE_AGE_DAYS:-7}

# verify_upstream VERSION ARCH ASSET: checks ASSET against
# trufflehog_<version>_checksums.txt, the SHA-256 list TruffleHog publishes
# with each release, after cosign verifies that list's keyless signature
# (trufflehog_<version>_checksums.txt.sig, with the certificate in .pem):
# signed by the release workflow of trufflesecurity/trufflehog at the tag
# v<version>, and at least TRUFFLEHOG_MIN_RELEASE_AGE_DAYS days ago. Returns
# 0 when it matches, 2 when nothing was published, and 1 otherwise.
verify_upstream() {
    local base="https://github.com/trufflesecurity/trufflehog/releases/download/v$1" name=${3##*/}
    local list="trufflehog_$1_checksums.txt" published actual identity signed age rc=0 suffix
    hash_fetch "${base}/${list}" list || rc=$?
    if [[ "${rc}" -eq 2 ]]; then
        echo "TruffleHog $1 publishes no ${list}."
        return 2
    elif [[ "${rc}" -ne 0 ]]; then
        return 1
    fi
    # Every release since 3.63.2 signs the list, and the table starts long
    # after that, so a missing signature or certificate is an error.
    for suffix in sig pem; do
        rc=0
        hash_fetch "${base}/${list}.${suffix}" "list.${suffix}" || rc=$?
        if [[ "${rc}" -eq 2 ]]; then
            echo "ERROR: TruffleHog $1 publishes no ${list}.${suffix}."
            return 1
        elif [[ "${rc}" -ne 0 ]]; then
            return 1
        fi
    done
    if ! command -v cosign > /dev/null; then
        echo "ERROR: cosign is required to verify the signature on ${list}."
        return 1
    fi
    if ! command -v openssl > /dev/null; then
        echo "ERROR: openssl is required to read when ${list} was signed."
        return 1
    fi
    # The exact identity, not the pattern TruffleHog's README suggests: it
    # names the tag, so a list signed for another release, or by another
    # workflow, fails.
    identity="https://github.com/trufflesecurity/trufflehog/.github/workflows/release.yml@refs/tags/v$1"
    if ! cosign verify-blob --certificate list.pem --signature list.sig --certificate-identity "${identity}" \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com list > /dev/null 2>&1; then
        echo "ERROR: cosign could not verify the signature on ${list} as ${identity}."
        return 1
    fi
    echo "ok: the signature on ${list} verified (${identity})."
    # The certificate is valid for ten minutes from when it was issued for
    # the signature, and cosign has checked that the signature's transparency
    # log entry falls inside that window, so its start is when the list was
    # signed. GoReleaser writes the PEM base64-encoded.
    if ! grep -q 'BEGIN CERTIFICATE' list.pem; then
        base64 -d list.pem > list.cert.pem 2> /dev/null || true
    else
        cp list.pem list.cert.pem
    fi
    signed=$(openssl x509 -in list.cert.pem -noout -startdate 2> /dev/null | sed -n 's/^notBefore=//p')
    signed=$(date -u -d "${signed}" +%s 2> /dev/null || true)
    if [[ ! "${signed}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: could not read when ${list} was signed from its certificate."
        return 1
    fi
    age=$((($(date -u +%s) - signed) / 86400))
    if ((age < TRUFFLEHOG_MIN_RELEASE_AGE_DAYS)); then
        echo "ERROR: ${list} was signed ${age} day(s) ago, on $(date -u -d "@${signed}" +%Y-%m-%d), and releases" \
            "younger than ${TRUFFLEHOG_MIN_RELEASE_AGE_DAYS} days are not added. Try again later, or set" \
            "TRUFFLEHOG_MIN_RELEASE_AGE_DAYS=0 after checking TruffleHog's advisories for $1."
        return 1
    fi
    echo "ok: ${list} was signed on $(date -u -d "@${signed}" +%Y-%m-%d), ${age} days ago."
    published=$(awk -v name="${name}" '$2 == name || $2 == "*" name { print $1; exit }' list)
    if [[ -z "${published}" ]]; then
        echo "${list} does not list ${name}."
        return 2
    fi
    actual=$(sha256sum "$3" | awk '{ print $1 }')
    if [[ "${actual}" != "${published}" ]]; then
        echo "ERROR: ${name} has SHA-256 ${actual}, but ${published} was published."
        return 1
    fi
    echo "ok: ${name} matches the published SHA-256."
}
# <<< upstream verification <<<

# >>> shared install_hash logic >>>
# Everything from here to the end marker is identical in the install_hash.sh
# of every juburr orb. The tool definition, and with it the asset names and
# URLs, is read from install.sh so the two scripts cannot disagree.

hash_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

hash_usage() {
    printf 'Usage: %s -v <version> [-a "<arch> ..."] [-c SHA-256:<hex> | -c SHA1:<hex> | -c NONE]\n' "$0" >&2
    exit 1
}

# hash_fetch URL DEST [CURL_ARG...]: downloads URL to DEST for verify_upstream.
# Returns 0 on success, 2 when the server says there is no such file (404),
# and 1 on any other failure, which must never be read as "not published".
hash_fetch() {
    local url=$1 dest=$2 code rc=0
    shift 2
    # Without -f, curl exits 0 on an HTTP error, so a non-zero exit is a
    # transfer failure, such as a connection that closed partway.
    code=$(curl -sSL --proto '=https' --proto-redir '=https' --retry 5 --connect-timeout 30 \
        -o "${dest}" -w '%{http_code}' "$@" "${url}") || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        echo "ERROR: could not download ${url} (curl exit code ${rc})."
        return 1
    fi
    case "${code}" in
        200) return 0 ;;
        404) return 2 ;;
        *)
            echo "ERROR: could not download ${url} (HTTP status ${code:-none})."
            return 1
            ;;
    esac
}

# hash_version_le A B: succeeds if version A sorts at or before version B.
hash_version_le() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# Loads install.sh's tool definition and shared functions, without its
# checksum table or main call.
INSTALL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"
# shellcheck source=/dev/null
source <(sed -n '/^# >>> tool definition >>>$/,/^# <<< shared install logic <<<$/p' "${INSTALL_SCRIPT}")
if ! declare -F tool_asset_name > /dev/null; then
    hash_die "Could not load the tool definition from ${INSTALL_SCRIPT}."
fi

VERSION=""
ARCHES=""
UPSTREAM_CHECKSUM=""
while getopts ':v:a:c:' flag; do
    case "${flag}" in
        v) VERSION=${OPTARG} ;;
        a) ARCHES=${OPTARG} ;;
        c) UPSTREAM_CHECKSUM=${OPTARG} ;;
        *) hash_usage ;;
    esac
done
VERSION=${VERSION#v}
if [[ -z "${VERSION}" ]]; then
    hash_usage
fi
if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    hash_die "Invalid version '${VERSION}'."
fi
ARCHES=${ARCHES:-${TOOL_ARCHES}}
read -r -a ARCH_LIST <<< "${ARCHES}"
if [[ "${#ARCH_LIST[@]}" -eq 0 ]]; then
    hash_die "-a names no architecture. Supported: ${TOOL_ARCHES}."
fi
for arch in "${ARCH_LIST[@]}"; do
    if [[ " ${TOOL_ARCHES} " != *" ${arch} "* ]]; then
        hash_die "Unsupported architecture '${arch}'. Supported: ${TOOL_ARCHES}."
    fi
done
if [[ -n "${UPSTREAM_CHECKSUM}" && "${UPSTREAM_CHECKSUM}" != "NONE" ]]; then
    if [[ ! "${UPSTREAM_CHECKSUM}" =~ ^(SHA-256:[0-9a-f]{64}|SHA1:[0-9a-f]{40})$ ]]; then
        hash_die "-c must be SHA-256:<hex>, SHA1:<hex>, or NONE."
    fi
    if [[ "${#ARCH_LIST[@]}" -gt 1 ]]; then
        hash_die "-c describes one asset, so pick its architecture with -a."
    fi
fi
REQUIRED_TOOLS=(curl sha256sum sha512sum tar gzip)
if [[ "${UPSTREAM_CHECKSUM}" == SHA1:* ]]; then
    REQUIRED_TOOLS+=(sha1sum)
fi
for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "${tool}" > /dev/null || hash_die "${tool} is required."
done

HASH_WORK_DIR=$(mktemp -d)
trap 'rm -rf "${HASH_WORK_DIR}"' EXIT

# check_upstream VERSION ARCH ASSET: anchors ASSET to what the project
# published, via verify_upstream (which returns 2 when nothing was published)
# and any checksum supplied with -c.
check_upstream() {
    local rc=0 expected actual
    (cd "${3%/*}" && verify_upstream "$1" "$2" "$3") >&2 || rc=$?
    if [[ "${rc}" -ne 0 && "${rc}" -ne 2 ]]; then
        hash_die "${3##*/} could not be verified against what ${TOOL_NAME} published for ${1}."
    fi
    # NONE only stands in for a checksum that was never published.
    if [[ "${UPSTREAM_CHECKSUM}" == "NONE" ]]; then
        if [[ "${rc}" -eq 2 ]]; then
            printf 'WARN: -c NONE: %s is not checked against any published checksum.\n' "${3##*/}" >&2
        fi
        return 0
    fi
    if [[ -n "${UPSTREAM_CHECKSUM}" ]]; then
        expected=${UPSTREAM_CHECKSUM#*:}
        case "${UPSTREAM_CHECKSUM%%:*}" in
            SHA-256) actual=$(sha256sum "$3" | awk '{ print $1 }') ;;
            SHA1) actual=$(sha1sum "$3" | awk '{ print $1 }') ;;
        esac
        if [[ "${actual}" != "${expected}" ]]; then
            hash_die "${3##*/} does not match the checksum given with -c (${actual})."
        fi
        printf 'ok: %s matches the checksum given with -c.\n' "${3##*/}" >&2
    elif [[ "${rc}" -eq 2 ]]; then
        hash_die "${TOOL_NAME} published no checksum for ${3##*/}. Supply one from another official source with -c," \
            "or pass -c NONE to add the entry unanchored."
    fi
}

ENTRIES=()
for arch in "${ARCH_LIST[@]}"; do
    # orb_extract works in ORB_WORK_DIR and names ORB_ASSET_NAME in messages.
    ORB_WORK_DIR="${HASH_WORK_DIR}/${arch}"
    ORB_ASSET_NAME=$(tool_asset_name "${VERSION}" "${arch}")
    member=$(tool_archive_member "${VERSION}" "${arch}")
    mkdir -p "${ORB_WORK_DIR}"
    mapfile -t urls < <(tool_asset_urls "${VERSION}" "${arch}" "${ORB_ASSET_NAME}")
    if ! orb_download "${ORB_WORK_DIR}/${ORB_ASSET_NAME}" "${urls[@]}" >&2; then
        hash_die "Could not download ${ORB_ASSET_NAME}. If ${TOOL_NAME} ${VERSION} has no ${arch} build," \
            "leave ${arch} out with -a."
    fi
    check_upstream "${VERSION}" "${arch}" "${ORB_WORK_DIR}/${ORB_ASSET_NAME}"
    # Hashes the same file install.sh verifies, with the same checks on it.
    if ! orb_extract "${ORB_WORK_DIR}/${ORB_ASSET_NAME}" "${member}" >&2; then
        hash_die "Could not take ${member} from ${ORB_ASSET_NAME}."
    fi
    ENTRIES+=("$(printf '    ["%s/%s"]="%s"' "${VERSION}" "${arch}" "$(sha512sum "${ORB_VERIFIED_FILE}" | awk '{ print $1 }')")")
done
# Nothing is printed until every architecture has passed.
printf '%s\n' "${ENTRIES[@]}"
# <<< shared install_hash logic <<<
