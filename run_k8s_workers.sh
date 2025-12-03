#!/bin/bash
set -euo pipefail

CONFIG_FILE="run_configuration.json"
SERVICE_MANIFEST="1-hailo-service.yaml"
IMAGE_NAME="hailo-app:v1"

print_usage() {
    echo "Usage: $0 <worker_count>" >&2
    echo "  worker_count: 생성할 워커 파드 개수 (1 이상의 정수)" >&2
}

# 입력값 검증
if [ "$#" -ne 1 ]; then
    print_usage
    exit 1
fi

WORKER_COUNT="$1"
if ! [[ "$WORKER_COUNT" =~ ^[0-9]+$ ]] || [ "$WORKER_COUNT" -le 0 ]; then
    echo "Error: worker_count는 1 이상의 정수여야 한다." >&2
    exit 1
fi

# 도구 확인
for bin in kubectl jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' 명령어를 찾을 수 없다. PATH를 확인하거나 설치가 필요하다." >&2
        exit 1
    fi
done

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE 파일을 찾을 수 없다." >&2
    exit 1
fi

# daemon set 배포
echo "[1/3] hailo-service DaemonSet을 적용한다."
# HAILO_TRACE/HAILORT_LOGGER_PATH 값이 담긴 env 파일을 ConfigMap으로 배포한다.
kubectl create configmap hailort-service-env --from-env-file=hailort_service.env -o yaml --dry-run=client | kubectl apply -f -
kubectl apply -f "$SERVICE_MANIFEST"

# DaemonSet 준비 대기 (최대 2분)
echo "[2/3] hailo-service DaemonSet 준비 상태를 확인한다."
if ! kubectl rollout status daemonset/hailo-service-daemon --timeout=120s; then
    echo "Error: hailo-service DaemonSet이 준비되지 않았다." >&2
    exit 1
fi

# 사용할 Job ID 추출
mapfile -t JOB_IDS < <(jq -r '.jobs[].id' "$CONFIG_FILE")
JOB_TOTAL=${#JOB_IDS[@]}

if [ "$WORKER_COUNT" -gt "$JOB_TOTAL" ]; then
    echo "Error: worker_count(${WORKER_COUNT})가 정의된 모델 개수(${JOB_TOTAL})를 초과한다." >&2
    exit 1
fi

# 기존 워커 정리 (옵션)
echo "[3/3] 워커 파드를 생성한다 (총 ${WORKER_COUNT}개)."
kubectl delete pod -l app=hailo-worker --ignore-not-found

for (( idx=0; idx<WORKER_COUNT; idx++ )); do
    job_id=${JOB_IDS[$idx]}
    pod_name="hailo-worker-${job_id}"

    cat <<POD | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  labels:
    app: hailo-worker
    job-id: "${job_id}"
spec:
  hostNetwork: true
  restartPolicy: Never
  containers:
    - name: workload-runner
      image: ${IMAGE_NAME}
      imagePullPolicy: Never
      command: ["/bin/bash", "-lc", "./run_all.sh"]
      env:
        # HailoRT trace / logger 설정을 워커에도 적용해, 서비스/애플리케이션 모두 동일 경로에 기록되도록 한다.
        - name: HAILORT_LOGGER_PATH
          value: /home/hailo/log_service
        - name: HAILO_TRACE
          value: "1"
        - name: HAILO_TRACE_TIME_IN_SECONDS_BOUNDED_DUMP
          value: "0"
        - name: HAILO_TRACE_SIZE_IN_KB_BOUNDED_DUMP
          value: "0"
        - name: HAILO_TRACE_PATH
          value: /home/hailo/traces
        - name: WORKER_JOB_ID
          value: "${job_id}"
        - name: WORKER_INSTANCE_INDEX
          value: "1"
      securityContext:
        privileged: true
      volumeMounts:
        - name: log-output-dir
          mountPath: /app/logs
        - name: host-log-service
          mountPath: /home/hailo/log_service
        - name: host-traces
          mountPath: /home/hailo/traces
        - name: host-home-hailo
          mountPath: /home/hailo
        - name: dshm
          mountPath: /dev/shm
        - name: host-lock
          mountPath: /var/lock
        - name: hailort-socket
          mountPath: /tmp
        - name: hailo-device
          mountPath: /dev/hailo0
  volumes:
    - name: log-output-dir
      hostPath:
        path: /home/hailo/logs_k3s
        type: DirectoryOrCreate
    - name: host-log-service
      hostPath:
        path: /home/hailo/log_service
        type: DirectoryOrCreate
    - name: host-traces
      hostPath:
        path: /home/hailo/traces
        type: DirectoryOrCreate
    - name: host-home-hailo
      hostPath:
        path: /home/hailo
        type: Directory
    - name: dshm
      hostPath:
        path: /dev/shm
        type: Directory
    - name: host-lock
      hostPath:
        path: /var/lock
        type: Directory
    - name: hailort-socket
      hostPath:
        path: /tmp
        type: Directory
    - name: hailo-device
      hostPath:
        path: /dev/hailo0
POD

echo "  -> 워커 파드 생성 완료: ${pod_name} (JOB_ID=${job_id})"
done

echo "모든 리소스 생성 요청을 완료했다. 파드 상태는 'kubectl get pods -l app=hailo-worker -w'로 확인." 
