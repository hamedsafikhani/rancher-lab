# Usage: source ~/rancher-lab/scripts/lab.sh
export LAB_ROOT="$HOME/rancher-lab"

set -a
source "$LAB_ROOT/versions.env"
source "$LAB_ROOT/config/lab.env"
set +a

# Only these variables are substituted in manifests (never secrets, never other '$')
LAB_VARS=$(sed -nE 's/^(export[[:space:]]+)?([A-Z0-9_]+)=.*/${\2}/p' \
  "$LAB_ROOT/versions.env" "$LAB_ROOT/config/lab.env" | tr '\n' ' ')

# Render a manifest template to stdout
render() { envsubst "$LAB_VARS" < "$1"; }

# Apply templates to a cluster:  kapply work manifests/todo/*.yaml
kapply() {
  local ctx="$1"; shift
  for f in "$@"; do render "$f" | kubectl --context "k3d-$ctx" apply -f -; done
}

# Show what would change in the cluster:  kdiff work manifests/todo/*.yaml
kdiff() {
  local ctx="$1"; shift
  for f in "$@"; do render "$f" | kubectl --context "k3d-$ctx" diff -f -; done
}

# MinIO client in a container
mcl() {
  docker run --rm -i --network lab-net \
    --add-host "${S3_HOST}:${LAB_IP}" \
    -v "$LAB_ROOT/object-storage/mc-config:/mc" \
    "$S3_MC_IMAGE" -C /mc "$@"
}
