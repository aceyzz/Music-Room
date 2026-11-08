# The Python API suite's runtime, for machines with Docker and nothing else
# (`make docker-api-test`). Only the dependencies live in the image: the tests
# themselves are mounted at run time, so editing one needs no rebuild. Also
# runs loadtest/verify (`make loadtest`), which needs the same two libraries.
#
# grpcurl is here because tests/auth/ drives AuthService through it
# (tests/auth/conftest.py) -- built from source rather than downloaded, so one
# Dockerfile serves amd64 and arm64.
FROM golang:1.25-alpine AS grpcurl
ARG GRPCURL_VERSION=v1.9.3
RUN CGO_ENABLED=0 go install github.com/fullstorydev/grpcurl/cmd/grpcurl@${GRPCURL_VERSION}

FROM python:3.12-slim
COPY --from=grpcurl /go/bin/grpcurl /usr/local/bin/grpcurl
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
WORKDIR /work
