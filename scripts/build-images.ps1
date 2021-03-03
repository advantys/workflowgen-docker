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

$buildPath = [io.path]::Combine(
    $env:BUILD_REPOSITORY_LOCALPATH,
    $env:WFGEN_VERSION_FOLDER,
    "windows",
    "windowsservercore-$env:WINDOWS_SERVER_VERSION"
)
$onbuildPath = Join-Path $buildPath "onbuild"
$imageName = "advantys/workflowgen"
$tag = "$env:WFGEN_VERSION-win-$env:WINDOWS_SERVER_VERSION"
$completeTag = "$imageName`:$tag"
$onbuildTag = "$completeTag-onbuild"
$minorVersion = $env:WFGEN_VERSION.Substring(0, $env:WFGEN_VERSION.LastIndexOf("."))
$minorVersionTag = "$imageName`:$minorVersion-win-$env:WINDOWS_SERVER_VERSION"
$minorVersionOnbuildTag = "$imageName`:$minorVersion-win-$env:WINDOWS_SERVER_VERSION-onbuild"
$tags = [ArrayList]::new()

$tags.AddRange(@(
    $completeTag,
    $onbuildTag,
    $minorVersionTag,
    $minorVersionOnbuildTag
))
docker build -t $completeTag $buildPath
Test-Error -ErrorMessage "Failed to build WorkflowGen image."
docker build -t $onbuildTag $onbuildPath
Test-Error -ErrorMessage "Failed to build WorkflowGen onbuild image."
docker tag $completeTag $minorVersionTag
docker tag $onbuildTag $minorVersionOnbuildTag

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
