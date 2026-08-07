#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This script is normally run with sudo, which sets $HOME to root's home. Resolve the
# invoking user's home instead, so a path like ~/certs/ca.pem means what they expect
# rather than silently looking under /root.
if [ -n "$SUDO_USER" ]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    USER_HOME="$HOME"
fi

echo ""
echo "================================================"
echo "  LongFi RadSecProxy Setup"
echo "================================================"
echo ""

# Check Docker
if ! command -v docker &>/dev/null; then
    echo -e "${RED}Error: Docker is not installed.${NC}"
    echo "Install it with: sudo apt install docker.io docker-compose-v2 -y"
    exit 1
fi

if ! docker compose version &>/dev/null; then
    echo -e "${RED}Error: Docker Compose plugin is not installed.${NC}"
    echo "Install it with: sudo apt install docker-compose-v2 -y"
    exit 1
fi

echo -e "${GREEN}Docker found.${NC}"
echo ""

# Certificates
echo "--- Certificates ---"

mkdir -p "$SCRIPT_DIR/certs"

# LongFi issues certificates named *.ca.pem, *.cert.pem and *.key.pem. If they have been
# copied to ~/certs — the location the README tells customers to use — pick them up
# automatically and rename them to what radsecproxy.conf expects. Only ask if that fails.
STAGE="$USER_HOME/certs"

if ls "$STAGE"/*.ca.pem "$STAGE"/*.cert.pem "$STAGE"/*.key.pem >/dev/null 2>&1; then
    cp "$STAGE"/*.ca.pem   "$SCRIPT_DIR/certs/ca.pem"
    cp "$STAGE"/*.cert.pem "$SCRIPT_DIR/certs/cert.pem"
    cp "$STAGE"/*.key.pem  "$SCRIPT_DIR/certs/key.pem"
    echo -e "${GREEN}Found your certificates in $STAGE and copied them into place.${NC}"
else
    echo "No certificates found in $STAGE."
    echo "Enter the path to each of the 3 files provided by LongFi Solutions."
    echo ""

    for FILE in ca cert key; do
        if [ "$FILE" = "key" ]; then
            LABEL="private key"
        elif [ "$FILE" = "cert" ]; then
            LABEL="client certificate"
        else
            LABEL="CA certificate"
        fi

        while true; do
            read -rp "Path to your $LABEL: " CERT_PATH
            CERT_PATH="${CERT_PATH/#\~/$USER_HOME}"
            if [ -f "$CERT_PATH" ]; then
                cp "$CERT_PATH" "$SCRIPT_DIR/certs/${FILE}.pem"
                echo -e "${GREEN}Copied ${FILE}.pem${NC}"
                break
            else
                echo -e "${RED}File not found: $CERT_PATH${NC}"
            fi
        done
    done
fi

# Lock down the certificates.
#
# The container runs as the unprivileged 'radsec' user (uid 10001). /certs is a bind
# mount, so the host's numeric ownership is what the container sees — the Dockerfile's
# chown does not apply. Creating a matching radsec user here means the private key can
# be mode 600 owned by radsec: readable by the proxy and by root, and by nobody else on
# this machine. Without it the key would have to be world-readable to work at all.
# No -r: it restricts allocation to the system range (100-999) and would make useradd warn
# about an explicit uid of 10001. -M skips the home directory, which is the part of -r we
# actually wanted. 10001 is inside the normal UID_MIN/UID_MAX range so nothing complains.
if ! getent group radsec >/dev/null; then
    groupadd -g 10001 radsec
fi
if ! getent passwd radsec >/dev/null; then
    useradd -u 10001 -g radsec -s /usr/sbin/nologin -M radsec
fi

EXISTING_UID="$(id -u radsec 2>/dev/null || true)"
if [ -n "$EXISTING_UID" ] && [ "$EXISTING_UID" != "10001" ]; then
    echo -e "${YELLOW}Warning: this machine already has a 'radsec' user with uid $EXISTING_UID.${NC}"
    echo "The container expects uid 10001 and will not be able to read the certificates."
    echo "Either remove that user, or set a matching 'user:' in docker-compose.yml."
fi

chown radsec:radsec "$SCRIPT_DIR/certs"/*.pem
chmod 600 "$SCRIPT_DIR/certs"/*.pem
echo -e "${GREEN}Certificate permissions set — owner radsec, mode 600.${NC}"

echo ""

# RADIUS shared secret
echo "--- RADIUS Shared Secret ---"
echo "This must match the secret configured on your access points."
echo ""
# Required, not optional. Letting this through with the placeholder produces a proxy that
# builds, starts, brings its TLS tunnel up and reports healthy — while rejecting every
# access point, because the shared secret does not match. A warning is not enough for a
# failure that looks like success.
while [ -z "${RADIUS_SECRET:-}" ]; do
    read -rp "Enter RADIUS shared secret: " RADIUS_SECRET
    if [ -z "$RADIUS_SECRET" ]; then
        echo -e "${RED}A shared secret is required — your access points will not authenticate without it.${NC}"
    fi
done

# Match any existing value rather than the literal 'changeme', so re-running this script
# to rotate a secret actually works. Anchored to the client block's indentation to avoid
# touching anything else.
sed -i "s/^\( *\)secret '.*'/\1secret '$RADIUS_SECRET'/" "$SCRIPT_DIR/radsecproxy.conf"
echo -e "${GREEN}Secret updated.${NC}"

echo ""

# Add certs/ to .gitignore
if ! grep -q "^certs/" "$SCRIPT_DIR/.gitignore" 2>/dev/null; then
    echo "certs/" >> "$SCRIPT_DIR/.gitignore"
    echo -e "${GREEN}Added certs/ to .gitignore${NC}"
fi

echo ""

# Build and start
read -rp "Build and start the container now? [Y/n]: " START
START="${START:-Y}"

if [[ "$START" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Building container (this may take a few minutes on first run)..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d --build
    echo ""
    echo -e "${GREEN}Container started.${NC}"
    echo ""
    echo "View logs with:"
    echo "  sudo docker compose logs -f radsecproxy"
else
    echo ""
    echo "Run this when ready:"
    echo "  sudo docker compose up -d --build"
fi

echo ""

# Optional: the longfi-fetch status banner.
#
# Installed from the copy that ships in this repository — no network access needed, so
# this works on an air-gapped or firewalled box. Not fatal if it is missing: the banner
# is a sanity-check convenience, not part of the proxy.
echo "--- Status Banner (optional) ---"
echo "longfi-fetch prints a one-screen summary of tunnel status, certificates and support contacts."
echo ""
read -rp "Install it? [Y/n]: " WANT_FETCH
WANT_FETCH="${WANT_FETCH:-Y}"

if [[ "$WANT_FETCH" =~ ^[Yy]$ ]]; then
    if [ -f "$SCRIPT_DIR/longfi-fetch" ]; then
        install -m 755 "$SCRIPT_DIR/longfi-fetch" /usr/local/bin/longfi-fetch
        echo -e "${GREEN}Installed. Run it any time with: sudo longfi-fetch${NC}"
    else
        echo -e "${YELLOW}longfi-fetch not found alongside this script — skipping.${NC}"
    fi
fi

echo ""
echo "================================================"
echo -e "  ${GREEN}Setup complete.${NC}"
echo "================================================"
echo ""
