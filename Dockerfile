# syntax = docker/dockerfile:1.2.1

# If true, start Delve and attach to Goshimmer Go binary.
# Must be defined above all build stages to work in build stage conditions.
ARG REMOTE_DEBUGGING=0

############################
# golang 1.17.2-buster multi-arch
FROM golang@sha256:5b036db95aaf91b8c75be815e2ba0ca0eecbfc3f57952c24c5d8c125970e2634 AS build

ARG RUN_TEST=0
ARG BUILD_TAGS=rocksdb,builtin_static

# Define second time inside the build stage to work in bash conditions.
ARG REMOTE_DEBUGGING=0

# Download and include snapshot into resulting image by default.
ARG DOWNLOAD_SNAPSHOT=1

# Ensure ca-certficates are up to date
RUN update-ca-certificates

RUN if [ $RUN_TEST -gt 0 ]; then \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libgflags-dev libsnappy-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev ; \
    fi

# Set the current Working Directory inside the container
RUN mkdir /goshimmer
WORKDIR /goshimmer

# If debugging is enabled install Delve binary.
RUN if [ $REMOTE_DEBUGGING -gt 0 ]; then \
    CGO_ENABLED=0 go install -ldflags "-s -w -extldflags '-static'" github.com/go-delve/delve/cmd/dlv@latest; \
    fi

# Use Go Modules
COPY go.mod .
COPY go.sum .

ENV GO111MODULE=on
RUN go mod download
RUN go mod verify

# 1. Mount everything from the current directory to the PWD(Present Working Directory) inside the container
# 2. Mount the testing cache volume
# 3. Run unittests
RUN --mount=target=. \
    --mount=type=cache,target=/root/.cache/go-build \
    if [ $RUN_TEST -gt 0 ]; then \
    go test ./... -tags rocksdb -count=1; \
    fi

# 1. Mount everything from the current directory to the PWD(Present Working Directory) inside the container
# 2. Mount the build cache volume
# 3. Build the binary
# 4. If debugging enabled, adjust build flags to suite debugging purposes.
RUN --mount=target=. \
    --mount=type=cache,target=/root/.cache/go-build \
    if [ $REMOTE_DEBUGGING -gt 0 ]; then \
    go build \
    -tags="$BUILD_TAGS" \
    -gcflags="all=-N -l" \
    -o /go/bin/goshimmer; \
    else  \
    go build \
    -tags="$BUILD_TAGS" \
    -ldflags='-w -s' \
    -o /go/bin/goshimmer; \
    fi

# Docker cache will be invalidated for RUNs after ARG definition (https://docs.docker.com/engine/reference/builder/#impact-on-build-caching)
ARG DEFAULT_SNAPSHOT_URL=https://dbfiles-goshimmer.s3.eu-central-1.amazonaws.com/snapshots/nectar/snapshot-latest.bin
ARG CUSTOM_SNAPSHOT_URL

# Enable building the image without downloading the snapshot.
# It's possible to download custom snapshot from external storage service - necessary for feature network deployment.
# If built with dummy snapshot then a snapshot needs to be mounted into the resulting image.
RUN if [ "$DOWNLOAD_SNAPSHOT" -gt 0 ] && [ "$CUSTOM_SNAPSHOT_URL" = "" ] ; then \
      wget -O /tmp/snapshot.bin $DEFAULT_SNAPSHOT_URL;  \
    elif [ "$DOWNLOAD_SNAPSHOT" -gt 0 ] && [ "$CUSTOM_SNAPSHOT_URL" != "" ]; then \
      apt update; apt install -y gawk; \
      git clone https://github.com/ffluegel/zippyshare.git; \
      cd zippyshare; \
      ./zippyshare.sh "$CUSTOM_SNAPSHOT_URL"; \
      SNAPSHOT_FILE=$(ls -t *.bin | head -1); \
      mv "$SNAPSHOT_FILE" /tmp/snapshot.bin; \
    else  \
      touch /tmp/snapshot.bin ; \
    fi

############################
# Image
############################
# https://github.com/GoogleContainerTools/distroless/tree/master/cc
# using distroless cc image, which includes everything in the base image (glibc, libssl and openssl)
FROM gcr.io/distroless/cc@sha256:4cad7484b00d98ecb300916b1ab71d6c71babd6860c6c5dd6313be41a8c55adb as prepare-runtime

# Gossip
EXPOSE 14666/tcp
# AutoPeering
#EXPOSE 14626/udp
# Pprof Profiling
EXPOSE 6061/tcp
# Prometheus exporter
EXPOSE 9311/tcp
# Webapi
EXPOSE 8080/tcp
# Dashboard
EXPOSE 8081/tcp

# Copy configuration
COPY --from=build /tmp/snapshot.bin /snapshot.bin
COPY config.default.json /config.json

# Copy the Pre-built binary file from the previous stage
COPY --chown=nonroot:nonroot --from=build /go/bin/goshimmer /run/goshimmer

# We execute this stage only if debugging is disabled, i.e REMOTE_DEBUGGIN==0.
FROM prepare-runtime as debugger-enabled-0

ENTRYPOINT ["/run/goshimmer", "--config=/config.json", "--messageLayer.snapshot.file=/snapshot.bin", "--database.directory=/tmp/mainnetdb"]

# We execute this stage only if debugging is enabled, i.e REMOTE_DEBUGGIN==1.
FROM prepare-runtime as debugger-enabled-1
EXPOSE 40000

# Copy the Delve binary
COPY --chown=nonroot:nonroot --from=build /go/bin/dlv /run/dlv
ENTRYPOINT ["/run/dlv","--listen=:40000", "--headless=true" ,"--api-version=2", "--accept-multiclient", "exec", "--continue", "/run/goshimmer", "--", "--config=/config.json", "--messageLayer.snapshot.file=/snapshot.bin", "--database.directory=/tmp/mainnetdb"]

# Execute corresponding build stage depending on the REMOTE_DEBUGGING build arg.
FROM debugger-enabled-${REMOTE_DEBUGGING} as runtime