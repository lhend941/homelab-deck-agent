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

## Setting it up, from nothing

### 1. Make a container for it

Debian or Ubuntu. An LXC, a VM, or a Raspberry Pi — it needs very little:

| | |
|---|---|
| RAM | 256 MB |
| Disk | 2 GB |
| CPU | 1 core |

The binary is fully static and carries its own runtime, so nothing else gets
installed. **Give it a container of its own** — step 3 trusts your servers'
certificates machine-wide, and you want that blast radius to be one box that
does nothing else.

On Proxmox, a Debian 13 container with those numbers on your normal LAN is
exactly right. It does not need a public address, a tunnel, or a port forward.

### 2. Install the agent

```bash
curl -fsSL https://raw.githubusercontent.com/lhend941/homelab-deck-agent/main/install.sh -o install.sh
less install.sh          # please actually read it
sudo bash install.sh --download
```

That downloads the release binary for your architecture, **verifies its SHA-256
against the published checksums, and refuses to install if that file is missing
or does not match.** It then creates an unprivileged `homelabdeck` user, installs
a systemd unit, and writes a starter config with a fresh pairing token.

**Write down the pairing token it prints.** You need it in step 5. If you lose
it:

```bash
sudo homelab-deck-agent pair      # prints the existing token, does not replace it
```

### 3. Trust your servers' certificates

**Do this before adding servers, or nothing will connect.** Almost every
homelab box ships a self-signed certificate — Proxmox and TrueNAS both do — and
the agent validates certificates like any other client.

For each server, on the agent's machine:

```bash
sudo homelab-deck-agent trust 192.168.1.20:8006
```

It shows you the certificate's fingerprint and asks before trusting anything.
Compare it against what the server itself shows. See
[HTTPS and self-signed certificates](#https-and-self-signed-certificates--read-this-first)
below for the case where this is not enough.

### 4. Add your servers

```bash
sudoedit /etc/homelab-deck/config.json
```

```json
{
  "token": "leave the token that is already there",
  "hosts": [
    {
      "id": "0F5B0C5E-2B7E-4E1F-9E9C-9E1A2B3C4D5E",
      "name": "PVE01",
      "platform": "proxmox",
      "address": "192.168.1.20",
      "port": 8006,
      "credential": {
        "proxmoxAPIToken": { "tokenID": "root@pam!homelabdeck", "secret": "..." }
      }
    }
  ]
}
```

- `id` is **any UUID** — generate one with `uuidgen`. Keep it stable and the app
  keeps the same host across restarts.
- `platform` is one of `proxmox`, `proxmoxBackup`, `truenas`, `homeAssistant`,
  `portainer`, `uptimeKuma`, `unifi`, `opnsense`, `pihole`, `adguard`, `unraid`.
- `credential` takes one of three shapes:

```json
{ "apiKey": "..." }
{ "proxmoxAPIToken": { "tokenID": "root@pam!homelabdeck", "secret": "..." } }
{ "usernameAndPassword": { "username": "...", "password": "..." } }
```

- Only `token` and `hosts` are required. `listenPort` defaults to 8787,
  `pollSeconds` to 60, and a host's `scheme` to `https`.

Then start it and check your work:

```bash
sudo systemctl enable --now homelab-deck-agent
homelab-deck-agent check
```

`check` reads every host once and prints how long each took, so a wrong
credential or an untrusted certificate shows up immediately with the reason
rather than as a blank card in the app later.

### 5. Connect the app

In Homelab Deck: **Settings → Alerts → Agent**.

- **Address** — what the agent printed at startup, e.g. `192.168.1.50:8787`
- **Pairing token** — from step 2

Tap **Test and pair**. It checks the address first, then the token, so a typo
is reported as the thing it actually is. Nothing is saved unless the test
passes.

Readings that came from the agent are labelled *via agent* on the fleet, with
their age. The newer of the two always wins, whoever took it.

### 6. Optional: alerts when you are not looking

Either or both, and they work independently.

**To ntfy, Gotify or a webhook** — add to the config:

```json
"forwarding": { "kind": "ntfy", "url": "https://ntfy.sh/your-topic" }
```

**Native push to the phone** — Settings → Alerts → Agent → *Turn on push*. The
relay address is already filled in.

Your servers' names and problems are **not** sent. The notification says only
that something needs attention; the app fetches the detail from your own agent
when you open it.

### Docker instead

For TrueNAS apps, Unraid, Synology, or a plain Docker host — so Proxmox is not
required:

```bash
docker build -t homelab-deck-agent .
docker run -d --name homelab-deck-agent \
  -v /etc/homelab-deck:/etc/homelab-deck \
  -v /var/lib/homelab-deck:/var/lib/homelab-deck \
  -p 8787:8787 homelab-deck-agent
```

### Upgrading

```bash
sudo bash install.sh --download && sudo systemctl restart homelab-deck-agent
```

Your config and pairing token are left alone.

## HTTPS and self-signed certificates — read this first

**This is the thing most likely to stop the agent working**, because almost
every homelab box ships a self-signed certificate. Proxmox and TrueNAS both do.

The agent validates certificates like any other client, and it will not skip
that check. So out of the box it cannot talk to a default Proxmox or TrueNAS
over HTTPS:

```
FAILED — Couldn't reach the host. SSL certificate problem:
         unable to get local issuer certificate
```

**The fix is to trust that server's certificate on the agent's machine**, once
per server:

```bash
sudo apt-get install -y ca-certificates openssl
echo | openssl s_client -connect YOUR-SERVER:PORT -showcerts 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' \
  | sudo tee /usr/local/share/ca-certificates/your-server.crt > /dev/null
sudo update-ca-certificates
sudo systemctl restart homelab-deck-agent
```

That is system-wide trust **on that machine**, which is why the agent belongs
in a container of its own: the blast radius is one box that does nothing else.

### The `trust` command

Rather than the procedure above, the agent can do it and check your work:

```bash
sudo homelab-deck-agent trust 10.0.0.20:8006
```

It fetches the certificate, shows you its subject, issuer and SHA-256
fingerprint, and asks you to confirm — the same trust-on-first-use the app
does, except the approval is at a prompt. Compare the fingerprint against what
the server itself shows, or pass one you already have:

```bash
sudo homelab-deck-agent trust 10.0.0.20:8006 --fingerprint AA:BB:... --yes
```

Any mismatch refuses outright and changes nothing. It also tells you when
trusting will not be enough, rather than leaving you to discover it.

### When trusting is not enough

The certificate still has to match the address you dial. A certificate issued
for `localhost` cannot validate a connection to `10.0.0.50`, however much you
trust it:

```
SSL: no alternative certificate subject name matches target ipv4 address
```

**TrueNAS's default certificate is exactly this** — `CN=localhost`, with no
subject alternative name for any real address. Trusting it changes nothing.
Either install a certificate on TrueNAS that names the address you use, or
watch TrueNAS directly from the app, which does trust-on-first-use with a
fingerprint you approve by hand.

Certificate pinning in the agent is the proper fix and is not built yet. A host
with `pinnedCertificateSHA256` set is refused with a message saying so, rather
than silently connecting to something unverified.

## The config file, and the deal it asks of you

`/etc/homelab-deck/config.json` holds **every credential the agent has, in
plaintext.** A headless Linux service has nowhere better — there is no Keychain.
So:

- the installer creates it `0600`, owned by an unprivileged `homelabdeck` user;
- **the agent refuses to start if the permissions are looser than that**;
- the systemd unit runs with almost every capability removed, and the config
  directory is read-only to the service.

That is the deal, and it is worth stating plainly rather than burying.

**The token is authentication, not encryption.** The API is plain HTTP. Reach it
over a tunnel or a VPN rather than forwarding a port to the internet.

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
