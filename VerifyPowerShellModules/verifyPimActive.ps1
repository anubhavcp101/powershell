#
function checkActiveRole {
    param (
        [string[]]$subsIDs,
        [string]$role = 'Contributor'
    )
    
    #
    $context = Get-AzContext
    $userId = $context.Account.ExtendedProperties.HomeAccountId.split('.')[0]

    $active = foreach ( $subsID in $subsIDs) {
        #
        $scope = '/subscriptions/$subsID'
        $ctx = Set-AzContext -Subscription $subsID -Scope Process
        $assignments = Get-AzRoleAssignmentScheduleInstance -Scope $scope -DefaultProfile $ctx
        if ( $assignments | Where-Object { ($_.PrincipalId -like $userId) -and ($_.RoleDefinitionDisplayName -like $role) } ) {
            $true
        } else {
            Write-Warning "Not Active Role in $subsID - $((Get-AzSubscription -SubscriptionId $subsID).Name)"
            $false
        }
    }

    if($active -contains $false) { Write-Warning 'All Roles are not active'; return $false }
    return $true
}