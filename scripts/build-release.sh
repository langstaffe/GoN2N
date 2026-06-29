#!/bin/sh

set -eu

VERSION="${VERSION:-0.1.0}"
OUTPUT="${OUTPUT:-dist}"

mkdir -p "$OUTPUT"

build() {
	os="$1"
	arch="$2"
	name="$3"

	echo "building $name"
	CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build \
		-trimpath \
		-ldflags="-s -w" \
		-o "$OUTPUT/$name" \
		./cmd/gon2n
}

build windows amd64 gon2n-windows-x64.exe

echo "release $VERSION written to $OUTPUT/"
