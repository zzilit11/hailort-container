#!/bin/bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_FILE="${SRC_DIR}/hailort_service.env"
DST_FILE="/etc/default/hailort_service"

if [ ! -f "$SRC_FILE" ]; then
    echo "Error: ${SRC_FILE} 파일을 찾을 수 없다." >&2
    exit 1
fi

echo "[1/3] 트레이스/로그 환경변수 파일을 ${DST_FILE}에 복사한다."
sudo install -Dm644 "$SRC_FILE" "$DST_FILE"

if command -v systemctl >/dev/null 2>&1; then
    echo "[2/3] systemd 유닛 정보를 새로고침한다."
    sudo systemctl daemon-reload

    echo "[3/3] hailort.service를 활성화하고 즉시 시작한다."
    sudo systemctl enable --now hailort.service
else
    echo "systemctl을 찾을 수 없습니다. hailort_service 프로세스를 수동으로 재시작하여 변경사항을 적용해야 한다." >&2
fi

echo "완료: hailort_service가 /home/hailo/log_service 및 /home/hailo/traces에 출력하도록 설정했다."
