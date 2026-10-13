<img width="2551" height="439" alt="image" src="https://github.com/user-attachments/assets/3a03e677-8411-4035-b1b8-11435ea8c16d" />


# LongFi RadSecProxy Container

The LongFi RadSecProxy Container is a preconfigured AAA proxy based on the open source radsecproxy project, a generic RADIUS proxy that in addition to usual RADIUS UDP transport, also supports TLS (RadSec).  This allows TLS termination at the edge of your network, in a lightweight containerized proxy that requires very little hardware resources.  That project can be found at https://radsecproxy.github.io/

## Why RadSecProxy?

RADIUS is the core authentication protocol for network access, and has normally operated as a clear text UDP protocol, not designed for travel across public networks.  RadSec (RADIUS over TLS) is a modern extension that secures RADIUS by encapsulating its traffic within a TLS-encrypted TCP tunnel, offering the Carrier Grade security required for sending RADIUS messages across the public internet.

## But my Wi-Fi vendor has some settings for RadSec?

We are aware that most network vendors have some native support for RadSec.  However, many of them lack the support or scalability required for Passpoint, OpenRoaming, Eduroam, and Carrier Offload.

If you have been directed to the LongFi radsecproxy repository, we have already verified your WLAN vendor (or controller architecture) does not support RadSec, or does not support it in the way required for Passpoint.  Please submit a feature request and ask for better RadSec support!!!

---

## Prerequisites

- A machine with Docker and Git installed.
  - If you are spinning up a new VM, we recommend Ubuntu 24.04 LTS or Debian 12 for consistent package management.
  - Need help setting up a VM and installing Docker? [See the VM Setup Guide below.](#vm-setup-guide)
- The machine has a private IP in your network reachable from your Access Points (or WLAN controller), and can resolve public DNS hostnames
  - Alternatively, you have a VPN tunnel from your site(s) to a cloud VM
- ACLs or Firewalls allow Access Points and Docker Container to communicate on UDP ports 1812 and 1813
- ACLs or Firewalls allow container/host to reach the internet on TCP port 2083
- TLS certificates provided by LongFi Solutions

### System Requirements

- **CPU:** x86_64 or ARM64, 2 cores
- **RAM:** 4GB minimum, 8GB or more recommended
- **Disk:** 20GB minimum, 32GB recommended for log retention

The proxy itself is small — the memory is for building radsecproxy from source on first run, which is slow and memory-hungry on a 2GB machine.

### Installing the prerequisites — example for Ubuntu

Update the package index and install Git, Docker and the Compose plugin:

```bash
sudo apt update && sudo apt install -y git docker.io docker-compose-v2
```

Make sure the Docker service is enabled so the container comes back after a reboot:

```bash
sudo systemctl enable --now docker
```

Confirm all three are present before continuing:

```bash
git --version && docker --version && docker compose version
```

Create the directory the setup script looks in for your certificates:

```bash
mkdir -p ~/certs
```

Copy the 3 files LongFi sent you into it, keeping their original names. From your own machine:

```bash
scp *.ca.pem *.cert.pem *.key.pem user@your-server:~/certs/
```

The setup script finds them there automatically and renames them as it copies them into place — you will not be asked for paths. If they are somewhere else, it will prompt instead.

> **Note:** on Ubuntu the Compose plugin package is `docker-compose-v2`. The name `docker-compose-plugin` belongs to Docker's own apt repository and is not available from the Ubuntu archives.

---

## Quick Setup (Recommended)

A setup script is included to walk you through installation. Git and Docker must already be present — on a fresh machine see [Installing the prerequisites](#installing-the-prerequisites--example-for-ubuntu) above.

```bash
cd /opt
sudo git clone https://github.com/LongFi-Solutions/longfi-radsecproxy.git
cd longfi-radsecproxy
sudo bash setup.sh
```

The script will:
- Verify Docker is installed
- Pick up your certificates from `~/certs` and copy them into place with the right names and permissions
- Set your RADIUS shared secret
- Build and start the container

---

## Manual Deployment

### 1. Install Git (if not already installed)

**For Debian/Ubuntu:**
```bash
sudo apt update
sudo apt install git -y
```

### 2. Clone the Repository

```bash
cd /opt
sudo git clone https://github.com/LongFi-Solutions/longfi-radsecproxy.git
cd longfi-radsecproxy
```

### 3. Install Docker (if not already installed)

**For Debian/Ubuntu:**
```bash
sudo apt update
sudo apt install docker.io docker-compose-v2 -y
sudo systemctl enable --now docker
```

**Verify:**
```bash
sudo docker --version
sudo docker compose version
```

### 4. Add Your Certificates

Create the `certs/` directory and copy in the 3 certificate files provided by LongFi Solutions. **The destination filenames are required** — `radsecproxy.conf` looks for exactly `/certs/ca.pem`, `/certs/cert.pem` and `/certs/key.pem`.

Your certificates are issued as `*.ca.pem`, `*.cert.pem` and `*.key.pem`, so the globs below each match one file and rename it as they copy:

```bash
sudo mkdir -p /opt/longfi-radsecproxy/certs
sudo cp /path/to/certs/*.ca.pem   /opt/longfi-radsecproxy/certs/ca.pem
sudo cp /path/to/certs/*.cert.pem /opt/longfi-radsecproxy/certs/cert.pem
sudo cp /path/to/certs/*.key.pem  /opt/longfi-radsecproxy/certs/key.pem
```

The container runs as an unprivileged `radsec` user (uid 10001), and `certs/` is a bind mount — so the certificates must be owned by a matching user on the host. Create it and lock the files down:

```bash
sudo getent group radsec >/dev/null || sudo groupadd -g 10001 radsec
sudo getent passwd radsec >/dev/null || sudo useradd -u 10001 -g radsec -s /usr/sbin/nologin -M radsec
sudo chown radsec:radsec /opt/longfi-radsecproxy/certs/*.pem
sudo chmod 600 /opt/longfi-radsecproxy/certs/*.pem
```

This keeps the private key readable only by the proxy and by root. The [Quick Setup](#quick-setup-recommended) script does all of this for you.

Confirm all three landed with the correct names and ownership:

```bash
ls -l /opt/longfi-radsecproxy/certs
```

**Important:** Never commit your certificates to git. The `certs/` directory is listed in `.gitignore`.

### 5. Set Your RADIUS Shared Secret

Edit `radsecproxy.conf` and replace `changeme` with the shared secret configured on your access points:

```bash
sudo nano /opt/longfi-radsecproxy/radsecproxy.conf
```

Find the client block and update the secret:
```
client 'local' {
    host '0.0.0.0/0'
    type 'udp'
    secret 'your-secret-here'
}
```

### 6. Build and Start the Container

```bash
cd /opt/longfi-radsecproxy
sudo docker compose up -d --build
```

### 7. Verify the Container is Running

```bash
sudo docker compose ps
sudo docker compose logs -f radsecproxy
```

You should see radsecproxy connect to `connect.longfisolutions.com` on startup.

---

## Container Management

**Status at a glance:**

```bash
sudo longfi-fetch
```

Prints a one-screen summary: whether the TLS tunnel to LongFi is up, the negotiated cipher, when the last heartbeat arrived, your client certificate and its expiry date, and the support address for renewals. A good first check if something looks wrong.

The setup script offers to install it. To add it later, or after pulling an update:

```bash
cd /opt/longfi-radsecproxy
sudo install -m 755 longfi-fetch /usr/local/bin/longfi-fetch
```

It reads the deployment from `/opt/longfi-radsecproxy` by default. If you cloned the repository somewhere else, point it at that directory or every field will read `n/a`:

```bash
sudo REPO_DIR=/path/to/longfi-radsecproxy longfi-fetch
```

**View logs:**
```bash
sudo docker compose logs -f radsecproxy
```

**View recent logs (last 100 lines):**
```bash
sudo docker compose logs --tail=100 radsecproxy
```

**Stop the container:**
```bash
sudo docker compose down
```

**Restart the container:**
```bash
sudo docker compose restart
```

**Apply a configuration change:**

`radsecproxy.conf` is mounted into the container, so an edit takes effect on restart — no rebuild required:

```bash
cd /opt/longfi-radsecproxy
sudo docker compose restart
```

Confirm the container is reading what you expect:

```bash
sudo docker compose exec radsecproxy grep secret /etc/radsecproxy/radsecproxy.conf
```

A rebuild (`up -d --build`) is only needed when the `Dockerfile` itself changes — for example after `git pull` brings a new radsecproxy version.

**Update to latest version:**
```bash
cd /opt/longfi-radsecproxy
sudo git pull origin main
sudo docker compose up -d --build
```

---

## Troubleshooting

Start with `sudo longfi-fetch` — it shows the tunnel state, certificates and expiry in one place.

| Symptom | Likely cause |
|---|---|
| `docker ps` shows `Restarting` | Bad config or unreadable certificates. Check `sudo docker compose logs radsecproxy` |
| `Error reading privatekey` / `Permission denied` | Certificates not owned by `radsec` or not mode 600. Re-run step 4 |
| `Failed reading certificate file` | A certificate is missing or misnamed. All three must be `ca.pem`, `cert.pem`, `key.pem` |
| Tunnel never comes up | Outbound TCP 2083 blocked, or DNS cannot resolve `connect.longfisolutions.com` |
| `certificate verify failed` | Wrong `ca.pem`, or the certificates are not the ones LongFi issued you |
| Access points rejected, tunnel healthy | Shared secret mismatch. Check `grep secret radsecproxy.conf` against your controller |
| Config edit had no effect | Either you edited a copy elsewhere — the mounted file is the one in this directory — or the container predates config mounting. See below |
| `longfi-fetch` shows `n/a` everywhere | Run it with `sudo`, or set `REPO_DIR` if the repository is not in `/opt/longfi-radsecproxy` |

### A config change that appears to deploy and does not

Early builds of this container copied `radsecproxy.conf` into the image instead of mounting
it. On those, editing the file and restarting does nothing — the container keeps running the
configuration it was built with, with no error and nothing in the logs. Rotating a shared
secret looks like it succeeded while the old one stays live.

One command tells you which you have:

```bash
sudo docker inspect radsecproxy --format '{{json .Mounts}}'
```

**Two** mounts — `radsecproxy.conf` and `certs` — is correct. **One** mount, certs only, means
the config is baked in and your edits are not being read.

To fix it, replace `docker-compose.yml` and `Dockerfile` with the current versions from this
repository, then rebuild. A restart is not enough, because both the image and the volume list
change:

```bash
sudo docker compose up -d --build
```

Re-run the inspect afterwards to confirm two mounts.

Full logs:

```bash
sudo docker compose logs -f radsecproxy
```

If you are stuck, send that log output to support@longfisolutions.com.

---

## Directory Structure

```
longfi-radsecproxy/
├── certs/              # Your certificate files (not tracked in git)
│   ├── ca.pem
│   ├── cert.pem
│   └── key.pem
├── Dockerfile
├── docker-compose.yml
├── radsecproxy.conf
├── setup.sh
├── longfi-fetch          # status banner (see Container Management)
└── README.md
```

---

## VM Setup Guide

<details>
<summary>Click to expand — creating a VM and installing Docker</summary>

### VM Specification

Create the VM on whichever hypervisor you use — Proxmox, VMware, Hyper-V, XCP-ng, VirtualBox — or install directly on bare metal or an existing Linux host. The proxy is small; these figures are comfortable rather than minimal:

| Resource | Value |
|----------|-------|
| vCPU | 2 |
| RAM | 8 GB (4 GB minimum) |
| Disk | 32 GB (20 GB minimum) |
| Network | One interface on a network your access points can reach |
| Guest OS | Ubuntu Server 24.04 LTS or Debian 12 |

If your hypervisor offers paravirtualized disk and network drivers, use them. If it can start the VM automatically with the host, enable that — this is infrastructure and should come back on its own after a reboot.

### Install the Operating System

Download **Ubuntu Server 24.04 LTS** from https://releases.ubuntu.com/24.04/ and verify it against the `SHA256SUMS` file in that same directory. You want the `live-server` image, not desktop.

During installation:

- Choose **Ubuntu Server**, not the minimized variant — minimized omits editors and diagnostic tools you will want when troubleshooting
- Set a hostname (e.g. `longfi-radsecproxy`)
- Create a user account
- **Enable OpenSSH server** so you can connect after install
- If you accept the LVM default, check the size of the root volume on the storage summary screen. The installer often leaves part of the disk unallocated in the volume group, which shows up later as less free space than expected

Give the machine a **static IP or a DHCP reservation**. Your access points will be configured to point at this address, so it cannot change.

### Install Docker

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
```

Optionally add your user to the `docker` group so `sudo` isn't needed for every command. Log out and back in for it to take effect:

```bash
sudo usermod -aG docker $USER
```

Verify:

```bash
docker --version
docker compose version
```

### Network Considerations

- If your access points are on a separate VLAN, make sure that VLAN reaches the VM. How you do that depends on your hypervisor's virtual switch or bridge configuration
- The VM needs outbound internet access on **TCP port 2083** to reach `connect.longfisolutions.com`
- Access points need to reach the VM on **UDP ports 1812 and 1813**

Once Docker is installed and networking is verified, return to the [Quick Setup](#quick-setup-recommended) section above.

</details>
