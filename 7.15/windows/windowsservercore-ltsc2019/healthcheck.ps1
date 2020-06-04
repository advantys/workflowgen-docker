<#
.SYNOPSIS
    Simple healthcheck for the containerized WorkflowGen application.
.NOTES
    File name: healthcheck.ps1
#>
#requires -Version 5.1
using namespace System

Import-Module "$PSScriptRoot\Utils.psm1" -Function Get-EnvVar
Import-Module "$PSScriptRoot\Const.psm1" -Variable Constants

$wfgenStartService = Get-EnvVar "WFGEN_START_SERVICE" -DefaultValue $global:Constants.SERVICE_ALL -TryFile
$state = [Environment]::GetEnvironmentVariable("WFGEN_CONTAINER_STATE", [EnvironmentVariableTarget]::Machine)

if (-not $state) {
    $state = $global:Constants.CONTAINER_STATE_ONLINE
}

$state = $state.Trim().ToLower()

if (
    $wfgenStartService -eq $global:Constants.SERVICE_ALL -or
    $wfgenStartService -eq $global:Constants.SERVICE_WEB_APPS
) {
    try {
        $res = Invoke-WebRequest "http://localhost/wfgen" -UseBasicParsing

        if (
            $state -eq $global:Constants.CONTAINER_STATE_OFFLINE -and
            $res.StatusCode -eq [Net.HttpStatusCode]::OK
        ) {
            return 0
        }
    } catch {
        if (
            $state -eq $global:Constants.CONTAINER_STATE_ONLINE -and
            $_.Exception.Response.StatusCode -eq ([Net.HttpStatusCode]::Unauthorized)
        ) {
            return 0
        }
    } finally {
        & netsh.exe http flush logbuffer | Out-Null
    }

    return 1
}

# In Win Services modes (engine, dir_sync or win_services) and in offline state the health check always return 0
return 0
