# Accessing Private Azure Resources via Bastion (No VPN Required)

## Purpose

This is a general-purpose guide for connecting to **any Azure resource deployed inside a
VNet with public network access disabled** — Azure SQL, Storage, Key Vault, Redis, private
AKS API servers, internal web apps, etc. — from a local machine that has **no VPN**, no
ExpressRoute, and no ability to modify local network settings (e.g., a locked-down corporate
laptop).

For a **step-by-step walkthrough specific to Azure SQL + Power BI Desktop**, see
[`Bastion_SQL_Connectivity_Guide.md`](./Bastion_SQL_Connectivity_Guide.md). This document
covers the underlying pattern so it can be adapted to any other private resource type.

---

## The Core Problem

Many organizations enforce Azure Policy that disables `publicNetworkAccess` on PaaS
resources (SQL, Storage, Key Vault, Cosmos DB, etc.), forcing all access through private
endpoints inside a VNet. This is great for security, but it means:

- You can't reach the resource from your laptop, home network, or office network directly.
- A traditional fix is a **VPN Gateway (P2S) or ExpressRoute** — but this requires
  installing/configuring a VPN client, which many corporate-managed devices won't allow, and
  is often overkill for occasional/ad hoc access needs.

**Azure Bastion** solves this without a VPN: it's a fully managed, browser- or CLI-accessible
jump host that lives inside the VNet and can tunnel a connection from your local machine into
the network, without ever exposing SSH/RDP or PaaS endpoints to the public internet.

---

## Two Ways to Use Bastion

### 1. Azure Portal — browser-based RDP/SSH session

- Go to the VM in the Azure Portal → **Connect** → **Bastion**.
- Authenticate (password, SSH key upload/paste, or in some cases Azure AD).
- You get a full RDP/SSH session **inside your browser tab**. Useful for interactive admin
  work, running CLI commands *from inside the VNet* (e.g., `az keyvault secret set` against a
  private-endpoint-only Key Vault), or as a stepping stone to further internal resources.
- **Limitation**: this only gives you a remote desktop/terminal. It does not, by itself, let
  a *local* application (like Power BI Desktop or SSMS on your own machine) talk to a private
  resource — for that, you need the CLI tunnel approach below.

### 2. Azure CLI — native-client tunneling (recommended for local app connectivity)

Requires **Bastion Standard SKU** with `enableTunneling: true`. This creates a local TCP
listener on your machine that forwards traffic through Bastion into the VNet, to a specific
target VM and port.

```bash
az extension add --name bastion   # one-time setup

az network bastion tunnel \
  --name <bastion-name> \
  --resource-group <resource-group> \
  --target-resource-id <target-vm-resource-id> \
  --resource-port <remote-port> \
  --port <local-port>
```

This lets your local tools connect to `127.0.0.1:<local-port>` and have that traffic
tunneled to `<remote-port>` on the target VM.

**Important SKU/port restriction**: native-client tunneling with `--target-ip-address`
(IP-Connect mode, tunneling directly to an IP rather than a VM resource ID) only supports
ports **22 (SSH)** and **3389 (RDP)** — you cannot use it to tunnel directly to arbitrary
ports like 1433 (SQL), 6379 (Redis), 443 (private web apps), etc. This is a hard platform
restriction, not a configuration issue.

---

## The Double-Hop Pattern (works for any private resource + any port)

Since direct IP-Connect tunneling is restricted to ports 22/3389, the general solution for
reaching **any** private resource on **any** port is to:

1. Deploy one small **jump box VM** inside the VNet (Linux or Windows), with network
   line-of-sight (NSG rules, routing) to whatever private resources you need to reach.
2. Use Bastion to tunnel to the jump box's SSH (Linux) or RDP (Windows) port — this part is
   always allowed since it's port 22/3389.
3. From within that tunnel, use a **second-layer forward** to reach the actual target
   resource/port:
   - **Linux jump box + SSH**: use `ssh -L <local-port>:<target-fqdn-or-ip>:<target-port> ...`
     to forward any port through the jump box.
   - **Windows jump box + RDP**: use RDP's built-in local resource/port forwarding, or run a
     tool like `netsh interface portproxy` on the jump box itself to forward inbound traffic
     to the private target.

```
[Your PC] --Bastion tunnel (port 22 or 3389)--> [Jump Box VM, inside VNet]
                                                        |
                                          (SSH -L / portproxy / socat, etc.)
                                                        v
                                        [Any private resource: SQL, Redis, internal API, ...]
```

This pattern is resource-agnostic — the only things that change per-resource are the target
FQDN/IP and port number in the forwarding command.

### Generic example: forwarding to any private resource on any port

```bash
# Terminal 1 — Bastion tunnel to jump box SSH
az network bastion tunnel \
  --name <bastion-name> \
  --resource-group <resource-group> \
  --target-resource-id /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/virtualMachines/<jumpbox-vm-name> \
  --resource-port 22 \
  --port 2222

# Terminal 2 — SSH local port-forward to the actual private target
ssh -p 2222 -i ~/.ssh/<jumpbox-key> -L <local-port>:<target-private-fqdn-or-ip>:<target-port> azureuser@127.0.0.1 -N
```

Then point your local application at `127.0.0.1:<local-port>`.

**Examples of `<target-private-fqdn-or-ip>:<target-port>`:**
- Azure SQL: `<server>.database.windows.net:1433`
- Azure Cache for Redis: `<cache-name>.redis.cache.windows.net:6380`
- Key Vault (for CLI tools, not portal): `<vault-name>.vault.azure.net:443`
- Private Storage account (Blob): `<account>.blob.core.windows.net:443`
- Internal web app / private endpoint: `<hostname>:443` or `:80`

---

## TLS / Hostname Considerations

Most Azure PaaS services present a TLS certificate for their **real FQDN**
(`*.database.windows.net`, `*.vault.azure.net`, etc.), not for `127.0.0.1`. If your local
client validates the certificate hostname (most do, and should), connecting directly to
`127.0.0.1:<port>` will fail certificate validation, even though the underlying tunnel is secure.

**Two options:**

1. **Recommended — hosts file entry.** Map the real hostname to `127.0.0.1` in your local
   machine's hosts file, then connect using the *real hostname* + local port. This satisfies
   TLS validation and any hostname-dependent auth (e.g., Azure AD token audience checks).

   - Windows: edit `C:\Windows\System32\drivers\etc\hosts` (as Administrator), add:
     ```
     127.0.0.1  <real-fqdn>
     ```
   - Linux/macOS: edit `/etc/hosts` (with `sudo`), add the same line.
   - Connect your client to `<real-fqdn>,<local-port>` (SQL Server client syntax) or
     `<real-fqdn>:<local-port>` (most other clients).

2. **Quick workaround — disable client-side TLS/cert validation.** Many client tools (e.g.,
   Power BI's "Use encrypted connection" checkbox) let you disable their own encryption/cert
   check. This is acceptable **only** because the SSH tunnel itself already encrypts all
   traffic end-to-end — you are not sending data in the clear, just skipping a redundant
   validation layer. Not recommended for tools/protocols where the underlying tunnel itself
   isn't already encrypted.

---

## Authentication Considerations

- If the target resource uses **Azure AD / Entra ID authentication only** (e.g.,
  `azureADOnlyAuthentication: true` on Azure SQL, or Key Vault's RBAC-based access), you
  authenticate with your normal Azure AD identity — there's no separate username/password to
  manage. Combine with the hosts-file trick above so hostname-bound AD token validation
  succeeds.
- If the target resource supports **RBAC (Azure Key Vault, Storage, etc.)**, ensure your
  identity (or the jump box's managed identity, if accessing from automation) has the
  appropriate role assignment (e.g., `Key Vault Secrets User`, `Storage Blob Data Reader`) —
  network access alone is not sufficient; you still need RBAC/IAM permissions.
- Watch for **misleading error messages**: a private-endpoint-only resource accessed from
  outside the VNet (e.g., a browser using a portal feature that reaches out directly, bypassing
  Bastion) often returns an error that looks like a permissions problem (e.g., "You do not have
  access to list secrets") when the real cause is a network-layer block. If RBAC/IAM looks
  correct but access still fails, suspect networking before permissions.

---

## Jump Box VM Setup & Key Management Best Practices

- **Use SSH key auth (Linux) or strong password/Azure AD login (Windows)** — avoid weak
  passwords even though the VM isn't publicly reachable directly.
- **Generate SSH keys locally** (`ssh-keygen -t ed25519 -f ~/.ssh/<name>`) so the private key
  material never has to be transmitted or pasted anywhere. Only the **public** key needs to be
  shared (safe to share/echo anywhere) to authorize it on the VM:
  ```bash
  az vm user update -g <rg> -n <vm-name> --username <user> --ssh-key-value "<public-key-contents>"
  ```
- **Never paste private key content into chat tools, tickets, email, or any other
  non-secure-storage system.** If this happens accidentally, treat the key as compromised and
  rotate it immediately (generate new keypair, authorize the new public key, remove the old
  one from `~/.ssh/authorized_keys` on the VM).
- **Back up private keys in Key Vault** only from a network location that can already reach
  the vault (e.g., from inside the jump box, once you're logged in via Bastion) — never
  attempt this from an external/local machine if the vault itself is private-endpoint-only.
- **Stop/deallocate the jump box VM when not in use** to reduce cost and reduce attack
  surface. Remember you'll need to `az vm start -g <rg> -n <vm-name>` before your next Bastion
  session if it's been deallocated.
- Keep the jump box's role minimal — it should only have network access to the specific
  private resources it needs to reach, not broad access to the entire VNet/subscription.

---

## Quick Reference Checklist (for a new team member starting from scratch)

1. Confirm Bastion is **Standard SKU** with `enableTunneling: true` (and `enableIpConnect:
   true` if you also want direct SSH/RDP-only IP tunneling).
2. Confirm a **jump box VM** exists in the VNet with network access to your target resource.
3. Generate an SSH key pair **locally** (never on a shared/remote system) and get the public
   key authorized on the jump box.
4. Start the jump box VM if it's deallocated.
5. Open a Bastion tunnel to the jump box's SSH port (Terminal 1).
6. Open an SSH local port-forward through that tunnel to your target resource/port (Terminal 2).
7. Add a hosts file entry if your target's TLS cert / Azure AD auth requires the real
   hostname.
8. Point your local application at `127.0.0.1:<local-port>` (or `<real-fqdn>:<local-port>`
   if using the hosts-file trick).
9. Keep both terminals open for the duration of your session.
10. Stop the jump box VM when done, if cost/security policy calls for it.
