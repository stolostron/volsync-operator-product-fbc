#! /bin/bash

set -e

if [[ $(basename "${PWD}") != "volsync-operator-product-fbc" ]]; then
  echo "error: Script must be run from the base of the repository."
  exit 1
fi

bundle_image=${1}

if [[ -z "${bundle_image}" ]]; then
  echo "error: the bundle image to be added must be provided as a positional argument."
  exit 1
fi

# Validate bundle image format
if [[ ! "${bundle_image}" =~ ^quay\.io/redhat-user-workloads/volsync-tenant/volsync-bundle-[0-9]+-[0-9]+@sha256:[a-f0-9]+$ ]]; then
  echo "error: the bundle image must follow the pattern:"
  echo "  ./build/add-bundle.sh quay.io/redhat-user-workloads/volsync-tenant/volsync-bundle-X-Y@sha256:<sha>"
  exit 1
fi

# Parse bundle
bundle_json=$(skopeo inspect --override-os=linux --override-arch=amd64 "docker://${bundle_image}")
bundle_digest=$(echo "${bundle_json}" | jq -r ".Digest")
bundle_version=$(echo "${bundle_json}" | jq -r ".Labels.version")
bundle_channels=$(echo "${bundle_json}" | jq -r '.Labels["operators.operatorframework.io.bundle.channels.v1"]')

echo "* Found bundle: ${bundle_digest}"
echo "* Found version: ${bundle_version}"
echo "* Found channels: ${bundle_channels}"

if [[ -n $(yq '.entries[] | select(.image == "'"${bundle_image}"'")' catalog-template.yaml) ]]; then
  echo "error: bundle entry already exists."
  exit 1
fi

# Add bundle
bundle_entry="
  image: ${bundle_image}
  schema: olm.bundle
" yq '.entries += env(bundle_entry)' -i catalog-template.yaml

# Add bundle to channels
for channel in ${bundle_channels//,/ }; do
  echo "  Adding to channel: ${channel}"
  if [[ -z $(yq '.entries[] | select(.schema == "olm.channel") | select(.name == "'"${channel}"'")' catalog-template.yaml) ]]; then
    #latest_channel=$(yq '.entries[] | select(.schema == "olm.channel").name' catalog-template.yaml | grep -v stable | sort --version-sort | tail -1)
    #new_channel=$(yq '.entries[] | select(.name == "'"${latest_channel}"'") | .name = "'"${channel}"'"' catalog-template.yaml)
    #echo "  Creating new ${channel} channel from ${latest_channel}"

    echo "  Creating new ${channel} channel ..."
    new_channel="
      name: ${channel}
      package: volsync-product
      schema: olm.channel
      entries: []
    "
    new_channel=${new_channel} yq '.entries += env(new_channel)' -i catalog-template.yaml
  fi

  # Extract-Process-Write approach: cleaner and more maintainable
  echo "    processing channel entries for ${channel}"

  # Step 1: Simply append new entry first (easier approach)
  channel_entry="
    name: volsync-product.${bundle_version}
    skipRange: '>=0.4.0 <${bundle_version#v}'
  " yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries += env(channel_entry)' -i catalog-template.yaml

  # Step 2: Sort the entries by name
  yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries |= sort_by(.name)' -i catalog-template.yaml

  # Step 3: Fix replacement chain - handle 'skips' logic properly
  # Get all entry names in sorted order
  entry_names=($(yq '.entries[] | select(.schema == "olm.channel") | select(.name == "'"${channel}"'").entries[].name' catalog-template.yaml))

  # First, collect all entries that are being skipped by other entries
  skipped_entries=()
  for entry_name in "${entry_names[@]}"; do
    skipped_by_this_entry=($(yq '.entries[] | select(.schema == "olm.channel") | select(.name == "'"${channel}"'").entries[] | select(.name == "'"${entry_name}"'").skips[]?' catalog-template.yaml 2>/dev/null || true))
    for skipped in "${skipped_by_this_entry[@]}"; do
      skipped_entries+=("$skipped")
    done
  done

  # Build replacement chain, keeping track of last non-skipped entry
  last_non_skipped=""
  for entry_name in "${entry_names[@]}"; do
    # Check if this entry is being skipped
    is_skipped=false
    for skipped in "${skipped_entries[@]}"; do
      if [[ "$entry_name" == "$skipped" ]]; then
        is_skipped=true
        break
      fi
    done

    if [[ "$is_skipped" == "true" ]]; then
      # Skipped entry: remove replaces field
      yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries |= map(select(.name == "'"${entry_name}"'") |= del(.replaces))' -i catalog-template.yaml
    elif [[ -z "$last_non_skipped" ]]; then
      # First non-skipped entry: remove replaces field
      yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries |= map(select(.name == "'"${entry_name}"'") |= del(.replaces))' -i catalog-template.yaml
      last_non_skipped="$entry_name"
    else
      # This entry replaces the last non-skipped entry
      yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries |= map(select(.name == "'"${entry_name}"'").replaces = "'"${last_non_skipped}"'")' -i catalog-template.yaml
      last_non_skipped="$entry_name"
    fi
  done
done

# Sort catalog
yq '.entries |= (sort_by(.schema, .name) | reverse)' -i catalog-template.yaml
yq '.entries |=
    [(.[] | select(.schema == "olm.package"))] +
   ([(.[] | select(.schema == "olm.channel"))] | sort_by(.name)) +
   ([(.[] | select(.schema == "olm.bundle"))] | sort_by(.name))' -i catalog-template.yaml