#!/usr/bin/env bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/prometheus/prometheus}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gardenlinux/gardenlinux/fips:1877.22}"
WORKDIR="${WORKDIR:-./.build/prometheus-fips-build}"
IMAGE_NAME="${IMAGE_NAME:-gl-fips-prometheus}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
VERSION="${VERSION:-3.15.0}"
UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA:-5241a27fe3c6983549fccc32f6e65917408c63cd}"
GO_IMAGE="${GO_IMAGE:-golang:1.27-bookworm}"
NODE_IMAGE="${NODE_IMAGE:-node:24-bookworm-slim}"

# --- prerequisites -----------------------------------------------------------

check_tool() { command -v "$1" &>/dev/null || { echo "error: $1 not found" >&2; exit 1; }; }
check_tool git
check_tool docker
docker buildx version &>/dev/null || { echo "error: docker buildx not available" >&2; exit 1; }

# --- buildx driver -----------------------------------------------------------

if ! docker buildx inspect fips-builder &>/dev/null; then
    docker buildx create --name fips-builder --driver docker-container
fi
docker buildx use fips-builder

# --- prepare source ----------------------------------------------------------

CLONE_DIR=".build/fips-port-prometheus"
if [ ! -d "${CLONE_DIR}" ]; then
    git clone "${REPO_URL}" "${CLONE_DIR}"
fi
git -C "${CLONE_DIR}" checkout "v${VERSION}"

mkdir -p "${WORKDIR}"

# --- generate Dockerfile.fips ------------------------------------------------

cat > "${WORKDIR}/Dockerfile.fips" <<DOCKERFILE
# ARGs used in FROM lines must be declared before the first FROM
ARG NODE_IMAGE
ARG GO_IMAGE

# Stage 1: build the web UI assets (Node + pnpm)
FROM --platform=\$BUILDPLATFORM \${NODE_IMAGE} AS node-ui
WORKDIR /src
COPY . .
RUN npm install -g corepack@latest && corepack enable pnpm && \\
    cd web/ui && pnpm install && \\
    cd react-app && pnpm install && cd .. && \\
    CI="" pnpm run build && \\
    cd /src && bash scripts/compress_assets.sh

# Stage 2: compile Prometheus and promtool
FROM --platform=\$BUILDPLATFORM \${GO_IMAGE} AS builder
ARG ARCH
ARG VERSION
ARG UPSTREAM_GIT_SHA
WORKDIR /src
COPY . .
COPY --from=node-ui /src/web/ui/static  web/ui/static
COPY --from=node-ui /src/web/ui/embed.go web/ui/embed.go
RUN sed -i 's|"crypto/md5"|"crypto/sha256"|' notifier/alertmanagerset.go && \\
    sed -i 's|hash := md5.Sum(b)|hash := sha256.Sum256(b)|' notifier/alertmanagerset.go
RUN CGO_ENABLED=0 GOARCH=\${ARCH} go build \\
    -tags netgo,builtinassets \\
    -ldflags "-s -w \\
        -X github.com/prometheus/common/version.Version=\${VERSION} \\
        -X github.com/prometheus/common/version.Revision=\${UPSTREAM_GIT_SHA} \\
        -X github.com/prometheus/common/version.Branch=HEAD \\
        -X github.com/prometheus/common/version.BuildUser=fips-builder \\
        -X github.com/prometheus/common/version.BuildDate=\$(date -u '+%Y%m%d-%H:%M:%S')" \\
    -o /prometheus ./cmd/prometheus && \\
    CGO_ENABLED=0 GOARCH=\${ARCH} go build \\
    -tags netgo,builtinassets \\
    -ldflags "-s -w \\
        -X github.com/prometheus/common/version.Version=\${VERSION} \\
        -X github.com/prometheus/common/version.Revision=\${UPSTREAM_GIT_SHA} \\
        -X github.com/prometheus/common/version.Branch=HEAD \\
        -X github.com/prometheus/common/version.BuildUser=fips-builder \\
        -X github.com/prometheus/common/version.BuildDate=\$(date -u '+%Y%m%d-%H:%M:%S')" \\
    -o /promtool ./cmd/promtool

# Stage 3: final GardenLinux FIPS image
FROM ${BASE_IMAGE}
ARG UPSTREAM_GIT_SHA
LABEL org.opencontainers.image.description="A FIPS-enabled Prometheus image"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="\${UPSTREAM_GIT_SHA}"
COPY --from=builder /prometheus /bin/prometheus
COPY --from=builder /promtool   /bin/promtool
COPY documentation/examples/prometheus.yml /etc/prometheus/prometheus.yml
COPY LICENSE  /LICENSE
COPY NOTICE   /NOTICE
RUN mkdir -p /prometheus && chown -R 65534:65534 /etc/prometheus /prometheus && chmod g+w /prometheus
ENV GODEBUG=fips140=only
WORKDIR /prometheus
EXPOSE 9090
USER 65534
ENTRYPOINT ["/bin/prometheus"]
CMD ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.path=/prometheus"]
DOCKERFILE

# --- build -------------------------------------------------------------------

docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg ARCH="${ARCH}" \
    --build-arg VERSION="${VERSION}" \
    --build-arg UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA}" \
    --build-arg GO_IMAGE="${GO_IMAGE}" \
    --build-arg NODE_IMAGE="${NODE_IMAGE}" \
    --load \
    --tag "${IMAGE_NAME}:${VERSION}-${ARCH}" \
    --file "${WORKDIR}/Dockerfile.fips" \
    "${CLONE_DIR}"

# --- report ------------------------------------------------------------------

echo "Built: ${IMAGE_NAME}:${VERSION}-${ARCH}"
