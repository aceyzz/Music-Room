# Build context: the repository root (docker-compose.yaml), not backend/ --
# the protos and the buf config live above it. backend/Dockerfile.dockerignore
# keeps the context to what this file copies.
#
# The generated code (backend/gen, db/sqlc, the OpenAPI spec) is gitignored, so
# it is generated here rather than expected from the host: a fresh clone builds
# with Docker alone.
FROM golang:1.25-alpine AS builder
WORKDIR /src

RUN apk add --no-cache git ca-certificates
RUN update-ca-certificates

# Same versions as the Makefile's `tools` target.
ARG BUF_VERSION=v1.47.2
ARG PROTOC_GEN_GO_VERSION=v1.36.11
ARG PROTOC_GEN_GO_GRPC_VERSION=v1.5.1
ARG GRPC_GATEWAY_VERSION=v2.30.0
ARG SQLC_VERSION=v1.30.0
RUN go install github.com/bufbuild/buf/cmd/buf@${BUF_VERSION} && \
    go install google.golang.org/protobuf/cmd/protoc-gen-go@${PROTOC_GEN_GO_VERSION} && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@${PROTOC_GEN_GO_GRPC_VERSION} && \
    go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway@${GRPC_GATEWAY_VERSION} && \
    go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-openapiv2@${GRPC_GATEWAY_VERSION} && \
    go install github.com/sqlc-dev/sqlc/cmd/sqlc@${SQLC_VERSION}

COPY backend/go.mod backend/go.sum backend/
RUN cd backend && go mod download

COPY buf.yaml buf.lock buf.gen.backend.yaml ./
COPY proto proto
COPY backend backend
RUN buf generate --template buf.gen.backend.yaml && cd backend && sqlc generate

# The seeder too (make seed runs it in this image): with Docker alone there is
# no generated code on the host for a `go run`.
RUN cd backend && CGO_ENABLED=0 GOOS=linux go build -o /music-room-backend ./cmd && \
    CGO_ENABLED=0 GOOS=linux go build -o /music-room-seed ./cmd/seed

FROM gcr.io/distroless/static-debian12
WORKDIR /
COPY --from=builder /music-room-backend /music-room-backend
COPY --from=builder /music-room-seed /music-room-seed
EXPOSE 50051
ENTRYPOINT ["/music-room-backend"]
