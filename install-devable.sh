#!/usr/bin/env bash
#
# install-devable.sh — downloads and installs the `devable` companion CLI
# (native binary, see apps/companion/) from the latest `companion/v*`
# GitHub release on devable-dev/devable-companion — a public, releases-only
# repo, so learners can install anonymously while the source repo stays
# private. This file is the source of truth; a copy is published to the
# release repo's root on each release (see docs/releasing-the-companion.md).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/devable-dev/devable-companion/main/install-devable.sh | bash
#   ./scripts/install-devable.sh [--dry-run] [--version vX.Y.Z]
#
# Options:
#   --dry-run        Resolve the release, print the tag/asset URL/install
#                     path, and exit 0 without downloading or installing
#                     anything.
#   --version vX.Y.Z  Install a specific companion version instead of the
#                      latest (matches the release tagged companion/vX.Y.Z).
#   -h, --help        Show this help.
#
# Env vars:
#   GITHUB_TOKEN / GH_TOKEN  Optional. Sent as an Authorization header when
#                            calling the GitHub API. The release repo is
#                            public, so learners need no token at all; set
#                            one only to lift GitHub's 60-req/hour
#                            unauthenticated rate limit.
#   INSTALL_DIR              Override the install directory entirely
#                            (skips the /usr/local/bin -> ~/.local/bin
#                            fallback logic below).
#
# Asset naming MUST match apps/companion/.goreleaser.yaml's archive
# name_template: `devable_{{ trimprefix .Tag "companion/v" }}_{{ .Os }}_{{ .Arch }}`
# (.tar.gz, or .zip on windows) — NOT `{{.Version}}`, which does nothing
# useful for a "companion/v*" tag (it fails semver parsing and, worse,
# leaves the literal "/" in place, corrupting the archive path). The
# template instead strips "companion/v" straight from the raw tag
# (e.g. tag companion/v1.2.3 -> asset devable_1.2.3_darwin_arm64.tar.gz) —
# see docs/releasing-the-companion.md for the full "why the tag looks the
# way it does" writeup, including how this was confirmed by hand.
#
# Install location: /usr/local/bin/devable if writable (using sudo if
# available and the directory needs elevated permissions), otherwise
# ~/.local/bin/devable, printing a PATH hint if that directory isn't
# already on PATH.

set -euo pipefail

REPO="devable-dev/devable-companion"
TAG_PREFIX="companion/v"
BINARY_NAME="devable"
DRY_RUN=false
REQUESTED_VERSION=""

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

log() { printf '%s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --version)
      [[ $# -ge 2 ]] || die "--version requires an argument (e.g. --version v1.2.3)"
      REQUESTED_VERSION="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

# ---- OS / arch detection -----------------------------------------------

detect_os() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin) echo "darwin" ;;
    Linux) echo "linux" ;;
    *) die "unsupported OS: $uname_s (this script supports macOS and Linux; for Windows see packaging/winget/Devable.Companion.yaml)" ;;
  esac
}

detect_arch() {
  local uname_m
  uname_m="$(uname -m)"
  case "$uname_m" in
    arm64 | aarch64) echo "arm64" ;;
    x86_64 | amd64) echo "amd64" ;;
    *) die "unsupported architecture: $uname_m" ;;
  esac
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

# Rosetta note: on Apple Silicon, `uname -m` reports the *process's*
# architecture, not the host's. A shell running under Rosetta 2 (e.g.
# launched from an x86_64 terminal app) reports x86_64 even on M-series
# hardware, so this script would install the amd64 binary — which runs
# fine under Rosetta, but the native arm64 build is smaller and faster.
# `sysctl.proc_translated == 1` means the current process IS translated.
if [[ "$OS" == "darwin" && "$ARCH" == "amd64" ]]; then
  if [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)" == "1" ]]; then
    log "note: detected an amd64 shell running under Rosetta 2 on Apple Silicon."
    log "      Installing the amd64 build (it runs fine via Rosetta). Run this"
    log "      script from a native arm64 shell to get the native binary instead."
  fi
fi

# ---- GitHub API -----------------------------------------------------------

GITHUB_API="https://api.github.com/repos/${REPO}"
AUTH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# Downloads a release asset to $1. Prefers the asset API url ($2) with an
# Authorization header when a token is available — required for private-repo
# assets, since browser_download_url ($3) is a redirect-to-storage link that
# does NOT accept an Authorization header (GitHub 404s auth'd requests to it
# for private repos). Falls back to the browser url when there's no token
# (public repo / anonymous case) or no API url was found for this asset.
download_asset() {
  local out="$1" api_url="$2" browser_url="$3"
  if [[ -n "$AUTH_TOKEN" && -n "$api_url" ]]; then
    curl -fsSL -H "Authorization: Bearer ${AUTH_TOKEN}" -H "Accept: application/octet-stream" -o "$out" "$api_url"
  else
    curl -fsSL -o "$out" "$browser_url"
  fi
}

no_release_message() {
  cat >&2 <<EOF

No companion release found on ${REPO} (looking for a release tagged
"${TAG_PREFIX}*").

If no release has been published yet, that's the whole explanation — see
docs/releasing-the-companion.md for the manual release runbook the owner
runs to publish one, then re-run this script.

Otherwise you may have hit GitHub's 60-req/hour unauthenticated rate
limit. Set GITHUB_TOKEN or GH_TOKEN and retry (e.g.
'export GITHUB_TOKEN="\$(gh auth token)"' if you have the GitHub CLI).
EOF
}

resolve_release() {
  # Fetch the release list (not just "latest") since the latest overall
  # GitHub release for this repo may not be a companion/v* one — this repo
  # will eventually host releases for other components too.
  local releases_json http_status tmp_body
  tmp_body="$(mktemp)"
  trap 'rm -f "$tmp_body"' RETURN

  local url="${GITHUB_API}/releases"
  local curl_auth=()
  if [[ -n "$AUTH_TOKEN" ]]; then
    curl_auth=(-H "Authorization: Bearer ${AUTH_TOKEN}")
  fi

  http_status="$(curl -sSL -o "$tmp_body" -w '%{http_code}' -H "Accept: application/vnd.github+json" "${curl_auth[@]+"${curl_auth[@]}"}" "$url" || echo "000")"

  if [[ "$http_status" == "404" ]]; then
    no_release_message
    exit 1
  elif [[ "$http_status" != "200" ]]; then
    die "GitHub API request failed (HTTP $http_status) for $url"
  fi

  releases_json="$(cat "$tmp_body")"

  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required to parse the GitHub API response (used in place of a jq dependency)"
  fi

  local tag_filter="$TAG_PREFIX"
  local requested="$REQUESTED_VERSION"
  RELEASE_JSON="$(
    printf '%s' "$releases_json" | python3 -c '
import json, sys
prefix = sys.argv[1]
requested = sys.argv[2]
releases = json.load(sys.stdin)
matches = [r for r in releases if r.get("tag_name", "").startswith(prefix)]
if requested:
    want = requested if requested.startswith(prefix) else prefix + requested.lstrip("v")
    matches = [r for r in matches if r.get("tag_name") == want]
if not matches:
    sys.exit(1)
# GitHub returns releases newest-created first; take the first match.
print(json.dumps(matches[0]))
' "$tag_filter" "$requested"
  )" || {
    no_release_message
    exit 1
  }
}

# ---- main -----------------------------------------------------------------

resolve_release

TAG_NAME="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
VERSION="${TAG_NAME#"$TAG_PREFIX"}"
ASSET_NAME="${BINARY_NAME}_${VERSION}_${OS}_${ARCH}.tar.gz"

# Two urls per asset: `url` is the GitHub API url (works for private-repo
# assets, but only with an Authorization header — see download_asset above);
# `browser_download_url` is the public redirect-to-storage url (works
# without auth, but only for public repos/assets).
ASSET_API_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c "
import json, sys
name = sys.argv[1]
rel = json.load(sys.stdin)
for a in rel.get('assets', []):
    if a.get('name') == name:
        print(a.get('url', ''))
        break
" "$ASSET_NAME")"

ASSET_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c "
import json, sys
name = sys.argv[1]
rel = json.load(sys.stdin)
for a in rel.get('assets', []):
    if a.get('name') == name:
        print(a.get('browser_download_url', ''))
        break
" "$ASSET_NAME")"

CHECKSUMS_API_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c "
import json, sys
rel = json.load(sys.stdin)
for a in rel.get('assets', []):
    if a.get('name') == 'checksums.txt':
        print(a.get('url', ''))
        break
")"

CHECKSUMS_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c "
import json, sys
rel = json.load(sys.stdin)
for a in rel.get('assets', []):
    if a.get('name') == 'checksums.txt':
        print(a.get('browser_download_url', ''))
        break
")"

if [[ -z "$ASSET_URL" ]]; then
  die "release ${TAG_NAME} has no asset named ${ASSET_NAME} (OS=${OS} ARCH=${ARCH}) — the release may be missing a platform build; check ${GITHUB_API}/releases/tags/${TAG_NAME}"
fi

# ---- install path resolution ----------------------------------------------

resolve_install_dir() {
  if [[ -n "${INSTALL_DIR:-}" ]]; then
    echo "$INSTALL_DIR"
    return
  fi
  if [[ -w "/usr/local/bin" ]] || (command -v sudo >/dev/null 2>&1 && [[ -d "/usr/local/bin" ]]); then
    echo "/usr/local/bin"
    return
  fi
  echo "$HOME/.local/bin"
}

INSTALL_DIR="$(resolve_install_dir)"
INSTALL_PATH="${INSTALL_DIR}/${BINARY_NAME}"

if $DRY_RUN; then
  will_use_asset_url="$ASSET_URL"
  if [[ -n "$AUTH_TOKEN" && -n "$ASSET_API_URL" ]]; then
    will_use_asset_url="$ASSET_API_URL (via API url + auth header — token present)"
  fi
  cat <<EOF
dry run — nothing downloaded or installed

  repo:            ${REPO}
  resolved tag:     ${TAG_NAME}
  resolved version: ${VERSION}
  os/arch:          ${OS}/${ARCH}
  asset name:       ${ASSET_NAME}
  asset url:        ${will_use_asset_url}
  checksums url:    ${CHECKSUMS_URL:-<none found on this release>}
  install path:     ${INSTALL_PATH}
EOF
  exit 0
fi

# ---- download, verify, install --------------------------------------------

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log "downloading ${ASSET_NAME}..."
download_asset "${WORKDIR}/${ASSET_NAME}" "$ASSET_API_URL" "$ASSET_URL"

if [[ -n "$CHECKSUMS_URL" ]]; then
  log "verifying checksum..."
  download_asset "${WORKDIR}/checksums.txt" "$CHECKSUMS_API_URL" "$CHECKSUMS_URL"
  # `|| true`: under `set -e` + `pipefail`, a no-match grep (exit 1) would
  # otherwise abort the script right here instead of reaching the friendly
  # die() below when checksums.txt has no entry for this asset.
  EXPECTED_SUM="$(grep " ${ASSET_NAME}\$" "${WORKDIR}/checksums.txt" | awk '{print $1}' || true)"
  if [[ -z "$EXPECTED_SUM" ]]; then
    die "checksums.txt on release ${TAG_NAME} has no entry for ${ASSET_NAME}"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SUM="$(sha256sum "${WORKDIR}/${ASSET_NAME}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    ACTUAL_SUM="$(shasum -a 256 "${WORKDIR}/${ASSET_NAME}" | awk '{print $1}')"
  else
    die "neither sha256sum nor shasum is available to verify the download"
  fi
  if [[ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]]; then
    die "checksum mismatch for ${ASSET_NAME}: expected ${EXPECTED_SUM}, got ${ACTUAL_SUM}"
  fi
  log "checksum OK"
else
  log "warning: no checksums.txt found on this release — skipping verification"
fi

log "extracting..."
tar -xzf "${WORKDIR}/${ASSET_NAME}" -C "$WORKDIR" "$BINARY_NAME"

mkdir -p "$INSTALL_DIR"
if [[ -w "$INSTALL_DIR" ]]; then
  install -m 755 "${WORKDIR}/${BINARY_NAME}" "$INSTALL_PATH"
elif command -v sudo >/dev/null 2>&1; then
  log "installing to ${INSTALL_PATH} requires sudo..."
  sudo install -m 755 "${WORKDIR}/${BINARY_NAME}" "$INSTALL_PATH"
else
  die "cannot write to ${INSTALL_DIR} and sudo is unavailable; set INSTALL_DIR to a writable directory and re-run"
fi

log "installed ${BINARY_NAME} ${VERSION} -> ${INSTALL_PATH}"

case ":$PATH:" in
  *":${INSTALL_DIR}:"*) : ;;
  *)
    log ""
    log "note: ${INSTALL_DIR} is not on your PATH. Add it, e.g.:"
    log "  echo 'export PATH=\"${INSTALL_DIR}:\$PATH\"' >> ~/.zshrc   # or ~/.bashrc"
    ;;
esac

log ""
log "run '${BINARY_NAME} doctor' to check your environment, then '${BINARY_NAME} login'."
