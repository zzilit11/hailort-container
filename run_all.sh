#!/bin/bash
set -e

CONFIG_FILE="run_configuration.json"
WORKER_SCRIPT="./run_worker.sh"

# 단일 워커 모드에서 실행할 Job ID (env: WORKER_JOB_ID 또는 JOB_ID)
TARGET_JOB_ID="${WORKER_JOB_ID:-${JOB_ID:-}}"
# 로그 파일명에 사용할 인스턴스 인덱스 (기본값 1)
TARGET_INSTANCE_INDEX="${WORKER_INSTANCE_INDEX:-1}"

# jq 설치 확인
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Install it using 'sudo apt install jq'"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found."
    exit 1
fi

# Global Settings 파싱
MODE=$(jq -r '.global_settings.mode' "$CONFIG_FILE")
LOG_DIR=$(jq -r '.global_settings.log_dir' "$CONFIG_FILE")

mkdir -p "$LOG_DIR"
if [ -z "$TARGET_JOB_ID" ]; then
    # 여러 작업을 단일 컨테이너에서 실행하는 경우에만 로그 디렉토리를 비움
    find "$LOG_DIR" -mindepth 1 -delete 2>/dev/null || true
fi

if [ -n "$TARGET_JOB_ID" ]; then
    echo "============================================"
    echo " Starting Worker (Single Job Mode)"
    echo " Mode: $MODE"
    echo " Target Job ID: $TARGET_JOB_ID"
    echo "============================================"
else
    echo "============================================"
    echo " Starting Multi-Process Manager (JSON Config)"
    echo " Mode: $MODE"
    echo "============================================"
fi

select_jobs_query='.jobs[]'
jq_args=(-c)
if [ -n "$TARGET_JOB_ID" ]; then
    select_jobs_query='.jobs[] | select(.id == $target_id)'
    jq_args+=("--argjson" "target_id" "$TARGET_JOB_ID")
fi

# Jobs 배열 순회
# jq -c를 사용하여 각 객체를 한 줄의 문자열로 추출
matched_job_found=false
while read -r job; do

    matched_job_found=true
    
    # 각 필드 추출
    ID=$(echo "$job" | jq -r '.id')
    HEF=$(echo "$job" | jq -r '.hef_path')
    IMAGE=$(echo "$job" | jq -r '.image_path')
    LABEL=$(echo "$job" | jq -r '.labels_path')
    FRAMES=$(echo "$job" | jq -r '.frame_count')
    BATCH=$(echo "$job" | jq -r '.batch_size')
    PRIORITY=$(echo "$job" | jq -r '.priority')
    TIMEOUT=$(echo "$job" | jq -r '.timeout_ms')
    THRESHOLD=$(echo "$job" | jq -r '.threshold')
    INSTANCES=$(echo "$job" | jq -r '.instances')

    echo ">> Launching Job Set #$ID"
    echo "   - Model: $(basename "$HEF")"
    
    if [ -n "$TARGET_JOB_ID" ]; then
        # 단일 작업 모드에서는 하나의 워커만 실행 (인스턴스 인덱스 선택)
        LOG_FILE="$LOG_DIR/job_${ID}_${TARGET_INSTANCE_INDEX}.log"
        "$WORKER_SCRIPT" \
            "$MODE" "$HEF" "$IMAGE" "$LABEL" \
            "$FRAMES" "$BATCH" "$PRIORITY" "$TIMEOUT" "$THRESHOLD" \
            "$LOG_FILE"

        echo "All jobs launched."
        wait
        exit 0
    else
        # Instance 수만큼 반복 실행
        for (( i=1; i<=INSTANCES; i++ )); do
            LOG_FILE="$LOG_DIR/job_${ID}_${i}.log"

            # 워커 스크립트 실행
            "$WORKER_SCRIPT" \
                "$MODE" "$HEF" "$IMAGE" "$LABEL" \
                "$FRAMES" "$BATCH" "$PRIORITY" "$TIMEOUT" "$THRESHOLD" \
                "$LOG_FILE"
        done
    fi
done < <(jq "${jq_args[@]}" "$select_jobs_query" "$CONFIG_FILE")

if [ -n "$TARGET_JOB_ID" ] && [ "$matched_job_found" = false ]; then
    echo "Error: No job found with id $TARGET_JOB_ID"
    exit 1
fi

echo "All jobs launched."
wait
