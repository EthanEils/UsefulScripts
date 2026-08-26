$resourceGroupName = ""

$roleAssignments = @(
    @{
        RoleDefinitionName = "Contributor"
        PrincipalType      = "ManagedIdentity"
        PrincipalName      = "<Your-Managed-Identity-Name>"
        Scope              = "<Your-Scope>"
    }
)

foreach ($assignment in $roleAssignments) {
    $roleDefinitionName = $assignment.RoleDefinitionName
    $principalType = $assignment.PrincipalType
    $principalName = $assignment.PrincipalName
    $scope = $assignment.Scope

    # Retrieve the principal ID based on the principal type and name
    if ($principalType -eq "ManagedIdentity") {
        $principal = Get-AzUserAssignedIdentity -ResourceGroupName $resourceGroupName -Name $principalName
        $principalId = $principal.PrincipalId
    }
    else {
        Write-Error "Unsupported PrincipalType: $principalType"
        continue
    }

    # Check to see if the role assignment already exists
    $existingAssignment = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $roleDefinitionName -Scope $scope -ErrorAction SilentlyContinue
    if ($existingAssignment) {
        Write-Host "Role assignment for '$roleDefinitionName' already exists for principal '$principalName' at scope '$scope'. Skipping..."
        continue
    }

    # Assign the role
    New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $roleDefinitionName -Scope $scope
}