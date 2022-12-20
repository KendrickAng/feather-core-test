# syntax=docker/dockerfile:1

ARG GO_VERSION="1.18"
ARG BUILDPLATFORM=linux/amd64
ARG RUNNER_IMAGE="gcr.io/distroless/static-debian11"

FROM --platform=${BUILDPLATFORM} golang:${GO_VERSION}-alpine as base

###############################################################################
# Builder
###############################################################################

FROM base as go-builder

ARG BUILDPLATFORM
ARG GIT_VERSION
ARG GIT_COMMIT

# NOTE: add libusb-dev to run with LEDGER_ENABLED=true
RUN set -eux &&\
    apk update &&\
    apk add --no-cache \
    ca-certificates \
    linux-headers \
    build-base \
    cmake \
    git

# install mimalloc for musl
WORKDIR ${GOPATH}/src/mimalloc
RUN set -eux &&\
    git clone --depth 1 https://github.com/microsoft/mimalloc . &&\
    mkdir -p build &&\
    cd build &&\
    cmake .. &&\
    make -j$(nproc) &&\
    make install


# download dependencies to cache as layer
WORKDIR ${GOPATH}/src/app
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/go/pkg/mod \
    go mod download -x

# Cosmwasm - Download correct libwasmvm version
RUN set -eux &&\
    WASMVM_VERSION=$(go list -m github.com/CosmWasm/wasmvm | cut -d ' ' -f 2) && \
    WASMVM_DOWNLOADS="https://github.com/CosmWasm/wasmvm/releases/download/${WASMVM_VERSION}"; \
    wget ${WASMVM_DOWNLOADS}/checksums.txt -O /tmp/checksums.txt; \
    if [ ${BUILDPLATFORM} = "linux/amd64" ]; then \
        WASMVM_URL="${WASMVM_DOWNLOADS}/libwasmvm_muslc.x86_64.a"; \
    elif [ ${BUILDPLATFORM} = "darwin/arm64" ]; then \
        WASMVM_URL="${WASMVM_DOWNLOADS}/libwasmvm_muslc.aarch64.a"; \
    else \
        echo "Unsupported Build Platfrom ${BUILDPLATFORM}"; \
        exit 1; \
    fi; \
    wget ${WASMVM_URL} -O /lib/libwasmvm_muslc.a; \
    CHECKSUM=`sha256sum /lib/libwasmvm_muslc.a | cut -d" " -f1`; \
    grep ${CHECKSUM} /tmp/checksums.txt; \
    rm /tmp/checksums.txt 

# Copy the remaining files
COPY . .

# Build app binary
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/go/pkg/mod \
    go install \
        -mod=readonly \
        -tags "netgo,muslc" \
        -ldflags " \
            -w -s -linkmode=external -extldflags \
            '-L/go/src/mimalloc/build -lmimalloc -Wl,-z,muldefs -static' \
            -X github.com/cosmos/cosmos-sdk/version.Name='feather-base' \
            -X github.com/cosmos/cosmos-sdk/version.AppName='feather-based' \
            #-X github.com/cosmos/cosmos-sdk/version.Version=${GIT_VERSION} \
            #-X github.com/cosmos/cosmos-sdk/version.Commit=${GIT_COMMIT} \
            -X github.com/cosmos/cosmos-sdk/version.BuildTags='netgo,muslc' \
        " \
        -trimpath \
        ./...

# ###############################################################################

FROM ${RUNNER_IMAGE} as feather-base

COPY --from=go-builder /go/bin/feather-based /usr/local/bin/feather-based

WORKDIR /feather-base

CMD ["/usr/local/bin/feather-based", "--home", "/feather-base", "start"]