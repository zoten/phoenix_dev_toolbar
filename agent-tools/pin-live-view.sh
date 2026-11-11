#!/bin/sh
# Rewrites the LiveView requirement in mix.exs, for the minimum CI row only
# (ADR 06): .github/workflows/ci.yml and agent-tools/ci-min.sh run it on a
# throwaway checkout. Never run it on a tree you commit or publish from.
#
#   agent-tools/pin-live-view.sh "~> 1.1.0"
set -eu

requirement="${1:?usage: pin-live-view.sh REQUIREMENT}"
line='      {:phoenix_live_view, "~> 1.1"},'

grep -qxF "$line" mix.exs || { echo "pin-live-view: no '$line' in mix.exs" >&2; exit 1; }
sed -i "s|^      {:phoenix_live_view, \"~> 1.1\"},\$|      {:phoenix_live_view, \"$requirement\"},|" mix.exs
grep -n ':phoenix_live_view' mix.exs
