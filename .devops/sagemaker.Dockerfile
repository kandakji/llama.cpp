ARG UBUNTU_VERSION=22.04

FROM ubuntu:$UBUNTU_VERSION AS build

ARG TARGETARCH

ARG GGML_CPU_ARM_ARCH=armv8-a

RUN apt-get update && \
    apt-get install -y build-essential git cmake libcurl4-openssl-dev

WORKDIR /app

COPY . .

RUN if [ "$TARGETARCH" = "amd64" ]; then \
        cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=${GGML_CPU_ARM_ARCH}; \
    else \
        echo "Unsupported architecture"; \
        exit 1; \
    fi && \
    cmake --build build -j $(nproc)

RUN mkdir -p /app/lib && \
    find build -name "*.so" -exec cp {} /app/lib \;

RUN mkdir -p /app/full \
    && cp build/bin/* /app/full \
    && cp *.py /app/full \
    && cp -r gguf-py /app/full \
    && cp -r requirements /app/full \
    && cp requirements.txt /app/full \
    && cp .devops/tools.sh /app/full/tools.sh

## Base image
FROM ubuntu:$UBUNTU_VERSION AS base

RUN apt-get update \
    && apt-get install -y libgomp1 unzip curl\
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

COPY --from=build /app/lib/ /app


### Server, Server only
FROM base AS server

ENV LLAMA_ARG_HOST=0.0.0.0
ENV MODEL_S3_PATH=""

# Install AWS CLI and curl in a single RUN command to reduce layers
# Clean up unnecessary files after installation
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws && \
    mkdir -p /models

COPY --from=build /app/full/llama-server /app

WORKDIR /app

# Expose port for the application to run on, has to be 8080
EXPOSE 8080

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT ["/bin/bash", "-c", "\
    echo \"Starting entrypoint with arg: $1\"; \
    if [ \"$1\" = \"serve\" ] && [ ! -z \"$MODEL_S3_PATH\" ]; then \
        echo \"serve command detected and MODEL_S3_PATH is set to: $MODEL_S3_PATH\"; \
        MODEL_FILE=$(basename $MODEL_S3_PATH); \
        echo \"Downloading model file: $MODEL_FILE\"; \
        aws s3 cp $MODEL_S3_PATH /models/; \
        echo \"Starting llama-server with model: /models/$MODEL_FILE\"; \
        /app/llama-server -m /models/$MODEL_FILE; \
    else \
        echo \"Either 'serve' command not provided or MODEL_S3_PATH not set\"; \
    fi", "--"]
