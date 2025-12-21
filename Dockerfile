FROM ghcr.io/ente-io/server:latest

RUN apk add --no-cache su-exec
RUN printf '#!/bin/sh\n\
cd /\n\
ls \n\
cp /var/config/production.yaml /museum.yaml\n\
echo "Config file copied successfully."\n\
exec su-exec 529 "$@"\n\
' > /entrypoint.sh && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/museum"]
