if ($env:FINOPS_AUTH_MODE -eq 'ManagedIdentity') {
    if ($env:FINOPS_MANAGED_IDENTITY_CLIENT_ID) {
        Connect-AzAccount -Identity -AccountId $env:FINOPS_MANAGED_IDENTITY_CLIENT_ID | Out-Null
    }
    else {
        Connect-AzAccount -Identity | Out-Null
    }
}
