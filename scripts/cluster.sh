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
        TRUST_STORES=system,nss mkcert -install > /dev/null 2>&1
        mkcert $REGISTRY_NAME > /dev/null 2>&1
        cp "$(mkcert -CAROOT)/rootCA.pem" ./ca.pem
        echo "   ✅ Certificates generated."
    else
        echo "   ✅ Certificates found."
    fi

    echo "2. Creating Cluster..."
    kind create cluster --config k8s-manifests/kind-config.yaml --image kindest/node:$K8S_VERSION > /dev/null 2>&1
    echo "   ✅ Cluster created"

    echo "3. Starting HTTPS Registry..."
    docker run -d --name $REGISTRY_NAME --restart=always \
      -p $REGISTRY_PORT:$REGISTRY_PORT -v "$(pwd):/certs" \
      -e REGISTRY_HTTP_ADDR=0.0.0.0:$REGISTRY_PORT \
      -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/$REGISTRY_NAME.pem \
      -e REGISTRY_HTTP_TLS_KEY=/certs/$REGISTRY_NAME-key.pem \
      registry:2 > /dev/null
    echo "   ✅ Registry started"

    echo "4. Connecting Registry to Kind Network..."
    # Connect the registry to the kind network so pods can access it
    docker network connect kind $REGISTRY_NAME > /dev/null

    # Get the registry IP on the kind network
    REG_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' $REGISTRY_NAME)
    echo "   Registry IP on kind network: $REG_IP"
    echo "   ✅ Registry connected"

    echo "5. Patching Trust..."
    for node in $(kind get nodes --name $CLUSTER_NAME 2>/dev/null); do
      docker exec $node mkdir -p /etc/containerd/certs.d/$REGISTRY_NAME:$REGISTRY_PORT
      cat <<EOF | docker exec -i $node cp /dev/stdin /etc/containerd/certs.d/$REGISTRY_NAME:$REGISTRY_PORT/hosts.toml
[host."https://$REGISTRY_NAME:$REGISTRY_PORT"]
  ca = "/etc/ssl/certs/ca.pem"
EOF

      docker exec $node sh -c "echo '$REG_IP $REGISTRY_NAME' >> /etc/hosts"

    done
    echo "   ✅ Trust patched"
    ;;

  down)
    echo "--- Tearing Down ---"
    echo "1. Deleting Cluster..."
    if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
        kind delete cluster --name $CLUSTER_NAME > /dev/null 2>&1
        echo "   ✅ Cluster deleted"
    else
        echo "   ℹ️  Cluster does not exist"
    fi

    echo "2. Removing Registry..."
    if [ "$(docker ps -a -q -f name=$REGISTRY_NAME)" ]; then
        docker stop $REGISTRY_NAME > /dev/null 2>&1 && docker rm $REGISTRY_NAME > /dev/null 2>&1
        echo "   ✅ Registry removed"
    else
        echo "   ℹ️  Registry does not exist"
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
    if docker exec ${CLUSTER_NAME}-control-plane curl -s --cacert /etc/ssl/certs/ca.pem https://kind-registry.local:5005/v2/ > /dev/null; then
        echo "   ✅ Node can access registry over HTTPS"
    else
        echo "   ❌ Node cannot access registry"
        exit 1
    fi

    # Test from pod (application level)
    echo "2. Testing from inside a pod..."
    kubectl run registry-test --image=curlimages/curl:latest --rm -i --restart=Never --command -- \
      sh -c "curl -k https://kind-registry.local:5005/v2/ 2>&1" > /dev/null

    if [ $? -eq 0 ]; then
        echo "   ✅ Pods can access registry over HTTPS"
    else
        echo "   ⚠️  Pod test failed (this is expected if no pods can resolve the registry)"
    fi

    ;;



  *)
    echo "Usage: $0 {up|down|status|verify}"
    echo ""
    echo "Commands:"
    echo "  up      - Create cluster and registry"
    echo "  down    - Destroy cluster and registry"
    echo "  status  - Check status of cluster and registry"
    echo "  verify  - Test registry connectivity"

    ;;
esac