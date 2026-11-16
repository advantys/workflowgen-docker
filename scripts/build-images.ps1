<#
.SYNOPSIS
    Builds docker images and pushes them.
#>
#requires -Version 5.1
using namespace System.Collections

function Test-Error {
    <#
    .SYNOPSIS
        Test if the $LASTEXITCODE is 0. Dispays an error message if not.
    .DESCRIPTION
        By default, this method will write to the error output with Write-Error.
    .PARAMETER ErrorMessage
        The message to write to the error output.
    .PARAMETER Throw
        Instead of writing to the error output, throws the error message.
    .PARAMETER Exit
        Exits with the last error code if it is not 0.
    #>
    [CmdletBinding(DefaultParameterSetName="Default")]
    param (
        [string]$ErrorMessage = "",
        [Parameter(Mandatory=$true, ParameterSetName="Throw")]
        [switch]$Throw,
        [Parameter(Mandatory=$true, ParameterSetName="Exit")]
        [switch]$Exit,
        [int[]]$AdditionalSuccessCodes = @()
    )
    $successCodes = @(0) + $AdditionalSuccessCodes

    if ($LASTEXITCODE -notin $successCodes) {
        $code = $LASTEXITCODE

        if ($Throw) {
            throw $ErrorMessage
        } elseif ($Exit) {
            Script:Write-Error $ErrorMessage
            exit $code
        } else {
            Microsoft.Powershell.Utility\Write-Error $ErrorMessage
        }
    }
}

# An absent policy is a historical stable entry. A version-only entry must
# reject contradictory aliases before any Docker command can run.
$floatingTagPolicy = [string]$env:WFGEN_PROMOTE_FLOATING_TAGS
if ($floatingTagPolicy -and $floatingTagPolicy -notin @('true', 'false')) {
    throw 'WFGEN_PROMOTE_FLOATING_TAGS must be true or false.'
}
$promoteAliases = $floatingTagPolicy -ne 'false'
if (-not $promoteAliases) {
    if ($env:WFGEN_VERSION -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        $env:WFGEN_VERSION_FOLDER -cne ([version]$env:WFGEN_VERSION).ToString(2) -or
        $env:WINDOWS_SERVER_VERSION -cnotmatch '^ltsc(2019|2022)$') {
        throw 'Version-only publishing requires a complete numeric version and matching Windows build context.'
    }
    if (([string]$env:WFGEN_VERSION -match '^\s*0*10\.0*5(?:[^0-9]|$)') -or
        ([string]$env:WFGEN_VERSION_FOLDER -match '^\s*0*10\.0*5(?:[^0-9]|$)')) {
        throw 'Version-only publishing is not supported by the existing V10.5 managed builder.'
    }
    foreach ($additionalTag in @($env:ADDITIONAL_TAGS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($additionalTag -cne $env:WFGEN_VERSION -or $env:WINDOWS_SERVER_VERSION -cne 'ltsc2019') {
            throw 'Version-only publishing permits only the exact WorkflowGen version as an additional tag.'
        }
    }
}

$buildPath = [io.path]::Combine(
    $env:BUILD_REPOSITORY_LOCALPATH,
    $env:WFGEN_VERSION_FOLDER,
    "windows",
    "windowsservercore-$env:WINDOWS_SERVER_VERSION"
)
# BEGIN WFGEN V10.5 managed builder
if (([string]$env:WFGEN_VERSION -match '^\s*0*10\.0*5(?:[^0-9]|$)') -or
    ([string]$env:WFGEN_VERSION_FOLDER -match '^\s*0*10\.0*5(?:[^0-9]|$)')) {
    # Either field can select this line; a mismatch must never fall through to
    # the legacy publisher. Noncanonical related values are rejected too.
    if ($env:WFGEN_VERSION -cnotmatch '^10\.5\.[0-9]+$' -or
        $env:WFGEN_VERSION_FOLDER -cne '10.5' -or
        $env:WINDOWS_SERVER_VERSION -cnotmatch '^ltsc(2019|2022)$') {
        throw 'V10.5 production version, folder and Windows platform must match the managed builder.'
    }
    $managedBuilderPath = Join-Path $buildPath 'build-official-images.ps1'
    if (-not (Test-Path -LiteralPath $managedBuilderPath -PathType Leaf)) {
        throw 'V10.5 requires its managed production image builder.'
    }
    try { & $managedBuilderPath -BuildPath $buildPath } catch { throw }
    return
}
# END WFGEN V10.5 managed builder
$onbuildPath = Join-Path $buildPath "onbuild"
$imageName = "advantys/workflowgen"
$tag = "$env:WFGEN_VERSION-win-$env:WINDOWS_SERVER_VERSION"
$completeTag = "$imageName`:$tag"
$onbuildTag = "$completeTag-onbuild"
$minorVersion = $env:WFGEN_VERSION.Substring(0, $env:WFGEN_VERSION.LastIndexOf("."))
$minorVersionTag = "$imageName`:$minorVersion-win-$env:WINDOWS_SERVER_VERSION"
$minorVersionOnbuildTag = "$imageName`:$minorVersion-win-$env:WINDOWS_SERVER_VERSION-onbuild"
$tags = [ArrayList]::new()
$dockerIsolation = if ($env:DOCKER_ISOLATION) {
    $env:DOCKER_ISOLATION
} else {
    "hyperv"
}

if ($dockerIsolation -notin @("process", "hyperv")) {
    throw "Unsupported Docker isolation mode: $dockerIsolation"
}

$tags.AddRange(@(
    $completeTag,
    $onbuildTag
))
if ($promoteAliases) {
    $tags.AddRange(@($minorVersionTag, $minorVersionOnbuildTag))
}
docker build --isolation=$dockerIsolation -t $completeTag $buildPath
Test-Error -ErrorMessage "Failed to build WorkflowGen image."
docker build --isolation=$dockerIsolation -t $onbuildTag $onbuildPath
Test-Error -ErrorMessage "Failed to build WorkflowGen onbuild image."
if ($promoteAliases) {
    docker tag $completeTag $minorVersionTag
    docker tag $onbuildTag $minorVersionOnbuildTag
}

if ($env:ADDITIONAL_TAGS) {
    $env:ADDITIONAL_TAGS -split "," `
        | ForEach-Object { $_.Trim() } -OutVariable additionalTags `
        | Where-Object { $_ -ne "latest" } `
        | ForEach-Object { "$imageName`:$_" } `
        | ForEach-Object {
            $onbuild = "$_-onbuild"

            $tags.AddRange(@($_, $onbuild))
            docker tag $completeTag $_
            docker tag $onbuildTag $onbuild
        }

    if ("latest" -in $additionalTags) {
        $latestTag = "$imageName`:latest"

        $tags.Add($latestTag)
        docker tag $completeTag $latestTag
    }
}

$tags | ForEach-Object {
    docker push $_
    Test-Error -ErrorMessage "Could not push image: $_"
}
