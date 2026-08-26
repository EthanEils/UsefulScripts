# Assign-MgGraphPermissions.ps1
<#
Example:
Assign-MgGraphPermissions.ps1 `
    -AutomationAccountName "my-automation-account" `
    -Tenant "mytenant.onmicrosoft.com" `
    -Subscription "3a3faefd-b59d-4c18-b50f-ef7a8f0d4f16" `
    -GraphPermission "User.Read.All"

.PARAMETER AutomationAccountName
  Name of the Automation Account whose Managed Identity will be assigned Graph API permissions.
.PARAMETER Tenant
  Tenant ID or domain name where the Automation Account resides.
.PARAMETER Subscription
  Subscription ID where the Automation Account resides.
.PARAMETER GraphPermission
  Graph API permission to assign (e.g., User.Read.All, Group.ReadWrite.All).
#>


#Requires -Modules "Az.Accounts", "Az.Resources", "Microsoft.Graph.Applications"
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$AutomationAccountName,
    [Parameter(Mandatory=$true)]
    [string]$Tenant,
    [Parameter(Mandatory=$true)]
    [string]$Subscription,
    [Parameter(Mandatory=$true)]
    [string]$GraphPermission
)

Connect-AzAccount -TenantId $Tenant -Subscription $Subscription  | Out-Null
Connect-MgGraph -TenantId $Tenant -Scopes "AppRoleAssignment.ReadWrite.All", "Application.Read.All" -NoWelcome

Write-Host "AZ context"
Get-AzContext | Format-List
Write-Host "MG context"
Get-MgContext | Format-List

$AutomationMSI = (Get-AzADServicePrincipal -Filter "displayName eq '$AutomationAccountName'")
Write-Host "Assigning permissions to $AutomationAccountName ($($AutomationMSI.Id))"

$GraphServicePrincipal = Get-AzADServicePrincipal -Filter "displayName eq 'Microsoft Graph'"
$GraphAppRoles = $GraphServicePrincipal.AppRole | Where-Object {$_.Value -eq $GraphPermission -and $_.AllowedMemberTypes -contains "Application"}

if($GraphAppRoles.Count -ne 1)
{
    Write-Warning "App roles found: $($GraphAppRoles)"
    throw "Some App Roles are not found on Graph API service principal"
}

Write-Host "Assigning $($GraphAppRoles.Value) to $($AutomationMSI.DisplayName)"
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $AutomationMSI.Id -PrincipalId $AutomationMSI.Id -ResourceId $GraphServicePrincipal.Id -AppRoleId $GraphAppRoles.Id | Out-Null


