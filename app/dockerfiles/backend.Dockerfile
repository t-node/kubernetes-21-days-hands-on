# DevBoard backend (Go + Gin) -- COURSE BUILD.
#
# Why this file exists:
# the upstream app/devboard/backend/Dockerfile builds FROM dhi.io/golang, a
# Docker Hardened Image. Those require an entitled Docker account, so
# `docker build` fails with an authentication error for most people. This is a
# functionally identical build on public base images.
#
# Differences from upstream, all deliberate:
#   - public golang / alpine bases instead of dhi.io
#   - alpine runtime (has a shell) instead of a distroless-style image, so
#     `kubectl exec -it ... -- sh` works during the debugging exercises
#
# Build context is app/devboard/backend.

########################  build stage  ########################
FROM golang:1.23-alpine AS builder

WORKDIR /src

# Cache module downloads separately from source changes
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Static, stripped binary: no CGO, no debug symbols
ARG APP_VERSION=1.0
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${APP_VERSION}" \
      -o /out/devboard-backend .

########################  runtime stage  ########################
FROM alpine:3.20

# ca-certificates for any outbound TLS; wget comes from busybox and is handy
# when you exec in to test connectivity.
RUN apk add --no-cache ca-certificates \
 && adduser -D -u 10001 appuser

WORKDIR /app
COPY --from=builder --chown=appuser:appuser /out/devboard-backend ./devboard-backend

USER appuser

# Documentation only. PORT (default 8080) is what the app actually binds.
EXPOSE 8080

# Exec form so SIGTERM reaches the process and graceful shutdown works.
ENTRYPOINT ["./devboard-backend"]
