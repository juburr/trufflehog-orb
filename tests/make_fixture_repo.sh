#!/usr/bin/env bash
#
# Makes the git repository the CI jobs scan with the real TruffleHog, in DIR:
#
#   DIR/origin.git  a bare repository with main
#   DIR/repo        a clone of it, on the branch feature
#
# main: a README, then deploy.env with a token (the "old" token), then a
# commit that deletes it, so it is only in history. feature, from main:
# config/app.env with a new token, and a third token on a line that ends in
# a trufflehog:ignore comment. clean, from main: a commit with no secret.
#
# The tokens have the shape of GitHub personal access tokens, which
# TruffleHog's GitHub detector reports without verifying them. They are
# random digits, made here, so the repository holds no secret, and no word
# in TruffleHog's false-positive lists can turn up in one. DIR/tokens lists
# them, one per line (old, new, ignored), for checking that no report or log
# holds them.
#
# Run from a checkout:
#   bash tests/make_fixture_repo.sh DIR

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 DIR" >&2
    exit 2
fi
DIR=$1
mkdir -p "${DIR}"
DIR=$(cd "${DIR}" && pwd)

token() {
    printf 'ghp_%s\n' "$(openssl rand -hex 18 | tr '0abcdef' '1234567')"
}
OLD=$(token)
NEW=$(token)
IGNORED=$(token)
printf '%s\n' "${OLD}" "${NEW}" "${IGNORED}" > "${DIR}/tokens"

commit() {
    git -C "${DIR}/repo" -c user.name="Fixture Author" -c user.email=author@example.com add -A
    git -C "${DIR}/repo" -c user.name="Fixture Author" -c user.email=author@example.com commit -q -m "$1"
}

git init -q --bare -b main "${DIR}/origin.git"
git clone -q "${DIR}/origin.git" "${DIR}/repo" 2> /dev/null
git -C "${DIR}/repo" symbolic-ref HEAD refs/heads/main
echo "# fixture" > "${DIR}/repo/README.md"
commit "start"
printf 'GITHUB_TOKEN=%s\n' "${OLD}" > "${DIR}/repo/deploy.env"
commit "add the deploy settings"
rm "${DIR}/repo/deploy.env"
commit "remove the deploy settings"
git -C "${DIR}/repo" push -q -u origin main 2> /dev/null
git -C "${DIR}/repo" remote set-head origin main

git -C "${DIR}/repo" checkout -q -b clean
echo "Nothing secret here." > "${DIR}/repo/docs.md"
commit "document"

git -C "${DIR}/repo" checkout -q -b feature main
mkdir -p "${DIR}/repo/config"
{
    printf 'token = "%s"\n' "${NEW}"
    printf 'other = "%s" # trufflehog:ignore\n' "${IGNORED}"
} > "${DIR}/repo/config/app.env"
commit "configure the app"

echo "Made ${DIR}/repo on feature, with origin/main $(git -C "${DIR}/repo" rev-parse --short origin/main)."
