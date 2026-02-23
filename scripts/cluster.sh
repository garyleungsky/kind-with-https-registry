#!/bin/bash
set -e

CLUSTER_NAME="local-cluster"
REGISTRY_NAME="kind-registry.local"
REGISTRY_PORT="5005"
K8S_VERSION="v1.32.2"


# Global Docker Check
if ! docker info > /dev/null 2>&1; then
    echo "   ❌ Docker is not running. Please start Docker and try again."
    exit 1
fi

case "$1" in
  up)
    echo "--- Spinning Up ---"
    echo "1. Checking Certificates..."
    if ! command -v mkcert &> /dev/null; then
        echo "   ❌ mkcert is not installed. Please install it first."
        exit 1
    fi

    if [ ! -f "$REGISTRY_NAME.pem" ] || [ ! -f "$REGISTRY_NAME-key.pem" ] || [ ! -f "ca.pem" ]; then
        echo "   ⚠️  Certificates missing. Generating them now..."
        JAVA_HOME="" TRUST_STORES=system,nss mkcert -install > /dev/null
        JAVA_HOME="" mkcert $REGISTRY_NAME > /dev/null
        cp "$(mkcert -CAROOT)/rootCA.pem" ./ca.pem
        echo "   ✅ Certificates generated."
    else
        echo "   ✅ Certificates found."
    fi

    echo "2. Creating Cluster..."

    # Check if cluster already exists
    if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
        echo "   ℹ️  Cluster already exists, skipping..."
    else
        kind create cluster --config k8s-manifests/kind-config.yaml --image kindest/node:$K8S_VERSION > /dev/null
        echo "   ✅ Cluster created"
    fi

    echo "3. Starting HTTPS Registry..."

    # Check if registry is already running
    if [ "$(docker ps -q -f name=$REGISTRY_NAME)" ]; then
        echo "   ℹ️  Registry already running, skipping..."
    elif [ "$(docker ps -aq -f name=$REGISTRY_NAME)" ]; then
        echo "   ⚠️  Registry exists but is stopped. Starting it..."
        docker start $REGISTRY_NAME > /dev/null
        echo "   ✅ Registry started"
    else
        docker run -d --name $REGISTRY_NAME --restart=always \
          -p $REGISTRY_PORT:$REGISTRY_PORT \
          -v "$(pwd):/certs" \
          --tmpfs /var/lib/registry:rw,size=2g \
          -e REGISTRY_HTTP_ADDR=0.0.0.0:$REGISTRY_PORT \
          -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/$REGISTRY_NAME.pem \
          -e REGISTRY_HTTP_TLS_KEY=/certs/$REGISTRY_NAME-key.pem \
          -e REGISTRY_STORAGE_CACHE_BLOBDESCRIPTOR=inmemory \
          -e REGISTRY_STORAGE_DELETE_ENABLED=true \
          registry:2 > /dev/null
        echo "   ✅ Registry started"
    fi

    echo "4. Connecting Registry to Kind Network..."
    # Check if registry is already connected to the kind network
    REG_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$REGISTRY_NAME" 2>/dev/null)
    if [ -n "$REG_IP" ] && [ "$REG_IP" != "<no value>" ]; then
        echo "   ℹ️  Registry already connected to kind network, skipping..."
    else
        # Connect the registry to the kind network so pods can access it
        docker network connect kind "$REGISTRY_NAME" > /dev/null
        REG_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$REGISTRY_NAME")
        echo "   ✅ Registry connected"
    fi
    echo "   Registry IP on kind network: $REG_IP"

    echo "5. Patching Trust..."
    for node in $(kind get nodes --name $CLUSTER_NAME 2>/dev/null); do
      docker exec "$node" mkdir -p /etc/containerd/certs.d/$REGISTRY_NAME:$REGISTRY_PORT
      cat <<EOF | docker exec -i "$node" cp /dev/stdin /etc/containerd/certs.d/$REGISTRY_NAME:$REGISTRY_PORT/hosts.toml
[host."https://$REGISTRY_NAME:$REGISTRY_PORT"]
  ca = "/etc/ssl/certs/ca.pem"
EOF

      docker exec "$node" sh -c "echo '$REG_IP $REGISTRY_NAME' >> /etc/hosts"

    done
    echo "   ✅ Trust patched"
    ;;

  down)
    echo "--- Tearing Down ---"
    echo "1. Deleting Cluster..."
    if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
        kind delete cluster --name $CLUSTER_NAME > /dev/null
        echo "   ✅ Cluster deleted"
    else
        echo "   ℹ️  Cluster does not exist"
    fi

    echo "2. Removing Registry..."
    if [ "$(docker ps -a -q -f name=$REGISTRY_NAME)" ]; then
        docker stop $REGISTRY_NAME > /dev/null && docker rm $REGISTRY_NAME > /dev/null
        echo "   ✅ Registry removed"
    else
        echo "   ℹ️  Registry does not exist"
    fi

    echo ""
    echo "ℹ️  Certificates preserved. Run '$0 clean' to remove them."
    ;;

  clean)
    echo "--- Cleaning Certificates ---"
    # Check if any certificate files exist
    cert_files=(./*.pem ./*.key ./*.crt ./*.csr)
    if [ -e "${cert_files[0]}" ] || [ -e "${cert_files[1]}" ] || [ -e "${cert_files[2]}" ] || [ -e "${cert_files[3]}" ]; then
        rm -f ./*.pem ./*.key ./*.crt ./*.csr
        echo "   ✅ Certificates removed"
    else
        echo "   ℹ️  No certificates found"
    fi
    ;;

  status)
    echo "--- Checking Infrastructure Status ---"
    
    # 1. Check Registry
    echo "1. Registry ($REGISTRY_NAME)..."
    if [ "$(docker inspect -f '{{.State.Running}}' $REGISTRY_NAME 2>/dev/null)" == "true" ]; then
        echo "   ✅ RUNNING (HTTPS on port $REGISTRY_PORT)"
    else
        echo "   ❌ NOT RUNNING"
    fi

    # 2. Check Kind Cluster
    echo "2. Kind Cluster ($CLUSTER_NAME)..."
    if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
        echo "   ✅ CREATED"
    else
        echo "   ❌ NOT FOUND"
    fi

    ;;

  verify)
    echo "--- Testing Registry Connection ---"

    # Test from node (containerd)
    echo "1. Testing from Kind node (containerd)..."
    NODE=$(kind get nodes --name $CLUSTER_NAME 2>/dev/null | head -n 1)
    if [ -z "$NODE" ]; then
        echo "   ❌ No nodes found for cluster $CLUSTER_NAME"
        exit 1
    fi
    if docker exec "$NODE" curl -s --cacert /etc/ssl/certs/ca.pem https://kind-registry.local:5005/v2/ > /dev/null; then
        echo "   ✅ Node can access registry over HTTPS"
    else
        echo "   ❌ Node cannot access registry"
        exit 1
    fi

    # Test from pod (application level)
    echo "2. Testing from inside a pod..."

    # Create a temporary configmap with the CA cert
    kubectl create configmap registry-ca --from-file=ca.pem=./ca.pem 2>/dev/null || true

    if kubectl run registry-test --image=curlimages/curl:latest --rm -i --restart=Never \
      --overrides='
{
  "spec": {
    "containers": [{
      "name": "registry-test",
      "image": "curlimages/curl:latest",
      "command": ["curl", "--cacert", "/etc/ssl/certs/ca.pem", "https://kind-registry.local:5005/v2/"],
      "volumeMounts": [{
        "name": "ca-cert",
        "mountPath": "/etc/ssl/certs",
        "readOnly": true
      }]
    }],
    "volumes": [{
      "name": "ca-cert",
      "configMap": {
        "name": "registry-ca"
      }
    }]
  }
}' > /dev/null 2>&1; then
        echo "   ✅ Pods can access registry over HTTPS with valid certificate"
    else
        echo "   ❌ Pod cannot verify registry certificate"
    fi

    # Cleanup
    kubectl delete configmap registry-ca 2>/dev/null || true

    ;;



  *)
    echo "Usage: $0 {up|down|clean|status|verify}"
    echo ""
    echo "Commands:"
    echo "  up      - Create cluster and registry"
    echo "  down    - Destroy cluster and registry (preserves certificates)"
    echo "  clean   - Remove generated certificates"
    echo "  status  - Check status of cluster and registry"
    echo "  verify  - Test registry connectivity"

    ;;
esac