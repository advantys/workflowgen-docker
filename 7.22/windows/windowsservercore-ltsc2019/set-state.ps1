<#
.SYNOPSIS
    Set the state of the container for purposes such as backup for example.
.NOTES
    File name: set-state.ps1
#>
#requires -Version 5.1
using namespace System

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet("Online", "Offline")]
    [string]$Name
)

Import-Module "$PSScriptRoot\Const.psm1" -Variable Constants

$offlineFilePath = [io.path]::Combine("C:", "inetpub", "wwwroot", "wfgen", "app_offline.htm")
$templateOfflineFilePath = [io.path]::Combine($Constants.APPLICATION_DATA_PATH, "Templates", "server", "offline.htm")

function Set-Offline {
    $appOfflineContent = if (Test-Path $templateOfflineFilePath) {
        Get-Content $templateOfflineFilePath -Raw -Encoding utf8
    } else {
        @"
<!DOCTYPE html>
<html>
    <head>
        <title>The service is temporary unavailable</title>
    </head>
    <body>
        <h1>Maintenance operations in progress</h1>
        <p>The WorkflowGen service is temporary unavailable due to system maintenance. The service should be available in a few minutes.
We appologize for the inconvenience.</p>
    </body>
</html>
"@
    }

    [Environment]::SetEnvironmentVariable("WFGEN_CONTAINER_STATE", $Constants.CONTAINER_STATE_OFFLINE, [EnvironmentVariableTarget]::Machine)
    Out-File $offlineFilePath -InputObject $appOfflineContent -Encoding utf8
}

function Set-Online {
    Remove-Item $offlineFilePath -Force -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable("WFGEN_CONTAINER_STATE", $Constants.CONTAINER_STATE_ONLINE, [EnvironmentVariableTarget]::Machine)
}

switch ($Name.ToLower()) {
    "online" { Set-Online }
    "offline" { Set-Offline }
}
