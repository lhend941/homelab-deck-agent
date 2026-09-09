# For anyone not running an LXC: TrueNAS apps, Unraid, Synology, a Pi, or a
# plain Docker host. Same binary, same config file.
FROM swift:6.0-jammy AS build
WORKDIR /src
COPY Package.swift ./
COPY agent ./agent
COPY homelab-deck-xcode/Sources ./homelab-deck-xcode/Sources
RUN swift build -c release --static-swift-stdlib

FROM ubuntu:jammy
# ca-certificates so hosts with a real certificate verify; curl for the
# container healthcheck below.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/.build/release/homelab-deck-agent /usr/local/bin/
RUN useradd --system --no-create-home homelabdeck
USER homelabdeck
# Two volumes, for two different things. The config holds every credential
# and is the one people back up; the state directory holds only a record of
# which alerts have already been sent. Losing the second is survivable — the
# agent re-announces live problems once — but a container that forgets on
# every restart does it every restart, so it is worth persisting.
VOLUME ["/etc/homelab-deck", "/var/lib/homelab-deck"]
EXPOSE 8787
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s \
  CMD curl -fsS http://127.0.0.1:8787/v1/health || exit 1
ENTRYPOINT ["/usr/local/bin/homelab-deck-agent"]
CMD ["run", "--config", "/etc/homelab-deck/config.json"]
