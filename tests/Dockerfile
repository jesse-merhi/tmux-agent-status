FROM ubuntu:24.04

ENV LANG=C.utf8
ENV LC_ALL=C.utf8

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        jq \
        lsof \
        procps \
        tmux \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home tester
USER tester
WORKDIR /home/tester/.tmux/plugins/tmux-agent-status
COPY --chown=tester:tester . .

CMD ["bash", "tests/run.sh"]
