FROM rust:1.89-alpine AS builder
WORKDIR /app

RUN apk add --no-cache musl-dev

COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release

FROM alpine:3.22
WORKDIR /app
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/target/release/image-service /usr/local/bin/image-service
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/image-service"]
