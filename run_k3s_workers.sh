#!/bin/bash
set -euo pipefail

CONFIG_FILE="run_configuration.json"
TEMPLATE_FILE="2-multi-process-template.yaml"
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
for bin in kubectl jq sed; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' 명령어를 찾을 수 없다. PATH를 확인하거나 설치가 필요하다." >&2
        exit 1
    fi
done

# 파일 존재 확인
for file in "$CONFIG_FILE" "$TEMPLATE_FILE"; do
    if [ ! -f "$file" ]; then
        echo "Error: $file 파일을 찾을 수 없다." >&2
        exit 1
    fi
done

# daemon set 배포
echo "[1/3] hailo-service DaemonSet을 적용한다."
if [ -f "hailort_service.env" ]; then
    kubectl create configmap hailort-service-env --from-env-file=hailort_service.env -o yaml --dry-run=client | kubectl apply -f -
else
    echo "Warning: hailort_service.env 파일이 없어 ConfigMap 생성을 건너뛴다. (파드 실행 시 환경변수 누락 가능성 있음)"
fi

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
    instance_index="1"

    # 템플릿 파일의 placeholder를 치환하여 적용
    # ${POD_NAME}, ${JOB_ID}, ${IMAGE_NAME}, ${INSTANCE_INDEX} 만 치환
    sed -e "s|\${POD_NAME}|${pod_name}|g" \
        -e "s|\${JOB_ID}|${job_id}|g" \
        -e "s|\${IMAGE_NAME}|${IMAGE_NAME}|g" \
        -e "s|\${INSTANCE_INDEX}|${instance_index}|g" \
        "$TEMPLATE_FILE" | kubectl apply -f -

    echo "  -> 워커 파드 생성 완료: ${pod_name} (JOB_ID=${job_id})"
done

echo "모든 리소스 생성 요청을 완료했다. 파드 상태는 'kubectl get pods -l app=hailo-worker -w'로 확인."