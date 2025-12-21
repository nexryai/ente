FROM ghcr.io/ente-io/server:latest
USER 529

WORKDIR /var/ente
CMD ["/museum"]
