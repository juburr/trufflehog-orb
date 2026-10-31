#!/bin/bash

# Shared helpers for the trufflehog-orb commands. Each command passes this
# file to its step as SCRIPT_TRUFFLEHOG_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions and variables. The helpers
# keep their state in TH_ variables.
#
# TruffleHog's JSON output holds every secret it finds, in full. It is only
# ever written to the command's private work directory, and everything the
# orb prints or writes goes through th_findings, which keeps no part of a
# secret, or th_scrub, which replaces every secret TruffleHog reported.

# th_subst VALUE: prints VALUE with environment variables expanded. The value
# is piped in on stdin: passed as an argument, a value starting with "-" would
# be parsed as a flag. Without the CircleCI CLI (GitHub Actions and local
# runs), the value is used as is.
th_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# th_bool NAME VALUE: prints true or false. CircleCI passes boolean parameters
# as 1 or 0; GitHub Actions and local callers use true or false.
th_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# th_words PARAMETER VALUE: sets TH_WORDS to VALUE split like shell words
# (see split_shell_words), naming PARAMETER in any error. Nothing in it is
# expanded or executed: a $(...) or backtick that reached a parameter through
# an environment variable (a branch name, a commit message) reaches the tool as
# text inside quotes, and fails the step outside them.
th_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    TH_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# th_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, setting
# BASH_REMATCH. In other locales a range such as [a-z] can match letters such
# as é (cimg images set LC_ALL=en_US.UTF-8), so checks with ranges use this.
th_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# th_require_jq: stops the step unless jq, which the reports are built with,
# is on the PATH.
th_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "ERROR: jq is not on the PATH, and this command needs it to write its reports." >&2
        echo "  CircleCI's cimg images and GitHub's hosted runners have it; elsewhere, install jq in an earlier step." >&2
        exit 1
    fi
}

# th_output DIR NAME: checks output_dir and report_name, creates DIR, and sets
# TH_OUT to DIR and TH_BASE to the path every report of this run starts with.
th_output() {
    if [[ "$1" != /* || "$1" == *$'\n'* ]]; then
        echo "ERROR: output_dir must be an absolute path, not '$1'." >&2
        exit 1
    fi
    if ! th_match "$2" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        echo "ERROR: report_name must be letters, digits, '.', '_' and '-', not '$2'." >&2
        exit 1
    fi
    if ! mkdir -p "$1"; then
        echo "ERROR: Could not create output_dir $1." >&2
        exit 1
    fi
    TH_OUT=${1%/}
    TH_OUT=${TH_OUT:-/}
    # shellcheck disable=SC2034 # read by the script that evals this file
    TH_BASE="${TH_OUT%/}/$2"
}

# th_uint PARAMETER VALUE [MIN]: stops the step unless VALUE is a whole number
# of at least MIN (default 0).
th_uint() {
    if ! th_match "$2" '^[0-9]{1,9}$' || ((10#$2 < ${3:-0})); then
        echo "ERROR: ${1} must be a whole number of at least ${3:-0}, not '$2'." >&2
        exit 1
    fi
}

# th_junit FILE SUITE CASES: writes JUnit XML to FILE, for CircleCI's Tests
# tab or any other JUnit reader, from CASES, a JSON array of test cases:
#   {"classname": ..., "name": ..., "status": "failed" | "skipped" | "passed",
#    "message": ..., "detail": ...}
# A run with no cases gets one passing case, so the tab shows it ran.
th_junit() {
    local dir=${1%/*}
    mkdir -p "${dir}"
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --arg suite "$2" '
        (if length == 0 then [{classname: $suite, name: "no findings", status: "passed"}] else . end) as $cases
        | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<testsuites>",
          "  <testsuite name=\"\($suite | @html)\" tests=\"\($cases | length)\" failures=\"\([$cases[] | select(.status == "failed")] | length)\" skipped=\"\([$cases[] | select(.status == "skipped")] | length)\">",
          ($cases[] |
            "    <testcase classname=\"\(.classname | @html)\" name=\"\(.name | @html)\">"
            + (if .status == "failed" then "<failure message=\"\((.message // "") | @html)\">\((.detail // "") | @html)</failure>"
               elif .status == "skipped" then "<skipped message=\"\((.message // "") | @html)\"/>"
               else "" end)
            + "</testcase>"),
          "  </testsuite>",
          "</testsuites>"
    ' <<< "$3" > "$1"
}

# th_gate FINDINGS REPORT_ONLY SUMMARY: ends a check. Without findings it
# succeeds. With findings it fails with SUMMARY, unless REPORT_ONLY is true,
# when it only warns: the reports are written either way.
th_gate() {
    if [[ "$1" == false ]]; then
        echo "Passed: $3"
        exit 0
    fi
    if [[ "$2" == true ]]; then
        echo "WARN: $3" >&2
        echo "WARN: report_only is true, so this step passes. The reports are in ${TH_OUT}." >&2
        exit 0
    fi
    echo "ERROR: $3" >&2
    echo "  The reports are in ${TH_OUT}. Set report_only to true to report findings without failing." >&2
    exit 1
}

# th_plural COUNT SINGULAR PLURAL: prints COUNT and the word that goes with
# it, such as "1 file" or "2 files".
th_plural() {
    if [[ "$1" -eq 1 ]]; then
        printf '%s %s\n' "$1" "$2"
    else
        printf '%s %s\n' "$1" "$3"
    fi
}

# th_tail FILE [LINES]: prints the last LINES (default 40) lines of FILE to
# stderr, indented, to show why a tool failed.
th_tail() {
    local lines=${2:-40} total first
    # A Go panic prints its message first, then the stack of every
    # goroutine, so the message is printed too when the tail leaves it out.
    total=$(wc -l < "$1")
    first=$(awk '/^(panic|fatal error): / { print NR; exit }' "$1")
    if [[ -n "${first}" ]] && ((first <= total - lines)); then
        awk -v n="${first}" 'NR >= n && NR < n + 8' "$1" | sed 's/^/  /' >&2
        echo "  ..." >&2
    fi
    tail -n "${lines}" "$1" | sed 's/^/  /' >&2
}

# th_export NAME VALUE: exports NAME=VALUE, shell-quoted, to later steps
# through BASH_ENV (on GitHub Actions, the action passes it on through
# GITHUB_ENV).
th_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}

# th_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
th_env_var_name() {
    if ! th_match "$2" '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

# th_json_is FILE FILTER [JQ_OPTION...]: whether FILE holds one JSON value for
# which FILTER is true. It compares jq's output instead of using -e, since jq
# 1.6 (as on Ubuntu 22.04 and some cimg images) exits 0 with -e when the file
# is empty, as a tool that failed before writing its report leaves it.
th_json_is() {
    local file=$1 filter=$2 options=()
    if [[ $# -gt 2 ]]; then
        options=("${@:3}")
    fi
    [[ "$(jq -c ${options[@]+"${options[@]}"} "(${filter}) | if . then true else false end" "${file}" 2> /dev/null)" == true ]]
}

# th_sha256 FILE: prints FILE's SHA-256.
th_sha256() {
    sha256sum -- "$1" | awk '{ print $1 }'
}

# th_url_public URL: prints URL without the userinfo, query and fragment,
# which can hold credentials, so it can go in a log or an artifact.
th_url_public() {
    local url=$1
    if [[ "${url}" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*@)?([^?#]*) ]]; then
        printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${url%%[?#]*}"
    fi
}

# th_ci_json: describes the CI job this runs in, for run records: a CircleCI
# job or a GitHub Actions run, or null elsewhere.
th_ci_json() {
    if [[ -n "${CIRCLE_BUILD_URL:-}" ]]; then
        jq -cn --arg url "${CIRCLE_BUILD_URL}" --arg sha "${CIRCLE_SHA1:-}" --arg job "${CIRCLE_JOB:-}" \
            --arg repo "${CIRCLE_PROJECT_USERNAME:-}${CIRCLE_PROJECT_REPONAME:+/${CIRCLE_PROJECT_REPONAME}}" \
            '{provider: "circleci", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    elif [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        jq -cn --arg url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}/attempts/${GITHUB_RUN_ATTEMPT:-1}" \
            --arg sha "${GITHUB_SHA:-}" --arg job "${GITHUB_JOB:-}" --arg repo "${GITHUB_REPOSITORY:-}" \
            '{provider: "github-actions", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    else
        echo null
    fi
}

# th_args_json ARG...: the arguments as a JSON array. They pass through jq
# NUL-separated, so arguments that start with "-" never reach jq's own option
# parsing, and a URL among them loses its userinfo, query and fragment.
th_args_json() {
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    # Ended by a word rather than a NUL, which jq 1.6 drops from the end of
    # raw input.
    { printf '%s\0' "$@"; printf 'end'; } | jq -Rsc 'split("\u0000") | .[:-1]
        | map(gsub("(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/?#\\s]*@"; "\(.scheme)")
            | gsub("(?<url>[A-Za-z][A-Za-z0-9+.-]*://[^?#\\s]*)[?#]\\S*"; "\(.url)"))'
}

# th_list PARAMETER VALUE: sets TH_LIST to VALUE, with environment variables
# expanded, split on commas, spaces and newlines.
th_list() {
    local value
    TH_LIST=()
    value=$(th_subst "$2")
    value=${value//,/ }
    # shellcheck disable=SC2034 # read by the script that evals this file
    read -r -d '' -a TH_LIST <<< "${value//$'\n'/ }" || true
}

# th_run COMMAND...: runs COMMAND without the environment variables that
# change what trufflehog does behind its flags. PRE_COMMIT, HUSKY,
# HUSKY_GIT_PARAMS and TRUFFLEHOG_PRE_COMMIT turn a git scan into a scan of
# staged changes alone, with its own --results and --fail. OVERSEER_BIN_CHECK
# and GO_UPGRADE_BIN_CHECK make its process supervisor print their value and
# exit 0 without scanning, and OVERSEER_IS_SLAVE makes it skip the
# supervisor.
th_run() {
    env -u PRE_COMMIT -u HUSKY -u HUSKY_GIT_PARAMS -u TRUFFLEHOG_PRE_COMMIT \
        -u OVERSEER_BIN_CHECK -u GO_UPGRADE_BIN_CHECK -u OVERSEER_IS_SLAVE "$@"
}

# th_tool: sets TH_TRUFFLEHOG to the trufflehog on the PATH and
# TH_TRUFFLEHOG_VERSION to the version it reports, or stops the step.
# --version exits while the flags are parsed, before the updater runs.
th_tool() {
    if ! TH_TRUFFLEHOG=$(command -v trufflehog 2> /dev/null) || [[ -z "${TH_TRUFFLEHOG}" ]]; then
        echo "ERROR: trufflehog is not on the PATH. Run this orb's install command in an earlier step." >&2
        exit 1
    fi
    TH_TRUFFLEHOG_VERSION=$(th_run "${TH_TRUFFLEHOG}" --no-update --version 2> /dev/null | awk '{ print $NF; exit }') \
        || TH_TRUFFLEHOG_VERSION=""
    # shellcheck disable=SC2034 # read by the script that evals this file
    TH_TRUFFLEHOG_VERSION=${TH_TRUFFLEHOG_VERSION#v}
}

# TH_SECRETS_JQ: from TruffleHog's results (slurped, one object per line),
# every string that is all or part of a secret: Raw, RawV2, each string in
# SecretParts, and each line of a multi-line one (a private key), longest
# first, so a secret is replaced before any part of it. Strings shorter than
# 4 characters are left out: replacing them everywhere would garble the
# reports and protect nothing.
# shellcheck disable=SC2034,SC2016 # read by the script that evals this file; jq program
TH_SECRETS_JQ='
    [.[] | (.Raw, .RawV2, (.SecretParts // empty | .. | strings)) | strings
      | ., (split("\n")[] | sub("^\\s+"; "") | sub("\\s+$"; ""))]
    | map(select(length >= 4)) | unique | sort_by(-length)'

# TH_SCRUB_JQ: a jq function, scrub, that replaces every string in $secrets
# (from TH_SECRETS_JQ) in a string with [REDACTED], as it is and as it reads
# escaped inside a JSON string, such as a line of TruffleHog's JSON log.
# split with a string argument is literal, so a secret is never read as a
# pattern.
# shellcheck disable=SC2016 # jq program, not shell
TH_SCRUB_JQ='def scrub: if type == "string" then reduce $secrets[] as $s (.;
    split($s) | join("[REDACTED]") | split($s | tojson | .[1:-1]) | join("[REDACTED]")) else . end;'

# th_scrub SECRETS FILE: prints FILE with every secret in SECRETS (a JSON
# file from TH_SECRETS_JQ) replaced, line by line, for showing a tool's log.
th_scrub() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq -R -r --slurpfile all "$1" '$all[0] as $secrets | '"${TH_SCRUB_JQ}"' scrub' "$2"
}

# th_rank RESULT: prints the rank of a result for fail_on: unverified 1,
# unknown 2, verified 3. Unknown names print nothing.
th_rank() {
    case "$1" in
        unverified) echo 1 ;;
        unknown) echo 2 ;;
        verified) echo 3 ;;
    esac
}

# TH_FINDINGS_JQ: turns TruffleHog's results (slurped) into the orb's
# findings, keeping no part of any secret: Raw, RawV2, SecretParts,
# Redacted (often the secret's first characters), ExtraData and
# StructuredData are dropped, and the strings kept go through scrub. Takes
# $secrets and $rank (fail_on's rank). A result is verified when the service
# accepted the secret, unknown when verification could not decide (or two
# detectors matched the same text), and unverified otherwise, which is every
# other result when verification is off.
# shellcheck disable=SC2034,SC2016 # read by the script that evals this file; jq program
TH_FINDINGS_JQ="${TH_SCRUB_JQ}"'
    def nonempty: if . == null or . == "" then null else . end;
    [.[] | (.SourceMetadata.Data // {}) as $data
      | ($data.Git // $data.Filesystem // {}) as $m
      | (if .Verified == true then "verified"
         elif ((.VerificationError // "") != "") then "unknown"
         else "unverified" end) as $result
      | {
          detector: ((.DetectorName // "") | tostring | nonempty // "Unknown"),
          detector_type: (.DetectorType // null),
          description: ((.DetectorDescription // "") | scrub | nonempty),
          decoder: ((.DecoderName // "") | nonempty),
          result: $result,
          failing: ({"unverified": 1, "unknown": 2, "verified": 3}[$result] >= $rank),
          verification_error: ((.VerificationError // "") | scrub | nonempty),
          file: (($m.file // "") | scrub | nonempty),
          line: (($m.line // 0) | if . > 0 then . else null end),
          commit: (($m.commit // "") | nonempty),
          author: (($m.email // "") | scrub | nonempty),
          timestamp: (($m.timestamp // "") | nonempty)
        }]
    | sort_by(.file // "", .line // 0, .commit // "", .detector)'

# th_counts FINDINGS: prints the counts the summary, the run record and the
# gate use, from the findings report.
th_counts() {
    jq -c '{
        findings: length,
        failing: ([.[] | select(.failing)] | length),
        verified: ([.[] | select(.result == "verified")] | length),
        unknown: ([.[] | select(.result == "unknown")] | length),
        unverified: ([.[] | select(.result == "unverified")] | length),
        detectors: (reduce .[] as $f ({}; .[$f.detector] += 1) | to_entries | sort_by(.key) | from_entries)
    }' "$1"
}

# th_where: a jq function, where, that describes a finding's location:
# file:line, the commit it was added in, or the commit's metadata (author or
# message) for a secret found there.
TH_WHERE_JQ='def where: (if .file then .file + (if .line then ":\(.line)" else "" end) else "commit metadata" end)
    + (if .commit then " (commit \(.commit[0:12]))" else "" end);'

# th_print_findings FINDINGS [MAX]: prints each finding (at most MAX, default
# 200) without any part of the secret.
th_print_findings() {
    local max=${2:-200}
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --argjson max "${max}" "${TH_WHERE_JQ}"'
        (.[:$max][] | "  \(where): \(.detector) (\(.result))"
            + (if .decoder and .decoder != "PLAIN" then ", found after \(.decoder) decoding" else "" end)),
        (if length > $max then "  ... and \(length - $max) more, in the JSON report" else empty end)' "$1"
}

# th_findings_junit FINDINGS FILE SUITE: writes JUnit with a failed case for
# each finding fail_on counts and a skipped one for each it doesn't.
th_findings_junit() {
    local cases
    # shellcheck disable=SC2016 # jq program, not shell
    cases=$(jq -c "${TH_WHERE_JQ}"'[.[] | {
            classname: (.file // ("commit " + (.commit // ""))),
            name: "\(.detector) at \(where)",
            status: (if .failing then "failed" else "skipped" end),
            message: "\(.detector) secret (\(.result))",
            detail: ("A \(.detector) secret (\(.result)) at \(where)."
                + (if .verification_error then " Verification: \(.verification_error)." else "" end))
        }]' "$1")
    th_junit "$2" "$3" "${cases}"
}

# th_sarif_root: sets TH_SARIF_ROOT to the directory SARIF reports name
# files from: the top of the git checkout the working directory is in, which
# is what GitHub code scanning expects, or else the working directory, both
# by their physical paths.
th_sarif_root() {
    if ! TH_SARIF_ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || [[ -z "${TH_SARIF_ROOT}" ]]; then
        TH_SARIF_ROOT=$(pwd -P)
    fi
}

# th_sarif_paths DIR PATH...: prints a JSON object that maps each PATH, as a
# tool wrote it (absolute, or relative to the directory DIR, a physical
# path), to the path a SARIF report names it by: relative to TH_SARIF_ROOT,
# or, for a file outside it, absolute. Symbolic links in PATH aren't
# followed. Empty paths and URLs are left out.
th_sarif_paths() {
    local dir=$1 path abs rel map='{}' paths=()
    shift
    # Bash 4.0 takes an empty "$@" for an unbound variable.
    if [[ $# -gt 0 ]]; then
        paths=("$@")
    fi
    for path in ${paths[@]+"${paths[@]}"}; do
        if [[ -z "${path}" || "${path}" == *://* ]]; then
            continue
        fi
        abs=${path}
        if [[ "${abs}" != /* ]]; then
            abs="${dir}/${abs}"
        fi
        rel=$(realpath -ms --relative-to="${TH_SARIF_ROOT}" -- "${abs}")
        if [[ "${rel}" == .. || "${rel}" == ../* || "${rel}" == /* ]]; then
            rel=$(realpath -ms -- "${abs}")
        fi
        # shellcheck disable=SC2016 # jq program, not shell
        map=$(jq -c --arg from "${path}" --arg to "${rel}" '. + {($from): $to}' <<< "${map}")
    done
    printf '%s\n' "${map}"
}

# th_sarif FINDINGS FILE DIR VERSION: writes SARIF 2.1.0 for the findings
# with a file, named from the top of the checkout (th_sarif_paths, with file
# paths relative to DIR). A finding in a commit's metadata has no file to
# show, so it is only in the JSON and JUnit reports. The level is error for a
# finding fail_on counts and warning otherwise. The fingerprint is the
# detector and the location, never anything derived from the secret.
th_sarif() {
    local files=() file paths
    while IFS= read -r file; do
        files+=("${file}")
    done < <(jq -r '[.[] | .file // empty] | unique[]' "$1")
    th_sarif_root
    paths=$(th_sarif_paths "$3" ${files[@]+"${files[@]}"})
    # shellcheck disable=SC2016 # jq program, not shell
    jq --arg version "$4" --argjson paths "${paths}" '
        def uri: (if startswith("/") then "file://" else "" end) + (@uri | gsub("%2F"; "/"));
        [.[] | select(.file != null)] as $located
        | ([$located[].detector] | unique) as $rules
        | {"$schema": "https://json.schemastore.org/sarif-2.1.0.json", version: "2.1.0",
           runs: [{
             tool: {driver: {name: "TruffleHog", version: $version, informationUri: "https://github.com/trufflesecurity/trufflehog",
                             rules: [$rules[] as $r | {id: $r, name: $r, shortDescription: {text: "\($r) secret"},
                                     fullDescription: {text: ([$located[] | select(.detector == $r) | .description // empty][0] // "\($r) secret")}}]}},
             results: [$located[] | (($paths[.file] // .file) | uri) as $uri | {
                 ruleId: .detector, ruleIndex: (.detector as $d | $rules | index($d)),
                 level: (if .failing then "error" else "warning" end),
                 message: {text: ("A \(.detector) secret (\(.result))"
                     + (if .commit then " was added in commit \(.commit[0:12])" else " is here" end)
                     + (if .decoder and .decoder != "PLAIN" then ", found after \(.decoder) decoding" else "" end)
                     + ". Rotate it: removing it from the code does not make it safe.")},
                 locations: [{physicalLocation: {artifactLocation: {uri: $uri}, region: {startLine: (.line // 1)}}}],
                 partialFingerprints: {"trufflehogOrbLocation/v1": "\(.detector):\($uri):\(.line // 0):\(.commit // "")"},
                 properties: {result: .result, decoder: .decoder, commit: .commit}
             }]
           }]}
    ' "$1" > "$2"
}

# th_tool_json PATH VERSION: describes the trufflehog that ran, for the run
# record.
th_tool_json() {
    local sha=""
    sha=$(sha512sum -- "$1" 2> /dev/null | awk '{ print $1 }') || sha=""
    jq -cn --arg path "$1" --arg version "$2" --arg sha "${sha}" \
        '{name: "trufflehog", path: $path, version: $version, sha512: (if $sha == "" then null else $sha end)}'
}

# th_run_record FILE COMMAND OUTCOME EXIT_CODE STARTED: writes a run record,
# the JSON document schemas/run-record.v1.json describes, saying what exactly
# this command scanned, with which TruffleHog, so a reviewer can tell without
# running it again. It reads what the command set:
#   TH_TRUFFLEHOG, TH_TRUFFLEHOG_VERSION  the trufflehog that ran, and its version
#   TH_ARGS          the arguments it ran with, as an array
#   TH_TARGET_JSON   what it scanned, as JSON
#   TH_SCAN_JSON     TruffleHog's own summary of the scan, from its log
#   TH_REPORTS       the report files written
#   TH_COUNTS        the counts from th_counts
#   TH_GATE_JSON     the gate's settings
# OUTCOME is passed, findings, findings-reported (findings with report_only)
# or error.
th_run_record() {
    local file=$1 path reports="[]" args
    for path in ${TH_REPORTS[@]+"${TH_REPORTS[@]}"}; do
        if [[ -f "${path}" ]]; then
            reports=$(jq -c --arg path "${path}" --arg sha "$(th_sha256 "${path}")" '. + [{path: $path, sha256: $sha}]' <<< "${reports}")
        fi
    done
    args=$(th_args_json ${TH_ARGS[@]+"${TH_ARGS[@]}"})
    if ! jq -n --arg command "$2" --arg outcome "$3" --argjson code "$4" --arg started "$5" \
        --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$(pwd)" --argjson ci "$(th_ci_json)" \
        --argjson tool "$(if [[ -n "${TH_TRUFFLEHOG:-}" ]]; then th_tool_json "${TH_TRUFFLEHOG}" "${TH_TRUFFLEHOG_VERSION:-}"; else echo null; fi)" \
        --argjson target "${TH_TARGET_JSON:-null}" --argjson scan "${TH_SCAN_JSON:-null}" \
        --argjson reports "${reports}" --argjson counts "${TH_COUNTS:-null}" --argjson gate "${TH_GATE_JSON:-null}" \
        --argjson args "${args}" '{
            schema: "https://github.com/juburr/trufflehog-orb/blob/main/schemas/run-record.v1.json",
            command: $command, outcome: $outcome, exit_code: $code,
            started_at: $started, finished_at: $finished, ci: $ci, working_directory: $cwd,
            tool: $tool, arguments: $args, target: $target, scan: $scan,
            gate: $gate, counts: $counts, reports: $reports
        }' > "${file}"; then
        echo "WARN: Could not write the run record ${file}." >&2
        return 0
    fi
    echo "Run record: ${file}"
}
