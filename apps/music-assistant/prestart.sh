#!/bin/sh
# app-prestart hook — intentionally a no-op.
#
# This app needs no app-specific prestart logic. The file exists solely to work
# around a bug in container-packaging-tools' generated framework prestart.sh,
# whose final line `[ -f <hook> ] && . <hook>` returns 1 — which, under
# `set -e`, fails the systemd ExecStartPre so the container never starts —
# whenever this hook is ABSENT. Shipping a present, zero-exit hook makes that
# line succeed. (The builder copies an app's prestart.sh in as app-prestart.sh.)
#
# Safe to delete once the upstream fix ships and our build picks it up:
#   https://github.com/halos-org/container-packaging-tools/pull/219
true
