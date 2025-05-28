#!/bin/bash
set -e

echo "🔍 [0/8] Checking for Docker and Docker Compose..."

# Periksa apakah Docker terinstal
if ! command -v docker >/dev/null 2>&1; then
  echo "🐳 Docker not found. Installing prerequisites..."
  curl -fsSL https://raw.githubusercontent.com/catnodes/Sepolia-RPC-Setup/main/install-prerequisites.sh | bash
fi

# Periksa apakah Docker Compose terinstal
if ! docker compose version >/dev/null 2>&1; then
  echo "🐳 Docker Compose plugin not found. Installing prerequisites..."
  curl -fsSL https://raw.githubusercontent.com/catnodes/Sepolia-RPC-Setup/main/install-prerequisites.sh | bash
fi

echo "✅ Docker and Compose are installed. Proceeding with Sepolia node setup..."

# ---- 1. Create Directory Structure ----
echo "🔧 [1/8] Creating directory structure..."
mkdir -p /home/geth/sepolia /home/beacon/sepolia Ethereum
# Pastikan izin direktori sesuai
sudo chown -R $(whoami):$(whoami) /home/geth/sepolia /home/beacon/sepolia
echo "✅ Directory structure ready."

# ---- 2. Generate JWT Secret ----
echo "🔧 [2/8] Generating JWT secret..."
if [ ! -f Ethereum/jwt-sepolia.hex ]; then
  openssl rand -hex 32 | tr -d "\n" > Ethereum/jwt-sepolia.hex
  chmod 644 Ethereum/jwt-sepolia.hex
  echo "✅ JWT secret created."
else
  echo "ℹ️  JWT secret already exists, skipping."
fi

# ---- 3. Create Default Whitelist File ----
echo "🔧 [3/8] Creating whitelist file..."
if [ ! -f Ethereum/whitelist.lst ]; then
  echo "127.0.0.1/32" > Ethereum/whitelist.lst
  chmod 644 Ethereum/whitelist.lst
  echo "✅ Whitelist file created."
else
  echo "ℹ️  Whitelist file already exists, skipping."
fi

# ---- 3.5. Create Reth Configuration File ----
echo "🔧 [3.5/8] Creating Reth configuration file..."
cat > Ethereum/reth.toml <<EOF
[prune]
# Minimum pruning interval measured in blocks
block_interval = 100

[prune.segments]
# Sender Recovery pruning configuration
sender_recovery = { distance = 100_000 }
# Transaction Lookup pruning configuration
transaction_lookup = { before = 1000000 }
# Receipts pruning configuration. This setting overrides \`receipts_log_filter\`.
receipts = { before = 1000000 }
# Account History pruning configuration
account_history = { distance = 10_000 }
# Storage History pruning configuration
storage_history = { distance = 10_000 }
EOF
chmod 644 Ethereum/reth.toml
echo "✅ Reth configuration file written."

# ---- 4. Write Docker Compose File ----
echo "🔧 [4/8] Writing Docker Compose file..."
cat > Ethereum/docker-compose.yml <<EOF
services:
  reth:
    image: ghcr.io/paradigmxyz/reth:latest
    container_name: reth
    restart: unless-stopped
    volumes:
      - /home/geth/sepolia:/home/geth/sepolia
      - ./jwt-sepolia.hex:/home/geth/jwt-sepolia.hex
      - ./reth.toml:/etc/reth/reth.toml
    command:
      - node
      - --chain=sepolia
      - --full
      - --datadir=/home/geth/sepolia
      - --http
      - --ws
      - --authrpc.addr=0.0.0.0
      - --authrpc.port=8551
      - --http.api=eth,net,web3,admin
      - --ws.api=eth,net,web3,admin
      - --authrpc.jwtsecret=/home/geth/jwt-sepolia.hex
      - --config=/etc/reth/reth.toml
    ports:
      - 8545:8545
      - 8546:8546

  prysm:
    image: gcr.io/prysmaticlabs/prysm/beacon-chain:latest
    container_name: prysm
    restart: unless-stopped
    depends_on:
      - reth
    volumes:
      - /home/beacon/sepolia:/home/beacon/sepolia
      - ./jwt-sepolia.hex:/home/beacon/jwt-sepolia.hex
    command:
      - --sepolia
      - --datadir=/home/beacon/sepolia
      - --execution-endpoint=http://reth:8551
      - --jwt-secret=/home/beacon/jwt-sepolia.hex
      - --rpc-host=0.0.0.0
      - --grpc-gateway-host=0.0.0.0
      - --checkpoint-sync-url=https://checkpoint-sync.sepolia.ethpandaops.io
      - --genesis-beacon-api-url=https://checkpoint-sync.sepolia.ethpandaops.io
      - --accept-terms-of-use
    ports:
      - 3500:3500
      - 4000:4000

  haproxy:
    image: haproxy:2.8
    container_name: haproxy
    restart: unless-stopped
    depends_on:
      - reth
      - prysm
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg
      - ./whitelist.lst:/etc/haproxy/whitelist.lst
    ports:
      - 8545:8545
      - 3500:3500
EOF
echo "✅ Docker Compose file written."

# ---- 5. Write HAProxy Config ----
echo "🔧 [5/8] Writing HAProxy config..."
cat > Ethereum/haproxy.cfg <<EOF
global
    maxconn 50000
    nbthread 4
    cpu-map 1-4 0-3

defaults
    timeout connect 5s
    timeout client 50s
    timeout server 50s

frontend reth_frontend
    bind *:8545
    mode tcp
    acl valid_ip src -f /etc/haproxy/whitelist.lst
    tcp-request content reject if !valid_ip
    use_backend reth_backend

frontend prysm_frontend
    bind *:3500
    mode tcp
    acl valid_ip src -f /etc/haproxy/whitelist.lst
    tcp-request content reject if !valid_ip
    use_backend prysm_backend

backend reth_backend
    mode tcp
    balance roundrobin
    server reth1 reth:8545 maxconn 10000 check

backend prysm_backend
    mode tcp
    balance leastconn
    server prysm1 prysm:3500 maxconn 5000 check
EOF
echo "✅ HAProxy config written."

# ---- 6. Start Docker Compose Stack ----
echo "🔧 [6/8] Starting Docker Compose stack..."
cd Ethereum
docker compose up -d
echo "✅ Docker Compose stack started."

# ---- 7. Set Up UFW Firewall (Best Practice) ----
echo "🔧 [7/8] Configuring UFW firewall rules..."
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 22/tcp
  sudo ufw allow 8545/tcp
  sudo ufw allow 3500/tcp
  sudo ufw --force enable
  sudo ufw status verbose
  echo "✅ UFW firewall configured."
else
  echo "⚠️  UFW not installed. Skipping firewall setup."
fi

# ---- 8. Verify Setup and Pruning ----
echo "🔧 [8/8] Verifying setup and pruning..."
echo "🔍 Checking container status..."
docker ps
echo "🔍 Checking Reth pruning status (may take a moment)..."
sleep 5
docker logs reth | grep -i "prun" || echo "ℹ️  No pruning logs yet, check again later with: docker logs reth"
echo "🔍 Checking current block number..."
curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545
echo "🔍 Checking database size..."
du -sh /home/geth/sepolia

echo ""
echo "🎉 All steps complete!"
echo "-----------------------------------------------------------"
echo "   - Reth (Execution): http://<your-server>:8545"
echo "   - Prysm (Consensus): http://<your-server>:3500"
echo ""
echo "👉 To whitelist more IPs: edit Ethereum/whitelist.lst then:"
echo "   docker restart haproxy"
echo ""
echo "💡 For L2/L3 use:"
echo "   --l1-rpc-urls http://<your-server>:8545"
echo "   --l1-consensus-host-urls http://<your-server>:3500"
echo ""
echo "🛡️  Firewall allows SSH/8545/3500 only"
echo "🗄️  Disk: ~50-100GB SSD expected with pruning"
echo ""
echo "🔍 To monitor pruning:"
echo "   docker logs reth | grep -i 'prun'"
echo "   watch -n 60 'du -sh /home/geth/sepolia'"
echo "-----------------------------------------------------------"
