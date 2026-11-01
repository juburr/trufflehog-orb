#!/usr/bin/env bash
#
# Tests the scan command's script offline, run by tests/run_command.sh with
# its parameters' defaults from the command's YAML, against a stand-in
# trufflehog that records every call (arguments, working directory, TMPDIR,
# and the variables TruffleHog reads behind its flags) and answers with
# results and log lines the test chooses, in a real git repository with an
# origin and a branch:
#
#   - the arguments for each source and scope: SHAs, never ref names, the
#     merge base for scope changes, --no-update, --json, --no-verification
#     unless verify, every result, the target after --
#   - the base for scope changes: base_ref, GitHub's pull_request, push and
#     merge_group events, origin/HEAD, and no commits to scan
#   - a partial clone (blobless or treeless) completed before TruffleHog
#     clones it, unless --trust-local-git-config, and a remote that can't
#     be reached
#   - no part of a secret in the log or any report: findings keep where a
#     secret is, never the secret, a prefix of it or its extra data, and
#     TruffleHog's log is shown scrubbed; a report that would hold a secret
#     is deleted
#   - the gate, fail_on and report_only, and JUnit, SARIF and run records
#   - a scan that can't complete, reports a scan error, never finishes, or
#     scans nothing fails whatever report_only says
#   - every input check failing before trufflehog runs, and extra_args'
#     allow-list
#
# The scripts run with the bash first on the PATH, so putting an older bash
# there checks it. A stand-in circleci CLI expands $ORB_TEST_VAR.
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUB="${WORK}/stub"
HOME_DIR="${WORK}/home"
JOB="${WORK}/job"
OUT="${WORK}/reports"
mkdir -p "${WORK}/bin" "${STUB}/calls" "${HOME_DIR}" "${JOB}"

# Like `circleci env subst`, expands $NAME and ${NAME} references, from stdin.
cat > "${WORK}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "$*" != "env subst" ]]; then
    echo "circleci stub: expected 'env subst' with the value on stdin, got: $*" >&2
    exit 1
fi
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s' "${output}${input}"
EOF

# The stand-in trufflehog. Settings:
#   STUB_RESULTS      a file of JSON results, one per line, the scan prints
#   STUB_STDOUT_LINE  a line it prints to stdout before them
#   STUB_LOG_LINE     a line it logs before finishing
#   STUB_EXIT         exit with this code, after a kingpin-style error
#   STUB_NO_SUMMARY   don't log the "finished scanning" line
#   STUB_CHUNKS, STUB_BYTES  the summary's counts (default 12 and 3456)
#   STUB_CLONE        for source git, clone the target first, as TruffleHog
#                     does without --trust-local-git-config, and fail as it
#                     does when the clone fails
cat > "${WORK}/bin/trufflehog" << 'EOF'
#!/usr/bin/env bash
set +o errexit +o nounset +o pipefail +o xtrace
calls="${STUB_DIR}/calls"
if [[ " $* " == *" --version "* ]]; then
    echo "trufflehog ${STUB_VERSION:-3.99.7}"
    exit 0
fi
n=$(($(find "${calls}" -name '*.args' | wc -l) + 1))
printf '%s\n' "$@" > "${calls}/${n}.args"
{
    printf 'cwd=%s\n' "${PWD}"
    printf 'tmpdir=%s\n' "${TMPDIR:-}"
    for var in PRE_COMMIT HUSKY HUSKY_GIT_PARAMS TRUFFLEHOG_PRE_COMMIT OVERSEER_BIN_CHECK GO_UPGRADE_BIN_CHECK OVERSEER_IS_SLAVE; do
        if [[ -n "${!var+set}" ]]; then printf 'set=%s\n' "${var}"; fi
    done
} > "${calls}/${n}.meta"
for arg in "$@"; do
    case "${arg}" in
        --exclude-paths=*) cp "${arg#*=}" "${calls}/${n}.exclude" ;;
    esac
done
[[ -d "${TMPDIR:-/nonexistent}" ]] || { echo "TMPDIR ${TMPDIR:-} is not a directory" >&2; exit 99; }
if [[ -n "${STUB_CLONE:-}" && "$1" == git && " $* " != *" --trust-local-git-config "* ]]; then
    target=${!#}
    if ! output=$(git clone --quiet -c 'remote.origin.fetch=+refs/*:refs/remotes/origin/*' "${target}" \
        "${TMPDIR}/trufflehog-clone" 2>&1); then
        jq -cn --arg error "could not clone repo: ${target}, error executing git clone: ${output}" \
            '{level: "error", logger: "trufflehog", msg: "error running scan", error: $error}' >&2
        exit 1
    fi
    echo cloned > "${calls}/${n}.cloned"
fi
if [[ -n "${STUB_EXIT:-}" ]]; then
    [[ -n "${STUB_RESULTS:-}" ]] && cat "${STUB_RESULTS}"
    [[ -n "${STUB_LOG_LINE:-}" ]] && printf '%s\n' "${STUB_LOG_LINE}" >&2
    echo "trufflehog: error: something went wrong, try --help" >&2
    exit "${STUB_EXIT}"
fi
echo '{"level":"info-0","ts":"2026-10-31T12:00:00Z","logger":"trufflehog","msg":"running source","source_manager_worker_id":"abc12"}' >&2
[[ -n "${STUB_STDOUT_LINE:-}" ]] && printf '%s\n' "${STUB_STDOUT_LINE}"
[[ -n "${STUB_RESULTS:-}" ]] && cat "${STUB_RESULTS}"
[[ -n "${STUB_LOG_LINE:-}" ]] && printf '%s\n' "${STUB_LOG_LINE}" >&2
if [[ -z "${STUB_NO_SUMMARY:-}" ]]; then
    printf '{"level":"info-0","ts":"2026-10-31T12:00:01Z","logger":"trufflehog","msg":"finished scanning","chunks":%s,"bytes":%s,"verified_secrets":1,"unverified_secrets":3,"scan_duration":"1.234s","trufflehog_version":"3.99.7","verification_caching":{"Hits":0}}\n' \
        "${STUB_CHUNKS:-12}" "${STUB_BYTES:-3456}" >&2
fi
exit 0
EOF
chmod +x "${WORK}/bin/"*

# --- The repository: main on the origin, and a branch two commits ahead ---
git_in() { git -C "$1" -c user.name=Test -c user.email=test@example.com "${@:2}"; }
ORIGIN="${WORK}/origin.git"
git init -q --bare -b main "${ORIGIN}"
git -C "${JOB}" init -q -b main
echo "# app" > "${JOB}/README.md"
git_in "${JOB}" add README.md
git_in "${JOB}" commit -q -m "the app"
git -C "${JOB}" remote add origin "${ORIGIN}"
git -C "${JOB}" push -q -u origin main 2> /dev/null
git -C "${JOB}" remote set-head origin main
MAIN_SHA=$(git -C "${JOB}" rev-parse HEAD)
git -C "${JOB}" checkout -q -b feature
mkdir -p "${JOB}/config" "${JOB}/keys"
echo "one" > "${JOB}/config/app.env"
git_in "${JOB}" add config
git_in "${JOB}" commit -q -m "configure"
C2=$(git -C "${JOB}" rev-parse HEAD)
echo "two" > "${JOB}/keys/id"
git_in "${JOB}" add keys
git_in "${JOB}" commit -q -m "keys"
C3=$(git -C "${JOB}" rev-parse HEAD)
JOB_PHYSICAL=$(cd "${JOB}" && pwd -P)
URI="file://${JOB_PHYSICAL}"

# --- Results: fake secrets, which must never show anywhere ---
SECRET_A="fake-secret-alpha-0123456789"
SECRET_A_PREFIX="fake-sec"
KEY_ID="FAKEKEYID0001122"
KEY_SECRET="fake/secret+bravo=key"
PEM_LINE_1="MIIfakeLineOneAAAAqwerty"
PEM_LINE_2="MIIfakeLineTwoBBBBasdfgh"
# The markers are split, so a secret scan of this repository doesn't take
# them for a private key.
PEM_MARK="PRIVATE"" KEY"
PEM="-----BEGIN ${PEM_MARK}-----"$'\n'"${PEM_LINE_1}"$'\n'"${PEM_LINE_2}"$'\n'"-----END ${PEM_MARK}-----"
SLACK="fake-slack-token-xyzzy-9876"
ACCOUNT="123456789012"
ALL_SECRETS=("${SECRET_A}" "${SECRET_A_PREFIX}" "${KEY_ID}" "${KEY_SECRET}" "${PEM_LINE_1}" "${PEM_LINE_2}" "${SLACK}" "${ACCOUNT}")

# result DETECTOR RAW [JQ_FILTER]: a TruffleHog JSON result line.
result() {
    jq -cn --arg d "$1" --arg raw "$2" "{
        SourceMetadata: {Data: {Git: {commit: \"${C2}\", file: \"config/app.env\", email: \"Dev <dev@example.com>\",
            repository: \"${URI}\", timestamp: \"2026-10-30 12:00:00 +0000\", line: 3,
            repository_local_path: \"/tmp/trufflehog-1-1\"}}},
        SourceID: 1, SourceType: 16, SourceName: \"trufflehog - git\", DetectorType: 8, DetectorName: \$d,
        DetectorDescription: \"\(\$d) tokens\", DecoderName: \"PLAIN\", Verified: false, VerificationFromCache: false,
        Raw: \$raw, RawV2: \"\", Redacted: \"\", ExtraData: null, StructuredData: null, SecretParts: null
    } | ${3:-.}"
}
FINDINGS="${WORK}/findings.jsonl"
{
    result Github "${SECRET_A}" ".Verified = true | .Redacted = \"${SECRET_A_PREFIX}...\" | .SecretParts = {token: \"${SECRET_A}\"}"
    result AWS "${KEY_ID}" ".VerificationError = \"more than one detector has found this result\"
        | .RawV2 = \"${KEY_ID}:${KEY_SECRET}\" | .SecretParts = {key: \"${KEY_ID}\", secret: \"${KEY_SECRET}\"}
        | .ExtraData = {account: \"${ACCOUNT}\"}
        | .SourceMetadata.Data.Git |= (.commit = \"${C3}\" | .file = \"deploy/key with space.txt\" | .line = 7)
        | .DecoderName = \"BASE64\""
    result PrivateKey "${PEM}" ".SourceMetadata.Data.Git |= (.commit = \"${C3}\" | .file = \"keys/id\" | .line = 1)"
    result Slack "${SLACK}" ".SourceMetadata.Data.Git |= (del(.file) | .line = 2)"
} > "${FINDINGS}"
CLEAN="${WORK}/clean.jsonl"
: > "${CLEAN}"

FAILURES=0
RC=0
OUTPUT=""

# run [NAME=VALUE ...] [-- VAR=value ...]: runs scan.sh through
# tests/run_command.sh in the job directory, with output_dir in OUT, the
# parameters given and the environment settings after --. Recorded calls
# and BASH_ENV start empty, and every run record is kept to check against
# the schema at the end.
RECORDS=0
mkdir -p "${WORK}/records"
run() {
    local params=() envs=() record
    while [[ $# -gt 0 && "$1" != -- ]]; do
        params+=("$1")
        shift
    done
    if [[ $# -gt 0 ]]; then
        shift
        envs=("$@")
    fi
    rm -rf "${STUB}/calls"
    mkdir -p "${STUB}/calls"
    : > "${WORK}/bash_env"
    OUTPUT=$(cd "${JOB}" && env -u GITHUB_ACTIONS -u GITHUB_EVENT_NAME -u GITHUB_EVENT_PATH HOME="${HOME_DIR}" \
        PATH="${WORK}/bin:${PATH}" BASH_ENV="${WORK}/bash_env" STUB_DIR="${STUB}" ${envs[@]+"${envs[@]}"} \
        bash "${ROOT}/tests/run_command.sh" scan "output_dir=${OUT}" ${params[@]+"${params[@]}"} 2>&1)
    RC=$?
    for record in "${OUT}"/*.run-record.json; do
        [[ -f "${record}" ]] || continue
        RECORDS=$((RECORDS + 1))
        cp "${record}" "${WORK}/records/${RECORDS}.json"
    done
}

check() {
    local description=$1 call
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        while IFS= read -r line; do
            printf '    | %s\n' "${line}"
        done <<< "${OUTPUT}"
        for call in "${STUB}/calls/"*.args; do
            [[ -f "${call}" ]] || continue
            printf '    trufflehog call %s: %s\n' "$(basename "${call}" .args)" "$(tr '\n' ' ' < "${call}")"
        done
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is() { [[ "${RC}" -eq "$1" ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
not_run() { [[ -z "$(find "${STUB}/calls" -name '*.args')" ]]; }
CALL="${STUB}/calls/1.args"
# has ARG...: the scan got each of these arguments, in this order, next to
# each other.
has() { [[ -f "${CALL}" ]] && grep -qzF -- "$(printf '%s\n' "$@")" "${CALL}"; }
lacks() { [[ -f "${CALL}" ]] && ! grep -q -- "^$1" "${CALL}"; }
first_is() { [[ "$(head -n 1 "${CALL}")" == "$1" ]]; }
ends_with() { [[ "$(tail -n $(($# + 1)) "${CALL}")" == "$(printf '%s\n' -- "$@")" ]]; }
meta() { grep -qxF -- "$1" "${STUB}/calls/1.meta"; }
no_meta() { ! grep -q -- "$1" "${STUB}/calls/1.meta"; }
report() { [[ -s "${OUT}/$1" ]]; }
no_report() { [[ ! -e "${OUT}/$1" ]]; }
json_is() { [[ "$(jq -c "$2" "${OUT}/$1" 2> /dev/null)" == "$3" ]]; }
# no_secret_anywhere: no fake secret, prefix or extra data in the log or any
# file under output_dir.
no_secret_anywhere() {
    local secret file
    for secret in "${ALL_SECRETS[@]}"; do
        if grep -qF -- "${secret}" <<< "${OUTPUT}"; then
            echo "the log holds ${secret}"
            return 1
        fi
        while IFS= read -r -d '' file; do
            if grep -qF -- "${secret}" "${file}"; then
                echo "${file} holds ${secret}"
                return 1
            fi
        done < <(find "${OUT}" -type f -print0 2> /dev/null)
    done
}

echo "=== scope changes: the arguments"
run -- STUB_RESULTS="${CLEAN}" PRE_COMMIT=1 HUSKY=1 HUSKY_GIT_PARAMS=x TRUFFLEHOG_PRE_COMMIT=1 OVERSEER_BIN_CHECK=x \
    GO_UPGRADE_BIN_CHECK=x OVERSEER_IS_SLAVE=1
check "a scan that finds nothing passes" rc_is 0
check "it runs trufflehog git" first_is git
check "with JSON output, never updating itself, without color" has --json --no-update --no-color
check "from the merge base with origin/main to HEAD, as SHAs" has "--since-commit=${MAIN_SHA}" "--branch=${C3}"
check "without verification" has --no-verification
check "reporting every result" has "--results=verified,unknown,unverified"
check "never --fail, since the orb reads the results" lacks --fail
check "the checkout's URI after --" ends_with "${URI}"
check "saying what it scans" said "Scanning the 2 commits HEAD (${C3:0:12}) adds to origin/main, since their merge base ${MAIN_SHA:0:12}."
check "in the working directory" meta "cwd=${JOB_PHYSICAL}"
check "without the variables that turn a scan into a pre-commit scan or skip it" no_meta '^set='
TMP_USED=$(sed -n 's/^tmpdir=//p' "${STUB}/calls/1.meta")
check "with a TMPDIR of its own, removed afterwards" test -n "${TMP_USED}" -a ! -e "${TMP_USED}"
check "the summary" said "Passed: TruffleHog found 0 secrets (0 verified, 0 unknown, 0 unverified); 0 at or above fail_on (unverified)."
check "TruffleHog's own counts" said "TruffleHog scanned 12 chunks (3456 bytes) in 1.234s."
check "saying nothing was sent anywhere" said "Verification was off (verify: false), so no secret was sent anywhere"
check "an empty JSON report" json_is trufflehog.json '.' '[]'
check "SARIF with no results" json_is trufflehog.sarif '[.version, (.runs[0].results | length), .runs[0].tool.driver.version]' '["2.1.0",0,"3.99.7"]'
check "JUnit with one passing case" grep -q 'name="no findings"' "${OUT}/junit/trufflehog.xml"

echo "=== scope changes: the base"
run base_ref=main -- STUB_RESULTS="${CLEAN}"
check "base_ref names the base, by its merge base" has "--since-commit=${MAIN_SHA}" "--branch=${C3}"
check "and says so" said "adds to base_ref main"
run base_ref="${C2}" -- STUB_RESULTS="${CLEAN}"
check "a commit on the branch makes the range the commits after it" has "--since-commit=${C2}" "--branch=${C3}"
check "1 commit" said "Scanning the 1 commit HEAD"
# shellcheck disable=SC2016 # expanded by the stand-in circleci
run 'base_ref=${ORB_TEST_VAR}' -- STUB_RESULTS="${CLEAN}" ORB_TEST_VAR="${C2}"
check "base_ref's environment variables are expanded" has "--since-commit=${C2}"
run base_ref=origin/nothing
check "a base_ref that isn't a commit fails" rc_is 1
check "saying how to fetch it" said "base_ref origin/nothing is not a commit in this checkout"
check "before trufflehog runs" not_run
run base_ref=-x
check "a base_ref that starts with - is refused" rc_is 2
check "before trufflehog runs" not_run
EVENT="${WORK}/event.json"
jq -n --arg base "${MAIN_SHA}" '{pull_request: {base: {sha: $base}}}' > "${EVENT}"
run -- STUB_RESULTS="${CLEAN}" GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${EVENT}"
check "on GitHub Actions, a pull request is compared with its base" said "adds to the pull request's base (${MAIN_SHA:0:12})"
check "by SHA" has "--since-commit=${MAIN_SHA}"
jq -n --arg before "${C2}" '{before: $before}' > "${EVENT}"
run -- STUB_RESULTS="${CLEAN}" GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="${EVENT}"
check "a push is compared with the commit before it" has "--since-commit=${C2}"
check "and says so" said "adds to the commit before the push (${C2:0:12})"
jq -n '{before: "0000000000000000000000000000000000000000"}' > "${EVENT}"
run -- STUB_RESULTS="${CLEAN}" GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="${EVENT}"
check "a new branch's push is compared with the default branch" said "adds to origin/main"
jq -n --arg base "${MAIN_SHA}" '{merge_group: {base_sha: $base}}' > "${EVENT}"
run -- STUB_RESULTS="${CLEAN}" GITHUB_ACTIONS=true GITHUB_EVENT_NAME=merge_group GITHUB_EVENT_PATH="${EVENT}"
check "a merge group is compared with its base" said "adds to the merge group's base"
jq -n '{pull_request: {base: {sha: "1111111111111111111111111111111111111111"}}}' > "${EVENT}"
run -- GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${EVENT}"
check "a base the checkout doesn't have fails" rc_is 1
check "saying to fetch the history" said "fetch-depth: 0"
check "before trufflehog runs" not_run
jq -n '{pull_request: {base: {sha: "main; echo hi"}}}' > "${EVENT}"
run -- GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${EVENT}"
check "a base that isn't a SHA fails" rc_is 1
check "naming it" said "which is not a commit SHA"
jq -n --arg base "${MAIN_SHA}" '{pull_request: {base: {sha: $base}}}' > "${EVENT}"
run base_ref="${C2}" -- STUB_RESULTS="${CLEAN}" GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${EVENT}"
check "base_ref wins over the event" has "--since-commit=${C2}"

CLONE="${WORK}/clone"
git clone -q "file://${ORIGIN}" "${CLONE}"
run working_dir="${CLONE}"
check "on the default branch there are no commits to scan, which passes" rc_is 0
check "saying so" said "There are no commits to scan, so nothing was scanned."
check "without running trufflehog" not_run
check "with empty reports" json_is trufflehog.json '.' '[]'
git -C "${CLONE}" remote remove origin
run working_dir="${CLONE}"
check "without a base_ref or an origin, the step fails" rc_is 1
check "saying what to set" said "Set base_ref to the branch, tag or commit whose code is already scanned, or set scope to history."
mkdir -p "${WORK}/plain"
run working_dir="${WORK}/plain" run_record=true
check "outside a git checkout, source git fails" rc_is 1
check "saying so" said "is not in a git checkout"
check "with a run record that names what was asked for" json_is trufflehog.run-record.json \
    '[.outcome, .target.source, .target.scope, .target.repository, .target.verification]' '["error","git","changes",null,false]'
SHALLOW="${WORK}/shallow"
git clone -q --depth 1 -b feature "file://${JOB}" "${SHALLOW}"
run working_dir="${SHALLOW}" base_ref=origin/main
check "in a shallow clone without the base, the step fails" rc_is 1
check "saying what to do" said "base_ref origin/main is not a commit in this checkout"

echo "=== a partial clone"
# As CircleCI's checkout makes by default: a blobless clone, which lacks the
# blobs of files that aren't in HEAD's tree, such as gone.txt on the branch
# old, until something fetches them. git serves no clone from it, and
# TruffleHog clones the checkout (STUB_CLONE).
PARTIAL_ORIGIN="${WORK}/partial-origin.git"
git clone -q --bare "${JOB}" "${PARTIAL_ORIGIN}"
git clone -q "${PARTIAL_ORIGIN}" "${WORK}/partial-work"
git -C "${WORK}/partial-work" checkout -q -b old origin/main
echo "gone" > "${WORK}/partial-work/gone.txt"
git_in "${WORK}/partial-work" add gone.txt
git_in "${WORK}/partial-work" commit -q -m "a file no other branch has"
git -C "${WORK}/partial-work" push -q origin old 2> /dev/null
git -C "${PARTIAL_ORIGIN}" config uploadpack.allowFilter true
git -C "${PARTIAL_ORIGIN}" config uploadpack.allowAnySHA1InWant true
# partial_clone FILTER DIR: a partial clone of the origin, on feature.
partial_clone() { git clone -q --filter="$1" -b feature "file://${PARTIAL_ORIGIN}" "$2"; }
missing_objects() { git -C "$1" rev-list --objects --all --missing=print | grep -c '^?'; }
PARTIAL="${WORK}/partial"
partial_clone blob:none "${PARTIAL}"
check "the blobless clone lacks a blob" test "$(missing_objects "${PARTIAL}")" -eq 1
REFS_BEFORE=$(git -C "${PARTIAL}" for-each-ref)
run working_dir="${PARTIAL}" base_ref=origin/main run_record=true -- STUB_RESULTS="${CLEAN}" STUB_CLONE=1
check "a partial clone's scan passes" rc_is 0
check "saying what it lacks" said "This checkout is a partial clone, which lacks 1 object TruffleHog's clone of it"
check "and where it fetches it from" said "Fetching them from origin."
check "after which TruffleHog's clone of the checkout works" test -f "${STUB}/calls/1.cloned"
check "the checkout lacks nothing now" test "$(missing_objects "${PARTIAL}")" -eq 0
check "with its refs as they were" test "$(git -C "${PARTIAL}" for-each-ref)" == "${REFS_BEFORE}"
check "the run record says what was fetched" json_is trufflehog.run-record.json \
    '[.target.partial_clone, .target.fetched_objects]' '[true,1]'
run working_dir="${PARTIAL}" base_ref=origin/main run_record=true -- STUB_RESULTS="${CLEAN}" STUB_CLONE=1
check "a partial clone that lacks nothing fetches nothing" not_said "Fetching them"
check "and says it fetched none" json_is trufflehog.run-record.json '[.target.partial_clone, .target.fetched_objects]' '[true,0]'
TREELESS="${WORK}/treeless"
partial_clone tree:0 "${TREELESS}"
run working_dir="${TREELESS}" base_ref=origin/main run_record=true -- STUB_RESULTS="${CLEAN}" STUB_CLONE=1
check "a treeless clone takes a second pass, for the blobs of the trees it fetched" rc_is 0
check "and lacks nothing after it" test "$(missing_objects "${TREELESS}")" -eq 0
check "TruffleHog's clone works" test -f "${STUB}/calls/1.cloned"
check "the run record counts both passes" json_is trufflehog.run-record.json '.target.fetched_objects > 1' 'true'
IN_PLACE="${WORK}/in-place"
partial_clone blob:none "${IN_PLACE}"
run working_dir="${IN_PLACE}" base_ref=origin/main extra_args=--trust-local-git-config run_record=true \
    -- STUB_RESULTS="${CLEAN}" STUB_CLONE=1
check "with --trust-local-git-config, which scans in place, nothing is fetched first" rc_is 0
check "saying git fetches what the scan reads" said "With --trust-local-git-config, TruffleHog scans it where it is"
check "the checkout still lacks the blob" test "$(missing_objects "${IN_PLACE}")" -eq 1
check "the run record says none was fetched" json_is trufflehog.run-record.json \
    '[.target.partial_clone, .target.fetched_objects]' '[true,null]'
UNREACHABLE="${WORK}/unreachable"
partial_clone blob:none "${UNREACHABLE}"
git -C "${UNREACHABLE}" remote set-url origin "${WORK}/no-such-origin.git"
run working_dir="${UNREACHABLE}" base_ref=origin/main run_record=true -- STUB_RESULTS="${CLEAN}" STUB_CLONE=1
check "a partial clone whose remote can't be reached fails" rc_is 1
check "saying why" said "git could not fetch the objects this partial clone lacks from origin"
check "and what to do" said "checkout with method: full"
check "before trufflehog runs" not_run
check "with an error run record" json_is trufflehog.run-record.json '[.outcome, .target.partial_clone]' '["error",true]'
run run_record=true -- STUB_RESULTS="${CLEAN}" STUB_CLONE=1
check "a full clone fetches nothing" not_said "partial clone"
check "TruffleHog's clone of it works" test -f "${STUB}/calls/1.cloned"
check "its run record says it isn't a partial clone" json_is trufflehog.run-record.json \
    '[.target.partial_clone, .target.fetched_objects]' '[false,null]'

echo "=== scopes history and all"
run scope=history -- STUB_RESULTS="${CLEAN}"
check "history scans HEAD's history" has "--branch=${C3}"
check "with no base" lacks --since-commit
check "and says how many commits" said "Scanning the history of HEAD (${C3:0:12}): 3 commits."
run scope=all -- STUB_RESULTS="${CLEAN}"
check "all scans every ref" lacks --branch
check "with no base" lacks --since-commit
run scope=history working_dir="${SHALLOW}" -- STUB_RESULTS="${CLEAN}"
check "a shallow history scan warns" said "WARN: This checkout is shallow"
run scope=history base_ref=main
check "base_ref with scope history is refused" rc_is 2
run scope=sideways
check "an unknown scope is refused" rc_is 2
run max_depth=25 exclude_globs='vendor/*,*.lock' -- STUB_RESULTS="${CLEAN}"
check "max_depth and exclude_globs reach trufflehog" has "--max-depth=25" "--exclude-globs=vendor/*,*.lock"
run max_depth=lots
check "a max_depth that isn't a number is refused" rc_is 1
run paths=src
check "paths with source git is refused" rc_is 2
run allow_empty=true
check "allow_empty with source git is refused" rc_is 2

echo "=== findings, and secrets kept out of everything"
run run_record=true -- STUB_RESULTS="${FINDINGS}"
check "secrets fail the step" rc_is 1
check "with the counts" said "ERROR: TruffleHog found 4 secrets (1 verified, 1 unknown, 2 unverified); 4 at or above fail_on (unverified)."
check "each one listed by where it is" said "  config/app.env:3 (commit ${C2:0:12}): Github (verified)"
check "with its decoder" said "  deploy/key with space.txt:7 (commit ${C3:0:12}): AWS (unknown), found after BASE64 decoding"
check "a secret in a commit's metadata too" said "  commit metadata (commit ${C2:0:12}): Slack (unverified)"
check "no secret, prefix or extra data in the log or any report" no_secret_anywhere
check "the JSON report holds every secret's place" json_is trufflehog.json 'length' '4'
check "and only these fields" json_is trufflehog.json '[.[] | keys] | unique' \
    '[["author","commit","decoder","description","detector","detector_type","failing","file","line","result","timestamp","verification_error"]]'
check "with the result of verification" json_is trufflehog.json '[.[] | .result] | sort' '["unknown","unverified","unverified","verified"]'
check "and verification's message" json_is trufflehog.json '[.[] | .verification_error // empty]' '["more than one detector has found this result"]'
check "the author and commit" json_is trufflehog.json "[.[] | select(.detector == \"Github\") | .author, .commit]" "[\"Dev <dev@example.com>\",\"${C2}\"]"
check "SARIF has the secrets in a file" json_is trufflehog.sarif '.runs[0].results | length' '3'
check "named from the top of the checkout, percent-encoded" json_is trufflehog.sarif \
    '[.runs[0].results[].locations[0].physicalLocation.artifactLocation.uri] | sort' '["config/app.env","deploy/key%20with%20space.txt","keys/id"]'
check "at error level" json_is trufflehog.sarif '[.runs[0].results[].level] | unique' '["error"]'
check "with each rule once" json_is trufflehog.sarif '[.runs[0].tool.driver.rules[].id]' '["AWS","Github","PrivateKey"]'
# shellcheck disable=SC2016 # jq program, not shell
check "and the right rule index" json_is trufflehog.sarif '.runs[0] as $r | [$r.results[] | $r.tool.driver.rules[.ruleIndex].id == .ruleId] | all' 'true'
check "fingerprints from the place, not the secret" json_is trufflehog.sarif \
    '.runs[0].results[] | select(.ruleId == "Github") | .partialFingerprints["trufflehogOrbLocation/v1"]' "\"Github:config/app.env:3:${C2}\""
check "JUnit fails each one" test "$(grep -o '<failure' "${OUT}/junit/trufflehog.xml" | wc -l)" -eq 4
check "the run record says findings" json_is trufflehog.run-record.json '[.outcome, .exit_code, .counts.findings, .counts.failing]' '["findings",0,4,4]'
check "and what was scanned" json_is trufflehog.run-record.json '.target | [.source, .scope, .head, .base, .commits, .verification]' \
    "[\"git\",\"changes\",\"${C3}\",\"${MAIN_SHA}\",2,false]"
check "with TruffleHog's own summary" json_is trufflehog.run-record.json '.scan | [.chunks, .bytes, .trufflehog_version]' '[12,3456,"3.99.7"]'
check "the arguments without the plumbing" json_is trufflehog.run-record.json '.arguments[0:2]' '["git","--since-commit='"${MAIN_SHA}"'"]'
check "and counts by detector" json_is trufflehog.run-record.json '.counts.detectors' '{"AWS":1,"Github":1,"PrivateKey":1,"Slack":1}'
run fail_on=unknown -- STUB_RESULTS="${FINDINGS}"
check "fail_on unknown counts verified and unknown secrets" said "2 at or above fail_on (unknown)."
check "and skips the rest in JUnit" test "$(grep -o '<skipped' "${OUT}/junit/trufflehog.xml" | wc -l)" -eq 2
check "and as SARIF warnings" json_is trufflehog.sarif '[.runs[0].results[].level] | sort' '["error","error","warning"]'
run fail_on=verified verify=true -- STUB_RESULTS="${FINDINGS}"
check "fail_on verified counts verified secrets alone" said "1 at or above fail_on (verified)."
check "verify runs without --no-verification" lacks --no-verification
check "and warns what verification sends" said "WARN: verify is true, so TruffleHog sends each secret it finds to the service it belongs to"
run fail_on=verified
check "fail_on verified without verify is refused" rc_is 2
check "saying nothing could ever fail" said "so no secret can be verified and none would ever fail the step"
check "before trufflehog runs" not_run
run fail_on=critical
check "an unknown fail_on is refused" rc_is 2
run report_only=true run_record=true -- STUB_RESULTS="${FINDINGS}"
check "report_only reports them and passes" rc_is 0
check "with a warning" said "WARN: report_only is true, so this step passes."
check "the run record says findings-reported" json_is trufflehog.run-record.json '.outcome' '"findings-reported"'

echo "=== TruffleHog's log is shown without secrets"
ESCAPED_PEM=$(jq -rn --arg p "${PEM}" '$p | tojson | .[1:-1]')
LOG_LINE="{\"level\":\"error\",\"msg\":\"verification failed\",\"error\":\"token ${SECRET_A} and key ${ESCAPED_PEM} were rejected\"}"
run -- STUB_RESULTS="${FINDINGS}" STUB_LOG_LINE="${LOG_LINE}"
check "an error line in its log is shown as a warning" said "WARN: trufflehog: verification failed: token [REDACTED] and key"
check "with every secret replaced, also inside JSON escapes" no_secret_anywhere
run -- STUB_RESULTS="${FINDINGS}" STUB_LOG_LINE="${LOG_LINE}" STUB_EXIT=1
check "a run that fails shows its log" said "trufflehog: error: something went wrong"
check "and fails the step" rc_is 1
check "saying it is not a result" said "trufflehog exited with 1, so the scan did not complete."
check "without any secret" no_secret_anywhere
check "and without reports" no_report trufflehog.json
run -- STUB_RESULTS="${FINDINGS}" STUB_STDOUT_LINE="Found unverified result: ${SECRET_A}"
check "output that isn't a JSON result fails the step" rc_is 1
check "without showing it" said "It isn't shown, since it could hold a secret."
check "and holds no secret" no_secret_anywhere
LEAK="${WORK}/leak.jsonl"
result Hex "${C2}" > "${LEAK}"
run report_only=true -- STUB_RESULTS="${LEAK}"
check "a report that would hold a secret fails the step, report_only or not" rc_is 1
check "saying it was deleted" said "A report held part of a secret TruffleHog found, so the reports were deleted."
check "the JSON report is gone" no_report trufflehog.json
check "the SARIF report too" no_report trufflehog.sarif
SECRET_IN_PATH="${WORK}/path.jsonl"
result Github "${SECRET_A}" ".SourceMetadata.Data.Git.file = \"leaked/${SECRET_A}.txt\"" > "${SECRET_IN_PATH}"
run -- STUB_RESULTS="${SECRET_IN_PATH}"
check "a secret in a file's name is replaced" json_is trufflehog.json '.[0].file' '"leaked/[REDACTED].txt"'
check "everywhere" no_secret_anywhere

echo "=== a scan that has no verdict"
run report_only=true run_record=true -- STUB_EXIT=2
check "trufflehog failing fails the step, report_only or not" rc_is 1
check "the run record says error" json_is trufflehog.run-record.json '[.outcome, .exit_code]' '["error",1]'
SCAN_ERROR='{"level":"error","logger":"trufflehog","msg":"encountered errors during scan","job":"1","source_name":"trufflehog - git","errors":["unable to resolve commit"]}'
run report_only=true -- STUB_RESULTS="${CLEAN}" STUB_LOG_LINE="${SCAN_ERROR}"
check "a scan error TruffleHog only logs fails the step" rc_is 1
check "showing it" said "trufflehog - git: unable to resolve commit"
check "saying it may not have scanned everything" said "TruffleHog reported errors during the scan"
run report_only=true -- STUB_RESULTS="${CLEAN}" STUB_NO_SUMMARY=1
check "a run that never says it finished fails the step" rc_is 1
check "saying so" said "without logging that it finished scanning"
run report_only=true -- STUB_RESULTS="${CLEAN}" STUB_CHUNKS=0
check "a git scan that scanned nothing of 2 commits fails the step" rc_is 1
check "saying so" said "TruffleHog scanned nothing, though 2 commits were to be scanned"

echo "=== source filesystem"
run source=filesystem -- STUB_RESULTS="${CLEAN}"
check "a filesystem scan passes" rc_is 0
check "runs trufflehog filesystem" first_is filesystem
check "on the working directory" ends_with .
check "without the git options" lacks --since-commit
check "leaving out .git directories" grep -qxF '(^|/)\.git(/|$)' "${STUB}/calls/1.exclude"
printf 'fixtures/\n# a comment\nvendor/' > "${JOB}/exclude.txt"
run source=filesystem paths="config, keys" exclude_paths=exclude.txt -- STUB_RESULTS="${CLEAN}"
check "paths are scanned in order" ends_with config keys
check "with the user's exclusions as well" test "$(cat "${STUB}/calls/1.exclude")" = "$(printf 'fixtures/\n# a comment\nvendor/\n(^|/)\\.git(/|$)')"
run source=filesystem paths=missing
check "a path that doesn't exist is refused" rc_is 2
check "before trufflehog runs" not_run
run source=filesystem -- STUB_RESULTS="${CLEAN}" STUB_BYTES=0
check "a filesystem scan that read nothing fails the step" rc_is 1
check "saying how to allow it" said "Set allow_empty"
run source=filesystem allow_empty=true -- STUB_RESULTS="${CLEAN}" STUB_BYTES=0
check "unless allow_empty is true" rc_is 0
FS="${WORK}/fs.jsonl"
jq -c '.SourceMetadata = {Data: {Filesystem: {file: "app.env", line: 3}}} | .SourceType = 15' <<< "$(result Github "${SECRET_A}")" > "${FS}"
run source=filesystem working_dir=config -- STUB_RESULTS="${FS}"
check "a filesystem finding is listed" said "  app.env:3: Github (unverified)"
check "and named from the top of the checkout in SARIF" json_is trufflehog.sarif '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' '"config/app.env"'
check "with no commit" json_is trufflehog.json '.[0].commit' 'null'
for param in scope=history base_ref=main max_depth=3 'exclude_globs=*.lock'; do
    run source=filesystem "${param}"
    check "${param%%=*} with source filesystem is refused" rc_is 2
done

echo "=== other parameters"
printf 'src/\n' > "${JOB}/include.txt"
printf 'detectors: []\n' > "${JOB}/custom.yaml"
run include_paths=include.txt exclude_paths=exclude.txt config=custom.yaml include_detectors="github, aws" \
    exclude_detectors=slack no_ignore_tag=true -- STUB_RESULTS="${CLEAN}"
check "path filters and the configuration are passed by absolute path" \
    has "--exclude-paths=${JOB_PHYSICAL}/exclude.txt" "--include-paths=${JOB_PHYSICAL}/include.txt"
check "detectors are passed as lists" has "--include-detectors=github,aws" "--exclude-detectors=slack" "--config=${JOB_PHYSICAL}/custom.yaml" --no-ignore-tag
for param in include_paths=nope.txt exclude_paths=nope.txt config=nope.yaml; do
    run "${param}"
    check "${param%%=*} naming a file that doesn't exist is refused" rc_is 2
done
run include_detectors='github;rm'
check "a detector that can't be one is refused" rc_is 2
run extra_args='--concurrency 4 --detector-timeout=30s --force-skip-binaries --allow_verification_overlap' -- STUB_RESULTS="${CLEAN}"
check "extra_args takes TruffleHog's tuning options" rc_is 0
check "passing them on" has --concurrency 4 --detector-timeout=30s --force-skip-binaries --allow_verification_overlap
for words in --json '--results=verified' --no-verification --fail '--since-commit=abc' --no-force-skip-binaries -j \
    somewhere --concurrency '--force-skip-binaries=false' --only-verified --log-level=2 --local-dev; do
    run extra_args="${words}"
    check "extra_args '${words}' is refused" rc_is 2
    check "before trufflehog runs" not_run
done
run extra_args='"unclosed'
check "extra_args with an unclosed quote is refused" rc_is 1

echo "=== reports"
run -- STUB_RESULTS="${FINDINGS}"
check "(a run that leaves reports)" report trufflehog.json
run source=filesystem paths=missing
check "a later run that stops on its parameters removes them first" no_report trufflehog.json
check "the SARIF too" no_report trufflehog.sarif
run report_name=../escape
check "a report_name that isn't a plain name is refused" rc_is 1
run output_dir=relative/dir
check "a relative output_dir is refused" rc_is 1
run junit=false -- STUB_RESULTS="${CLEAN}"
check "junit false writes no JUnit" no_report junit/trufflehog.xml

echo "=== run records"
check "the scans wrote run records" test "${RECORDS}" -gt 0
problems=""
for record in "${WORK}/records/"*.json; do
    # shellcheck disable=SC2016 # jq program, not shell
    problem=$(jq -r --slurpfile schema "${ROOT}/schemas/run-record.v1.json" '$schema[0] as $schema
        | ($schema.required - keys | map("missing \(.)")[]),
          (select(.schema != $schema.properties.schema.const) | "schema is \(.schema)"),
          (select(.outcome as $o | $schema.properties.outcome.enum | index($o) | not) | "outcome \(.outcome)")' "${record}" 2>&1)
    [[ -n "${problem}" ]] && problems+="${record##*/}: ${problem}"$'\n'
done
OUTPUT=${problems}
check "every record has the fields the schema requires" test -z "${problems}"
if command -v python3 > /dev/null 2>&1 && python3 -c 'import jsonschema' 2> /dev/null; then
    OUTPUT=$(python3 - "${ROOT}/schemas/run-record.v1.json" "${WORK}/records/"*.json 2>&1 << 'EOF'
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
validator = jsonschema.Draft202012Validator(schema)
bad = 0
for path in sys.argv[2:]:
    for error in validator.iter_errors(json.load(open(path))):
        print(f"{path}: {'/'.join(map(str, error.path))}: {error.message}")
        bad += 1
sys.exit(1 if bad else 0)
EOF
    )
    RC=$?
    check "and validates against it with jsonschema" rc_is 0
else
    echo "  skip: Python's jsonschema is not installed, so only the checks above ran"
fi

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} command check(s) failed."
    exit 1
fi
echo "All command checks passed."
