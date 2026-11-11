#!/usr/bin/env bash
# Publishes the release that `mix bump` prepared: pushes main and its tag, waits
# for CI on that commit, then runs `mix hex.publish` (it shows the package and asks
# for confirmation and your Hex password).
#
#   ./publish.sh               # push, wait for CI, publish
#   ./publish.sh --dry-run     # checks and `mix hex.publish --dry-run`: nothing pushed or published
#   ./publish.sh --skip-ci     # do not wait for CI (it still runs on the push)
#
# First time on this machine: `mix hex.user auth`.
set -euo pipefail

dry_run=0
wait_ci=1

for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --skip-ci) wait_ci=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

fail() { echo "Aborting: $*" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel)"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "not on main."
[ -z "$(git status --porcelain)" ] || fail "the working tree is not clean."

version="$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)"
[ -n "$version" ] || fail "no @version in mix.exs."
tag="$version"

git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || fail "no tag $tag: run mix bump first."
[ "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse HEAD)" ] || fail "$tag is not on HEAD: run mix bump."

echo "==> $tag"

if [ "$dry_run" -eq 1 ]; then
  # --yes skips the "Proceed?" prompt: a dry run never uploads anything.
  echo "==> mix hex.publish --dry-run --yes"
  mix hex.publish --dry-run --yes
  echo "==> dry run done: nothing pushed or published"
  exit 0
fi

mix hex.user whoami >/dev/null 2>&1 || fail "not logged in to Hex: run mix hex.user auth."
[ "$wait_ci" -eq 0 ] || command -v gh >/dev/null 2>&1 || fail "gh not found (or use --skip-ci)."

read -r -p "Push main and $tag to origin, then publish $tag to Hex? [y/N] " answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || fail "not confirmed."

echo "==> git push origin main $tag"
git push origin main "$tag"

if [ "$wait_ci" -eq 1 ]; then
  sha="$(git rev-parse HEAD)"
  echo "==> waiting for CI on ${sha:0:7}"
  run_id=""
  for _ in $(seq 1 30); do
    run_id="$(gh run list --commit "$sha" --workflow CI --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
    [ -n "$run_id" ] && break
    sleep 5
  done
  [ -n "$run_id" ] || fail "no CI run found for ${sha:0:7}: check GitHub, then rerun with --skip-ci."
  gh run watch "$run_id" --exit-status || fail "CI failed on $tag: nothing published. Fix, then mix bump again."
fi

echo "==> mix hex.publish"
mix hex.publish

echo "==> published $tag: https://hex.pm/packages/phoenix_dev_toolbar"
