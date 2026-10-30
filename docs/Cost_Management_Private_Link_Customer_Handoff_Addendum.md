# Cost Management Private Connectivity: Customer Ownership and Handoff

**Document status:** Design guidance and customer implementation handoff  
**Prepared:** October 23, 2026  
**Applies to:** Azure Commercial deployment of the Azure FinOps MACC vs Retail solution

## Executive decision

The existing Private Link guide and Bicep templates provide a conditional implementation path for testing Azure Resource Manager (ARM) Private Link with the Cost Management query used by this solution. The feature remains disabled by default. It is not a validated customer architecture or a guarantee that every solution communication can use a private endpoint.

The customer must own the remaining architecture, development, deployment, validation, security approval, and operations. The solution author can explain the current application behavior and provide advisory guidance, but should not select or implement the customer's tenant-wide ARM Private Link, DNS, firewall, Bastion, monitoring, Power BI, or operational design.

The customer should not approve the statement "all communications are private except Retail Prices" as written. A more accurate objective is:

> Customer cost and billing payloads, durable data, secrets, telemetry, and application access use approved private paths. Public outbound traffic is deny-by-default and limited to the Azure Retail Prices API and explicitly approved Microsoft identity, certificate-validation, deployment, and platform dependencies. Every exception is documented, logged, and accepted by the customer.

## What the current solution already provides

When the Bicep private-networking option is enabled with a compatible Function plan, the current baseline provides important foundations:

- Function regional VNet integration and route-all application settings.
- A private endpoint for Function inbound access.
- Private endpoints and private DNS for Azure SQL.
- Private endpoints and private DNS for Blob, Queue, and Table storage.
- Optional private endpoint and private DNS for Key Vault.
- Managed identity for Cost Management access and identity-based host-storage access.
- Disabled public access for the Function, SQL, and runtime Storage in the Bicep private-networking path.

When explicitly enabled, the Bicep platform templates create the ARM resource-management private link and root-management-group association, and the workload template creates the ARM private endpoint and DNS configuration. These controls do not enforce deny-by-default outbound access, privatize Azure Monitor, establish a private Power BI refresh path, or resolve the Bastion and ARM private DNS conflict.

The Terraform baseline does not currently provide equivalent private-networking coverage and should not be represented as a production private deployment without customer development.

## Remaining gaps the customer must resolve

| Area | Current gap | Customer-owned decision or development |
|---|---|---|
| Cost Management and Billing | ARM Private Link is available as opt-in Bicep but is not deployed by default or validated for the exact customer operations. | Obtain support confirmation, deploy or reuse the tenant-scoped resource-management private link and association, enable the workload endpoint, and run an authorized proof of concept. |
| Outbound enforcement | The current VNet design uses a NAT Gateway and has no deny-by-default firewall or route-table enforcement. | Route all Function traffic through an approved inspection point such as Azure Firewall and deny public ARM access. |
| Function configuration traffic | Legacy route-all settings do not provide the strongest auditable statement for all current application and configuration traffic. | Use and validate `outboundVnetRouting.allTraffic=true`, including managed-identity, content, deployment, and other configuration traffic. |
| Microsoft Entra and platform dependencies | Managed-identity token acquisition, certificate validation, and some platform functions can require Microsoft public service endpoints. | Determine the minimum required destinations, approve them as explicit exceptions, and enforce and log the allowlist. |
| Azure Monitor | Application Insights is not currently connected through Azure Monitor Private Link. | Create or reuse an Azure Monitor Private Link Scope, add the monitoring resources, use Private Only mode where appropriate, and disable public ingestion/query access after validation. |
| Key Vault | A private endpoint exists in the private Bicep path, but the template leaves Key Vault public network access enabled with trusted-services bypass. | Disable public access when the private path is approved, remove unnecessary bypasses, and validate Key Vault reference resolution through the VNet. |
| Function content storage | Premium Functions can use Azure Files for content, while the current template creates Blob, Queue, and Table private endpoints only. | Confirm the hosting and deployment model. If Azure Files is used, add the File private endpoint, private DNS, content-share routing, and required secure credential handling. |
| Power BI | A private SQL endpoint does not automatically give Power BI Service a private refresh path. | Select and operate an approved VNet data gateway or customer-managed gateway, or keep report refresh within an approved private environment. |
| Bastion and DNS | Linking ARM private DNS to the same VNet can break Azure Bastion. | Approve a dedicated ingestion spoke or another supported DNS topology. Keep Bastion in a network that is not affected by the ARM DNS override. |
| Retail Prices | The current code sends service, meter, region, and unit filters to the public Retail Prices endpoint. | Accept this metadata exposure or build a separate catalog-sync process that writes a non-customer-specific retail catalog to private Storage. |
| Infrastructure parity | Bicep and Terraform do not currently provide equivalent networking features. | Choose one IaC owner and implementation path. Do not combine both tools as owners of the same resources. |
| Operations | No customer-specific monitoring, incident response, certificate/DNS change process, or recovery ownership is defined. | Create runbooks, alerts, periodic access reviews, test schedules, and named operational owners. |

## Recommended customer target architecture

The following design is a recommended starting point, not a deployable customer architecture:

1. Place the ingestion Function in a dedicated workload spoke using a plan that supports regional VNet integration.
2. Place private endpoints in a separate endpoint subnet. Include ARM resource management, SQL, Storage subresources required by the selected Function deployment model, Key Vault, Function inbound access, and Azure Monitor through AMPLS.
3. Scope `privatelink.azure.com` resolution to the ingestion environment. Do not link that zone to the Bastion VNet without an approved supported design.
4. Configure `outboundVnetRouting.allTraffic=true`.
5. Apply a default route from the Function integration subnet to the customer-approved firewall or network virtual appliance.
6. Deny direct internet egress. Allow only the documented public dependencies after customer security review.
7. Do not allow public `management.azure.com` egress. The same hostname must resolve to the approved ARM private endpoint from the Function.
8. Disable public network access on SQL, Storage, Key Vault, monitoring resources, and Function ingress after their private paths are proven.
9. Use managed identity and least-privilege RBAC. Do not grant tenant-root deployment permissions to the runtime identity.
10. Provide a private administrative, deployment, database-migration, and Power BI refresh path.

### Reduce the Retail Prices exception

The most privacy-preserving pattern is to separate customer ingestion from retail-price collection:

1. A customer-approved catalog job calls `https://prices.azure.com` on a schedule.
2. The catalog job uses no customer identifiers, costs, resource groups, or subscription IDs.
3. It writes the required catalog data to a private Storage account.
4. The ingestion Function joins customer cost rows to the private catalog and does not call the public Retail Prices API.

If the customer keeps the direct lookup, require HTTPS, restrict all pagination links to the expected `prices.azure.com` host, do not attach ARM credentials, and document that service, meter, region, and unit filters are visible to the Retail Prices service.

### Application hardening

The customer development team should also:

- Reject any ARM request URI whose scheme is not HTTPS or whose host is not the configured ARM hostname before attaching an access token.
- Reject Retail Prices pagination URLs that do not use HTTPS and the approved Retail Prices hostname.
- Keep access tokens, response bodies, customer costs, billing contacts, and subscription identifiers out of telemetry and shared diagnostics.
- Retain retry and throttling controls without silently falling back to public ARM connectivity.
- Pin supported API versions through the customer's normal compatibility and change-management process.

## Responsibility assignment

| Work item | Accountable owner | Responsible implementer | Advisory input |
|---|---|---|---|
| Security objective and accepted public exceptions | Customer security authority | Customer security and architecture teams | Solution author explains observed application dependencies. |
| Tenant-root ARM Private Link association | Customer platform owner | Customer cloud platform team | Microsoft documentation and support confirmation. |
| VNet, subnets, DNS, firewall, UDRs, and Bastion-safe topology | Customer network owner | Customer network engineering team | Solution author supplies endpoint and protocol requirements. |
| Function, monitoring, Storage, SQL, Key Vault, and Power BI private paths | Customer application owner | Customer development, platform, and BI teams | Existing solution code and this guide are reference inputs. |
| IaC adaptation and deployment pipeline | Customer engineering owner | Customer DevOps team | Solution author may clarify current Bicep and Terraform behavior. |
| RBAC and managed identity | Customer identity owner | Customer IAM team | Solution author supplies required runtime operations. |
| Validation and risk acceptance | Customer security authority | Customer test and security teams | Microsoft support confirms product compatibility where needed. |
| Production operations and incident response | Customer operations owner | Customer operations team | Solution author provides application-level troubleshooting context only. |

The solution author is not the accountable or responsible party for customer tenant governance, production network architecture, deployment, security certification, or ongoing operations.

## Customer implementation work packages

The customer should plan and track at least these work packages:

1. **Architecture and dependency inventory:** Confirm cloud, tenant, subscriptions, regions, DNS, Bastion, deployment, monitoring, Power BI, and all outbound dependencies.
2. **ARM Private Link proof of concept:** Confirm support and test the exact Cost Management query, subscription reads, and optional Billing APIs.
3. **Network and DNS implementation:** Build the dedicated workload topology, private endpoints, zone links, forwarding, UDRs, and firewall policy.
4. **Platform privatization:** Secure Storage, SQL, Key Vault, Function ingress, Application Insights/Log Analytics, deployment, and report-refresh paths.
5. **Application hardening:** Add URI allowlist guards, choose the retail catalog pattern, and prevent sensitive logging.
6. **Infrastructure as code:** Implement the approved design in the customer's chosen IaC and CI/CD system.
7. **Security validation:** Perform positive and negative tests, capture evidence, and complete risk acceptance.
8. **Operational readiness:** Establish monitoring, alerting, access review, backup, recovery, change management, and incident response.

## Required customer acceptance evidence

Before production approval, the customer should produce and retain:

- An approved architecture and data-flow diagram showing every private endpoint and public exception.
- An endpoint inventory with owner, purpose, protocol, authentication method, and data classification.
- DNS evidence captured from the Function execution environment.
- Firewall and routing evidence proving the Cost Management request used the ARM private endpoint.
- A successful authorized query for every intended subscription and enabled Billing operation.
- A negative test proving the same workload cannot reach public ARM when the private path is removed or unavailable.
- Evidence that public access is disabled on each service intended to be private.
- Firewall logs showing only approved public destinations.
- Validation that Bastion, deployment, SQL migration, monitoring, and Power BI refresh paths still work.
- A documented rollback procedure tested in a nonproduction environment.
- Named production owners, support contacts, alert routing, and review cadence.
- Written customer acceptance of unavoidable public Microsoft identity/platform dependencies and the Retail Prices design.

An HTTP 401 or 403, private DNS resolution alone, or the existence of a private endpoint is not sufficient evidence.

## Handoff and exit criteria

The advisory handoff is complete when:

- The customer acknowledges ownership of the remaining design and development.
- The customer selects its production network, DNS, firewall, monitoring, deployment, and Power BI patterns.
- The customer assigns accountable and responsible owners.
- Microsoft support or the appropriate product team confirms the required ARM Private Link compatibility, or the customer records the unresolved blocker.
- The customer accepts that the existing repository is a reference baseline and must be adapted before it represents the approved production design.

No production deployment should proceed solely from this document. The detailed technical guide that follows remains conditional implementation guidance for the customer's engineering teams.

\newpage

# Detailed Technical Reference

The following section reproduces the complete original **Using Private Link for Cost Management API Calls** guide so that the customer has the existing technical information and the ownership guidance in one deliverable.
