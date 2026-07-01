#!/bin/sh

set -eu

VERSION="${VERSION:-latest}"
REPO="${REPO:-langstaffe/GoN2N}"
INSTALL_DIR="${INSTALL_DIR:-/opt/gon2n}"
N2NR_PORT="${N2NR_PORT:-51873}"
MEMBER_PORT="${MEMBER_PORT:-51874}"
LEASE="${LEASE:-30s}"
ADDRESS_SUBNET="${ADDRESS_SUBNET:-10.239.180.0/24}"

if [ "$(id -u)" -ne 0 ]; then
	echo "Please run as root, for example: curl -fsSL <url> | sudo sh" >&2
	exit 1
fi

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Missing required command: $1" >&2
		exit 1
	fi
}

download_file() {
	url="$1"
	output="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fL "$url" -o "$output"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$output" "$url"
	else
		echo "curl or wget is required" >&2
		exit 1
	fi
}

resolve_latest_version() {
	if [ "$VERSION" != "latest" ]; then
		echo "$VERSION"
		return 0
	fi
	if command -v curl >/dev/null 2>&1; then
		tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	elif command -v wget >/dev/null 2>&1; then
		tag="$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	else
		echo "curl or wget is required" >&2
		exit 1
	fi
	if [ -z "$tag" ]; then
		echo "Could not resolve latest release for $REPO. Please rerun with VERSION=v0.1.0" >&2
		exit 1
	fi
	echo "$tag"
}

try_download_asset() {
	versioned_name="$1"
	fallback_name="$2"
	output="$3"
	if [ -n "${BASE_URL:-}" ]; then
		base_url="$BASE_URL"
	else
		base_url="https://github.com/$REPO/releases/download/$RESOLVED_VERSION"
	fi

	if download_file "$base_url/$versioned_name" "$output"; then
		return 0
	fi
	echo "Download failed for $versioned_name, trying $fallback_name"
	download_file "$base_url/$fallback_name" "$output"
}

detect_arch() {
	case "$(uname -m)" in
		x86_64|amd64)
			echo "amd64"
			;;
		i386|i686)
			echo "386"
			;;
		aarch64|arm64)
			echo "arm64"
			;;
		armv7l|armv7*)
			echo "armv7"
			;;
		*)
			echo "Unsupported architecture: $(uname -m)" >&2
			exit 1
			;;
	esac
}

random_token() {
	prefix="$1"
	length="$2"
	if command -v openssl >/dev/null 2>&1; then
		value="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "$length")"
	else
		value="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length")"
	fi
	echo "$prefix$value"
}

detect_public_host() {
	if [ -n "${PUBLIC_HOST:-}" ]; then
		echo "$PUBLIC_HOST"
		return 0
	fi
	if command -v curl >/dev/null 2>&1; then
		host="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
		if [ -n "$host" ]; then
			echo "$host"
			return 0
		fi
		host="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
		if [ -n "$host" ]; then
			echo "$host"
			return 0
		fi
	fi
	host="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
	if [ -n "$host" ]; then
		echo "$host"
		return 0
	fi
	return 1
}

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

share_uri() {
	server="$1"
	community="$2"
	shared_key="$3"
	member_secret="$4"
	member_url="http://$server:$MEMBER_PORT"
	json='{"format":"gon2n.share.v2","server":"'"$(json_escape "$server")"'","port":"'"$(json_escape "$N2NR_PORT")"'","community":"'"$(json_escape "$community")"'","addressSubnet":"'"$(json_escape "$ADDRESS_SUBNET")"'","memberServiceUrl":"'"$(json_escape "$member_url")"'","sharedKey":"'"$(json_escape "$shared_key")"'","memberServiceKey":"'"$(json_escape "$member_secret")"'","forceRelay":true,"preferTapMetric":true,"verboseEdgeLogs":false}'
	token="$(printf '%s' "$json" | base64 | tr -d '\n=' | tr '+/' '-_')"
	echo "gon2n:$token"
}

ARCH="$(detect_arch)"
RESOLVED_VERSION="$(resolve_latest_version)"
N2NR_DIR="$INSTALL_DIR/n2nR"
MEMBER_DIR="$INSTALL_DIR/member-server"
N2NR_BIN="$N2NR_DIR/n2nR-server-linux-$ARCH"
MEMBER_BIN="$MEMBER_DIR/gon2n-member-server"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

need_cmd uname
need_cmd install
need_cmd systemctl
need_cmd base64
need_cmd sed
need_cmd awk

COMMUNITY="${COMMUNITY:-$(random_token g 12)}"
SHARED_KEY="${SHARED_KEY:-$(random_token "" 24)}"
MEMBER_SECRET="${MEMBER_SECRET:-$(random_token "" 48)}"
PUBLIC_SERVER="$(detect_public_host || true)"
if [ -z "$PUBLIC_SERVER" ]; then
	echo "Could not detect public server address. Please rerun with PUBLIC_HOST=your.server.ip" >&2
	exit 1
fi

mkdir -p "$N2NR_DIR" "$MEMBER_DIR"

N2NR_DOWNLOAD="$TMP_DIR/n2nR-server"
MEMBER_DOWNLOAD="$TMP_DIR/gon2n-member-server"

try_download_asset \
	"n2nR-server-$RESOLVED_VERSION-linux-$ARCH" \
	"n2nR-server-linux-$ARCH" \
	"$N2NR_DOWNLOAD"
try_download_asset \
	"gon2n-member-server-$RESOLVED_VERSION-linux-$ARCH" \
	"gon2n-member-server-linux-$ARCH" \
	"$MEMBER_DOWNLOAD"

install -m 755 "$N2NR_DOWNLOAD" "$N2NR_BIN"
install -m 755 "$MEMBER_DOWNLOAD" "$MEMBER_BIN"

cat > /etc/systemd/system/n2nR-supernode.service <<EOF
[Unit]
Description=n2nR Supernode
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$N2NR_BIN -f -p $N2NR_PORT --gon2n-fast-reconnect
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/gon2n-member-server.service <<EOF
[Unit]
Description=GoN2N Member Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="GON2N_SHARED_SECRET=$MEMBER_SECRET"
ExecStart=$MEMBER_BIN member-server --listen :$MEMBER_PORT --lease $LEASE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable n2nR-supernode gon2n-member-server
systemctl stop n2nR-supernode gon2n-member-server 2>/dev/null || true
systemctl restart n2nR-supernode
systemctl restart gon2n-member-server

echo
echo "GoN2N server installed."
echo "release: $RESOLVED_VERSION"
echo "n2nR service: n2nR-supernode"
echo "member service: gon2n-member-server"
echo "n2nR port: $N2NR_PORT TCP/UDP"
echo "member-server port: $MEMBER_PORT TCP"
echo
echo "Copy this into GoN2N:"
share_uri "$PUBLIC_SERVER" "$COMMUNITY" "$SHARED_KEY" "$MEMBER_SECRET"
echo
echo "If clients cannot connect, make sure your cloud firewall allows TCP/UDP $N2NR_PORT and TCP $MEMBER_PORT."
