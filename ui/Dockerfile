FROM ubuntu:26.04

ARG PUID=1000
ARG PGID=1000

LABEL agentbox.uid="${PUID}" \
      agentbox.gid="${PGID}" \
      agentbox.base="ubuntu26.04" \
      agentbox.version="5"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-opensnitch-ui \
    qtwayland5 \
    qt5-gtk-platformtheme \
    libwayland-client0 \
    libwayland-cursor0 \
    libwayland-egl1 \
    libxkbcommon0 \
    libxkbcommon-x11-0 \
    libxcb-xinerama0 \
    libxcb-cursor0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-randr0 \
    libxcb-render-util0 \
    libxcb-shape0 \
    libx11-xcb1 \
    libgl1 \
    libegl1 \
    dbus-x11 \
    xauth \
    xserver-xephyr \
    pulseaudio-utils \
    alsa-utils \
    fonts-dejavu-core \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Crea gruppo e utente non-root con UID/GID corrispondenti all'utente host
RUN (userdel -r ubuntu 2>/dev/null || true) && \
    (groupdel ubuntu 2>/dev/null || true) && \
    groupadd -g "${PGID}" -o snitch && \
    useradd -m -u "${PUID}" -g "${PGID}" -o -s /bin/sh snitch && \
    mkdir -p /run/opensnitch /home/snitch/.config/opensnitch && \
    chown -R "${PUID}:${PGID}" /run/opensnitch /home/snitch

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY opensnitch-launcher.py /usr/local/bin/opensnitch-launcher.py
COPY xephyr-fullscreen.py /usr/local/bin/xephyr-fullscreen.py
COPY xephyr-host.py /usr/local/bin/xephyr-host.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/opensnitch-launcher.py /usr/local/bin/xephyr-fullscreen.py /usr/local/bin/xephyr-host.py

USER ${PUID}:${PGID}
WORKDIR /home/snitch

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
