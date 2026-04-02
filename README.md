# File based catalog for the VolSync operator

This is based on/copied from gatekeeper-operator-fbc

# Managing the File Based Catalog

## Initializing the catalog from a current operator index

This step may not need to be re-done. It was initially done with the oldest supported OCP at the time to generate
the catalog-template. The next step (Adding or removing OCP versions) will then filter the catalog to include only the explicitly supported
versions for each OCP release.

Use the [build/fetch-catalog.sh](../build/fetch-catalog.sh) script to pulling from the OCP vX.Y
index for the `volsync-product` operator package:

```bash
./build/fetch-catalog.sh X.Y volsync-product
```

## Adding or removing OCP versions

1. Update
   [konflux-release-data](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/tree/main/tenants-config/cluster/stone-prd-rh01/tenants/volsync-tenant),
   adding or removing OCP versions as needed.
2. If versions should be updated for an incoming or outgoing OCP version, update the
   [supported-versions.json](../supported-versions.json) map. This file dictates the allowed 
   operator versions for each OCP release using a range defined by `min` and `max` boundaries 
   (using the `X.Y` version format). 
   
   The generation scripts will filter the catalog to ensure only versions falling within this range are kept. You can use an empty string (`""`) to indicate that there is no boundary in that direction:
   * **Empty `min` (`""`):** No lower boundary (includes everything up to the `max`).
   * **Empty `max` (`""`):** No upper boundary (includes everything from the `min` onwards).
   * **Empty `min` and `max` (`""`):** No boundaries at all (includes all available versions).

   **Example format:**
   ```json
   {
     "4.50": {
       "min": "",
       "max": ""
     },
     "4.51": {
       "min": "0.8",
       "max": "0.9"
     },
     "4.52": {
       "min": "0.9",
       "max": ""
     }
   }
   ```

3. Merge the PRs from Konflux corresponding to the addition or removal of the application. For
   additions, run the [pipeline-patch.sh](../.tekton/pipeline-patch.sh) script to patch the incoming
   pipeline with relevant updates.

## Updating the catalog entries

1. Run the [`add-bundle.sh`](../build/add-bundle.sh) script to add catalog entries into
   [`catalog-template.yaml`](../catalog-template.yaml) giving the Konflux bundle image as an
   argument. The image can be found on the Konflux console in the Application in the Components tab.
   For example:

   ```shell
   ./build/add-bundle.sh quay.io/redhat-user-workloads/volsync-tenant/volsync-bundle-X-Y@sha256:<sha>
   ```

2. Modifying catalogs for already-released OCP versions is generally not allowed since
   they have already been deployed to customers. However, for unreleased versions of OCP,
   you can define the exact set of allowed operator versions.

   Update the OCP version <-> operator version map, [supported-versions.json](../supported-versions.json),
   to explicitly declare the operator versions that should be included for that specific OCP release.

3. Run the [build/generate-catalog-template.sh](../build/generate-catalog-template.sh) to regenerate
   the catalog template files:

   ```bash
   ./build/generate-catalog-template.sh
   ```

4. Run the [render-catalog.sh](../build/render-catalog.sh) script to re-render the catalog for the
   template files:

   ```bash
   ./build/render-catalog.sh
   ```

   **NOTE:** The catalog rendering replaces the Konflux image registry with the production Red Hat
   registry so the `opm` CLI can no longer reach it if you try to generate the catalog again before
   the image's release. In this case, you need to revert the bundle reference to the Konflux one for
   the script to complete.

## Testing an FBC image

A catalog source can be created pointing to the FBC image as follows:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: fbc-test-catalogsource
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/redhat-user-workloads/<tenant>-tenant/<fbc-image>@sha256:<digest>
  displayName: Konflux FBC test CatalogSource
  publisher: Red Hat
```
