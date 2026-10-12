FROM alpine:3.20
RUN apk add --no-cache rsync curl git coreutils
COPY sync.sh /sync.sh
CMD ["/sync.sh"]
