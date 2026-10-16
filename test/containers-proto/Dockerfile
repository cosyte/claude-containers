# Throwaway prototype stage (task: containers in sessions), never shipped: the session image
# plus rootless podman, built only by .github/workflows/containers-proto.yml.
ARG BASE=claude-code-box:ci
FROM ${BASE}
# podman and its runtime pieces (crun, conmon, netavark, passt for rootless networking),
# uidmap for newuidmap/newgidmap, libcap2-bin for setcap, the docker CLI and compose to
# drive `podman system service` through DOCKER_HOST.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        podman crun conmon netavark aardvark-dns passt uidmap catatonit \
        libcap2-bin docker-cli docker-compose; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    # Mode "fcaps": file capabilities on newuidmap/newgidmap, not setuid root.
    chmod u-s /usr/bin/newuidmap /usr/bin/newgidmap; \
    setcap cap_setuid+ep /usr/bin/newuidmap; \
    setcap cap_setgid+ep /usr/bin/newgidmap; \
    # The storage lives on a volume (overlay on the container's own overlayfs is refused).
    install -d -o claude -g claude /home/claude/.local /home/claude/.local/share \
        /home/claude/.local/share/containers /home/claude/.config /home/claude/.config/containers
# No systemd in a session: cgroupfs and a file event log.
COPY --chown=claude:claude containers.conf /home/claude/.config/containers/containers.conf
COPY uidmap-helper.py /usr/local/lib/containers-proto/uidmap-helper.py
COPY newidmap-client.py /usr/local/lib/containers-proto/helper-bin/newuidmap
COPY newidmap-client.py /usr/local/lib/containers-proto/helper-bin/newgidmap
RUN chmod 755 /usr/local/lib/containers-proto/helper-bin/* /usr/local/lib/containers-proto/uidmap-helper.py
