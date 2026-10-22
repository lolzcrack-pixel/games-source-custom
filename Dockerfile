FROM        ghcr.io/parkervcp/games:source

USER        root
COPY        wrapper.sh /wrapper.sh
RUN         sed -i 's/\r$//' /wrapper.sh && chmod +x /wrapper.sh

USER        container
WORKDIR     /home/container

CMD         ["/wrapper.sh"]
