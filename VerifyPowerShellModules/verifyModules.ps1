#
function verifyModules {
    param (
        [string[]]$modules 
    )
    
    foreach ($module in $modules) {
        #
        if ( -not (Get-Module -ListAvailable -Name $module) ) {
            Write-Output "The module $module not found so installing"
            Install-Module $module -Scope CurrentUser -Force -AllowClobber
        } else {
            #
            Write-Output "The module $module exists"
        }
    }
}
verifyModules -modules @('Az.Accounts','Az.Compute')