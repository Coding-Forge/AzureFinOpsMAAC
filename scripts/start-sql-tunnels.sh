#!/usr/bin/env bash
# Starts the double-hop tunnel to Azure SQL:
#   1) az network bastion tunnel -> jump box SSH (localhost:$BASTION_LOCAL_PORT)
#   2) ssh -L forward through that tunnel -> SQL private endpoint (localhost:$SQL_LOCAL_PORT)
# Usage: RG=<rg> BASTION=<bastion> VM=<jumpbox-vm> SQL_SERVER=<server> KEY=~/.ssh/<key> ./start-sql-tunnels.sh
# Ctrl+C stops both tunnels.
set -euo pipefail

: "${RG:?set RG}" "${BASTION:?set BASTION}" "${VM:?set VM}" "${SQL_SERVER:?set SQL_SERVER}" "${KEY:?set KEY}"
BASTION_LOCAL_PORT="${BASTION_LOCAL_PORT:-2222}"
SQL_LOCAL_PORT="${SQL_LOCAL_PORT:-14330}"
ADMIN_USER="${ADMIN_USER:-azureuser}"

VM_ID=$(az vm show -g "$RG" -n "$VM" --query id -o tsv)

# Ensure the jump box is running
state=$(az vm get-instance-view -g "$RG" -n "$VM" --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv)
if [[ "$state" != "PowerState/running" ]]; then
  echo "Starting jump box ($state)..."
  az vm start -g "$RG" -n "$VM"
fi

echo "Tunnel 1: Bastion -> $VM:22 on localhost:$BASTION_LOCAL_PORT"
az network bastion tunnel --name "$BASTION" --resource-group "$RG" \
  --target-resource-id "$VM_ID" --resource-port 22 --port "$BASTION_LOCAL_PORT" &
BASTION_PID=$!
trap 'kill $BASTION_PID 2>/dev/null || true' EXIT INT TERM

for _ in $(seq 1 30); do
  (exec 3<>"/dev/tcp/127.0.0.1/$BASTION_LOCAL_PORT") 2>/dev/null && break
  sleep 1
done

echo "Tunnel 2: localhost:$SQL_LOCAL_PORT -> $SQL_SERVER.database.windows.net:1433"
ssh -p "$BASTION_LOCAL_PORT" -i "$KEY" -o StrictHostKeyChecking=accept-new \
  -L "$SQL_LOCAL_PORT:$SQL_SERVER.database.windows.net:1433" \
  "$ADMIN_USER@127.0.0.1" -N
