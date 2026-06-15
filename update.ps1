<#
.SYNOPSIS
    Updates this official Docker repository with the correct version.
.DESCRIPTION
    This script's algorithm uses the existence or not of a folder based on the
    version provided in order to create a new version directory or update an
    existing one.
.PARAMETER ToVersion
    The version to which the repository should be updated.
.PARAMETER TemplatesPath
    Path to the template folder. This is concretely the docker folder in
    WorkflowGen's source repository.
#>
#requires -Version 5.1
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ $_ -match "^[0-9]+\.[0-9]+\.[0-9]+$" })]
    [string]$ToVersion,
    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$TemplatesPath
)

Import-Module powershell-yaml

if ($TemplatesPath) {
    $TemplatesPath = Resolve-Path $TemplatesPath
}

$pipelinesDefPath = Join-Path $PSScriptRoot "azure-pipelines.yml"
$buildVersionPath = Join-Path $PSScriptRoot "BUILD_VERSION.txt"
$minorVersion = $ToVersion.Substring(0, $ToVersion.LastIndexOf("."))
$majorVersion = $minorVersion.Substring(0, $minorVersion.LastIndexOf("."))
$windowsServerVersions = @("ltsc2019", "ltsc2022")
$primaryWindowsServerVersion = "ltsc2019"

function New-VersionDockerFiles {
    param (
        [Parameter(Mandatory=$true)]
        [string]$WindowsServerVersion
    )

    if (-not $TemplatesPath) {
        throw [ArgumentException]::new("Parameter TemplatesPath needs to be populated.")
    }

    $onbuildDockerfileTemplatePath = [io.path]::Combine($TemplatesPath, "workflowgen", "Dockerfile.onbuild.template")
    $filesToCopy = @(
        (Join-Path $TemplatesPath "Auth.psm1"),
        (Join-Path $TemplatesPath "Const.psm1"),
        (Join-Path $TemplatesPath "Utils.psm1"),
        ([io.path]::Combine($TemplatesPath, "workflowgen", "set-state.ps1")),
        ([io.path]::Combine($TemplatesPath, "workflowgen", "healthcheck.ps1")),
        ([io.path]::Combine($TemplatesPath, "workflowgen", "monitor-services.ps1")),
        ([io.path]::Combine($TemplatesPath, "workflowgen", "docker-entrypoint.ps1")),
        ([io.path]::Combine($TemplatesPath, "workflowgen", "Dockerfile.template"))
    )

    $path = [io.path]::Combine($PSScriptRoot, $minorVersion, "windows", "windowsservercore-$WindowsServerVersion")
    $onbuildPath = Join-Path $path "onbuild"

    New-Item $onbuildPath -ItemType Directory -Force | Out-Null
    Copy-Item $filesToCopy $path
    Copy-Item $onbuildDockerfileTemplatePath $onbuildPath
    Join-Path $path "Dockerfile.template" | Rename-Item -NewName "Dockerfile"
    Join-Path $onbuildPath "Dockerfile.onbuild.template" | Rename-Item -NewName "Dockerfile"
}

function Update-DockerFiles {
    Join-Path $PSScriptRoot $minorVersion `
        | Get-ChildItem -Recurse -File `
        | Where-Object Name -eq "Dockerfile" `
        | ForEach-Object {
            $content = Get-Content $_.FullName -Raw -Encoding UTF8
            $content = $content -replace "#{WFGEN_VERSION}#", $ToVersion
            $content = $content -replace "$minorVersionRegex\.[0-9]+(?=/manual.zip)", $ToVersion
            $content = $content -replace "(?<=WFGEN_VERSION=)[^\s]+", $ToVersion
            $content = $content -replace "(?<=advantys/workflowgen:)$minorVersionRegex\.[0-9]+(?=-win-ltsc[0-9]+)", $ToVersion

            foreach ($windowsServerVersion in $windowsServerVersions) {
                if ($_.FullName -like "*windowsservercore-$windowsServerVersion*") {
                    $content = $content -replace "#{WINDOWS_SERVER_VERSION}#", $windowsServerVersion
                }
            }

            Set-Content -Path $_.FullName -Value $content -Encoding UTF8
        }
}

function Update-PipelineDefinition {
    $pipelinesDef = Get-Content $pipelinesDefPath -Raw -Encoding UTF8 | ConvertFrom-Yaml -Ordered
    $requiredJobs = $windowsServerVersions | ForEach-Object { "Build$_" }
    $currentJobs = $pipelinesDef.jobs | ForEach-Object { $_.job }

    foreach ($requiredJob in $requiredJobs) {
        if ($requiredJob -notin $currentJobs) {
            throw "Official Docker pipeline is missing the $requiredJob job."
        }
    }

    [array]$newJobs = $pipelinesDef.jobs | ForEach-Object {
        $windowsServerVersion = switch ($_.job) {
            "Buildltsc2019" { "ltsc2019" }
            "Buildltsc2022" { "ltsc2022" }
        }

        if (-not $windowsServerVersion) {
            return $_
        }

        $matrix = $_.strategy.matrix
        $matrix.GetEnumerator() `
            | Where-Object { $matrix[$_.Key].ADDITIONAL_TAGS } `
            | ForEach-Object {
                $matrix[$_.Key].ADDITIONAL_TAGS = $matrix[$_.Key].ADDITIONAL_TAGS.Split(",") `
                    | ForEach-Object { $_.Trim() } `
                    | ForEach-Object {
                        if ($_ -eq "latest" -or $_ -eq $majorVersion -or $_ -eq $minorVersion -or $_ -match "$minorVersionRegex\.[0-9]+") {
                            return
                        }

                        return $_
                    } `
                    | ForEach-Object -Begin { $acc = "" } -Process {
                        if (-not $acc) {
                            $acc = $_
                        } else {
                            $acc = "$acc, $_"
                        }
                    } -End { $acc }
            }

        $newMatrix = @{
            WFGEN_VERSION = $ToVersion
            WFGEN_VERSION_FOLDER = $minorVersion
            WINDOWS_SERVER_VERSION = $windowsServerVersion
        }

        if ($windowsServerVersion -eq $primaryWindowsServerVersion) {
            $newMatrix.ADDITIONAL_TAGS = "latest, $majorVersion, $minorVersion, $ToVersion"
        }

        $_.strategy.matrix = $matrix
        $_.strategy.matrix[$minorVersion] = $newMatrix
        return $_
    }

    $pipelinesDef.jobs = $newJobs
    $pipelinesDef | ConvertTo-Yaml -OutFile $pipelinesDefPath -Force
}

# Write the target minor version so the pipeline can build only this version
Set-Content -Path $buildVersionPath -Value $minorVersion -NoNewline
$minorVersionRegex = $minorVersion -replace "\.", "\."

$windowsServerVersions `
    | ForEach-Object {
        $path = [io.path]::Combine($PSScriptRoot, $minorVersion, "windows", "windowsservercore-$_")

        if (-not (Test-Path $path)) {
            New-VersionDockerFiles -WindowsServerVersion $_
        }
    }

Update-DockerFiles
Update-PipelineDefinition
