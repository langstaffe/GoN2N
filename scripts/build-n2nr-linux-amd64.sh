#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
N2N_VERSION="${N2N_VERSION:-3.1.1}"
N2NR_VERSION="${N2NR_VERSION:-v0.1.0}"
TARGET="${TARGET:-linux-amd64}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/dist/n2nR-build}"
OUTPUT_DIR="${OUTPUT:-$ROOT_DIR/dist}"
N2N_URL="${N2N_URL:-https://github.com/ntop/n2n/archive/refs/tags/$N2N_VERSION.tar.gz}"
PATCH_FILE="$ROOT_DIR/patches/n2nR-fast-reconnect.patch"
N2N_DIR="$BUILD_ROOT/n2n-$N2N_VERSION-$TARGET"

case "$TARGET" in
	linux-amd64)
		HOST=""
		: "${CC:=gcc}"
		: "${OUTPUT_NAME:=n2nR-linux-amd64}"
		;;
	linux-arm64)
		HOST="aarch64-linux-gnu"
		: "${CC:=aarch64-linux-gnu-gcc}"
		: "${OUTPUT_NAME:=n2nR-linux-arm64}"
		;;
	linux-armv7|linux-armhf)
		HOST="arm-linux-gnueabihf"
		: "${CC:=arm-linux-gnueabihf-gcc}"
		: "${OUTPUT_NAME:=n2nR-linux-armv7}"
		;;
	linux-386|linux-i386)
		HOST="i686-linux-gnu"
		: "${CC:=i686-linux-gnu-gcc}"
		: "${OUTPUT_NAME:=n2nR-linux-386}"
		;;
	*)
		echo "unsupported TARGET: $TARGET" >&2
		echo "supported: linux-amd64, linux-arm64, linux-armv7, linux-386" >&2
		exit 1
		;;
esac

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
	tmp_dir="$BUILD_ROOT/.extract-$N2N_VERSION-$TARGET"
	rm -rf "$tmp_dir"
	mkdir -p "$tmp_dir"
	tar -xzf "$archive" -C "$tmp_dir"
	mv "$tmp_dir/n2n-$N2N_VERSION" "$N2N_DIR"
	rmdir "$tmp_dir"
fi

if git -C "$N2N_DIR" apply --recount --check "$PATCH_FILE"; then
	git -C "$N2N_DIR" apply --recount "$PATCH_FILE"
elif git -C "$N2N_DIR" apply --recount --reverse --check "$PATCH_FILE"; then
	echo "n2nR patch is already applied"
else
	echo "failed to apply n2nR patch" >&2
	exit 1
fi

cd "$N2N_DIR"

if [ ! -x ./configure ]; then
	./autogen.sh
fi

if [ ! -f config.mak ]; then
	if [ -n "$HOST" ]; then
		CC="$CC" ./configure --host="$HOST"
	else
		CC="$CC" ./configure
	fi
fi

make supernode CFLAGS="${CFLAGS:-} -DGON2N_VERSION=\\\"$N2NR_VERSION\\\""

cp supernode "$OUTPUT_DIR/$OUTPUT_NAME"
chmod 755 "$OUTPUT_DIR/$OUTPUT_NAME"

echo "wrote $OUTPUT_DIR/$OUTPUT_NAME"
