#!/bin/bash
# Create a minimal Konflux Snapshot for supported VolSync FBC components.
# Queries each component's lastPromotedImage to construct the snapshot.
#
# Usage: ./create_supported_snapshots.sh <commit_sha> <volsync_version> <prod|dev> [no]
#
# Examples:
#   ./create_supported_snapshots.sh 1d53bde25fb1 0.14 prod          # prints + saves to file
#   ./create_supported_snapshots.sh 1d53bde25fb1 0.14 dev           # prints + saves to file
#   ./create_supported_snapshots.sh 1d53bde25fb1 0.14.2 prod        # 0.14.2 matches as 0.14
#   ./create_supported_snapshots.sh 1d53bde25fb1 0.14 prod no       # prints only, no file
#
# Requires: gh, oc, jq
# KUBECONFIG must point to the Konflux cluster.

set -euo pipefail

REPO="stolostron/volsync-operator-product-fbc"
NS="volsync-tenant"

# --- args ---
COMMIT="${1:?Usage: $0 <commit_sha> <volsync_version> <prod|dev> [no]}"
VS_VER_FULL="${2:?Usage: $0 <commit_sha> <volsync_version> <prod|dev> [no]}"
SUFFIX="${3:-}"
NOSAVE="${4:-}"

if [ -z "$SUFFIX" ]; then
  echo "" >&2
  echo "Missing 3rd argument. Which application?" >&2
  echo "" >&2
  echo "  volsync-fbc      →  $0 $COMMIT $VS_VER_FULL prod" >&2
  echo "  volsync-fbc-dev  →  $0 $COMMIT $VS_VER_FULL dev" >&2
  echo "" >&2
  exit 1
fi

# Normalize version: 0.14.2 → 0.14 (supported-versions.json uses major.minor only)
VS_VER=$(echo "$VS_VER_FULL" | cut -d. -f1,2)

# Resolve short commit SHA to full 40-char SHA
COMMIT=$(gh api "repos/${REPO}/commits/${COMMIT}" --jq '.sha')

# --- resolve naming ---
if [ "$SUFFIX" = "prod" ]; then
  APP="volsync-fbc"
  COMP_FMT="volsync-fbc-%s"        # volsync-fbc-4-17
elif [ "$SUFFIX" = "dev" ]; then
  APP="volsync-fbc-dev"
  COMP_FMT="volsync-fbc-%s-dev"    # volsync-fbc-4-17-dev
else
  echo "Invalid suffix: $SUFFIX (use prod or dev)" >&2
  exit 1
fi

SNAP_NAME="${APP}-${VS_VER//./-}-$(date +%Y%m%d-%H%M%S)"

# --- confirm settings ---
cat >&2 <<CONFIRM

──────────────────────────────────────
  commit:     ${COMMIT:0:12}
  volsync:    ${VS_VER_FULL} (matching as ${VS_VER})
  app:        ${APP}
  components: ${COMP_FMT/\%s/<OCP>}
  snapshot:   ${SNAP_NAME}
  save file:  $( [[ "$NOSAVE" =~ ^(n|no)$ ]] && echo "no" || echo "yes" )
──────────────────────────────────────

CONFIRM

read -r -p "Continue? [Y/n] " REPLY <&2
if [[ "${REPLY:-Y}" =~ ^[Nn] ]]; then
  echo "Aborted." >&2
  exit 0
fi

# --- 1. supported OCP versions from supported-versions.json at this commit ---
echo "" >&2
SUPPORTED=$(gh api "repos/${REPO}/contents/supported-versions.json?ref=${COMMIT}" --jq '.content' | base64 -d)
OCP_VERSIONS=$(echo "$SUPPORTED" | jq -r --arg vs "$VS_VER" '
  to_entries[] |
  select(
    (.value.min == "" or (.value.min | split(".") | map(tonumber)) <= ($vs | split(".") | map(tonumber))) and
    (.value.max == "" or (.value.max | split(".") | map(tonumber)) >= ($vs | split(".") | map(tonumber)))
  ) | .key
' | sort -V)

if [ -z "$OCP_VERSIONS" ]; then
  echo "No supported OCP versions for VolSync ${VS_VER}" >&2
  exit 1
fi

echo "VolSync ${VS_VER} → OCP: $(echo $OCP_VERSIONS | tr '\n' ' ')" >&2
echo "" >&2

# --- 2. query each component's promoted image ---
COMPONENTS=""
COUNT=0
for OCP in $OCP_VERSIONS; do
  COMP=$(printf "$COMP_FMT" "${OCP//./-}")
  COMP_STATUS=$(oc -n "$NS" get component "$COMP" -o jsonpath='{.status.lastBuiltCommit}{"\t"}{.status.lastPromotedImage}' 2>/dev/null || true)
  if [ -z "$COMP_STATUS" ]; then
    echo "  - ${COMP} (not found)" >&2
    continue
  fi
  BUILT_COMMIT="${COMP_STATUS%%	*}"
  IMAGE="${COMP_STATUS##*	}"
  if [ "$BUILT_COMMIT" != "$COMMIT" ]; then
    echo "  - ${COMP} (commit mismatch: ${BUILT_COMMIT:0:12})" >&2
    continue
  fi
  if [ -n "$IMAGE" ]; then
    COMPONENTS+="  - name: ${COMP}
    containerImage: ${IMAGE}
    source:
      git:
        dockerfileUrl: catalog.Dockerfile
        revision: ${COMMIT}
        url: https://github.com/${REPO}
"
    echo "  + ${COMP}" >&2
    COUNT=$((COUNT + 1))
  else
    echo "  - ${COMP} (no promoted image)" >&2
  fi
done

if [ "$COUNT" -eq 0 ]; then
  echo "No components found" >&2
  exit 1
fi

# --- 3. output snapshot ---
# Trim trailing newline from COMPONENTS to avoid blank line at end
COMPONENTS="${COMPONENTS%
}"

YAML="apiVersion: appstudio.redhat.com/v1alpha1
kind: Snapshot
metadata:
  name: ${SNAP_NAME}
  namespace: ${NS}
spec:
  application: ${APP}
  components:
${COMPONENTS}"

echo "" >&2
echo "── snapshot YAML ──────────────────" >&2
echo "" >&2
echo "$YAML" >&2
echo "" >&2
echo "── end ───────────────────────────" >&2

if [[ ! "$NOSAVE" =~ ^(n|no)$ ]]; then
  OUTPUT="snapshot-${SNAP_NAME}.yaml"
  echo "$YAML" > "$OUTPUT"
  echo "" >&2
  echo "Saved: ${OUTPUT}" >&2
fi

echo "" >&2
echo "Done: ${COUNT} components" >&2
