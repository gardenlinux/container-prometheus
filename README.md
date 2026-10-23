build-prometheus-fips-report.txt
=================================

## Summary

**Application:** Prometheus — an open-source systems monitoring and alerting toolkit.
It collects and stores metrics as time series data, and is widely used as the
foundation for Kubernetes-native observability stacks.

**Triage results:**
- Primary language: Go
- FIPS mechanism: ENV GODEBUG=fips140=only (Go FIPS-only mode)
- Build pattern: D (generate Dockerfile.fips from scratch)
  Rationale: upstream Dockerfiles are designed for pre-built host binaries
  (they COPY from a local dist/ directory), not for a self-contained multi-stage
  Docker build. Pattern D was the only viable approach.

**Application metadata:**
- Version: 3.15.0
- License: Apache-2.0
- Upstream git SHA: 5241a27fe3c6983549fccc32f6e65917408c63cd

**FIPS crypto library:** Go standard library in FIPS-only mode (GODEBUG=fips140=only).
No external crypto library required; Go 1.27+ enforces FIPS 140-3 approved
algorithms when this environment variable is set.

**Built images:**
- gl-fips-prometheus:3.15.0-amd64  (379 MB compressed)


## Steps taken

- Cloned https://github.com/prometheus/prometheus, checked out v3.15.0
  (commit 5241a27fe3c6983549fccc32f6e65917408c63cd).

- Triage: go.mod present → Go. No existing Dockerfile suitable for multi-stage
  reuse (upstream uses host-built dist/ binaries). Selected Pattern D.
  License: Apache-2.0 (LICENSE file at repo root).

- Generated a three-stage Dockerfile:
  1. node-ui stage (node:24-bookworm-slim): builds the web UI assets via pnpm
     and runs scripts/compress_assets.sh to produce web/ui/static/ and
     web/ui/embed.go with //go:embed directives.
  2. builder stage (golang:1.27-bookworm): copies UI assets from node-ui,
     applies source patches, then compiles prometheus and promtool with
     -tags netgo,builtinassets and version ldflags.
  3. Final stage (ghcr.io/gardenlinux/gardenlinux/fips:1877.22): copies
     binaries and config, sets GODEBUG=fips140=only, runs as USER 65534 (nobody).

- Fix 1 — ARG scoping: ARG NODE_IMAGE and ARG GO_IMAGE must appear before the
  first FROM in the Dockerfile so they can be referenced in FROM lines. Initially
  placed between stages; moved to the top of the heredoc.

- Fix 2 — react-app excluded from pnpm workspace: Prometheus 3.x has a split UI
  (legacy react-app + new mantine-ui). The react-app is intentionally excluded
  from the pnpm workspace (per Makefile comment) to avoid dependency conflicts.
  Added an explicit "cd react-app && pnpm install && cd .." step before the
  shared pnpm run build, matching the upstream ui-install Makefile target.

- Fix 3 — chown nobody:nobody fails in gardenlinux: gardenlinux shadow-utils
  requires numeric GID in chown. Changed to chown -R 65534:65534.

- Fix 4 — MD5 panic in FIPS-only mode: Prometheus uses crypto/md5 in
  notifier/alertmanagerset.go to hash the alertmanager config for change
  detection. MD5 is not a FIPS-approved algorithm; calling it with
  GODEBUG=fips140=only causes an immediate panic on config load.
  Applied a sed patch in the builder stage to replace the import and call
  with crypto/sha256 / sha256.Sum256(). This is a non-security hash
  (change detection only), so SHA-256 is a correct drop-in replacement.


## Test script output (final run)

*** Checking if gl-fips-prometheus:3.15.0-amd64 docker image is available ***
[docker inspect output omitted for brevity — image present, created 2026-10-15]
*** Checking if gl-fips-prometheus:3.15.0-amd64 is based on gardenlinux ***
NAME="Garden Linux"  ✓
*** Checking if gl-fips-prometheus:3.15.0-amd64 is using FIPS-enabled gardenlinux image ***
VARIANT_ID=container-sslfips-amd64  ✓
*** Checking that gl-fips-prometheus:3.15.0-amd64 starts under a non-root user ***
effective_user=nobody (uid 65534)  ✓
*** Checking if gl-fips-prometheus:3.15.0-amd64 has GO FIPS mode enabled ***
GODEBUG=fips140=only  ✓
*** Checking if gl-fips-prometheus:3.15.0-amd64 contains org.opencontainers.image.description label ***
"A FIPS-enabled Prometheus image"  ✓
*** Checking if gl-fips-prometheus:3.15.0-amd64 contains org.opencontainers.image.licenses label ***
"Apache-2.0"  ✓
*** Checking if gl-fips-prometheus:3.15.0-amd64 contains org.opencontainers.image.revision label ***
"5241a27fe3c6983549fccc32f6e65917408c63cd"  ✓

All tests passed.


## Kubernetes (k3d) test run

Cluster: fips-test (k3d)
Image imported: gl-fips-prometheus:3.15.0-amd64

Pod manifest: .build/fips-port-prometheus-pod.yaml
Pod name: fips-port-prometheus

Pod logs (selected):
  time=2026-10-15T08:58:07.100Z level=INFO msg="Starting Prometheus Server"
    mode=server version="(version=3.15.0, branch=HEAD, revision=5241a27fe...)"
  time=2026-10-15T08:58:08.020Z level=INFO msg="Start listening for connections"
    component=web address=0.0.0.0:9090
  time=2026-10-15T08:58:08.053Z level=INFO msg="TSDB started"
  time=2026-10-15T08:58:08.053Z level=INFO msg="Loading configuration file"
    filename=/etc/prometheus/prometheus.yml
  time=2026-10-15T08:58:08.058Z level=INFO msg="Completed loading of configuration file"
    totalDuration=5.048023ms
  time=2026-10-15T08:58:08.058Z level=INFO msg="Server is ready to receive web requests."

| Image tag                        | Pod status | Pass/fail |
|----------------------------------|------------|-----------|
| gl-fips-prometheus:3.15.0-amd64 | Running    | Pass      |
