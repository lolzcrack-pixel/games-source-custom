FROM        ghcr.io/parkervcp/games:source

USER        root
COPY        wrapper.sh /wrapper.sh
RUN         sed -i 's/\r$//' /wrapper.sh && chmod +x /wrapper.sh \
            && script --version

USER        container
WORKDIR     /home/container

ENV         RESTART_TIMES=08:00

CMD         ["/wrapper.sh"]
