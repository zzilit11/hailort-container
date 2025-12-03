# Hailo K3s Deployment Guide - Multi Container

### 0. 호스트 환경 준비 (Prerequisites)
K3s 파드가 NPU 디바이스(/dev/hailo0)를 점유해야 하므로, 호스트 OS에서 실행 중인 서비스와 충돌하지 않도록 정리합니다.
```bash
# Host에서 Hailo 서비스 실행 상태 확인
sudo systemctl status hailort.service

# 서비스 중지 (Device Busy 방지)
sudo systemctl stop hailort.service

# 재부팅 시 자동 실행 방지 (K8s가 관리하므로 비활성화 권장)
sudo systemctl disable hailort.service
```
--------------------------
### 1. 이미지 빌드 및 K3s 배포 (Build & Import)
K3s는 로컬 Docker 데몬의 이미지를 바로 볼 수 없으므로, 빌드 후 K3s 런타임(containerd)으로 이미지를 옮겨야 합니다.
```bash
# 1. Docker 이미지 빌드
docker build -t hailo-app:v1 .

# 2. 이미지를 tar로 저장 후 K3s containerd로 import
# (방법 A: 파이프로 즉시 전송 - 권장)
docker save hailo-app:v1 | sudo k3s ctr images import -

# (방법 B: tar 파일 이용 시)
# docker save -o ../hailo-app.tar hailo-app:v1
# sudo k3s ctr images import ../hailo-app.tar

# 3. 이미지가 잘 들어갔는지 확인
sudo k3s ctr images ls | grep hailo-app
```
--------------------------
### 2. 기존 리소스 정리 (Cleanup)
배포 전 기존에 실행 중인 파드나 설정을 제거하여 깨끗한 상태를 만듭니다.
```bash
# 현재 디렉토리의 모든 yaml 파일에 정의된 리소스 삭제
kubectl delete -f .

# (선택) 특정 파드만 삭제하고 싶을 때
# kubectl delete pod -l app=hailo-service
```
--------------------------
### 3. 서비스 데몬 배포 (Infrastructure Layer)
NPU를 제어하는 hailo-service-daemon을 먼저 실행합니다.
```bash
# 1. 서비스 데몬 YAML 적용
kubectl apply -f 1-hailo-service.yaml

# 2. 파드 생성 상태 모니터링 (Running 뜰 때까지 대기)
kubectl get pods -l app=hailo-service -w

# (옵션) 기존 데몬셋 강제 교체 필요 시
# kubectl replace --force -f 1-hailo-service.yaml
```

#### [Check] NPU 동작 확인
서비스 데몬이 하드웨어를 정상적으로 잡았는지 확인합니다.
```bash
# 1. 실행 중인 서비스 파드 이름 확인
kubectl get pods -l app=hailo-service

# 2. 파드 내부 진입 (파드명 변경 필요: hailo-service-daemon-xxxx)
kubectl exec -it <POD_NAME> -- /bin/bash

# 3. (파드 내부) NPU 사용량 실시간 모니터링
watch -n 0.5 hailort-cli run-stats
# 확인 후 exit으로 빠져나옴
```
--------------------------
### 4. 워크로드 실행 (Application Layer)
실제 멀티 프로세스 애플리케이션(hailo-multi-process-runner)을 실행합니다.
```bash
# 1. 앱 파드 배포
kubectl apply -f 2-app-multi-process.yaml

# 2. 파드 상태 확인
kubectl get pod hailo-multi-process-runner
```

#### 실행 방법 A: 자동 실행 확인 (Logs)
YAML의 command가 ./run_all.sh로 설정된 경우입니다.

```Bash
# 로그 실시간 확인
kubectl logs -f hailo-multi-process-runner
```

#### 실행 방법 B: 수동 실행 (Debug)
YAML의 command가 sleep infinity로 설정된 경우 직접 들어가서 실행합니다.

```Bash
# 1. 쉘 진입
kubectl exec -it hailo-multi-process-runner -- /bin/bash

# --- 아래는 컨테이너 내부 명령어 ---

# 2. 실행 권한 재확인
chmod +x run_all.sh run_worker.sh

# 3. 스크립트 실행
./run_all.sh
```

#### 실행 방법 C: 단일 워커 파드로 특정 Job 실행
각 워커 파드가 서로 다른 모델을 실행하도록 JOB ID와 인스턴스 인덱스를 지정할 수 있다.

```bash
# 실행할 Job ID 지정 (run_configuration.json의 jobs[].id 값)
export WORKER_JOB_ID=<JOB_ID>

# (선택) 동일 Job 내에서 사용할 인스턴스 인덱스 지정, 기본값 1
export WORKER_INSTANCE_INDEX=1

# 스크립트 실행 시 대상 Job만 실행하고 나머지는 건너뜀
./run_all.sh
```

- 여러 Job을 하나의 컨테이너에서 순차 실행하는 기본 동작과 달리, 단일 워커 모드에서는 지정된 Job만 실행하고 종료한다.
- 단일 워커 모드에서는 공유 로그 디렉터리를 비우지 않으므로, 각 워커 파드의 로그가 `log_dir` 하위의 `job_<id>_<index>.log` 파일로 분리된다.
--------------------------