# Homelab Deck agent

An optional always-on service for your own network, for the one thing a phone
genuinely cannot do well: **notice a problem at 3am and tell you about it.**

iOS decides when a backgrounded app may run. "Usually about once an hour, and
sometimes much longer" is a weak backbone for the job that actually matters, so
the agent takes it over: it polls on a schedule nobody defers, and the app reads
from it.

**The app works without this.** Point your phone at each server and it talks to
them directly — that is still the primary mode, and nothing here is required.

## What it does

- Polls every server you configure, on a fixed interval.
- Serves one JSON endpoint the Homelab Deck app reads.
- Forwards alerts to **ntfy, Gotify, or a webhook** when something needs
  attention — and forwards a given problem *once*, not every minute.

It runs the **same adapters and the same rules as the app**. An agent that
graded problems differently from the phone would be worse than no agent,
because you would stop trusting both.

## What it deliberately does not do

Said out loud, because a service that quietly skipped things would look broken:

- **No consoles.** The agent has no screen, and a service that could open a
  root shell on request is a far larger thing to leave running on a network
  than a poller. Consoles stay in the app, behind a biometric prompt.
- **No pinned self-signed certificates yet.** The app refuses a certificate no
  human has approved, and that rule is not negotiable — so rather than disable
  validation, the agent *refuses* those hosts and says why.
- **Synology** is not supported yet; its adapter is unverified against real
  hardware.

## Install

Debian or Ubuntu — an LXC, a VM, a Raspberry Pi. Needs ~256MB of RAM and 2GB of
disk, because the binary is fully static and carries its own runtime.

```bash
curl -fsSL https://raw.githubusercontent.com/lhend941/homelab-deck-agent/main/install.sh -o install.sh
less install.sh          # please actually read it
sudo bash install.sh --download
```

The installer downloads the release binary for your architecture, **verifies
its SHA-256 against the published `SHA256SUMS`, and refuses to install if that
file is missing or does not match.** A daemon that will hold every credential
on your network is not something to install from an unverified download.

Then pair and configure:

```bash
sudo homelab-deck-agent pair          # writes a config skeleton + a token
sudoedit /etc/homelab-deck/config.json # add your servers
sudo systemctl enable --now homelab-deck-agent
```

Check it:

```bash
homelab-deck-agent check              # one timed pass over every host
curl localhost:8787/v1/health
```

Docker, for TrueNAS apps, Unraid, Synology, or a plain Docker host — so Proxmox
is not required:

```bash
docker build -t homelab-deck-agent .
docker run -d --name homelab-deck-agent \
  -v /etc/homelab-deck:/etc/homelab-deck \
  -v /var/lib/homelab-deck:/var/lib/homelab-deck \
  -p 8787:8787 homelab-deck-agent
```

## The config file, and the deal it asks of you

`/etc/homelab-deck/config.json` holds **every credential the agent has, in
plaintext.** A headless Linux service has nowhere better — there is no Keychain.
So:

- the installer creates it `0600`, owned by an unprivileged `homelabdeck` user;
- **the agent refuses to start if the permissions are looser than that**;
- the systemd unit runs with almost every capability removed.

That is the deal, and it is worth stating plainly rather than burying.

**The token is authentication, not encryption.** The API is plain HTTP. Reach it
over a tunnel or a VPN rather than forwarding a port to the internet.

## Connecting the app

In Homelab Deck: **Settings → Alerts → Agent**. Enter the address the agent
prints at startup and the pairing token from `homelab-deck-agent pair`.

A reading that came from the agent says so on the card, with its age. The newer
of the two always wins, whoever took it.

## Uninstall

```bash
sudo systemctl disable --now homelab-deck-agent
sudo rm -f /usr/local/bin/homelab-deck-agent \
           /etc/systemd/system/homelab-deck-agent.service
sudo rm -rf /etc/homelab-deck /var/lib/homelab-deck   # deletes your credentials
sudo userdel homelabdeck
```

## Source

This repository publishes the installer and the release binaries. The agent's
source currently lives with the app, because it compiles the app's own adapter
files rather than a copy of them — that is deliberate, and it is what keeps the
two grading problems identically.

## Support

Issues here for the agent. The app itself: https://homelabdeck.app/support/
