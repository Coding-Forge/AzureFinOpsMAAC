# Azure Billing Contact Audit

Generated: 2026-07-16 09:06:03 -04:00

Signed-in Azure CLI user: **brcampb@MngEnvMCAP907283.onmicrosoft.com**

This report is read-only evidence for invoice recipient, legal payer identity, bill-to, sold-to, PO number, customer scope, and billing-role access review.

## Review checklist

- Search this report and the raw JSON files for Amentum, old Amentum domains, and Amentum mailbox aliases.
- Confirm SoldTo values identify the current customer legal entity.
- Confirm BillTo values and invoice contact/email fields identify current customer contacts and mailboxes.
- Confirm PoNumber values align to the current purchasing process.
- Confirm affected subscriptions point to the expected BillingProfileId and InvoiceSectionId.
- Confirm billing-role assignments are limited to current customer, Microsoft, and reseller administrators.
- If a CSP reseller controls the billing record, request Partner Center customer, account, order, MCA acceptance, reseller relationship, and reconciliation exports from the reseller.

## Warnings

| Area | Scope | Message | Detail |
| --- | --- | --- | --- |
|  |  |  |  |

## Billing accounts

| BillingAccountName | DisplayName | AccountType | AgreementType | Status | SoldTo | RegistrationNumber | RawJson |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |

## Billing profiles

| BillingAccountName | BillingProfileName | DisplayName | Status | BillTo | InvoiceEmailOptIn | InvoiceDay | PoNumber | Currency | RawJson |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |  |  |

## Invoice sections

| BillingAccountName | BillingProfileName | InvoiceSectionName | DisplayName | State | Labels | SystemId | RawJson |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |

## Subscription billing properties

| SubscriptionName | SubscriptionId | State | BillingAccountId | BillingProfileId | InvoiceSectionId | ProductId | ProductName | SkuId | RawJson |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ME-MngEnvMCAP907283-brcampb-1 | c3454f9a-72a4-473e-b7ab-4e9b1107fd6d | Enabled | /providers/Microsoft.Billing/billingAccounts/992a88b7-cd5b-53cb-2366-db5e28024d14:9229fd47-2538-4637-95a2-d5b3bdd8f0c2_2019-05-31 | /providers/Microsoft.Billing/billingAccounts/992a88b7-cd5b-53cb-2366-db5e28024d14:9229fd47-2538-4637-95a2-d5b3bdd8f0c2_2019-05-31/billingProfiles/J5TQ-WFJU-BG7-PKDK-SGB | /providers/Microsoft.Billing/billingAccounts/992a88b7-cd5b-53cb-2366-db5e28024d14:9229fd47-2538-4637-95a2-d5b3bdd8f0c2_2019-05-31/billingProfiles/J5TQ-WFJU-BG7-PKDK-SGB/invoiceSections/EJHH-JWQV-PJA-XRBR-SGB | DZH318Z0BPS6 | Microsoft Azure Standard | 0001 | raw-json/subscription.c3454f9a-72a4-473e-b7ab-4e9b1107fd6d.billingProperty.json |

## Billing role assignments

| Scope | BillingAccountName | Parent | PrincipalId | PrincipalName | PrincipalEmail | RoleDefinitionId | RoleAssignmentName |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |

