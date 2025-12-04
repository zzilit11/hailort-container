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
Deploy the hailo-service-daemon that controls the NPU first.
```bash
# 1. Apply Service Daemon YAML
kubectl apply -f 1-hailo-service.yaml

# 2. Monitor pod creation status (Wait until 'Running')
kubectl get pods -l app=hailo-service -w

# (Optional) Force replace existing DaemonSet if needed
# kubectl replace --force -f 1-hailo-service.yaml
```

#### [Check] Verify NPU Operation
Verify that the service daemon has correctly acquired the hardware.
```bash
# 1. Check the running service pod name
kubectl get pods -l app=hailo-service

# 2. Enter the pod (Replace pod name: hailo-service-daemon-xxxx)
kubectl exec -it <POD_NAME> -- /bin/bash
```

--------------------------
### 4. Workload Execution (Application Layer)
Execute the actual multi-process application (hailo-multi-process-runner).
```bash
# 1. Deploy App Pod
kubectl apply -f 2-app-multi-process.yaml

# 2. Check Pod status
kubectl get pod hailo-multi-process-runner
```

#### Execution Method A: Check Auto-Run (Logs)
Use this when the YAML command is set to ./run_all.sh.

```Bash
# Follow logs in real-time
kubectl logs -f hailo-multi-process-runner
```

#### Execution Method B: Manual Execution (Debug)
Use this when the YAML command is set to sleep infinity to manually enter the container and execute the script.

```Bash
# 1. Enter Shell
kubectl exec -it hailo-multi-process-runner -- /bin/bash

# --- Commands inside the container ---

# 2. Execute script
./run_all.sh
```

#### Execution Method C: Execute Specific Job with Single Worker Pod
You can specify a Job ID and instance index so that each worker pod runs a different model.

```bash
# Specify the Job ID to run (jobs[].id value from run_configuration.json)
export WORKER_JOB_ID=<JOB_ID>

# (Optional) Specify the instance index within the same Job (default: 1)
export WORKER_INSTANCE_INDEX=1

# Execute the script (Runs only the target Job and skips others)
./run_all.sh
```

- 여러 Job을 하나의 컨테이너에서 순차 실행하는 기본 동작과 달리, 단일 워커 모드에서는 지정된 Job만 실행하고 종료한다.
- 단일 워커 모드에서는 공유 로그 디렉터리를 비우지 않으므로, 각 워커 파드의 로그가 `log_dir` 하위의 `job_<id>_<index>.log` 파일로 분리된다.
--------------------------
### 5. DaemonSet + Single Worker Pod Deployment Script

```bash
./run_k8s_workers.sh 3
```
