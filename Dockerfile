FROM alpine:latest
LABEL maintainer="eli.lasry@cnvrg.io"

RUN apk add --no-cache bash ca-certificates curl git jq

COPY clean-branch-tag.sh /usr/bin/clean-branch-tag.sh

ENTRYPOINT ["/usr/bin/clean-branch-tag.sh"]
