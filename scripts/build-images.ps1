<#
.SYNOPSIS
    Builds docker images and pushes them.
#>
#requires -Version 5.1
using namespace System.Collections

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
docker build -t $onbuildTag $onbuildPath
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

$tags | ForEach-Object { docker push $_ }
