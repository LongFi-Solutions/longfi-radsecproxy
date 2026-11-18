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
| down | hours old, or `n/a` | Genuinely down, see [The tunnel is genuinely down](#the-tunnel-is-genuinely-down) |

If every field reads `n/a`, you did not use `sudo`, or the repository is not in
`/opt/longfi-radsecproxy`:

```bash
sudo REPO_DIR=/path/to/longfi-radsecproxy longfi-fetch
```

---

## Everyday checks

For a deployment that is up and working. All of these are read-only.

**Is the container running:**

```bash
sudo docker compose ps
```

**Follow the log live:**

```bash
sudo docker compose logs -f radsecproxy
```

**Last 100 lines:**

```bash
sudo docker compose logs --tail=100 radsecproxy
```

**Is the link alive right now:**

```bash
sudo docker logs radsecproxy --tail 300 2>&1 | grep 'status server response from longfi' | tail -1
```

A timestamp within the last few minutes means the tunnel is up, whatever `longfi-fetch`
reports for `Tunnel`.

**Tunnel connections and reconnects in the last 24 hours:**

```bash
sudo docker logs radsecproxy --since 24h 2>&1 | grep 'TLS connection to longfi'
```

No output is normal and good. The proxy logs this when it connects, so a stable link that
has not reconnected in 24 hours produces nothing. Repeated lines through the day mean the
tunnel is flapping, which is worth reporting.

**Anything that looks like a problem:**

```bash
sudo docker compose logs --tail=500 radsecproxy | grep -iE 'error|fail|unable|denied|refused'
```

---

## Traffic and health counts

radsecproxy is a proxy. It keeps no session table, so there is no "currently active
sessions" figure to read anywhere. Everything below is counted from the container log over
a time window.

Two things shape every number here:

- Docker keeps roughly the last 30 MB of log (`max-size: 10m`, `max-file: 3`). On a busy
  site that can be well under 24 hours, so **a 24 hour count is a floor, not a total.**
- radsecproxy logs to stderr, so `2>&1` is required. Without it every command below returns
  nothing on a perfectly healthy container.

These use `docker logs` rather than `docker compose logs` because compose prefixes each
line with the service name, which breaks the column-based commands further down.

### What your log actually contains

Run this once per deployment before relying on the counts. Log content varies with
radsecproxy version and `LogLevel`, and this tells you which of the commands below will
return anything:

```bash
sudo docker logs radsecproxy --tail 2000 2>&1 | grep -oE 'Access-[A-Za-z]+|Accounting-[A-Za-z]+' | sort | uniq -c | sort -rn
```

If that prints nothing, the log is not recording per-packet lines and only the tunnel and
heartbeat commands will be useful.

### Message mix over a window

Last hour:

```bash
sudo docker logs radsecproxy --since 1h 2>&1 | grep -oE 'Access-[A-Za-z]+|Accounting-[A-Za-z]+' | sort | uniq -c | sort -rn
```

Last 24 hours, same shape:

```bash
sudo docker logs radsecproxy --since 24h 2>&1 | grep -oE 'Access-[A-Za-z]+|Accounting-[A-Za-z]+' | sort | uniq -c | sort -rn
```

### Accept versus reject

```bash
sudo docker logs radsecproxy --since 24h 2>&1 | grep -c 'Access-Accept'
```

```bash
sudo docker logs radsecproxy --since 24h 2>&1 | grep -c 'Access-Reject'
```

Expect noticeably more Access-Requests than Accepts. EAP-AKA is multi-round, so a single
successful carrier authentication is roughly two Access-Requests and one Accept. A ratio
far above that, or a Reject count climbing, is the signal worth acting on.

### Connections by carrier and realm

Realm distribution, which is the most reliable way to break traffic down by carrier:

```bash
sudo docker logs radsecproxy --since 24h 2>&1 | grep -oE '@[A-Za-z0-9._-]+' | sort | uniq -c | sort -rn | head -20
```

AT&T specifically (its three realms are `mnc410`, `mnc280` and `mnc150` under `mcc310`):

```bash
sudo docker logs radsecproxy --since 24h 2>&1 | grep -cE 'mnc(410|280|150)\.mcc310'
```

Both depend on usernames appearing in the log. If the realm command above returns nothing,
they are not being logged at this `LogLevel` and per-carrier counts are not available from
the log.

### Access points seen

Distinct addresses appearing in the window. This includes the upstream and the container's
own addresses, so subtract those; what remains are your access points or controller:

```bash
sudo docker logs radsecproxy --since 24h 2>&1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u
```

### Traffic by hour

A quick shape-of-the-day histogram. Useful for "is it busy, or has it stopped":

```bash
sudo docker logs radsecproxy --since 24h 2>&1 | grep 'Access-Request' | awk '{print $2, $3, $4}' | cut -d: -f1 | uniq -c
```

A gap of several hours in the middle of a working day means traffic stopped reaching the
proxy, not that authentication is failing.

### One-shot summary

Everything above in a single paste, for sending to support or pasting into a ticket:

```bash
sudo bash -c '
echo "=== container ==="
docker inspect -f "{{.State.Status}} since {{.State.StartedAt}}" radsecproxy
echo "=== last heartbeat ==="
docker logs radsecproxy --tail 300 2>&1 | grep "status server response from longfi" | tail -1
echo "=== message mix, 24h ==="
docker logs radsecproxy --since 24h 2>&1 | grep -oE "Access-[A-Za-z]+|Accounting-[A-Za-z]+" | sort | uniq -c | sort -rn
echo "=== realms, 24h ==="
docker logs radsecproxy --since 24h 2>&1 | grep -oE "@[A-Za-z0-9._-]+" | sort | uniq -c | sort -rn | head -10
echo "=== errors, last 500 lines ==="
docker logs radsecproxy --tail 500 2>&1 | grep -iE "error|fail|unable|denied|refused" | tail -20
'
```

---

## The tunnel is genuinely down

Only work through this once `Last beat` has confirmed there is a real problem. Each step
rules out one layer.

**1. Is the container even running?**

```bash
sudo docker compose ps
```

`Restarting` means a bad config or unreadable certificates. Go to the logs above.

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
