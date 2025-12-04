# Hailo K3s Deployment Guide - Multi Container

### 0. Prerequisites (Host Preparation)
Since K3s pods require exclusive access to the NPU device (/dev/hailo0), you must clean up conflicting services running on the host OS.
```bash
# Check the status of the Hailo service on the Host
sudo systemctl status hailort.service

# Stop the service (Prevent Device Busy errors)
sudo systemctl stop hailort.service

# Disable auto-start on reboot (Recommended as K8s will manage this)
sudo systemctl disable hailort.service
```
--------------------------
### 1. Build & Import (Image Build & K3s Deployment)
K3s cannot directly access images from the local Docker daemon. You must build the image and then import it into the K3s runtime (containerd).
```bash
# 1. Build Docker image
docker build -t hailo-app:v1 .

# 2. Save the image as a tar and import it to K3s containerd
# (Method A: Pipe directly - Recommended)
docker save hailo-app:v1 | sudo k3s ctr images import -

# (Method B: Using a tar file)
# docker save -o ../hailo-app.tar hailo-app:v1
# sudo k3s ctr images import ../hailo-app.tar

# 3. Verify that the image has been imported successfully
sudo k3s ctr images ls | grep hailo-app
```
--------------------------
### 2. Cleanup (Remove Existing Resources)
Remove existing pods or configurations before deployment to ensure a clean state.
```bash
# Delete resources defined in all yaml files in the current directory
kubectl delete -f .

# (Optional) Delete specific pods only
# kubectl delete pod -l app=hailo-service
```
--------------------------
### 3. Service Daemon Deployment (Infrastructure Layer)
Deploy the hailo-service-daemon that controls the NPU. The DaemonSet provides the Hailo runtime socket and device access to the worker pods.
```bash
# Apply Service Daemon YAML (configures privileged access and hostPath mounts)
kubectl apply -f 1-hailo-service.yaml

# Monitor pod creation status (wait until 'Running')
kubectl get pods -l app=hailo-service -w
```

If you need to recreate the DaemonSet, rerun the apply command. An optional `hailort_service.env` file is turned into a ConfigMap so that environment variables are injected into the DaemonSet container.

--------------------------
### 4. Workload Execution with Dedicated Worker Pods
Workloads now run in individual worker pods instead of a single multi-process runner. Each worker pod is created from `2-multi-process-template.yaml` and executes only one Job ID from `run_configuration.json` by passing `WORKER_JOB_ID` to `run_all.sh`.

**Deploy workers automatically**
```bash
# Create the DaemonSet (if not already running) and start N worker pods
./run_k3s_workers.sh <worker_count>

# Example: launch three workers for the first three jobs defined in run_configuration.json
./run_k3s_workers.sh 3
```

- The script validates prerequisites (`kubectl`, `jq`, `sed`), applies the DaemonSet, waits for it to become ready, and then spawns worker pods named `hailo-worker-<job_id>`.
- Worker pods mount `/home/hailo/npu-project/log_pod/log_worker` on the host to `/app/log_worker` in the container. Each pod writes a single log file per job as `job_<id>_<index>.log` without clearing the shared directory.
- `WORKER_INSTANCE_INDEX` defaults to `1` but can be changed in the template if multiple instances per job are required.

**Monitor or debug workers**
```bash
# Watch worker pod status
kubectl get pods -l app=hailo-worker -w

# Tail a worker log file on the host
tail -f /home/hailo/npu-project/log_pod/log_worker/job_<id>_<index>.log

# Enter a worker pod shell for manual debugging
kubectl exec -it hailo-worker-<job_id> -- /bin/bash
```

Inside the pod you can rerun `./run_all.sh` or adjust environment variables as needed. The `run_configuration.json` file controls which model, inputs, and thresholds each job uses.
