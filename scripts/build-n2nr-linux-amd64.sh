#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
N2N_VERSION="${N2N_VERSION:-3.1.1}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/dist/n2nR-build}"
N2N_DIR="$BUILD_ROOT/n2n-$N2N_VERSION"
OUTPUT_DIR="${OUTPUT:-$ROOT_DIR/dist}"
OUTPUT_NAME="${OUTPUT_NAME:-n2nR-linux-amd64}"
N2N_URL="${N2N_URL:-https://github.com/ntop/n2n/archive/refs/tags/$N2N_VERSION.tar.gz}"
PATCH_FILE="$ROOT_DIR/patches/n2nR-fast-reconnect.patch"
PATCH_MARKER="$N2N_DIR/.gon2n-n2nr-patched"

mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"

if ! command -v git >/dev/null 2>&1; then
	echo "git is required to apply the n2nR patch" >&2
	exit 1
fi

if [ ! -d "$N2N_DIR" ]; then
	archive="$BUILD_ROOT/n2n-$N2N_VERSION.tar.gz"
	if [ ! -f "$archive" ]; then
		if command -v curl >/dev/null 2>&1; then
			curl -L "$N2N_URL" -o "$archive"
		elif command -v wget >/dev/null 2>&1; then
			wget -O "$archive" "$N2N_URL"
		else
			echo "curl or wget is required to download n2n $N2N_VERSION" >&2
			exit 1
		fi
	fi
	tar -xzf "$archive" -C "$BUILD_ROOT"
fi

if [ ! -f "$PATCH_MARKER" ]; then
	if git -C "$N2N_DIR" apply --recount --check "$PATCH_FILE"; then
		git -C "$N2N_DIR" apply --recount "$PATCH_FILE"
	elif git -C "$N2N_DIR" apply --recount --reverse --check "$PATCH_FILE"; then
		echo "n2nR patch is already applied"
	else
		echo "failed to apply n2nR patch" >&2
		exit 1
	fi
	touch "$PATCH_MARKER"
fi

cd "$N2N_DIR"

if [ ! -x ./configure ]; then
	./autogen.sh
fi

if [ ! -f config.mak ]; then
	./configure
fi

make supernode

cp supernode "$OUTPUT_DIR/$OUTPUT_NAME"
chmod 755 "$OUTPUT_DIR/$OUTPUT_NAME"

echo "wrote $OUTPUT_DIR/$OUTPUT_NAME"
