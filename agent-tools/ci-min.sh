#!/usr/bin/env bash
# Replays the minimum-supported CI row (.github/workflows/ci.yml: Elixir 1.17,
# OTP 26, LiveView ~> 1.1.0) in Docker, on a copy of the working tree.
#
# The copy holds tracked and untracked (not ignored) files, so uncommitted changes
# are tested. Nothing in the repo is touched: mix.lock, deps and _build live in the
# container and in named volumes (pdt-ci-min-*), reused between runs.
#
#   agent-tools/ci-min.sh              # compile and test, warnings as errors
#   agent-tools/ci-min.sh --clean      # drop the cached volumes first
#   PDT_CI_IMAGE=elixir:1.17-otp-26 PDT_LIVE_VIEW="~> 1.1.0" agent-tools/ci-min.sh
set -euo pipefail

image="${PDT_CI_IMAGE:-elixir:1.17-otp-26}"
live_view="${PDT_LIVE_VIEW:-~> 1.1.0}"
volumes=(pdt-ci-min-deps pdt-ci-min-build pdt-ci-min-home)

cd "$(git rev-parse --show-toplevel)"

if [ "${1:-}" = "--clean" ]; then
  docker volume rm -f "${volumes[@]}" >/dev/null
fi

# Tracked and untracked files that still exist (a deleted tracked file is skipped).
files() {
  git ls-files -co --exclude-standard -z |
    while IFS= read -r -d '' file; do
      [ -e "$file" ] && printf '%s\0' "$file"
    done
}

echo "ci-min: $image, LiveView $live_view"

files | tar --null -T - -cf - | docker run --rm -i \
  -e MIX_ENV=test \
  -e PDT_LIVE_VIEW="$live_view" \
  -e HOME=/home \
  -v pdt-ci-min-deps:/work/deps \
  -v pdt-ci-min-build:/work/_build \
  -v pdt-ci-min-home:/home \
  -w /work \
  "$image" sh -euc '
    tar -xf - -C /work
    mix local.hex --force --if-missing >/dev/null
    mix local.rebar --force --if-missing >/dev/null
    elixir --version | tail -1
    sh agent-tools/pin-live-view.sh "$PDT_LIVE_VIEW"
    mix deps.update phoenix_live_view
    mix deps.get
    mix compile --warnings-as-errors
    mix test --warnings-as-errors
  '

echo "ci-min: passed"
