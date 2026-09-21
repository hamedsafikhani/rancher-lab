#!/usr/bin/env bash
# Find images that pods fail to pull, pull them on the host, import into k3d.
# Usage: ./fix-images.sh [cluster-name]   (default: mgmt)
CLUSTER="${1:-mgmt}"

IMAGES=$(kubectl --context "k3d-${CLUSTER}" get pods -A -o json | jq -r '
  .items[].status
  | ((.initContainerStatuses // []) + (.containerStatuses // []))[]
  | select(.state.waiting.reason == "ImagePullBackOff"
        or .state.waiting.reason == "ErrImagePull")
  | .image' | sort -u)

if [ -z "$IMAGES" ]; then
  echo "No failing image pulls in cluster '${CLUSTER}'."
  exit 0
fi

echo "Images to fix:"; echo "$IMAGES"
for img in $IMAGES; do
  until docker pull "$img"; do echo "retry $img in 10s"; sleep 10; done
  k3d image import "$img" -c "$CLUSTER"
done
echo "Done. Stuck pods will retry automatically within a few minutes."
