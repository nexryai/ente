FROM ghcr.io/ente-io/server:latest

RUN echo '#!/bin/sh\n\
if [ -f /var/config/production.yaml ]; then\n\
    cp /var/config/production.yaml /museum.yaml\n\
    echo "Config file copied successfully."\n\
fi\n\
exec su -s /bin/sh -c "./museum" 529' > /entrypoint.sh && chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
