OCB_VERSION ?= $(shell awk '/collector\/receiver\/otlpreceiver/ {print $$4}' manifest.yaml)
GO_IMAGE ?= golang:1.26
IMAGE ?= hud-otelcol:dev
ARCH ?= $(shell docker version --format '{{.Server.Arch}}')

# Builds run in a Go container so the only local requirement is Docker.
GO_RUN = docker run --rm -v $(CURDIR):/src -w /src \
	-v hud-otelcol-gomod:/go/pkg/mod -v hud-otelcol-gocache:/root/.cache/go-build \
	-e CGO_ENABLED=0 -e GOFLAGS=-buildvcs=false -e GOOS=linux -e GOARCH=$(ARCH) $(GO_IMAGE)

.PHONY: build image smoke clean

build:
	$(GO_RUN) sh -c 'go install go.opentelemetry.io/collector/cmd/builder@$(OCB_VERSION) && builder --config manifest.yaml && chown -R $(shell id -u):$(shell id -g) _build'

image: build
	docker build -t $(IMAGE) -f Dockerfile _build

smoke: image
	IMAGE=$(IMAGE) ./test/smoke.sh

clean:
	rm -rf _build dist
