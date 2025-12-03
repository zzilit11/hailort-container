# ==========================================
# Stage 1: Builder (기존과 동일)
# ==========================================
FROM ubuntu:24.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive

# 필수 패키지
RUN apt-get update && apt-get install -y \
    git build-essential cmake pkg-config \
    libopencv-dev libjsoncpp-dev wget \
    && rm -rf /var/lib/apt/lists/*

# HailoRT 빌드 (Service 포함)
WORKDIR /tmp_hailo_source
RUN git clone https://github.com/hailo-ai/hailort.git . && \
    git checkout hailo8
RUN cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release -DHAILO_BUILD_SERVICE=1 && \
    cmake --build build --config release --target install

# User Application 빌드
WORKDIR /app
COPY CMakeLists.txt .
COPY src/ ./src/
RUN mkdir build && cd build && cmake .. && make -j4

# ==========================================
# Stage 2: Runtime (스크립트 추가)
# ==========================================
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# 1. jq 포함 필수 패키지 설치
RUN apt-get update && apt-get install -y \
    libopencv-dev libjsoncpp-dev libgomp1 \
    jq \
    && rm -rf /var/lib/apt/lists/*

# 2. 라이브러리/서비스 복사
COPY --from=builder /usr/local/lib/libhailort.so* /usr/lib/
COPY --from=builder /usr/local/bin/hailort_service /usr/bin/

# 3. User Binary 복사
WORKDIR /app
RUN mkdir -p build
COPY --from=builder /app/build/multi_process ./build/multi_process
COPY --from=builder /app/build/inference_driver ./build/inference_driver

# 4. [NEW] 스크립트 및 설정 파일 복사
# 호스트의 현재 디렉토리에 있는 .sh 및 .json 파일을 컨테이너의 /app으로 복사
COPY run_all.sh .
COPY run_worker.sh .
COPY run_configuration.json .

# 5. 스크립트 수정 및 권한 부여
# 컨테이너 안에서는 systemctl을 사용할 수 없으므로 해당 라인 주석 처리
RUN sed -i 's/sudo systemctl restart hailort.service/# sudo systemctl restart hailort.service/g' run_all.sh && \
    chmod +x run_all.sh run_worker.sh

# 6. Linker 설정
RUN ldconfig

CMD ["/bin/bash"]