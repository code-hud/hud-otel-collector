# Certs are arch-independent, so build that stage natively (no QEMU needed for arm64).
FROM --platform=$BUILDPLATFORM alpine:3.24 AS certs
RUN apk --no-cache add ca-certificates

FROM scratch
ARG USER_UID=10001
ARG USER_GID=10001
USER ${USER_UID}:${USER_GID}
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ARG TARGETPLATFORM
COPY --chmod=755 $TARGETPLATFORM/hud-otelcol /hud-otelcol
ENTRYPOINT ["/hud-otelcol"]
# 4317/4318: OTLP gRPC/HTTP, 13133: health check
EXPOSE 4317 4318 13133
