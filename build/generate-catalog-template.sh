#! /bin/bash

set -e

if [[ $(basename "${PWD}") != "volsync-operator-product-fbc" ]]; then
  echo "error: Script must be run from the base of the repository."
  exit 1
fi

echo "Using supported version Volsync-Product map:"
jq '.' supported-versions.json

ocp_versions=$(jq -r 'keys[]' supported-versions.json)

# Version comparison helpers relying on bash's built-in version sort
version_lt() {
  [[ "$1" != "$2" && "$1" == "$(printf "%s\n%s" "$1" "$2" | sort --version-sort | head -n1)" ]]
}

version_gt() {
  [[ "$1" != "$2" && "$1" == "$(printf "%s\n%s" "$1" "$2" | sort --version-sort | tail -n1)" ]]
}

# Evaluates if a version is outside the supported range (bounds are inclusive).
# Returns 0 (true) to prune, 1 (false) to keep.
shouldPrune() {
  local target_version="$1"
  local min="$2"
  local max="$3"

  if [[ -n "${min}" ]] && version_lt "${target_version}" "${min}"; then
    return 0
  fi

  if [[ -n "${max}" ]] && version_gt "${target_version}" "${max}"; then
    return 0
  fi

  return 1
}

# Generate base templates for each OCP version
for version in ${ocp_versions}; do
  cp catalog-template.yaml "catalog-template-${version//./-}.yaml"
done

# Prune old and no longer supported X.Y channels
echo "# Pruning channels:"
for channel in $(yq '.entries[] | select(.schema == "olm.channel").name' catalog-template.yaml); do
  echo "  Found channel: ${channel}"
  
  for ocp_version in ${ocp_versions}; do
    # Extract min and max for this specific OCP version
    min="$(jq -r ".[\"${ocp_version}\"][\"min\"]" supported-versions.json)"
    max="$(jq -r ".[\"${ocp_version}\"][\"max\"]" supported-versions.json)"

    # Special case: acm-2.6 channel was only there until OCP 4.14
    if [ "${channel}" == "acm-2.6" ]; then
      if [ "${ocp_version}" != "4.14" ]; then
        echo "  - Pruning channel from OCP ${ocp_version}: ${channel} ..."
        yq '.entries[] |= select(.schema == "olm.channel") |= del(select(.name == "'"${channel}"'"))' -i "catalog-template-${ocp_version//./-}.yaml"
      fi
      continue
    fi

    # Check if an entire minor-version channel (e.g., stable-0.10) should be pruned.
    # We explicitly skip this check for "stable" because we never delete the stable channel itself.
    if [ "${channel}" != "stable" ]; then
      if shouldPrune "${channel#*\-}" "${min}" "${max}"; then
        echo "  - Pruning channel from OCP ${ocp_version}: ${channel} ..."
        yq '.entries[] |= select(.schema == "olm.channel") |= del(select(.name == "'"${channel}"'"))' -i "catalog-template-${ocp_version//./-}.yaml"
        continue
      fi
    fi

    # Prune old bundles from surviving channels
    for entry in $(yq '.entries[] | select(.schema == "olm.channel" and .name == "'"${channel}"'").entries[].name' catalog-template.yaml); do
      full_version=${entry#*\.v}
      # Strip patch version to match supported-versions.json format
      short_version=${full_version%.*}

      if shouldPrune "${short_version}" "${min}" "${max}"; then
        echo "  - Pruning entry from OCP ${ocp_version}: ${entry}"
        yq -i 'del(.entries[] | select(.schema == "olm.channel" and .name == "'"${channel}"'").entries[] | select(.name == "'"${entry}"'"))' "catalog-template-${ocp_version//./-}.yaml"
      fi
    done

    # Always remove "replaces" field from the first remaining entry
    echo "  - OCP: ${ocp_version} CHANNEL: ${channel} - removing replaces from first entry"
    yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries[0] |= del(.replaces)' -i "catalog-template-${ocp_version//./-}.yaml"
  done
done
echo

# Prune old no longer supported bundles
echo "# Pruning bundles:"
for bundle_name in $(yq '.entries[] | select(.schema == "olm.bundle").name' catalog-template.yaml); do
  
  full_version="${bundle_name#volsync-product.v}"
  short_version="${full_version%.*}"

  for ocp_version in ${ocp_versions}; do
    min="$(jq -r ".[\"${ocp_version}\"][\"min\"]" supported-versions.json)"
    max="$(jq -r ".[\"${ocp_version}\"][\"max\"]" supported-versions.json)"

    if shouldPrune "${short_version}" "${min}" "${max}"; then
      echo "  - Pruning bundle ${bundle_name} from OCP ${ocp_version} ..."
      yq -i 'del(.entries[] | select(.schema == "olm.bundle" and .name == "'"${bundle_name}"'"))' "catalog-template-${ocp_version//./-}.yaml"
    fi
  done
done
