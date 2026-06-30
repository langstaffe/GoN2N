#!/bin/sh

set -eu

VERSION="${VERSION:-v0.1.0}"
OUTPUT="${OUTPUT:-dist}"

mkdir -p "$OUTPUT"

build() {
	os="$1"
	arch="$2"
	name="$3"
	goarm="${4:-}"

	echo "building $name"
	CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" GOARM="$goarm" go build \
		-trimpath \
		-ldflags="-s -w" \
		-o "$OUTPUT/$name" \
		./cmd/gon2n
}

build windows amd64 gon2n-member-server-windows-x64.exe
build windows 386 gon2n-member-server-windows-x86.exe
build linux amd64 gon2n-member-server-linux-amd64
build linux 386 gon2n-member-server-linux-386
build linux arm64 gon2n-member-server-linux-arm64
build linux arm gon2n-member-server-linux-armv7 7

echo "release $VERSION written to $OUTPUT/"
