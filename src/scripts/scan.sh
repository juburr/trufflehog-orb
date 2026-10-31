#!/bin/bash
#
# Scans for secrets with TruffleHog for the scan command: the commits a git
# branch adds (scope changes), its whole history (history) or every ref (all),
# or the files under some paths (source filesystem).
#
# TruffleHog's JSON output holds each secret it finds in full, so it stays in
# this step's private work directory, removed when the step ends. The orb's
# log and reports keep no part of a secret: findings are rebuilt from the
# fields that name where a secret is (TH_FINDINGS_JQ), anything shown from
# TruffleHog's log goes through th_scrub, and every report is checked for
# every secret before the step ends.
#
# Verification (TruffleHog sending each secret it finds to the service it
# belongs to, to see whether it works) is off unless verify is true.
#
# Findings at or above fail_on fail the step unless report_only is true. A
# scan that can't complete, that reports a scan error, or that scanned
# nothing it should have fails it either way.

set -euo pipefail

if [[ -z "${SCRIPT_TRUFFLEHOG_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_TRUFFLEHOG_LIB is not set; run this script through the orb's scan command." >&2
    exit 1
fi
eval "${SCRIPT_TRUFFLEHOG_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Reports ---
# Checked and cleared before anything else, so a run that stops on a
# parameter never leaves an earlier run's reports to be stored as its own.
# Neither is expanded: the steps that store the reports read them as given.
REPORT_NAME=${PARAM_REPORT_NAME}
th_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${TH_BASE}.json"
SARIF="${TH_BASE}.sarif"
JUNIT_FILE="${TH_OUT}/junit/${REPORT_NAME}.xml"
RECORD="${TH_BASE}.run-record.json"
rm -f "${REPORT}" "${SARIF}" "${JUNIT_FILE}" "${RECORD}"

SOURCE=$(th_subst "${PARAM_SOURCE}")
SCOPE=$(th_subst "${PARAM_SCOPE}")
BASE_REF=$(th_subst "${PARAM_BASE_REF}")
MAX_DEPTH=$(th_subst "${PARAM_MAX_DEPTH}")
th_list paths "${PARAM_PATHS}"
PATHS=(${TH_LIST[@]+"${TH_LIST[@]}"})
VERIFY=$(th_bool verify "${PARAM_VERIFY}")
FAIL_ON=$(th_subst "${PARAM_FAIL_ON}")
INCLUDE_PATHS=$(th_subst "${PARAM_INCLUDE_PATHS}")
EXCLUDE_PATHS=$(th_subst "${PARAM_EXCLUDE_PATHS}")
EXCLUDE_GLOBS=$(th_subst "${PARAM_EXCLUDE_GLOBS}")
th_list include_detectors "${PARAM_INCLUDE_DETECTORS}"
INCLUDE_DETECTORS=(${TH_LIST[@]+"${TH_LIST[@]}"})
th_list exclude_detectors "${PARAM_EXCLUDE_DETECTORS}"
EXCLUDE_DETECTORS=(${TH_LIST[@]+"${TH_LIST[@]}"})
CONFIG=$(th_subst "${PARAM_CONFIG}")
NO_IGNORE_TAG=$(th_bool no_ignore_tag "${PARAM_NO_IGNORE_TAG}")
ALLOW_EMPTY=$(th_bool allow_empty "${PARAM_ALLOW_EMPTY}")
JUNIT=$(th_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(th_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(th_bool report_only "${PARAM_REPORT_ONLY}")
th_words extra_args "$(th_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${TH_WORDS[@]+"${TH_WORDS[@]}"})

# usage MESSAGE...: stops the step on a parameter that can't work, before
# anything runs.
usage() {
    printf 'ERROR: %s\n' "$1" >&2
    if [[ $# -gt 1 ]]; then
        printf '  %s\n' "${@:2}" >&2
    fi
    exit 2
}

# --- Parameters ---
case "${SOURCE}" in
    git | filesystem) ;;
    *) usage "source must be git or filesystem, not '${SOURCE}'." ;;
esac
case "${SCOPE}" in
    changes | history | all) ;;
    *) usage "scope must be changes, history or all, not '${SCOPE}'." ;;
esac
case "${FAIL_ON}" in
    unverified | unknown | verified) ;;
    *) usage "fail_on must be unverified, unknown or verified, not '${FAIL_ON}'." ;;
esac
FAIL_RANK=$(th_rank "${FAIL_ON}")
if [[ "${FAIL_ON}" == verified && "${VERIFY}" != true ]]; then
    usage "fail_on is verified, but verify is false, so no secret can be verified and none would ever fail the step." \
        "Set verify to true to have TruffleHog check each secret with the service it belongs to, or set fail_on" \
        "to unverified (every secret found) or unknown."
fi
th_uint max_depth "${MAX_DEPTH}"
MAX_DEPTH=$((10#${MAX_DEPTH}))
if [[ "${SOURCE}" == filesystem ]]; then
    # The git parameters say which commits to scan, which a directory has
    # none of: a value other than the default is a mistake.
    if [[ "${SCOPE}" != changes ]]; then
        usage "scope is for source git, which scans commits; source filesystem scans the files under paths."
    fi
    for name in base_ref:BASE_REF exclude_globs:EXCLUDE_GLOBS; do
        var=${name#*:}
        if [[ -n "${!var}" ]]; then
            usage "${name%%:*} is for source git, not filesystem."
        fi
    done
    if [[ "${MAX_DEPTH}" -ne 0 ]]; then
        usage "max_depth is for source git, not filesystem."
    fi
    if [[ ${#PATHS[@]} -eq 0 ]]; then
        PATHS=(.)
    fi
    for path in "${PATHS[@]}"; do
        if [[ "${path}" == *$'\n'* ]]; then
            usage "paths must not hold a newline."
        fi
        # A leading ~ is the home directory, as in the shell.
        if [[ "${path}" == \~ || "${path}" == \~/* ]]; then
            path="${HOME:-}${path:1}"
        fi
        # TruffleHog logs a path that doesn't exist as a scan error and scans
        # nothing, so it is checked here.
        if [[ ! -e "${path}" ]]; then
            usage "paths names '${path}', which doesn't exist in $(pwd)."
        fi
    done
else
    if [[ ${#PATHS[@]} -ne 0 ]]; then
        usage "paths is for source filesystem. A git scan covers the repository the working directory is in;" \
            "use include_paths or exclude_paths to narrow it."
    fi
    if [[ -n "${BASE_REF}" && "${SCOPE}" != changes ]]; then
        usage "base_ref is for scope changes; scope ${SCOPE} doesn't compare with a base."
    fi
    if [[ "${ALLOW_EMPTY}" == true ]]; then
        usage "allow_empty is for source filesystem: a git scan always has HEAD's commits to scan."
    fi
    if [[ "${BASE_REF}" == -* || "${BASE_REF}" == *[[:space:]]* ]]; then
        usage "base_ref must name a commit, such as origin/main, not '${BASE_REF}'."
    fi
    if [[ "${EXCLUDE_GLOBS}" == *$'\n'* ]]; then
        usage "exclude_globs must be one line of comma-separated globs."
    fi
fi
# Path filter files and the configuration are passed by absolute path.
for name in include_paths:INCLUDE_PATHS exclude_paths:EXCLUDE_PATHS config:CONFIG; do
    var=${name#*:}
    file=${!var}
    if [[ -z "${file}" ]]; then
        continue
    fi
    if [[ "${file}" == *$'\n'* || ! -f "${file}" ]]; then
        usage "${name%%:*} names '${file}', which is not a file in $(pwd)."
    fi
    printf -v "${var}" '%s/%s' "$(cd "$(dirname -- "${file}")" && pwd -P)" "${file##*/}"
done
# check_detectors PARAMETER DETECTOR...: stops the step unless each one can
# name a detector: a name such as github or aws, a detector type number, or
# a range of them.
check_detectors() {
    local name=$1 detector
    shift
    while [[ $# -gt 0 ]]; do
        detector=$1
        shift
        if ! th_match "${detector}" '^[A-Za-z0-9_.-]+$'; then
            usage "${name} must name detectors (such as github or aws, a detector type number, or a range of them)," \
                "separated by commas or spaces, not '${detector}'."
        fi
    done
}
check_detectors include_detectors ${INCLUDE_DETECTORS[@]+"${INCLUDE_DETECTORS[@]}"}
check_detectors exclude_detectors ${EXCLUDE_DETECTORS[@]+"${EXCLUDE_DETECTORS[@]}"}
# extra_args takes TruffleHog's tuning options only. What is scanned, which
# results are reported and how the report is read are parameters or set by
# the orb, and a word that isn't an option would be read as another path. An
# allow-list, since every boolean flag also has a --no- form.
VALUE_OPTIONS=" concurrency detector-timeout archive-max-size archive-max-depth archive-timeout max-decode-depth
    filter-entropy deduplication-cache-size user-agent-suffix verifier max-symlink-depth "
FLAG_OPTIONS=" allow-verification-overlap no-verification-cache filter-unverified force-skip-binaries
    force-skip-archives trust-local-git-config skip-additional-refs drop-unverified-jwt-results custom-verifiers-only "
expect_value=false
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    if [[ "${expect_value}" == true ]]; then
        expect_value=false
        continue
    fi
    name=${word#--}
    name=${name%%=*}
    # TruffleHog reads --flag_name as --flag-name.
    name=${name//_/-}
    if [[ "${word}" != --* ]]; then
        usage "extra_args can't hold '${word}': it isn't an option, so trufflehog would read it as another thing to scan."
    elif [[ "${VALUE_OPTIONS}" =~ [[:space:]]${name}[[:space:]] ]]; then
        if [[ "${word}" != *=* ]]; then
            expect_value=true
        fi
    elif [[ "${FLAG_OPTIONS}" =~ [[:space:]]${name}[[:space:]] && "${word}" != *=* ]]; then
        :
    else
        usage "extra_args can't hold '${word}'. It takes TruffleHog's tuning options:" \
            "--concurrency, --detector-timeout, --archive-max-size, --archive-max-depth, --archive-timeout," \
            "--max-decode-depth, --filter-entropy, --filter-unverified, --deduplication-cache-size," \
            "--allow-verification-overlap, --no-verification-cache, --force-skip-binaries, --force-skip-archives," \
            "--max-symlink-depth, --trust-local-git-config, --skip-additional-refs, --drop-unverified-jwt-results," \
            "--user-agent-suffix, --verifier and --custom-verifiers-only. What is scanned and reported is set by" \
            "the parameters."
    fi
done
if [[ "${expect_value}" == true ]]; then
    usage "extra_args ends in an option without its value."
fi

th_require_jq
th_tool
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by th_run_record
    TH_REPORTS=("${REPORT}" "${SARIF}" "${JUNIT_FILE}")
    # shellcheck disable=SC2034 # read by th_run_record
    TH_GATE_JSON=$(jq -cn --arg fail_on "${FAIL_ON}" --argjson report_only "${REPORT_ONLY}" \
        --argjson allow_empty "${ALLOW_EMPTY}" '{fail_on: $fail_on, report_only: $report_only, allow_empty: $allow_empty}')
    th_run_record "${RECORD}" scan "$1" "$2" "${STARTED}"
}

# stop MESSAGE...: ends a scan that has no verdict: the reports are removed,
# the run record says error, and the step fails, whatever report_only says.
stop() {
    rm -f "${REPORT}" "${SARIF}" "${JUNIT_FILE}"
    printf 'ERROR: %s\n' "$1" >&2
    if [[ $# -gt 1 ]]; then
        printf '  %s\n' "${@:2}" >&2
    fi
    record error 1
    exit 1
}

# --- What to scan ---
OPTIONS=()
TARGETS=()
TH_TARGET_JSON=null
COMMITS=0
if [[ "${SOURCE}" == git ]]; then
    if ! TOP=$(git rev-parse --show-toplevel 2> /dev/null) || [[ -z "${TOP}" ]]; then
        stop "source is git, and $(pwd) is not in a git checkout. Set working_dir to the checkout, or scan the" \
            "files with source filesystem."
    fi
    if ! HEAD_SHA=$(git rev-parse --verify --quiet 'HEAD^{commit}'); then
        stop "The checkout in ${TOP} has no commit to scan."
    fi
    SHALLOW=$(git rev-parse --is-shallow-repository 2> /dev/null || echo false)
    BASE=""
    BASE_FROM=""
    if [[ "${SCOPE}" == changes ]]; then
        # Where this branch left the code it is compared with: base_ref; on
        # GitHub Actions, the pull request's base, the commit before a push,
        # or the merge group's base; otherwise the remote's default branch.
        tip=""
        if [[ -n "${BASE_REF}" ]]; then
            if ! tip=$(git rev-parse --verify --quiet "${BASE_REF}^{commit}"); then
                stop "base_ref ${BASE_REF} is not a commit in this checkout. Fetch it in an earlier step, such as" \
                    "git fetch origin ${BASE_REF#origin/}, or check out with all history (actions/checkout: fetch-depth: 0)."
            fi
            BASE_FROM="base_ref ${BASE_REF}"
        elif [[ "${GITHUB_ACTIONS:-}" == true && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH:-}" ]]; then
            what=""
            sha=""
            case "${GITHUB_EVENT_NAME:-}" in
                pull_request | pull_request_target)
                    sha=$(jq -r '.pull_request.base.sha // empty' "${GITHUB_EVENT_PATH}" 2> /dev/null || true)
                    what="the pull request's base"
                    ;;
                push)
                    sha=$(jq -r '.before // empty' "${GITHUB_EVENT_PATH}" 2> /dev/null || true)
                    what="the commit before the push"
                    # A new branch has no commit before the push; it is
                    # compared with the default branch instead.
                    if [[ "${sha}" =~ ^0+$ ]]; then
                        sha=""
                    fi
                    ;;
                merge_group)
                    sha=$(jq -r '.merge_group.base_sha // empty' "${GITHUB_EVENT_PATH}" 2> /dev/null || true)
                    what="the merge group's base"
                    ;;
            esac
            if [[ -n "${sha}" ]]; then
                if ! th_match "${sha}" '^[0-9a-f]{40}([0-9a-f]{24})?$'; then
                    stop "The ${GITHUB_EVENT_NAME} event names ${what} as '${sha}', which is not a commit SHA."
                fi
                if ! git cat-file -e "${sha}^{commit}" 2> /dev/null; then
                    stop "${what^}, ${sha:0:12}, is not in this checkout, which is usually a shallow clone. Check out" \
                        "with all history (actions/checkout: fetch-depth: 0), or set base_ref."
                fi
                tip=${sha}
                BASE_FROM="${what} (${sha:0:12})"
            fi
        fi
        if [[ -z "${tip}" ]]; then
            if head=$(git symbolic-ref -q refs/remotes/origin/HEAD 2> /dev/null); then
                candidates=("${head#refs/remotes/}")
            else
                candidates=(origin/main origin/master)
            fi
            for candidate in "${candidates[@]}"; do
                if tip=$(git rev-parse --verify --quiet "${candidate}^{commit}"); then
                    BASE_FROM=${candidate}
                    break
                fi
                tip=""
            done
        fi
        if [[ -z "${tip}" ]]; then
            stop "base_ref is empty, and this checkout has no origin/HEAD, origin/main or origin/master to compare with." \
                "Set base_ref to the branch, tag or commit whose code is already scanned, or set scope to history."
        fi
        if ! BASE=$(git merge-base "${tip}" "${HEAD_SHA}" 2> /dev/null); then
            stop "${BASE_FROM} and HEAD have no common commit in this checkout, which is usually a shallow clone. Fetch" \
                "more history (actions/checkout: fetch-depth: 0), or set scope to history."
        fi
        COMMITS=$(git rev-list --count "${BASE}..${HEAD_SHA}")
        # TruffleHog resolves refs in its own clone of the checkout, where
        # branch names don't mean what they mean here, so it gets SHAs.
        OPTIONS+=("--since-commit=${BASE}" "--branch=${HEAD_SHA}")
        echo "Scanning the $(th_plural "${COMMITS}" commit commits) HEAD (${HEAD_SHA:0:12}) adds to ${BASE_FROM}, since their merge base ${BASE:0:12}."
    elif [[ "${SCOPE}" == history ]]; then
        COMMITS=$(git rev-list --count "${HEAD_SHA}")
        OPTIONS+=("--branch=${HEAD_SHA}")
        echo "Scanning the history of HEAD (${HEAD_SHA:0:12}): $(th_plural "${COMMITS}" commit commits)."
    else
        COMMITS=$(git rev-list --count --all)
        echo "Scanning every ref in the checkout: $(th_plural "${COMMITS}" commit commits)."
    fi
    if [[ "${SHALLOW}" == true && "${SCOPE}" != changes ]]; then
        echo "WARN: This checkout is shallow, so TruffleHog sees only the commits it has, and reads the oldest as adding" >&2
        echo "  every file in it. Check out with all history (actions/checkout: fetch-depth: 0) to scan all of it." >&2
    fi
    if [[ "${MAX_DEPTH}" -gt 0 ]]; then
        OPTIONS+=("--max-depth=${MAX_DEPTH}")
    fi
    if [[ -n "${EXCLUDE_GLOBS}" ]]; then
        OPTIONS+=("--exclude-globs=${EXCLUDE_GLOBS}")
    fi
    if [[ -n "${EXCLUDE_PATHS}" ]]; then
        OPTIONS+=("--exclude-paths=${EXCLUDE_PATHS}")
    fi
    # TruffleHog clones the checkout before scanning it, so the repository's
    # own git configuration never runs anything.
    TARGETS=("file://$(jq -rn --arg path "${TOP}" '$path | @uri | gsub("%2F"; "/")')")
    # shellcheck disable=SC2034 # read by th_run_record
    TH_TARGET_JSON=$(jq -cn --arg scope "${SCOPE}" --arg repo "${TOP}" --arg head "${HEAD_SHA}" --arg base "${BASE}" \
        --arg from "${BASE_FROM}" --argjson commits "${COMMITS}" --argjson shallow "${SHALLOW}" --argjson verify "${VERIFY}" \
        '{source: "git", scope: $scope, repository: $repo, head: $head,
          base: (if $base == "" then null else $base end), base_from: (if $from == "" then null else $from end),
          commits: $commits, shallow: $shallow, paths: null, verification: $verify}')
else
    for path in "${PATHS[@]}"; do
        if [[ "${path}" == \~ || "${path}" == \~/* ]]; then
            path="${HOME:-}${path:1}"
        fi
        TARGETS+=("${path}")
    done
    # A checkout's .git directory is git's own data, which source git scans
    # as history; read as files it is compressed objects and, on GitHub
    # Actions, the token actions/checkout keeps in .git/config.
    {
        if [[ -n "${EXCLUDE_PATHS}" ]]; then
            cat -- "${EXCLUDE_PATHS}"
            echo
        fi
        echo '(^|/)\.git(/|$)'
    } > "${WORK}/exclude-paths.txt"
    OPTIONS+=("--exclude-paths=${WORK}/exclude-paths.txt")
    echo "Scanning the files under $(printf "'%s' " "${TARGETS[@]}")(without .git directories)."
    # shellcheck disable=SC2034 # read by th_run_record
    TH_TARGET_JSON=$(jq -cn --argjson verify "${VERIFY}" --args \
        '{source: "filesystem", scope: null, repository: null, head: null, base: null, base_from: null,
          commits: null, shallow: null, paths: $ARGS.positional, verification: $verify}' "${TARGETS[@]}")
fi
if [[ -n "${INCLUDE_PATHS}" ]]; then
    OPTIONS+=("--include-paths=${INCLUDE_PATHS}")
fi
if [[ ${#INCLUDE_DETECTORS[@]} -gt 0 ]]; then
    OPTIONS+=("--include-detectors=$(IFS=,; echo "${INCLUDE_DETECTORS[*]}")")
fi
if [[ ${#EXCLUDE_DETECTORS[@]} -gt 0 ]]; then
    OPTIONS+=("--exclude-detectors=$(IFS=,; echo "${EXCLUDE_DETECTORS[*]}")")
fi
if [[ -n "${CONFIG}" ]]; then
    OPTIONS+=("--config=${CONFIG}")
fi
if [[ "${NO_IGNORE_TAG}" == true ]]; then
    OPTIONS+=(--no-ignore-tag)
fi
if [[ "${VERIFY}" == true ]]; then
    echo "WARN: verify is true, so TruffleHog sends each secret it finds to the service it belongs to, to check" >&2
    echo "  whether it works. The services see the secret, the request comes from this job, and the secret's owner" >&2
    echo "  may log it." >&2
else
    OPTIONS+=(--no-verification)
fi
# Every result, whatever its verification says, so the reports and the gate
# see them all; fail_on decides which fail the step.
OPTIONS+=("--results=verified,unknown,unverified")
OPTIONS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
# shellcheck disable=SC2034 # read by th_run_record
TH_ARGS=("${SOURCE}" "${OPTIONS[@]}")

# finish FINDINGS_FILE: writes the reports from the orb's findings, checks
# that none of them holds a secret, and ends the step through the gate.
finish() {
    local counts failing summary leaked file
    # shellcheck disable=SC2034 # read by th_run_record
    TH_COUNTS=$(th_counts "$1")
    counts=${TH_COUNTS}
    cp "$1" "${REPORT}"
    if [[ "${SOURCE}" == git ]]; then
        th_sarif "$1" "${SARIF}" "$(cd "${TOP}" && pwd -P)" "${TH_TRUFFLEHOG_VERSION}"
    else
        th_sarif "$1" "${SARIF}" "$(pwd -P)" "${TH_TRUFFLEHOG_VERSION}"
    fi
    if [[ "${JUNIT}" == true ]]; then
        th_findings_junit "$1" "${JUNIT_FILE}" "${REPORT_NAME}"
    fi
    # No report may hold any secret TruffleHog found, or any line of one.
    # This can't happen by construction; the check makes sure. It reads the
    # reports' string values, so a short part of a credential (a user name)
    # can't match their structure. The JUnit file holds the same strings as
    # the JSON report.
    for file in "${REPORT}" "${SARIF}"; do
        # shellcheck disable=SC2016 # jq program, not shell
        if ! leaked=$(jq --slurpfile all "${WORK}/secrets.json" \
            '[.. | strings] as $values | [$all[0][] | . as $s | select(any($values[]; contains($s)))] | length' "${file}") \
            || [[ "${leaked}" != 0 ]]; then
            stop "A report held part of a secret TruffleHog found, so the reports were deleted. This is a bug in" \
                "trufflehog-orb: please report it, without the secret."
        fi
    done
    failing=$(jq -r '.failing' <<< "${counts}")
    summary=$(jq -r --arg fail_on "${FAIL_ON}" '"TruffleHog found \(.findings) \(if .findings == 1 then "secret" else "secrets" end)"
        + " (\(.verified) verified, \(.unknown) unknown, \(.unverified) unverified); \(.failing) at or above fail_on (\($fail_on))."' <<< "${counts}")
    if [[ "${failing}" -gt 0 ]]; then
        if [[ "${REPORT_ONLY}" == true ]]; then
            record findings-reported 0
        else
            record findings 0
        fi
        th_gate true "${REPORT_ONLY}" "${summary}"
    fi
    record passed 0
    th_gate false "${REPORT_ONLY}" "${summary}"
}

if [[ "${SOURCE}" == git && "${COMMITS}" -eq 0 ]]; then
    echo "There are no commits to scan, so nothing was scanned."
    echo '[]' > "${WORK}/secrets.json"
    echo '[]' > "${WORK}/findings.json"
    finish "${WORK}/findings.json"
fi

# --- Scan ---
mkdir -p "${WORK}/tmp"
echo "Running TruffleHog ${TH_TRUFFLEHOG_VERSION:-(version unknown)}:"
printf '  trufflehog'
printf ' %q' "${SOURCE}" --json --no-update --no-color "${OPTIONS[@]}" -- "${TARGETS[@]}"
printf '\n'
code=0
# Its own TMPDIR keeps TruffleHog's clone of the checkout in the work
# directory, and away from other trufflehog processes, whose temporary files
# it removes when it starts. --no-update stops it from replacing itself with
# an unsigned download before scanning.
th_run TMPDIR="${WORK}/tmp" "${TH_TRUFFLEHOG}" "${SOURCE}" --json --no-update --no-color "${OPTIONS[@]}" \
    -- "${TARGETS[@]}" > "${WORK}/results.jsonl" 2> "${WORK}/log.jsonl" || code=$?

# Every line TruffleHog writes to stdout with --json is a result, which
# holds its secret: none is ever printed. A line that isn't a JSON object
# means the output isn't what this command reads.
jq -n -R -c '[inputs | select(length > 0) | (fromjson? // "not json") | if type == "object" then . else "not an object" end]' \
    "${WORK}/results.jsonl" > "${WORK}/results.json"
if ! jq '[.[] | objects] | '"${TH_SECRETS_JQ}" "${WORK}/results.json" > "${WORK}/secrets.json"; then
    echo '[]' > "${WORK}/secrets.json"
fi
th_scrub "${WORK}/secrets.json" "${WORK}/log.jsonl" > "${WORK}/log.txt" 2> /dev/null || : > "${WORK}/log.txt"

if [[ "${code}" -ne 0 ]]; then
    th_tail "${WORK}/log.txt" 30
    stop "trufflehog exited with ${code}, so the scan did not complete. This is not a scan result: check the" \
        "parameters and the log above."
fi
if ! th_json_is "${WORK}/results.json" 'all(.[]; type == "object")'; then
    stop "trufflehog wrote output that isn't a JSON result. It isn't shown, since it could hold a secret."
fi
# TruffleHog logs a git ref it can't resolve, a path it can't read and the
# like as scan errors, then exits 0 having scanned nothing.
SCAN_ERRORS=$(jq -n -R -c '[inputs | fromjson? | objects | select(.msg == "encountered errors during scan")]' "${WORK}/log.txt")
if [[ "${SCAN_ERRORS}" != "[]" ]]; then
    jq -r '.[] | "  \(.source_name // .job // "scan"): \((.errors // [.error // "unknown error"]) | map(tostring) | join("; "))"' \
        <<< "${SCAN_ERRORS}" >&2
    stop "TruffleHog reported errors during the scan (above), so it may not have scanned everything." \
        "This is not a scan result."
fi
jq -n -R -r 'inputs | fromjson? | objects | select(.level == "error") | "WARN: trufflehog: \(.msg)\(if .error then ": \(.error)" else "" end)"' \
    "${WORK}/log.txt" >&2 || true
# Its last log line on a scan that ran to the end. Without it, the scan was
# interrupted, or never ran.
TH_SCAN_JSON=$(jq -n -R -c '[inputs | fromjson? | objects | select(.msg == "finished scanning")] | last
    | if . == null then null else {chunks, bytes, verified_secrets, unverified_secrets, scan_duration, trufflehog_version} end' \
    "${WORK}/log.txt")
if [[ "${TH_SCAN_JSON}" == null ]]; then
    th_tail "${WORK}/log.txt" 30
    stop "trufflehog exited 0 without logging that it finished scanning, so the scan may not have run." \
        "This is not a scan result."
fi
CHUNKS=$(jq -r '.chunks // 0' <<< "${TH_SCAN_JSON}")
BYTES=$(jq -r '.bytes // 0' <<< "${TH_SCAN_JSON}")
echo "TruffleHog scanned $(th_plural "${CHUNKS}" chunk chunks) ($(th_plural "${BYTES}" byte bytes)) in $(jq -r '.scan_duration // "?"' <<< "${TH_SCAN_JSON}")."
if [[ "${SOURCE}" == git && "${CHUNKS}" == 0 ]]; then
    stop "TruffleHog scanned nothing, though $(th_plural "${COMMITS}" commit commits) were to be scanned, so its git log may" \
        "have failed. This is not a scan result."
fi
if [[ "${SOURCE}" == filesystem && "${BYTES}" == 0 && "${ALLOW_EMPTY}" != true ]]; then
    stop "TruffleHog found nothing to read under paths (every file excluded, empty or unreadable). Set allow_empty" \
        "to true if that is expected."
fi

# --- Findings and reports ---
# shellcheck disable=SC2016 # jq program, not shell
jq --slurpfile all "${WORK}/secrets.json" --argjson rank "${FAIL_RANK}" \
    '$all[0] as $secrets | ([.[] | objects]) | '"${TH_FINDINGS_JQ}" "${WORK}/results.json" > "${WORK}/findings.json"
if [[ "$(jq 'length' "${WORK}/findings.json")" -gt 0 ]]; then
    th_print_findings "${WORK}/findings.json"
fi
if [[ "${VERIFY}" != true ]]; then
    echo "Verification was off (verify: false), so no secret was sent anywhere, and none can be verified."
fi
finish "${WORK}/findings.json"
