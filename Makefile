.PHONY: build release windows-release test fmt

build:
	go build -o bin/gon2n ./cmd/gon2n

release:
	sh scripts/build-release.sh

windows-release:
	sh scripts/build-release.sh

test:
	go test ./...

fmt:
	gofmt -w ./cmd ./internal
