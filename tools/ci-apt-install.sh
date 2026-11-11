#!/usr/bin/env bash
#
# ci-apt-install.sh — install apt packages with bounded retries and per-attempt timeouts.
#
# **Why this exists.** On 2026-11-11 three PR checks (Formatting/lints, Tests, Formal) failed before
# any Rust or Lean step ran, all on `Temporary failure resolving 'azure.archive.ubuntu.com'`. A
# runner's mirror/DNS failure is transient infrastructure; without a retry it is indistinguishable
# from a red PR, and a hung `apt-get` holds the job until its timeout. Apt's own `Acquire::Retries`
# covers a fetch, not an outage that lasts a minute; this loop covers the outage, and the per-attempt
# `timeout` makes a persistent failure fail fast instead of hanging.
#
# Usage: sudo tools/ci-apt-install.sh PACKAGE...   (root, as the workflows' sudo step)
#   APT_ATTEMPTS=4 APT_UPDATE_TIMEOUT=120 APT_INSTALL_TIMEOUT=420
#
set -uo pipefail

ATTEMPTS="${APT_ATTEMPTS:-4}"
UPDATE_TIMEOUT="${APT_UPDATE_TIMEOUT:-120}"
INSTALL_TIMEOUT="${APT_INSTALL_TIMEOUT:-420}"

if (( $# == 0 )); then
  echo "usage: $0 PACKAGE..." >&2
  exit 2
fi

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
  echo "ci-apt-install: attempt ${attempt}/${ATTEMPTS}: $*"
  if timeout "${UPDATE_TIMEOUT}" apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=25 update \
    && timeout "${INSTALL_TIMEOUT}" apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=25 \
      install --no-install-recommends -y "$@"; then
    echo "ci-apt-install: succeeded on attempt ${attempt}"
    exit 0
  fi
  echo "ci-apt-install: attempt ${attempt} failed" >&2
  if (( attempt < ATTEMPTS )); then
    sleep $((attempt * 15))
  fi
done

echo "ci-apt-install: all ${ATTEMPTS} attempts failed" >&2
exit 1
