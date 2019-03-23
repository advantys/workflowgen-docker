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
$minorVersion = $ToVersion.Substring(0, $ToVersion.LastIndexOf("."))
$majorVersion = $minorVersion.Substring(0, $minorVersion.LastIndexOf("."))
$minorVersionRegex = $minorVersion -replace "\.", "\."
$matrix = @{
    WFGEN_VERSION_FOLDER = $minorVersion
    WFGEN_VERSION = $ToVersion
}
$repoHasVersion = (Get-ChildItem $PSScriptRoot -Directory `
    | Where-Object Name -eq $minorVersion `
    | Measure-Object `
    | ForEach-Object Count) -as [bool]

if ($repoHasVersion) {
    Join-Path $PSScriptRoot $minorVersion `
        | Get-ChildItem -Recurse -File `
        | Where-Object Name -eq "Dockerfile" `
        | ForEach-Object {
            $content = Get-Content $_.FullName -Encoding UTF8

            if ($_.FullName -like "*\onbuild\*") {
                $content = $content -replace "(?<=advantys/workflowgen:)$minorVersionRegex\.[0-9]+(?=-win-[ltsc2016|ltsc2019])", $ToVersion
            } else {
                $content = $content -replace "$minorVersionRegex\.[0-9]+(?=/manual.zip)", $ToVersion
                $content = $content -replace "(?<=WFGEN_VERSION=)[^\s]+", $ToVersion
            }

            Set-Content -Path $_.FullName -Value $content -Encoding UTF8
        }

    $pipelinesDef = Get-Content $pipelinesDefPath -Raw -Encoding UTF8 | ConvertFrom-Yaml
    $newJobs = $pipelinesDef.jobs | ForEach-Object {
        $currentMatrix = $_.strategy.matrix[$minorVersion]
        $currentMatrix.WFGEN_VERSION = $ToVersion

        if ($currentMatrix.ADDITIONAL_TAGS) {
            $currentMatrix.ADDITIONAL_TAGS = $currentMatrix.ADDITIONAL_TAGS.Split(",") `
                | ForEach-Object { $_.Trim() } `
                | ForEach-Object {
                    if ($_ -match "$minorVersionRegex\.[0-9]+") {
                        return $ToVersion
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

        $_.strategy.matrix[$minorVersion] = $currentMatrix
        return $_
    }

    $pipelinesDef.jobs = $newJobs
    $pipelinesDef | ConvertTo-Yaml -OutFile $pipelinesDefPath -Force
} else {
    if (-not $TemplatesPath) {
        throw [ArgumentException]::new("Parameter TemplatesPath needs to be populated.")
    }

    $onbuildDockerfileTemplatePath = [io.path]::Combine($TemplatesPath, "workflowgen", "Dockerfile.onbuild.template")
    $filesToCopy = @(
        (Join-Path $TemplatesPath "Auth.psm1"),
        (Join-Path $TemplatesPath "Const.psm1"),
        (Join-Path $TemplatesPath "Utils.psm1"),
        (Join-Path $TemplatesPath "healthcheck.ps1"),
        (Join-Path $TemplatesPath "monitor-services.ps1"),
        ([io.path]::Combine($TemplatesPath, "workflowgen", "docker-entrypoint.ps1")),
        ([io.path]::Combine($TemplatesPath, "workflowgen", "Dockerfile.template"))
    )

    "ltsc2016", "ltsc2019" `
        | ForEach-Object {
            $path = [io.path]::Combine($PSScriptRoot, $minorVersion, "windows", "windowsservercore-$_")

            [pscustomobject]@{
                Path = $path
                OnbuildPath = (Join-Path $path "onbuild")
            }
        } `
        | ForEach-Object {
            New-Item $_.OnbuildPath -ItemType Directory -Force | Out-Null
            Copy-Item $filesToCopy $_.Path
            Copy-Item $onbuildDockerfileTemplatePath $_.OnbuildPath
            Join-Path $_.Path "Dockerfile.template" | Rename-Item -NewName "Dockerfile"
            Join-Path $_.OnbuildPath "Dockerfile.onbuild.template" | Rename-Item -NewName "Dockerfile"
        }
    Join-Path $PSScriptRoot $minorVersion `
        | Get-ChildItem -Recurse -File `
        | Where-Object Name -eq "Dockerfile" `
        | ForEach-Object {
            $content = Get-Content $_.FullName -Encoding UTF8
            $content = $content -replace "#{WFGEN_VERSION}#", $ToVersion

            if ($_.FullName -like "*ltsc2016*") {
                $content = $content -replace "#{WINDOWS_SERVER_VERSION}#", "ltsc2016"
            } elseif ($_.FullName -like "*ltsc2019*") {
                $content = $content -replace "#{WINDOWS_SERVER_VERSION}#", "ltsc2019"
            }

            Set-Content -Path $_.FullName -Value $content -Encoding UTF8
        }

    $pipelinesDef = Get-Content $pipelinesDefPath -Raw -Encoding UTF8 | ConvertFrom-Yaml

    $newJobs = $pipelinesDef.jobs | ForEach-Object {
        $newMatrix = @{
            WFGEN_VERSION = $ToVersion
            WFGEN_VERSION_FOLDER = $minorVersion
            WINDOWS_SERVER_VERSION = $(switch ($_.job) {
                "Buildltsc2016" { "ltsc2016" }
                "Buildltsc2019" { "ltsc2019" }
            })
        }
        $newMatrixLatest = $newMatrix + @{
            ADDITIONAL_TAGS = "latest, $majorVersion, $minorVersion, $ToVersion"
        }
        $matrix = $_.strategy.matrix

        $matrix.GetEnumerator() `
            | Where-Object { $matrix[$_.Key].ADDITIONAL_TAGS } `
            | ForEach-Object {
                $matrix[$_.Key].ADDITIONAL_TAGS = $matrix[$_.Key].ADDITIONAL_TAGS.Split(",") `
                    | ForEach-Object { $_.Trim() } `
                    | ForEach-Object {
                        if ($_ -eq "latest" -or $_ -eq $majorVersion -or $_ -eq $minorVersion -or $_ -eq $ToVersion) {
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

        $_.strategy.matrix = $matrix
        $_.strategy.matrix[$minorVersion] = switch ($_.job) {
            "Buildltsc2019" { $newMatrixLatest }
            default { $newMatrix }
        }
        return $_
    }
    $pipelinesDef.jobs = $newJobs
    $pipelinesDef | ConvertTo-Yaml -OutFile $pipelinesDefPath -Force
}
