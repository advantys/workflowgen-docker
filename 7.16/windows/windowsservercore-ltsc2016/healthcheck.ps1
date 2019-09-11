<#
.SYNOPSIS
    Simple healthcheck for the containerized WorkflowGen application.
.NOTES
    File name: healthcheck.ps1
#>
#requires -Version 5.1
Import-Module "$PSScriptRoot\Utils.psm1" -Function Get-EnvVar
Import-Module "$PSScriptRoot\Const.psm1" -Variable Constants

$wfgenStartService = Get-EnvVar "WFGEN_START_SERVICE" -DefaultValue $global:Constants.SERVICE_ALL -TryFile

if ($wfgenStartService -eq $global:Constants.SERVICE_ALL -or $wfgenStartService -eq $global:Constants.SERVICE_WEB_APPS) {
    try {
        Invoke-WebRequest "http://localhost/wfgen" -UseBasicParsing | Out-Null
    } catch {
        if ($_.Exception.Response.StatusCode -eq ([Net.HttpStatusCode]::Unauthorized)) {
            return 0
        }
    } finally {
        & netsh.exe http flush logbuffer | Out-Null
    }

    return 1
}

# In Win Services modes (engine, dir_sync or win_services) the health check always return 0
return 0
