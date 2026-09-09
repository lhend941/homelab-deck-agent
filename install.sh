#!/usr/bin/env bash
#
# Installs the Homelab Deck agent on a Debian/Ubuntu box — an LXC, a VM, a Pi.
#
# Deliberately boring and re-runnable: it builds the binary, creates an
# unprivileged user, installs a systemd unit, and writes a config skeleton
# with a fresh pairing token. It never overwrites an existing config, because
# that file holds every credential the agent has.

set -euo pipefail

PREFIX="${PREFIX:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/homelab-deck}"
CONFIG="$CONFIG_DIR/config.json"
UNIT=/etc/systemd/system/homelab-deck-agent.service
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

[[ $EUID -eq 0 ]] || { echo "Run this with sudo." >&2; exit 1; }

# Three ways in.
#
#   --download [VERSION]  fetch a signed release binary from GitHub. This is
#                         the route for anyone who is not me: nothing to build,
#                         nothing to cross-compile, and the checksum is
#                         verified before anything is installed.
#   --binary PATH         install a binary built elsewhere — cross-compile on a
#                         Mac with build-linux.sh and the container needs no
#                         toolchain at all, so it can be 256MB of RAM.
#   (neither)             build from source here, which needs Swift.
BINARY=""
DOWNLOAD=""
VERSION="latest"
RELEASES="${RELEASES:-https://github.com/lhend941/homelab-deck-agent/releases}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="${2:-}"; shift 2 ;;
    --download)
      DOWNLOAD=1
      # Optional version argument; anything starting with - is the next flag.
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then VERSION="$2"; shift; fi
      shift ;;
    *) shift ;;
  esac
done

if [[ -n "$DOWNLOAD" ]]; then
  case "$(uname -m)" in
    x86_64|amd64)   ARCH=x86_64 ;;
    aarch64|arm64)  ARCH=aarch64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }

  BASE="$RELEASES/latest/download"
  [[ "$VERSION" != "latest" ]] && BASE="$RELEASES/download/$VERSION"

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  ASSET="homelab-deck-agent-linux-$ARCH"

  echo "→ downloading $ASSET ($VERSION)"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/$ASSET" "$BASE/$ASSET" || {
    echo "Download failed. Check $RELEASES for available versions." >&2; exit 1; }

  # A daemon that will hold every credential on your network is not something
  # to install from an unverified download. The checksum file is published
  # alongside the binary and this refuses to continue without it.
  echo "→ verifying checksum"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" || {
    echo "No SHA256SUMS published for $VERSION — refusing to install unverified." >&2
    exit 1; }
  EXPECTED="$(awk -v a="$ASSET" '$2 ~ a {print $1}' "$TMP/SHA256SUMS" | head -1)"
  [[ -n "$EXPECTED" ]] || { echo "SHA256SUMS has no entry for $ASSET." >&2; exit 1; }
  ACTUAL="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    echo "CHECKSUM MISMATCH — not installing." >&2
    echo "  expected $EXPECTED" >&2
    echo "  got      $ACTUAL" >&2
    exit 1
  fi
  echo "  ok ($ACTUAL)"
  BINARY="$TMP/$ASSET"
fi

if [[ -n "$BINARY" ]]; then
  [[ -f "$BINARY" ]] || { echo "No such binary: $BINARY" >&2; exit 1; }
  echo "→ installing the prebuilt binary to $PREFIX"
  install -m 0755 "$BINARY" "$PREFIX/homelab-deck-agent"
else
  command -v swift >/dev/null 2>&1 || {
    cat >&2 <<'MSG'
No binary given and Swift isn't installed here.

Either cross-compile on a Mac and pass the result:
    ./build-linux.sh
    scp agent/build/homelab-deck-agent-linux-x86_64 root@this-box:/tmp/agent
    sudo ./install.sh --binary /tmp/agent

Or install a Swift toolchain here:  https://swift.org/install/linux/
MSG
    exit 1
  }
  echo "→ building (this takes a few minutes the first time)"
  ( cd "$REPO" && swift build -c release --static-swift-stdlib )
  echo "→ installing to $PREFIX"
  install -m 0755 "$REPO/.build/release/homelab-deck-agent" "$PREFIX/homelab-deck-agent"
fi

id homelabdeck >/dev/null 2>&1 || {
  echo "→ creating the homelabdeck service user"
  useradd --system --no-create-home --shell /usr/sbin/nologin homelabdeck
}

mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG" ]]; then
  echo "→ keeping the existing $CONFIG"
else
  echo "→ writing a starter config"
  "$PREFIX/homelab-deck-agent" pair --config "$CONFIG"
fi
# The file holds credentials: owned by the service user, readable by nobody else.
chown -R homelabdeck:homelabdeck "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
chmod 600 "$CONFIG"

echo "→ installing the systemd unit"
install -m 0644 "$HERE/homelab-deck-agent.service" "$UNIT"
systemctl daemon-reload
systemctl enable homelab-deck-agent

cat <<MSG

Installed.

  1. Add your servers to $CONFIG
  2. systemctl start homelab-deck-agent
  3. journalctl -u homelab-deck-agent -f

Nothing is polled until at least one host is configured.

Do not port-forward this. Reach it over a tunnel or a VPN — the token is
authentication, not encryption, and the agent speaks plain HTTP by design.
MSG
