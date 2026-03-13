FROM alpine:3.19 AS base
RUN apk add --no-cache ca-certificates

FROM otel/opentelemetry-collector-contrib:0.96.0

COPY --from=base /bin/sh /bin/sh
COPY --from=base /bin/cat /bin/cat
COPY --from=base /bin/sleep /bin/sleep
COPY --from=base /lib/ld-musl-* /lib/

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
