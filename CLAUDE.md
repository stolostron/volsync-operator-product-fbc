# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

File-Based Catalog (FBC) for the VolSync operator product, used to publish the operator to OpenShift's OLM (Operator Lifecycle Manager) via Konflux. There is no runnable application code — only catalog definitions, build scripts, Tekton pipelines, and a Dockerfile.

## Key concepts

- **catalog-template.yaml** — single source of truth for all operator versions, channels, and bundle images. All per-OCP catalog directories are generated from this file.
- **supported-versions.json** — maps each OCP version (e.g. `"4.17"`) to a `{min, max}` range of allowed VolSync operator minor versions. Empty string means no boundary in that direction.
- **catalog-\<OCP\>/** directories — rendered, decomposed catalogs (one per OCP version). These are generated artifacts; edit `catalog-template.yaml` and `supported-versions.json` instead.
- Bundle image references in the template use Konflux staging URLs during development; `render-catalog.sh` rewrites them to `registry.redhat.io/rhacm2/volsync-operator-bundle` for production.

## Build and validation commands

All scripts must be run from the repository root.

```bash
# Install opm CLI (fetches latest from GitHub)
make opm

# Validate all rendered catalog directories
make validate-catalog

# Build FBC container image (podman)
make build-image

# Run the catalog image locally on port 50051
make run-image

# Test the running catalog via gRPC (installs grpcurl if needed)
make test-image

# Stop the running catalog image
make stop-image
```

### Catalog management workflow

```bash
# 1. Add a new bundle from Konflux
./build/add-bundle.sh quay.io/redhat-user-workloads/volsync-tenant/volsync-bundle-X-Y@sha256:<sha>

# 2. Generate per-OCP catalog templates (prunes channels/bundles per supported-versions.json)
./build/generate-catalog-template.sh

# 3. Render and decompose catalogs into catalog-*/ directories
./build/render-catalog.sh

# 4. Validate the rendered catalogs
make validate-catalog
```

### Other scripts

```bash
# Validate all bundle images are reachable (requires registry credentials)
./build/validate-bundle-images.sh

# Generate a Konflux Snapshot for release (requires gh, oc, jq, KUBECONFIG)
./gen-fbc-snapshot.sh <commit_sha> <volsync_version> <prod|dev>

# Patch Tekton pipelines for new OCP versions (hermetic build, multi-arch, build-args)
./.tekton/pipeline-patch.sh
```

## Tool requirements

- **opm** — installed via `make opm`; required for catalog validation and rendering
- **yq** — used heavily by all build scripts for YAML manipulation
- **skopeo** — required by `add-bundle.sh` and `validate-bundle-images.sh` for image inspection
- **jq** — used by most scripts to read `supported-versions.json`
- **podman** — used by `make build-image` / `make run-image`

## Release context

- **VolSync-to-ACM version alignment:** VolSync `0.X.Z` maps to ACM `2.(X+1).Z` for VolSync <= 0.16. Starting from VolSync 0.17, the mapping shifts: `0.Y.Z` maps to ACM `5.(Y-17).Z` (e.g. VolSync 0.17.0 → ACM 5.0.0).
- **Branch workflow:** the `dev` branch is a scratch space for iterating on release candidates. Multiple RCs may be built and tested there. Only the chosen release candidate is merged (or PR'd) to `main` for production release.
- **Image registry stages:** Konflux builds land at `quay.io/redhat-user-workloads/volsync-tenant/...`. From there they promote to stage (`registry.stage.redhat.io`) and then production (`registry.redhat.io`). The released image is not necessarily the latest Konflux build — an older build that was already promoted to stage may be chosen instead.

## Things to know when making changes

- Rendered `catalog-*/` directories are generated output. Never edit them directly — modify `catalog-template.yaml` or `supported-versions.json`, then regenerate.
- OCP versions <= 4.16 use `olm.bundle.object` format; >= 4.17 use `olm.csv.metadata` (handled automatically by `render-catalog.sh`).
- After rendering, Konflux staging image URLs (`quay.io/redhat-user-workloads/...`) are automatically replaced with production registry URLs. If you need to re-render, revert the bundle reference in `catalog-template.yaml` to the Konflux URL first.
- The `add-bundle.sh` script manages the OLM upgrade graph: it sorts entries, builds the `replaces` chain, and respects `skips` entries for patch versions.
- Each OCP version has four Tekton pipeline files in `.tekton/`: `{pull-request,push}` x `{prod,dev}`.
- `gen-fbc-snapshot.sh` is interactive (confirmation prompt) and requires `KUBECONFIG` pointing to the Konflux cluster.

## Personal configuration

Read personal config at the start of any task that needs an assignee, email, or project key.
Use the tool-aware fallback chain: `~/.config/opencode/user.local.md` (OpenCode),
`.claude/user.local.md` (Claude Code), or `.cursor/rules/user.local.mdc` (Cursor, already in context).
If none exist, fall back to agent memory (`user-config`), then placeholders.
Run `make personalize` to generate all three files (if this repo uses Fleet Engineering tooling).

## Fleet Engineering Skills

All skills are available as slash commands. See the [Fleet Engineering skills catalog](https://github.com/OpenShift-Fleet/agentic-sdlc/blob/main/skills/README.md) for the full list with when-to-use guidance.
