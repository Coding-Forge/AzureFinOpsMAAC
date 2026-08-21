# Connecting Power BI Desktop to a Private Azure SQL Database via Bastion (No VPN)

## Purpose

This guide documents how to connect a client tool (Power BI Desktop, SSMS, Azure Data
Studio, etc.) running on a machine with **no VPN and no direct network path** into a VNet,
to an **Azure SQL Database that only accepts private connections** (public network access
disabled, private endpoint only).

This pattern is required whenever:
- Azure Policy or organizational standards force `publicNetworkAccess: Disabled` on SQL
  (common in locked-down/regulated tenants).
- You don't have (or can't get) a VPN gateway / ExpressRoute / P2S VPN connection to the VNet.
- You're on a managed corporate machine where you cannot change network settings, install a
  VPN client, or add routes.

The solution uses **Azure Bastion** (Standard SKU) as a browser/CLI-based jump point, combined
with a **jump box VM** inside the VNet, to build a "double-hop" tunnel from your local machine
all the way to the private SQL endpoint — no VPN required.

---

## Why a Direct Bastion Tunnel to SQL Doesn't Work

Azure Bastion's native-client tunneling (`az network bastion tunnel`) has two SKU-dependent
capabilities:

| Bastion SKU | Native-client tunneling | IP-Connect (`--target-ip-address`) |
|---|---|---|
| Basic | Not supported | Not supported |
| Standard | Supported | Supported, but **only to ports 22 and 3389** |

This means you **cannot** tunnel Bastion directly to SQL's port 1433 using `--target-ip-address`,
even on Standard SKU — Azure blocks it with an error like:
> Custom ports are not allowed. Allowed ports for Tunnel with IP connect is 22, 3389

**Workaround: double-hop tunneling.** Tunnel Bastion to the jump box's SSH port (22, which
*is* allowed), then use an SSH local port-forward (`-L`) from within that tunnel to reach SQL's
1433 port through the jump box's own network access (the jump box lives inside the VNet, so it
can reach the SQL private endpoint directly).

```
[Your PC] --Bastion tunnel (port 22)--> [Jump Box VM] --SSH -L forward--> [SQL Private Endpoint:1433]
```

---

## Prerequisites

1. **Azure Bastion**, Standard SKU, with:
   - `enableTunneling: true`
   - `enableIpConnect: true` (not strictly required for this pattern, but useful for RDP/SSH direct-to-VM scenarios)
2. **A jump box VM** deployed inside the same VNet/subnet that has network line-of-sight to
   the target resource (e.g., NSG rules or subnet routing that allow the jump box to reach
   the SQL private endpoint on 1433).
3. **SSH key pair** for jump box login (see key-management notes below).
4. Azure CLI (`az`) installed locally, logged in (`az login`), with the `bastion` extension:
   ```bash
   az extension add --name bastion
   ```
5. Power BI Desktop (or any SQL client) installed locally.

### Example Bicep snippet (Bastion)

```bicep
resource bastionHost 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: bastionHostName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    enableIpConnect: true
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionPublicIpId
          }
        }
      }
    ]
  }
}
```

---

## Step-by-Step: Connecting Power BI Desktop to Azure SQL

### Step 1 — Open a Bastion tunnel to the jump box's SSH port

In a terminal on your local machine (WSL2, PowerShell, macOS/Linux terminal — anywhere `az`
is installed):

```bash
az network bastion tunnel \
  --name <bastion-name> \
  --resource-group <resource-group> \
  --target-resource-id /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/virtualMachines/<jumpbox-vm-name> \
  --resource-port 22 \
  --port 2222
```

- `--port 2222` is the **local** port on your machine that will forward to the jump box's SSH port through Bastion.
- Leave this terminal running — it holds the tunnel open. Closing it drops the connection.

### Step 2 — Open a second terminal: SSH local port-forward through the tunnel to SQL

```bash
ssh -p 2222 -i ~/.ssh/<your-private-key> -L 14330:<sql-server-name>.database.windows.net:1433 azureuser@127.0.0.1 -N
```

- `-L 14330:<sql-fqdn>:1433` forwards local port `14330` → through the jump box → to SQL's
  private endpoint on port 1433.
- `-N` means "don't execute a remote command, just hold the tunnel open."
- Leave this terminal running too.

At this point you have a working path: `127.0.0.1:14330` (on your machine) → jump box → SQL.

### Step 3 — Fix TLS hostname validation (hosts file trick)

Azure SQL's TLS certificate is issued for the real hostname (e.g.,
`codingforgeazfinops.database.windows.net`), not for `127.0.0.1`. If you connect to
`127.0.0.1` directly, certificate validation fails, and if you're using Azure AD
authentication, Azure AD's token validation also expects the real hostname.

**Fix**: add a hosts file entry that maps the real hostname to your local loopback address.
This lets you connect to the *real hostname* (satisfying TLS/Azure AD) while the connection
actually resolves to your tunnel on `127.0.0.1`.

On Windows, edit `C:\Windows\System32\drivers\etc\hosts` **as Administrator**:

1. Open Notepad "Run as administrator."
2. File → Open → navigate to `C:\Windows\System32\drivers\etc\`.
3. Change the file type filter to "All Files" (the `hosts` file has no extension).
4. Open `hosts` and add:
   ```
   127.0.0.1  <sql-server-name>.database.windows.net
   ```
5. Save.

Verify with:
```
ping <sql-server-name>.database.windows.net
```
It should resolve to `127.0.0.1` (the ping itself may time out — that's fine, we only care
about the resolved IP address shown).

> **Alternative (faster, less secure)**: skip the hosts file and connect directly to
> `127.0.0.1,14330`, but uncheck "Use encrypted connection" in Power BI's connection dialog.
> This works because the SSH tunnel itself is already encrypted end-to-end — you're just
> disabling Power BI's *additional* TLS layer, which would otherwise fail on the hostname
> mismatch. The hosts-file approach is recommended when Azure AD authentication is required,
> since Azure AD token validation depends on the real hostname.

### Step 4 — Connect in Power BI Desktop

1. **Get Data → SQL Server database**
2. **Server**: `<sql-server-name>.database.windows.net,14330` (using the hosts-file approach)
   — or `127.0.0.1,14330` if using the unencrypted workaround
3. **Database**: your database name
4. **Connectivity mode**: Import or DirectQuery (Import recommended for most FinOps/reporting scenarios)
5. **Authentication kind**: "Organizational account" (Azure AD) if the SQL server uses
   `azureADOnlyAuthentication: true` (no SQL logins exist) — sign in with your normal
   Azure AD/Entra credentials
6. Click **Next**, select your tables/views, and load.

Both terminal tunnels (Step 1 and Step 2) **must remain open** for the entire session,
including for any future data refreshes.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `IpConnect` feature not enabled | Bastion SKU is Basic, or IP-Connect not enabled | Upgrade to Standard SKU; `az network bastion update --enable-ip-connect true` |
| "Custom ports are not allowed" | Tried `--target-ip-address` tunnel directly to SQL (1433) | Use the double-hop pattern via the jump box's SSH port instead |
| "Unable to connect using an encrypted connection" in Power BI | TLS cert hostname mismatch (`127.0.0.1` vs. real FQDN) | Use the hosts-file trick (Step 3), or uncheck "Use encrypted connection" |
| Azure AD sign-in fails/loops when connecting via `127.0.0.1` | Azure AD token audience/hostname validation fails against loopback address | Use the hosts-file trick so you connect via the real hostname |
| Jump box SSH connection refused | VM deallocated | `az vm start -g <rg> -n <jumpbox-vm-name>` before connecting |
| "Forbidden"/"ForbiddenByConnection" when using CLI/tools directly against SQL from your own machine | SQL has no public network access — this is expected; only the tunnel path works | Use the tunnel; do not attempt direct connections from outside the VNet |

---

## Security Notes

- **Never paste private key material into chat tools, tickets, or any text-based system.**
  Generate SSH keys locally (`ssh-keygen`) so the private key never leaves the machine that
  generated it; only the **public** key needs to be shared (e.g., via `az vm user update`) to
  authorize a new key on the jump box VM.
- If a private key is ever accidentally pasted/echoed anywhere it shouldn't be (chat, logs,
  tickets), treat it as compromised and rotate it immediately:
  1. Generate a new keypair locally.
  2. Add the new public key to the VM: `az vm user update -g <rg> -n <vm> --username <user> --ssh-key-value "<new-public-key>"`.
  3. Remove the old public key from `~/.ssh/authorized_keys` on the VM.
- Store a backup of the jump box's private key in Key Vault **only from a session that is
  already inside the VNet** (e.g., from the jump box itself once logged in via Bastion) —
  never attempt this from your local machine if Key Vault is private-endpoint-only, as it
  will fail with a network-layer `Forbidden` error (not a permissions error).
- The jump box VM should be stopped/deallocated when not in use to reduce cost and attack
  surface; remember to `az vm start` it before starting a new tunnel session.
