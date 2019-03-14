#requires -Version 5.1
<#
.SYNOPSIS
    Starts ServiceMonitor.exe based on the WFGEN_START_SERVICE environment
    variable.
.NOTES
    File name: monitor-services.ps1
#>
using namespace System

Import-Module "$PSScriptRoot\Utils.psm1" -Prefix "WFG"
Import-Module "$PSScriptRoot\Const.psm1" -Variable Constants

$ErrorActionPreference = "Stop"

$wfgenStartService = Get-WFGEnvVar "WFGEN_START_SERVICE" -TryFile -DefaultValue "all" -TryAzureAppServices
$formatWinEvent = {
    [OutputType([string])]
    param (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0)]
        [System.Diagnostics.Eventing.Reader.EventRecord]$Event
    )

    process {
        return "{0} ; {1} ; {2} ; {3}" -f @(
            $Event.TimeCreated,
            $Event.RecordId,
            $Event.LevelDisplayName,
            $Event.Message
        )
    }
}
$sleepAndCheckStatus = { param ([Management.Automation.Job]$Job)
    Start-Sleep -Milliseconds 500

    if ($Job.State -ne "Running") {
        # Terminate the container if ServiceMonitor exited
        Receive-Job $Job | Out-Host
        return $false
    }

    return $true
}
$getWinServiceLogs = { param ([string]$Name, [Management.Automation.Job]$ServiceMonitorJob)
    Start-Sleep -Seconds 5 # Wait for service to get started
    Get-WinEvent -ProviderName $Name -MaxEvents 10 `
        | Sort-Object RecordId -OutVariable logs `
        | & $formatWinEvent `
        | Out-Host

    $lastRecordId = $logs[0].RecordId

    while ($true) {
        if (-not (& $sleepAndCheckStatus -Job $ServiceMonitorJob)) {
            break
        }

        $currentRecordId = Get-WinEvent -ProviderName $Name -MaxEvents 1 `
            | ForEach-Object RecordId

        if ($currentRecordId -gt $lastRecordId) {
            $lastRecordId = $currentRecordId
            $recordsDiff = $currentRecordId - $lastRecordId

            Get-WinEvent `
                -ProviderName $Name `
                -MaxEvents $( if ($recordsDiff -gt 0) { $recordsDiff } else { 1 } ) `
                | Sort-Object RecordId `
                | & $formatWinEvent `
                | Out-Host
        }
    }
}

switch -Regex ($wfgenStartService) {
    "$( $global:Constants.SERVICE_ALL )|$( $global:Constants.SERVICE_WEB_APPS )" {
        $getIISLogs = {
            try {
                Invoke-WebRequest "http://localhost/" | Out-Null
            } catch {}

            & netsh.exe http flush logbuffer | Out-Null

            while (-not (Test-Path $Path)) {
                Start-Sleep -Milliseconds 500
            }

            Get-Content -Path $Path -Tail 1 -Wait
        }
        $fetchLogsJob = Start-Job `
            -InitializationScript {$Path = "C:\iislog\W3SVC\u_extend1.log"} `
            -ScriptBlock $getIISLogs
        $serviceMonitorJob = Start-Job -ScriptBlock { & C:\ServiceMonitor.exe "w3svc" }
        $getFileCount = {
            Get-ChildItem C:\iislog\W3SVC -File | Measure-Object | ForEach-Object Count
        }

        # Wait for first web request to return
        New-WFGRetryPolicy -RetryCount 10 -IntervalMilliseconds 10000 -CatchException ([Exception]) -OutVariable RetryPolicy `
            | Invoke-WFGBlock -Block {
                if (-not (Test-Path "C:\iislog\W3SVC\u_extend1.log")) {
                    throw [Exception]::new()
                }
            } -ErrorVariable PolicyBlockError -ErrorAction SilentlyContinue

        # Handle errors without printing the stack trace
        if ($PolicyBlockError.Count -ge $RetryPolicy.Retry) {
            Write-WFGError "LOGS: IIS logs were never written"
            exit 1
        }

        $lastFileCount = & $getFileCount

        while ($true) {
            if (-not (& $sleepAndCheckStatus -Job $serviceMonitorJob)) {
                break
            }

            $currentFileCount = & $getFileCount

            # Get new logs if new log file has been created
            if ($currentFileCount -gt $lastFileCount) {
                $lastFileCount = $currentFileCount
                $currentLogFilePath = Get-ChildItem C:\iislog\W3SVC -File `
                    | Sort-Object -Property CreationTime -Descending `
                    | Select-Object -First 1 `
                    | ForEach-Object FullName

                $fetchLogsJob | Stop-Job | Remove-Job
                # Evaluates immediatly the current log file's full name
                # This is needed because the evaluation is not transfered into the job and the result is then $null
                $initializationBlock = [scriptblock]::Create("`$Path = '$currentLogFilePath'")
                $fetchLogsJob = Start-Job -InitializationScript $initializationBlock -ScriptBlock $getIISLogs
            }

            Receive-Job $fetchLogsJob | Out-Host
        }
    }

    "$( $global:Constants.SERVICE_WIN_SERVICES )|$( $global:Constants.SERVICE_ENGINE )" {
        # Service name is hardcoded because of variable capturing issues with script blocks as jobs
        & $getWinServiceLogs -Name "WorkflowGenEngineService" -ServiceMonitorJob (Start-Job -ScriptBlock {
            & C:\ServiceMonitor.exe "WorkflowGenEngineService"
        })
    }

    "$( $global:Constants.SERVICE_DIR_SYNC )" {
        # Service name is hardcoded because of variable capturing issues with script blocks as jobs
        & $getWinServiceLogs -Name "WorkflowGenDirSyncService" -ServiceMonitorJob (Start-Job -ScriptBlock {
            & C:\ServiceMonitor.exe "WorkflowGenDirSyncService"
        })
    }
}
