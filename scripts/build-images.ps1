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

docker build -t $completeTag $buildPath
docker build -t $onbuildTag $onbuildPath
