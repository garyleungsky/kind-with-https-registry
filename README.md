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

 ### Option A: Using HTTPS Registry (Tests Full TLS Stack)

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
     > [!NOTE]
     > Push operations may take 1-2 minutes due to Docker client rate limiting with HTTPS registries.
     > This is a Docker Desktop limitation, not a registry performance issue. See [Performance Notes](#performance-notes) below.

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

 ### Option B: Using `kind load` (Fast Development Workflow)

 For faster development iteration, you can load images directly into kind nodes without using the registry:

 ```bash
 # Pull the image
 docker pull gcr.io/google-samples/hello-app:1.0

 # Load directly into kind (takes ~2 seconds)
 kind load docker-image gcr.io/google-samples/hello-app:1.0 --name local-cluster

 # Deploy using the original image name
 kubectl run hello-app --image=gcr.io/google-samples/hello-app:1.0 --image-pull-policy=Never

 # Verify
 kubectl get pods
 ```

 **Pros:**
 - ✅ Very fast (~2 seconds vs 1-2 minutes)
 - ✅ No registry push needed
 - ✅ Perfect for rapid development

 **Cons:**
 - ❌ Doesn't test registry functionality
 - ❌ Doesn't validate TLS/HTTPS setup
 - ❌ Images only available in this specific cluster

 **When to use:**
 - Use **Option A** when testing registry functionality or TLS setup
 - Use **Option B** for fast development iteration


 ## Performance Notes

 ### Registry Push Performance

 When pushing images to the HTTPS registry, you may notice it takes 1-2 minutes. This is **normal** and caused by Docker client behavior, not registry performance.

 **What's happening:**
 - Registry responses are very fast (1-5ms)
 - Docker client adds ~5 second delays between layer operations
 - For a 15-layer image: 15 layers × 5 seconds = ~75 seconds minimum
 - This is Docker Desktop's rate limiting/retry logic for HTTPS registries

 **Registry optimizations already applied:**
 - ✅ tmpfs (RAM disk) for storage - eliminates disk I/O
 - ✅ In-memory blob descriptor caching
 - ✅ Optimized storage configuration

 **Workarounds:**
 1. **Use `kind load`** for development (see Option B above) - ~2 seconds
 2. **Accept the delay** when testing HTTPS registry functionality
 3. **Push smaller images** with fewer layers
 4. **Subsequent pushes** of the same layers are faster (cached)

 ### Cluster Startup Performance

 - **First run:** 20-60 seconds (downloading node image)
 - **Subsequent runs:** 10-15 seconds (image cached)
 - This is normal for Kubernetes cluster creation

 **Time breakdown:**
 - Certificate generation: ~1-2 seconds
 - Kind cluster creation: ~10-11 seconds (largest component)
 - Registry startup: ~1 second
 - Network configuration: <1 second
 - Trust patching: ~1 second
