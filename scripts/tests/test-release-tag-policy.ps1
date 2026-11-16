#requires -Version 7.0
[CmdletBinding()]
param([string]$OutputRoot = (Join-Path ([IO.Path]::GetTempPath()) ('wfgen-release-tag-tests-' + [guid]::NewGuid().ToString('N'))))

$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$output = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $output) { throw 'Use a fresh test output directory.' }
$null = [IO.Directory]::CreateDirectory($output)
$script:assertions = 0

function Check([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
function Reject([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Check $failed $Message
}
function New-Fixture([string]$Name) {
    $path = Join-Path $output $Name
    $null = [IO.Directory]::CreateDirectory($path)
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'update.ps1') -Destination $path
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'azure-pipelines.yml') -Destination $path
    foreach ($minor in @('10.5', '10.6', '10.7')) {
        foreach ($platform in @('ltsc2019', 'ltsc2022')) {
            $context = Join-Path $path "$minor/windows/windowsservercore-$platform"
            $null = [IO.Directory]::CreateDirectory((Join-Path $context 'onbuild'))
            [IO.File]::WriteAllText((Join-Path $context 'Dockerfile'), "FROM fixture`nENV WFGEN_VERSION=$minor.0`n")
            [IO.File]::WriteAllText((Join-Path $context 'onbuild/Dockerfile'), "FROM advantys/workflowgen:$minor.0-win-$platform`n")
        }
    }
    return $path
}
function Read-Pipeline([string]$Path) {
    return Get-Content -LiteralPath (Join-Path $Path 'azure-pipelines.yml') -Raw | ConvertFrom-Yaml -Ordered
}
function Read-Entry([string]$Path, [string]$Minor, [string]$Platform = 'ltsc2019') {
    $pipeline = Read-Pipeline $Path
    return ($pipeline.jobs | Where-Object job -eq "Build$Platform").strategy.matrix[$Minor]
}
function Run-Update([string]$Path, [string]$Version, [string]$Policy = 'true') {
    & (Join-Path $Path 'update.ps1') -ToVersion $Version -PromoteFloatingTags $Policy
}
function Get-OwnerSnapshot($Pipeline) {
    $owners = [ordered]@{}
    foreach ($job in $Pipeline.jobs) {
        if ($job.strategy -and $job.strategy.matrix) {
            foreach ($item in $job.strategy.matrix.GetEnumerator()) {
                $owners["$($job.job)/$($item.Key)"] = $item.Value | ConvertTo-Json -Compress
            }
        }
    }
    return $owners
}
function Invoke-MockedBuild {
    param([string]$Path, [string]$Version, [string]$Platform, [AllowNull()][string]$Policy, [string]$AdditionalTags = '')
    $environmentNames = @('BUILD_REPOSITORY_LOCALPATH', 'WFGEN_VERSION', 'WFGEN_VERSION_FOLDER', 'WINDOWS_SERVER_VERSION', 'WFGEN_PROMOTE_FLOATING_TAGS', 'ADDITIONAL_TAGS', 'DOCKER_ISOLATION')
    $previous = @{}
    foreach ($name in $environmentNames) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
    $dockerCalls = [Collections.Generic.List[object]]::new()
    $failure = $null
    $oldExitCode = $global:LASTEXITCODE
    function docker {
        $dockerCalls.Add([string[]]$args)
        $global:LASTEXITCODE = 0
    }
    try {
        $env:BUILD_REPOSITORY_LOCALPATH = $Path
        $env:WFGEN_VERSION = $Version
        $env:WFGEN_VERSION_FOLDER = ([version]$Version).ToString(2)
        $env:WINDOWS_SERVER_VERSION = $Platform
        $env:WFGEN_PROMOTE_FLOATING_TAGS = $Policy
        $env:ADDITIONAL_TAGS = $AdditionalTags
        $env:DOCKER_ISOLATION = 'process'
        try { & (Join-Path $repositoryRoot 'scripts/build-images.ps1') | Out-Null } catch { $failure = $_ }
    } finally {
        foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        $global:LASTEXITCODE = $oldExitCode
    }
    return [pscustomobject]@{ Calls = $dockerCalls.ToArray(); Error = $failure }
}
function Get-PushedTags($Result) {
    return @($Result.Calls | Where-Object { $_[0] -eq 'push' } | ForEach-Object { $_[1] } | Sort-Object -Unique)
}
function Check-Set($Actual, $Expected, [string]$Message) {
    $difference = @(Compare-Object @($Actual | Sort-Object -Unique) @($Expected | Sort-Object -Unique))
    Check ($difference.Count -eq 0) $Message
}

$beta = New-Fixture 'beta'
$originalOwners = Get-OwnerSnapshot (Read-Pipeline $beta)
Run-Update $beta '10.6.0' 'false'
$betaOwners = Get-OwnerSnapshot (Read-Pipeline $beta)
foreach ($key in $originalOwners.Keys) {
    Check ($betaOwners[$key] -ceq $originalOwners[$key]) "Beta changed an existing matrix entry: $key"
}
foreach ($platform in @('ltsc2019', 'ltsc2022')) {
    $entry = Read-Entry $beta '10.6' $platform
    Check ($entry.WFGEN_VERSION -ceq '10.6.0') 'Beta version must remain numeric.'
    Check ($entry.WFGEN_PROMOTE_FLOATING_TAGS -ceq 'false') 'Beta policy must be persisted per platform.'
}
Check ((Read-Entry $beta '10.6').ADDITIONAL_TAGS -ceq '10.6.0') 'Beta must expose only the exact bare version.'
Check ((Get-Content -LiteralPath (Join-Path $beta 'BUILD_VERSION.txt') -Raw) -ceq '10.6') 'Build selection must stay scoped to the new minor.'
$allBetaTags = @()
foreach ($platform in @('ltsc2019', 'ltsc2022')) {
    $entry = Read-Entry $beta '10.6' $platform
    $result = Invoke-MockedBuild $beta '10.6.0' $platform $entry.WFGEN_PROMOTE_FLOATING_TAGS $entry.ADDITIONAL_TAGS
    Check ($null -eq $result.Error) "Version-only publisher failed for $platform."
    $allBetaTags += Get-PushedTags $result
}
Check-Set $allBetaTags @(
    'advantys/workflowgen:10.6.0', 'advantys/workflowgen:10.6.0-onbuild',
    'advantys/workflowgen:10.6.0-win-ltsc2019', 'advantys/workflowgen:10.6.0-win-ltsc2019-onbuild',
    'advantys/workflowgen:10.6.0-win-ltsc2022', 'advantys/workflowgen:10.6.0-win-ltsc2022-onbuild'
) 'Beta publisher emitted an unexpected alias or omitted a full-version tag.'

Run-Update $beta '10.6.0' 'false'
Check ((Read-Entry $beta '10.5').ADDITIONAL_TAGS -ceq 'latest, 10, 10.5, 10.5.0') 'Repeated Beta generation must preserve stable owners.'
Run-Update $beta '10.5.1' 'true'
Check ((Read-Entry $beta '10.5').ADDITIONAL_TAGS -ceq 'latest, 10, 10.5, 10.5.1') 'A stable backport must remain eligible while a newer Beta exists.'
Check ((Read-Entry $beta '10.6').WFGEN_PROMOTE_FLOATING_TAGS -ceq 'false') 'Stable backport must preserve the Beta policy.'
Check ((Read-Entry $beta '10.6').ADDITIONAL_TAGS -ceq '10.6.0') 'Stable backport must not promote the Beta.'

Run-Update $beta '10.6.1' 'true'
$stable = Read-Entry $beta '10.6'
Check ($stable.WFGEN_PROMOTE_FLOATING_TAGS -ceq 'true') 'Stable promotion must replace the Beta policy.'
Check ($stable.ADDITIONAL_TAGS -ceq 'latest, 10, 10.6, 10.6.1') 'Stable release must receive normal aliases.'
Check ((Read-Entry $beta '10.5').ADDITIONAL_TAGS -ceq '10.5, 10.5.1') 'Stable promotion must transfer only the applicable aliases.'
$stablePublish = Invoke-MockedBuild $beta '10.6.1' 'ltsc2019' 'true' $stable.ADDITIONAL_TAGS
Check ($null -eq $stablePublish.Error) 'Stable publisher failed.'
$stableTags = Get-PushedTags $stablePublish
foreach ($tag in @('latest', '10', '10-onbuild', '10.6', '10.6-onbuild', '10.6-win-ltsc2019', '10.6-win-ltsc2019-onbuild', '10.6.1', '10.6.1-onbuild')) {
    Check ("advantys/workflowgen:$tag" -cin $stableTags) "Stable publication omitted $tag."
}
$pipelineBeforeRejection = Get-Content -LiteralPath (Join-Path $beta 'azure-pipelines.yml') -Raw
Reject { Run-Update $beta '10.6.0' 'true' } 'Stable downgrade must be rejected.'
Reject { Run-Update $beta '10.6.0' 'false' } 'Beta downgrade must be rejected.'
Reject { Run-Update $beta '10.6.2' 'false' } 'Version-only mode must not overwrite a stable minor context.'
Check ((Get-Content -LiteralPath (Join-Path $beta 'azure-pipelines.yml') -Raw) -ceq $pipelineBeforeRejection) 'Rejected releases must not change the matrix.'

$default = New-Fixture 'default'
$explicit = New-Fixture 'explicit-stable'
& (Join-Path $default 'update.ps1') -ToVersion '10.6.0'
Run-Update $explicit '10.6.0' 'true'
Check ((Get-Content -LiteralPath (Join-Path $default 'azure-pipelines.yml') -Raw) -ceq (Get-Content -LiteralPath (Join-Path $explicit 'azure-pipelines.yml') -Raw)) 'Default release behavior must equal explicit stable mode.'
$legacyBuild = Invoke-MockedBuild $default '10.6.0' 'ltsc2019' $null 'latest, 10, 10.6, 10.6.0'
$explicitBuild = Invoke-MockedBuild $default '10.6.0' 'ltsc2019' 'true' 'latest, 10, 10.6, 10.6.0'
Check ($null -eq $legacyBuild.Error -and $null -eq $explicitBuild.Error) 'Historical/default stable build failed.'
Check-Set (Get-PushedTags $legacyBuild) (Get-PushedTags $explicitBuild) 'Historical matrix entries must keep stable tag behavior.'

foreach ($case in @(
    @{ Version='10.6.0'; Policy='invalid'; Additional='10.6.0' },
    @{ Version='10.6.0'; Policy='false'; Additional='latest, 10, 10.6.0' },
    @{ Version='10.6.0'; Policy='false'; Additional='10.6' },
    @{ Version='10.6'; Policy='false'; Additional='10.6' },
    @{ Version='10.5.1'; Policy='false'; Additional='10.5.1' }
)) {
    $rejectedBuild = Invoke-MockedBuild $default $case.Version 'ltsc2019' $case.Policy $case.Additional
    Check ($null -ne $rejectedBuild.Error) 'Invalid or unsupported publisher policy must be rejected.'
    Check ($rejectedBuild.Calls.Count -eq 0) 'Rejected publisher policy must fail before any Docker command.'
}
$wrongPlatformAlias = Invoke-MockedBuild $default '10.6.0' 'ltsc2022' 'false' '10.6.0'
Check ($null -ne $wrongPlatformAlias.Error -and $wrongPlatformAlias.Calls.Count -eq 0) 'Version-only bare aliases must belong to the primary platform.'
Reject { Run-Update $default '10.7.0' 'invalid' } 'Invalid updater policy must be rejected.'

[pscustomobject]@{ Assertions=$script:assertions; Result='Passed'; DockerExecuted=$false; OutputRoot=$output }
