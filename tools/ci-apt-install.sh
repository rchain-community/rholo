#!/usr/bin/env bash
#
# ci-apt-install.sh — install apt packages with bounded retries, and fall back to the public Ubuntu
# archives when the runner's mirror cannot be reached.
#
# **Why this exists.** On 2026-11-11 three PR checks (Formatting/lints, Tests, Formal) failed before
# any Rust or Lean step ran, all on `Temporary failure resolving 'azure.archive.ubuntu.com'` — the
# GitHub-hosted runner's default apt mirror. The first version of this helper retried that mirror and
# still failed after four bounded attempts: the outage outlasted the retry window. A runner's mirror
# is infrastructure, not the PR, so after the runner's own sources have been tried, the install is
# retried against `archive.ubuntu.com` / `security.ubuntu.com`, which the same run was resolving fine
# for `packages.microsoft.com`.
#
# Usage: sudo tools/ci-apt-install.sh PACKAGE...   (root, as the workflows' sudo step)
#   APT_ATTEMPTS=4 APT_UPDATE_TIMEOUT=120 APT_INSTALL_TIMEOUT=420
#
set -uo pipefail

ATTEMPTS="${APT_ATTEMPTS:-4}"
UPDATE_TIMEOUT="${APT_UPDATE_TIMEOUT:-120}"
INSTALL_TIMEOUT="${APT_INSTALL_TIMEOUT:-420}"
FALLBACK_SOURCES="${APT_FALLBACK_SOURCES:-/tmp/ci-apt-ubuntu.sources}"

if (( $# == 0 )); then
  echo "usage: $0 PACKAGE..." >&2
  exit 2
fi

# Ubuntu 24.04 is `noble`; derive it so an `ubuntu-latest` bump is not a silent wrong suite.
CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-noble}")"
KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg

write_fallback_sources() {
  local signed_by=""
  if [[ -f "$KEYRING" ]]; then
    signed_by="Signed-By: $KEYRING"
  fi
  cat >"$FALLBACK_SOURCES" <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: $CODENAME $CODENAME-updates $CODENAME-backports
Components: main universe restricted multiverse
$signed_by

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: $CODENAME-security
Components: main universe restricted multiverse
$signed_by
EOF
}

apt_attempt() { # sources-override-or-empty package...
  local override=$1
  shift
  local opts=(
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=25
    -o Acquire::https::Timeout=25
  )
  if [[ -n "$override" ]]; then
    opts+=(
      -o "Dir::Etc::sourcelist=$override"
      -o "Dir::Etc::sourceparts=-"
      -o "APT::Get::List-Cleanup=0"
    )
  fi
  timeout "$UPDATE_TIMEOUT" apt-get "${opts[@]}" update \
    && timeout "$INSTALL_TIMEOUT" apt-get "${opts[@]}" install --no-install-recommends -y "$@"
}

wrote_fallback=0
for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
  override=""
  if (( attempt > 2 )); then
    if (( wrote_fallback == 0 )); then
      write_fallback_sources
      wrote_fallback=1
    fi
    override="$FALLBACK_SOURCES"
    echo "ci-apt-install: attempt ${attempt}/${ATTEMPTS} via the public archives ($FALLBACK_SOURCES)"
  else
    echo "ci-apt-install: attempt ${attempt}/${ATTEMPTS} via the runner's own sources"
  fi
  if apt_attempt "$override" "$@"; then
    echo "ci-apt-install: succeeded on attempt ${attempt}"
    exit 0
  fi
  echo "ci-apt-install: attempt ${attempt} failed" >&2
  if (( attempt < ATTEMPTS )); then
    sleep $((attempt * 15))
  fi
done

echo "ci-apt-install: all ${ATTEMPTS} attempts failed (runner mirror and public archives)" >&2
exit 1
