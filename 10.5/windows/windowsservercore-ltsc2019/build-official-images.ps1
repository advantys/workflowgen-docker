#requires -Version 5.1
<#
.SYNOPSIS
Builds and verifies the managed V10.5 production images before publishing tags.
.DESCRIPTION
Exported beside the V10.5 Dockerfile. Other release lines retain their existing
shared builder. Docker failures are terminating; certificate probes are offline.
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BuildPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:WFGEN_VERSION -cnotmatch '^10\.5\.[0-9]+$' -or $env:WFGEN_VERSION_FOLDER -cne '10.5' -or
    $env:WINDOWS_SERVER_VERSION -cnotmatch '^ltsc(2019|2022)$') {
    throw 'The managed production builder supports only V10.5 and its declared Windows platforms.'
}
$expectedPath = [IO.Path]::GetFullPath([IO.Path]::Combine(
    $env:BUILD_REPOSITORY_LOCALPATH, '10.5', 'windows', "windowsservercore-$env:WINDOWS_SERVER_VERSION"))
if ([IO.Path]::GetFullPath($BuildPath) -ine $expectedPath) { throw 'Unexpected production image context.' }
$onbuildPath = Join-Path $BuildPath 'onbuild'
$completeTag = "advantys/workflowgen:$env:WFGEN_VERSION-win-$env:WINDOWS_SERVER_VERSION"
$onbuildTag = "$completeTag-onbuild"
$expectedParent = "FROM $completeTag"
$onbuildDockerfile = [IO.File]::ReadAllText((Join-Path $onbuildPath 'Dockerfile'))
if ($onbuildDockerfile -notmatch ('(?m)^' + [regex]::Escape($expectedParent) + '\s*$')) {
    throw 'ONBUILD must inherit the exact WorkflowGen version/platform built in this job.'
}
$dockerIsolation = if ($env:DOCKER_ISOLATION) { $env:DOCKER_ISOLATION } else { 'hyperv' }
if ($dockerIsolation -notin @('process','hyperv')) { throw "Unsupported Docker isolation mode: $dockerIsolation" }
# Each invocation, including a retry of the same Azure build, must recheck live
# Microsoft signing/freshness data rather than reuse an earlier successful layer.
$runGuid = [guid]::NewGuid().ToString('N')
$certificateRefresh = if ([string]::IsNullOrWhiteSpace($env:BUILD_BUILDID)) { $runGuid } else { "$env:BUILD_BUILDID-$runGuid" }
function Invoke-DockerChecked {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    & docker @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Docker $($Arguments[0]) failed with exit code $LASTEXITCODE." }
}
Invoke-DockerChecked @('build','--pull',"--isolation=$dockerIsolation",'--build-arg',"CERTIFICATE_REFRESH=$certificateRefresh",'-t',$completeTag,$BuildPath)
# No --pull here: the exact local parent has just been built and checked by its
# Dockerfile; pulling its published tag could replace it with an older image.
Invoke-DockerChecked @('build',"--isolation=$dockerIsolation",'-t',$onbuildTag,$onbuildPath)
foreach ($image in @($completeTag,$onbuildTag)) {
    Invoke-DockerChecked @('run','--rm','--network','none','--entrypoint','powershell',$image,'-NoProfile','-File','C:\update-windows-certificates.ps1','-VerifyOnly')
}

# Keep the original version/platform, minor, additional and latest alias rules.
# No alias operation or push is reached until both certificate probes pass.
$minorTag = "advantys/workflowgen:10.5-win-$env:WINDOWS_SERVER_VERSION"
$minorOnbuildTag = "$minorTag-onbuild"
$tags = New-Object 'System.Collections.Generic.List[string]'
$tags.AddRange([string[]]@($completeTag,$onbuildTag,$minorTag,$minorOnbuildTag))
Invoke-DockerChecked @('tag',$completeTag,$minorTag)
Invoke-DockerChecked @('tag',$onbuildTag,$minorOnbuildTag)
if ($env:ADDITIONAL_TAGS) {
    $additionalTags = @($env:ADDITIONAL_TAGS -split ',' | ForEach-Object { $_.Trim() })
    foreach ($additionalTag in @($additionalTags | Where-Object { $_ -ne 'latest' })) {
        if ($additionalTag -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') { throw 'Invalid additional Docker tag.' }
        $alias = "advantys/workflowgen:$additionalTag"
        $onbuildAlias = "$alias-onbuild"
        $tags.AddRange([string[]]@($alias,$onbuildAlias))
        Invoke-DockerChecked @('tag',$completeTag,$alias)
        Invoke-DockerChecked @('tag',$onbuildTag,$onbuildAlias)
    }
    if ('latest' -in $additionalTags) {
        $tags.Add('advantys/workflowgen:latest')
        Invoke-DockerChecked @('tag',$completeTag,'advantys/workflowgen:latest')
    }
}
foreach ($tag in $tags) { Invoke-DockerChecked @('push',$tag) }
