FROM gcr.io/go-containerregistry/crane:latest AS crane
FROM alpine:3.20
RUN apk add --no-cache git curl jq bash
COPY --from=crane /ko-app/crane /usr/local/bin/crane
CMD ["sleep", "infinity"]
