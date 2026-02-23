# Kind Cluster with HTTPS Registry Setup

## Part 1: Prerequisites

1.  **Install Tools**:
    ```bash
    brew install kind mkcert docker kubectl make jq curl
    
    # For Firefox support (optional)
    brew install nss
    ```

2.  **Setup Root CA**:
    Initialize `mkcert` (requires sudo equivalent password prompt usually):
    ```bash
    JAVA_HOME="" sudo mkcert -install
    ```
    Verify CA installation:
    ```bash
    ls "$(mkcert -CAROOT)"
    ```

## Part 2: DNS Configuration

1.  **Configure DNS**:
    Add the registry domain to your local hosts file.
    > [!IMPORTANT]
    > The registry name must be `kind-registry.local`.
    ```bash
    export REGISTRY_NAME=kind-registry.local
    # Requires sudo
    sudo sh -c "echo '127.0.0.1 $REGISTRY_NAME' >> /etc/hosts"
    ```

## Part 3: Cluster Spin-up

 Once the prerequisites are installed and certificates are generated, you can use `make` or the script directly to manage the cluster.
 
 ### Using Makefile (Recommended)
 
 ```bash
 # Start the cluster and registry
 make up
 
 # Check status
 make status
 
 # Verify connectivity
 make verify
 
 # Tear down
 make down

 # Clean certificates (optional)
 make clean
 ```

 ### Using Script Directly

 ```bash
 # Start the cluster and registry
 ./scripts/cluster.sh up

 # Check status
 ./scripts/cluster.sh status

 # Verify connectivity
 ./scripts/cluster.sh verify

 # Tear down
 ./scripts/cluster.sh down

 # Clean certificates (optional)
 ./scripts/cluster.sh clean
 ```

### Script Usage
 The script automatically generates the necessary certificates if they are missing.
 
 ## Part 4: Usage Example
 
 Here is how to pull a public image, push it to your local registry, and deploy it to the cluster.
 
 1.  **Pull an image**:
     ```bash
     docker pull gcr.io/google-samples/hello-app:1.0
     ```
 
 2.  **Tag the image**:
     Tag it with your local registry address.
     ```bash
     docker tag gcr.io/google-samples/hello-app:1.0 kind-registry.local:5005/hello-app:1.0
     ```
 
 3.  **Push to local registry**:
     ```bash
     docker push kind-registry.local:5005/hello-app:1.0
     ```
 
 4.  **Deploy to cluster**:
     Apply the example manifest.
     ```bash
     kubectl apply -f k8s-manifests/example-pod.yaml
     ```
 
 5.  **Verify**:
     Check if the pod is running.
     ```bash
     kubectl get pods
     # Should show 'hello-registry' as Running
     ```
 
 6.  **Check Registry Catalog**:
     You can verify that the image is in the local registry using `curl` and `jq`.
     ```bash
     # List repositories
     curl -s --cacert ca.pem https://kind-registry.local:5005/v2/_catalog | jq
     # Output:
     # {
     #   "repositories": [
     #     "hello-app"
     #   ]
     # }

     # List tags for hello-app
     curl -s --cacert ca.pem https://kind-registry.local:5005/v2/hello-app/tags/list | jq
     # Output:
     # {
     #   "name": "hello-app",
     #   "tags": [
     #     "1.0"
     #   ]
     # }
     ```
