#! /bin/bash

set -e

if [[ $(basename "${PWD}") != "volsync-operator-product-fbc" ]]; then
  echo "error: Script must be run from the base of the repository."
  exit 1
fi

# Render the template to a catalog

##### Special case for OCP <=4.16 #####
echo "Rendering catalogs with olm.bundle.object for OCP <=4.16 ..."
old_catalog_templates=$(find catalog-template-*.yaml | grep -e "4-14" -e "4-15" -e "4-16")
for old_catalog_template in ${old_catalog_templates}; do
  echo "  Rendering catalog with ${old_catalog_template} ..."
  opm alpha render-template basic "${old_catalog_template}" -o=yaml >"${old_catalog_template//-template/}"
done
#######################################

echo ""

#catalog_templates=$(find catalog-template-*.yaml -not -name "catalog-template-4-14.yaml")
catalog_templates=$(find catalog-template-*.yaml | grep -v -e "4-14" -e "4-15" -e "4-16")

echo "Rendering catalogs with olm.csv.meatadata for OCP >=4.17 ..."
for catalog_template in ${catalog_templates}; do
  echo "  Rendering catalog with ${catalog_template} ..."
  opm alpha render-template basic "${catalog_template}" -o=yaml --migrate-level=bundle-object-to-csv-metadata >"${catalog_template//-template/}"
done

# Decompose the catalog into files for consumability
catalogs=$(find catalog-*.yaml -not -name "catalog-template*.yaml")
rm -rf catalog-*/

for catalog_file in ${catalogs}; do
  catalog_dir=${catalog_file%\.yaml}
  echo "Decomposing ${catalog_file} into directory for consumability: ${catalog_dir}/ ..."
  yq 'select(.schema == "olm.bundle")' -s '"'"${catalog_dir}"'/bundles/bundle-v" + (.properties[] | select(.type == "olm.package").value.version) + ".yaml"' "${catalog_file}"
  yq 'select(.schema == "olm.channel")' -s '"'"${catalog_dir}"'/channels/channel-" + (.name) + ".yaml"' "${catalog_file}"
  yq 'select(.schema == "olm.package")' -s '"'"${catalog_dir}"'/package.yaml"' "${catalog_file}"
  rm "${catalog_file}"
done

rm catalog-template-*.yaml
