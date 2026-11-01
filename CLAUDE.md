# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, for TruffleHog, Truffle Security's scanner for leaked secrets. The orb installs a checksum-verified TruffleHog and wraps scanning with a gate and reports that never hold any part of a secret: `install` and `scan`. TruffleHog's live verification (trying each secret against its service) is off unless `verify` is true. TruffleHog is AGPL-3.0; the orb downloads the official release and runs it unmodified, and must never vendor TruffleHog's code or test data, or publish a binary built from it.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh

# Tests (offline; git, jq, and python3 with jsonschema for the run record schema)
for t in tests/*_test.sh; do bash "$t" || break; done

# Run the scan script with its YAML defaults (what test-deploy.yml uses for steps that must fail)
bash tests/run_command.sh scan working_dir=/path/to/checkout

# The repository the CI jobs scan with the real TruffleHog
bash tests/make_fixture_repo.sh /tmp/fixture

# Print checksum table entries for a new TruffleHog release (needs cosign 2 and openssl)
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - `install` and `scan`, one script each in `scripts/`
- `scripts/lib/trufflehog.sh` - Helpers shared by the command scripts, passed to each step as `SCRIPT_TRUFFLEHOG_LIB: << include(scripts/lib/trufflehog.sh) >>` and `eval`ed after a check that it is set. Only defines functions and variables; no `set` line. Its state lives in `TH_` variables.
- `examples/` - Usage examples, pinned to the orb's current version
- `../schemas/run-record.v1.json` - The run record's JSON Schema. Its URL is in every run record, so fields are only ever added within v1.
- `../actions/<command>/action.yml` - The GitHub Action for each command (see below)

### Install (`scripts/install.sh`, `install_hash.sh`)

`install.sh` follows the layout every juburr orb's install.sh shares: a tool definition, the shared install logic (byte-identical across the orbs; never edit it here alone), and the `sha512sums` table keyed `"<version>/<arch>"`, holding the SHA-512 of the `trufflehog` binary at the root of `trufflehog_<version>_linux_<amd64|arm64>.tar.gz`. `tests/install_test.sh` is the shared install contract; its tool fixture section adds the `download_base_url` mirror checks. `scripts/cache_key.sh` is shared too. The tool definition:

- **Mirror.** `tool_install` reads `download_base_url` (`trufflehog_download_base_url`), an https mirror that replaces `https://github.com` in the release URL, refusing credentials, a query or a fragment, then runs the shared single-binary install.
- **Smoke test.** `tool_version` runs `trufflehog --no-update --version` without `OVERSEER_BIN_CHECK`, `GO_UPGRADE_BIN_CHECK` and `OVERSEER_IS_SLAVE`. `--version` exits while kingpin parses the flags, before the updater runs. The Linux binaries are UPX-packed (since 3.88.5), so `go version -m` can't read them.

The table covers 3.97.0 to 3.99.7; 3.99.5 (and 3.95.4) were tagged without release assets. `install_hash.sh`'s `verify_upstream` requires, for each release:

1. cosign 2 verifying `trufflehog_<version>_checksums.txt` against its detached `.sig` and `.pem` (GoReleaser's keyless `sign-blob`, no bundle) for the exact identity `https://github.com/trufflesecurity/trufflehog/.github/workflows/release.yml@refs/tags/v<version>` and issuer `https://token.actions.githubusercontent.com`. TruffleHog's README suggests a looser identity regex; the orb pins the tag. The `.pem` is base64-encoded.
2. The certificate's `notBefore` (signing time) at least `TRUFFLEHOG_MIN_RELEASE_AGE_DAYS` (default 7) days ago.
3. The archive's SHA-256 in that list.

TruffleHog publishes no SLSA provenance or GitHub attestations. To add a release: run `install_hash.sh -v <version>` once it is 7 days old, paste the entries into the table, newest first, and move the default in `install.yml` and `actions/install/action.yml` (and the README's pins and badge) when it is the newest. `tests/wiring_test.sh` requires the default to be the newest table entry. The `install-hash` job in `.github/workflows/actions.yml` runs it for the default with cosign 2.6.5 from cosign-orb's action.

### `scripts/scan.sh`

Runs `trufflehog <git|filesystem> --json --no-update --no-color [options] -- <target>` with stdout (results) and stderr (JSON logs) in the step's `mktemp -d` work directory, with `TMPDIR` inside it and through `th_run`.

- **Order.** `output_dir` and `report_name` are checked and the earlier run's reports removed first, then every parameter is checked before anything runs (`usage`, exit 2). A failure after that (`stop`) removes the reports, writes an `error` run record and exits 1, whatever `report_only` says.
- **Never the secret.** TruffleHog's JSON results hold the secret in full in `Raw`, `RawV2` and `SecretParts`; `Redacted` often holds its first characters; `ExtraData` is free-form (account IDs, user names). `TH_FINDINGS_JQ` builds the orb's findings from `DetectorName`, `DetectorType`, `DetectorDescription`, `DecoderName`, `Verified`, `VerificationError` and the source metadata's `file`, `line`, `commit`, `email` and `timestamp`, and every kept string goes through `scrub`, which replaces every string `TH_SECRETS_JQ` collected (`Raw`, `RawV2`, `SecretParts` values, each line of a multi-line one, at least 4 characters, longest first), raw and JSON-escaped. TruffleHog's log is only shown through `th_scrub`. Stdout is never printed: a line that isn't a JSON object fails the step without being shown. `finish` checks every string value of the JSON and SARIF reports for every secret and fails (deleting the reports) if one holds any. The SARIF fingerprint is detector and location, never a hash of the secret.
- **Results.** A result is `verified` when `Verified`, `unknown` when `VerificationError` is set (with verification off that is two detectors matching the same text, or an encrypted private key), else `unverified`. `--results=verified,unknown,unverified` is always passed, and `fail_on` (`unverified` < `unknown` < `verified`) decides which fail; `fail_on: verified` without `verify` is refused, since it could never fail.
- **No verdict.** A non-zero exit; a `msg: "encountered errors during scan"` log line (TruffleHog exits 0 after an unresolvable ref, a missing path, no merge base); no `msg: "finished scanning"` line (a signal, or an early exit); a git scan with commits to scan and `chunks` 0 (a `git log` failing mid-scan is only logged at V(2)); a filesystem scan with `bytes` 0 unless `allow_empty`. `--fail` and `--fail-on-scan-errors` are never passed: the first exits 183 like a finding, the second exits before the summary line.
- **git.** The repository is the checkout the working directory is in (`git rev-parse --show-toplevel`), passed as a percent-encoded `file://` URI (TruffleHog reads the parsed URL's path). TruffleHog clones it to a temporary directory (the CVE-2025-41390 fix) with `+refs/*:refs/remotes/origin/*`, where `refs/remotes/origin/main` becomes `refs/remotes/origin/remotes/origin/main`, so ref names don't resolve: the orb always passes SHAs.
  - A partial clone (CircleCI's `checkout` is blobless by default since November 2025) can't be cloned: upload-pack never fetches missing objects from a promisor remote ("lazy fetching disabled"). So `complete_partial_clone`, when `extensions.partialclone` or a `remote.<name>.promisor` names a promisor remote, lists what the refs reach that the checkout lacks (`git rev-list --objects --all --missing=print`, which fetches nothing) and fetches it as git's own lazy fetch does (`-c fetch.negotiationAlgorithm=noop fetch --no-tags --no-write-fetch-head --recurse-submodules=no --filter=blob:none --stdin <remote>`, object IDs on stdin, no ref updated), up to 5 passes (a treeless clone takes two). The run record has `partial_clone` and `fetched_objects`. With `--trust-local-git-config` TruffleHog scans in place, so nothing is fetched first. `tests/commands_test.sh` runs the stand-in with `STUB_CLONE`, which clones the target as TruffleHog does.
  - `changes`: the merge base of the base and HEAD as `--since-commit`, HEAD's SHA as `--branch`. The base is `base_ref`; else, on GitHub Actions (`GITHUB_EVENT_PATH`), `pull_request.base.sha` (also for `pull_request_target`), a push's `before` (all zeros for a new branch: skipped), or `merge_group.base_sha`; else `origin/HEAD`, `origin/main`, `origin/master`. A base the checkout lacks fails with the `fetch-depth: 0` hint. No commits in the range passes without running TruffleHog, with empty reports.
  - `history`: `--branch=<HEAD SHA>`. `all`: neither (TruffleHog's `--all`: every ref, tags, stash and remote-tracking refs included). Both warn on a shallow checkout, where the oldest commit reads as adding every file.
- **filesystem.** `paths` (default `.`) after `--`, each checked to exist (TruffleHog logs a missing one as a scan error). `.git` directories are left out with `(^|/)\.git(/|$)` appended to an orb-written `--exclude-paths` file (after the user's lines): TruffleHog has no default exclusions, ignores `.gitignore`, and `.git/config` holds the token `actions/checkout` persists.
- **Environment.** `th_run` unsets `PRE_COMMIT`, `HUSKY`, `HUSKY_GIT_PARAMS` and `TRUFFLEHOG_PRE_COMMIT` (since 3.93.0 they turn a git scan into HEAD..HEAD with its own `--results` and `--fail`) and `OVERSEER_BIN_CHECK`, `GO_UPGRADE_BIN_CHECK`, `OVERSEER_IS_SLAVE` (overseer, the process supervisor TruffleHog always runs, prints and exits 0, or skips itself). The git and filesystem flags read no environment variables. `TMPDIR` is the work directory's, since TruffleHog removes other processes' `trufflehog-<pid>-<n>` directories when it starts.
- **extra_args** is an allow-list of tuning options (`VALUE_OPTIONS`, `FLAG_OPTIONS`; `--flag_name` is read as `--flag-name`), since kingpin gives every boolean a `--no-` form; anything else, and any word that isn't an option, is refused.
- **Reports.** `<report_name>.json` (the findings), `<report_name>.sarif` (findings with a file, URIs from the top of the checkout by `th_sarif_paths`, a file outside it as `file://`; commit-metadata findings are left out), `junit/<report_name>.xml`, and with `run_record` the run record (`TH_TARGET_JSON`, `TH_SCAN_JSON` from the summary line, `TH_COUNTS`). `output_dir` and `report_name` are not expanded, since the store steps read them as given.

### Shared helpers (`scripts/lib/trufflehog.sh`)

- From trivy-orb's: `th_subst`, `th_bool`, `split_shell_words`/`th_words`, `th_match` (C locale), `th_require_jq`, `th_output`, `th_uint`, `th_junit`, `th_gate`, `th_plural`, `th_tail`, `th_export`, `th_env_var_name`, `th_json_is` (never `jq -e` on a tool's output: jq 1.6 exits 0 on an empty file), `th_sha256`, `th_url_public`, `th_ci_json`, `th_args_json`.
- TruffleHog's own: `th_list`, `th_run`, `th_tool`, `TH_SECRETS_JQ`, `TH_SCRUB_JQ`, `th_scrub`, `th_rank`, `TH_FINDINGS_JQ`, `th_counts`, `TH_WHERE_JQ`, `th_print_findings`, `th_findings_junit`, `th_sarif_root`/`th_sarif_paths` (from openapi-orb), `th_sarif`, `th_tool_json`, `th_run_record`.
- Keep `schemas/run-record.v1.json` in step with `th_run_record`; `tests/commands_test.sh` checks every run record it writes against it.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT SCRIPT_TRUFFLEHOG_LIB=<lib>`. Inputs never appear inside a `run:` script. `install` restores and saves `actions/cache` with the command's key ingredients. `scan` names its artifact `trufflehog-reports-<report_name>-<random>` and uploads `output_dir` with `actions/upload-artifact` under `if: always()` and `store_artifacts`; `no_output_timeout` is CircleCI's. Every `uses:` is pinned to a commit SHA with its version in a comment.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. The action inputs were generated from the command YAML; keep them in sync by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number. The action descriptions leave out "Environment variables are expanded", since there is no CircleCI CLI on GitHub's runners. `tests/actions_test.sh` checks all of this.

### Tests

- `tests/install_test.sh`: the shared install contract, then `download_base_url`. Its fake credential URL ends in `# trufflehog:ignore`, since CI scans this repository's own commits with the orb; anything else secret-shaped in a test needs the same, or its markers split.
- `tests/commands_test.sh`: `scan.sh` through `tests/run_command.sh` (so with its YAML defaults), against a stand-in trufflehog that records each call's arguments, working directory, `TMPDIR` and the variables `th_run` unsets, copies `--exclude-paths` files, and answers with results and log lines the test builds, in a real git repository with an origin and a branch. The fake secrets (`ALL_SECRETS`) must appear nowhere in the log or under `output_dir`. The test's fake private key has its markers split, so a secret scan of this repository doesn't report it. It passes with bash 4.0, 4.3 and 5 first on the `PATH`.
- `tests/wiring_test.sh`: every `PARAM_` a script reads is passed, every parameter is used, reports are stored, run steps are named, the README documents every command and action, every trufflehog call that scans passes `--no-update`, and install defaults to the newest table entry.
- `tests/make_fixture_repo.sh DIR`: the repository the CI jobs scan with the real TruffleHog: a token only in main's history, one on the branch `feature`, one followed by `trufflehog:ignore`, and a branch `clean`; and `DIR/partial`, a blobless clone of it on `feature`. The tokens are `ghp_` and 36 random digits from 1 to 9, made at run time (TruffleHog's GitHub detector reports any of that shape without verifying it, and digits can't hit its false-positive word lists), listed in `DIR/tokens`.
- `tests/validate_reports.sh` (and `.py`, from openapi-orb): SARIF against the OASIS schema pinned by SHA-256, JUnit counts, run records.

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-install`, `test-env-subst` (env subst and shell conventions), `test-commands` (command and wiring tests, on `cimg/python` with jsonschema), `test-actions`, orb-tools lint, pack and review (`orb_name: trufflehog`), shellcheck.
- `.circleci/test-deploy.yml` - `install-test` (the default, its table entry, the cache, 3.97.0), `checksum-test` (the unlisted 3.96.0 refused before downloading, `known_versions` installing it, a local HTTPS mirror serving the real release, then one with a changed binary), `arm64-test` (install and a history scan), `scan-test` (the fixture every way: changes, history, all, filesystem, `no_ignore_tag`, `verify` with `fail_on: verified` against GitHub with the fake token, a blobless clone; what each found; a failing scan's log without the tokens; the clean branch; then the orb's own commits; then the reports validated). Publishing runs on `v*` tags.
- `.github/workflows/actions.yml` - The same with the actions on GitHub's runners: `offline-tests`, `install` (amd64 and arm64), `install-from-cache`, `install-hash`, `scan` (both architectures; the fixture's scans name `base_ref: origin/main`, since this run's event names commits the fixture doesn't have; then this run's own commits by the event's base).

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `th_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them (`tests/run_command.sh` sets them from the YAML).
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, so copy `"$@"` into an array only when `$#` is non-zero. No `declare -n` (bash 4.3).
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_TRUFFLEHOG_LIB}"`). Secrets never go on a command line, and nothing TruffleHog found is ever printed or written except through `TH_FINDINGS_JQ` or `th_scrub`.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script.
- The scripts must work with jq 1.6: never `jq -e` on a tool's output.

## Naming

Command names say what they do (`install`, `scan`). Parameters that map onto one TruffleHog flag take its long name in snake_case (`include_paths`, `exclude_paths`, `exclude_globs`, `include_detectors`, `exclude_detectors`, `config`, `no_ignore_tag`, `max_depth`); `source` is the TruffleHog source (`git`, `filesystem`), `scope` and `base_ref` choose the commits, `verify` turns verification on. Plumbing matches the other juburr orbs: `working_dir`, `paths`, `extra_args`, `output_dir`, `report_name`, `junit`, `run_record`, `report_only`, `allow_empty`, `store_artifacts`; `fail_on` as in trivy-orb and grype-orb.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh` and `yamllint .`
- Run every `tests/*_test.sh`, also with bash 4.0 and 4.3 first on the `PATH`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`, and validate `.circleci/test-deploy.yml` with the packed orb spliced in under `orbs.trufflehog-orb`
- Never run the real TruffleHog on a workstation you don't control; CI runs it
