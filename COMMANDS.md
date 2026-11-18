# Commands

Operational cheat sheet for a deployed LongFi RadSecProxy container. Installation is in
[README.md](README.md); this is the day-to-day and the "something is wrong" page.

Every command assumes the repository is at `/opt/longfi-radsecproxy`. If you cloned it
elsewhere, `cd` there instead and set `REPO_DIR` for `longfi-fetch`.

---

## Start here

```bash
sudo longfi-fetch
```

One screen: container state, tunnel, cipher, last heartbeat, certificate expiry.

### Reading the result

**`Last beat` is the real health indicator, not `Tunnel`.**

`Tunnel` is derived from a connection line in the container log. Docker keeps only the
last 30 MB of log, so on a site that has been connected for weeks without a reconnect,
that line has scrolled away and `Tunnel` reads `down` on a perfectly healthy link.

`Last beat` is the timestamp of the most recent Status-Server reply from LongFi. The proxy
sends these continuously, so a recent timestamp proves the tunnel is carrying traffic right
now.

| `Tunnel` | `Last beat` | Verdict |
|---|---|---|
| up | recent | Healthy |
| down | within the last few minutes | Healthy. Ignore the tunnel line |
| down | hours old, or `n/a` | Genuinely down, work through the section below |

If every field reads `n/a`, you did not use `sudo`, or the repository is not in
`/opt/longfi-radsecproxy`:

```bash
sudo REPO_DIR=/path/to/longfi-radsecproxy longfi-fetch
```

---

## The tunnel is genuinely down

Work down this list. Each step rules out one layer.

**1. Is the container even running?**

```bash
sudo docker compose ps
```

`Restarting` means a bad config or unreadable certificates. Go to the logs below.

**2. Does DNS resolve?**

```bash
getent hosts connect.longfisolutions.com
```

No output means the VM cannot resolve public DNS. Nothing else will work until it can.

**3. Is outbound TCP 2083 open?**

```bash
timeout 5 bash -c '</dev/tcp/connect.longfisolutions.com/2083' && echo reachable || echo BLOCKED
```

`BLOCKED` is a firewall or egress ACL, not a proxy problem. This is the single most common
cause of a tunnel that never comes up on a new install.

**4. Do the certificates still work?**

```bash
sudo openssl x509 -noout -subject -enddate -in /opt/longfi-radsecproxy/certs/cert.pem
```

An expired client certificate takes the tunnel down with no other warning. Renewals:
support@longfisolutions.com.

**5. Does a TLS handshake succeed outside the proxy?**

```bash
sudo openssl s_client -connect connect.longfisolutions.com:2083 \
  -CAfile /opt/longfi-radsecproxy/certs/ca.pem \
  -cert /opt/longfi-radsecproxy/certs/cert.pem \
  -key /opt/longfi-radsecproxy/certs/key.pem </dev/null 2>&1 | head -30
```

This separates "the network and certificates are fine, radsecproxy is misbehaving" from
"the certificates or the path are wrong". Look at the `Verify return code` line at the end.

A hostname mismatch here is expected and harmless: `radsecproxy.conf` sets
`certificateNameCheck off`, so the proxy does not check it either.

---

## Logs

**Follow live:**

```bash
sudo docker compose logs -f radsecproxy
```

**Recent:**

```bash
sudo docker compose logs --tail=100 radsecproxy
```

**Anything that looks like a problem:**

```bash
sudo docker compose logs --tail=500 radsecproxy | grep -iE 'error|fail|unable|denied|refused'
```

**Prove the tunnel is alive right now:**

```bash
sudo docker compose logs --tail=300 radsecproxy | grep 'status server response from longfi' | tail -3
```

Three recent timestamps means the link is up, whatever `longfi-fetch` says about it.

**Find the connection itself:**

```bash
sudo docker compose logs radsecproxy | grep 'TLS connection to longfi'
```

No output does not mean no connection. It can simply have rotated out of the log.

---

## Access points and the shared secret

A healthy tunnel with authentications still failing is almost always one of these two.

**Check the configured secret:**

```bash
sudo docker compose exec radsecproxy grep secret /etc/radsecproxy/radsecproxy.conf
```

This reads the file the container is actually running, which is the point. Compare it
against the secret on your controller.

**Are the access points reaching the VM at all?**

```bash
sudo tcpdump -ni any 'udp port 1812 or udp port 1813' -c 20
```

Install it first if needed: `sudo apt install -y tcpdump`.

No packets means the APs cannot reach this machine. Check the VLAN, the route, and that
your firewall allows UDP 1812 and 1813 inbound to the VM.

---

## Changing the configuration

`radsecproxy.conf` is mounted into the container, so an edit takes effect on restart with
no rebuild.

```bash
sudo nano /opt/longfi-radsecproxy/radsecproxy.conf
```

```bash
cd /opt/longfi-radsecproxy && sudo docker compose restart
```

Confirm the container picked it up:

```bash
sudo docker compose exec radsecproxy grep secret /etc/radsecproxy/radsecproxy.conf
```

### When a config edit appears to work and does not

Early builds copied the config into the image instead of mounting it. On those, editing and
restarting changes nothing, silently, with no error in the logs. Rotating a shared secret
looks like it succeeded while the old one stays live.

```bash
sudo docker inspect radsecproxy --format '{{json .Mounts}}'
```

**Two** mounts (`radsecproxy.conf` and `certs`) is correct. **One** mount, certs only, means
your edits are not being read. Fix it by rebuilding, since both the image and the volume
list have to change:

```bash
cd /opt/longfi-radsecproxy && sudo docker compose up -d --build
```

Re-run the inspect afterwards to confirm two mounts.

---

## Container lifecycle

**Restart:**

```bash
cd /opt/longfi-radsecproxy && sudo docker compose restart
```

**Stop:**

```bash
cd /opt/longfi-radsecproxy && sudo docker compose down
```

**Start:**

```bash
cd /opt/longfi-radsecproxy && sudo docker compose up -d
```

**Update to the latest version:**

```bash
cd /opt/longfi-radsecproxy && sudo git pull origin main && sudo docker compose up -d --build
```

A rebuild is only needed when the `Dockerfile` changes. A config edit needs a restart only.

**Reinstall `longfi-fetch` after an update:**

```bash
cd /opt/longfi-radsecproxy && sudo install -m 755 longfi-fetch /usr/local/bin/longfi-fetch
```

---

## Certificates

**What is installed, and when does it expire:**

```bash
sudo openssl x509 -noout -subject -enddate -in /opt/longfi-radsecproxy/certs/cert.pem
```

**Issuing CA:**

```bash
sudo openssl x509 -noout -subject -in /opt/longfi-radsecproxy/certs/ca.pem
```

**Names, ownership and permissions:**

```bash
ls -l /opt/longfi-radsecproxy/certs
```

All three must be named exactly `ca.pem`, `cert.pem` and `key.pem`, owned by `radsec`
(uid 10001), mode 600. Anything else and the container will not start.

**Fix ownership and permissions:**

```bash
sudo chown radsec:radsec /opt/longfi-radsecproxy/certs/*.pem && sudo chmod 600 /opt/longfi-radsecproxy/certs/*.pem
```

Never send a `key.pem` to anyone, including LongFi support. We never need it.

---

## Contacting support

Send both of these to support@longfisolutions.com:

```bash
sudo longfi-fetch
```

```bash
sudo docker compose logs --tail=200 radsecproxy
```

The log is the part that usually identifies the problem. The banner tells us which
deployment and certificate you are on.
