<#
.SYNOPSIS
    This script prepares the environement based on provided environment
    variables. It also modifies WorkflowGen's properties in order for it to
    run like it is configured.
.NOTES
    File name: docker-entrypoint.ps1
#>
#requires -Version 5.1
#requires -Modules WebAdministration
using namespace System
using namespace System.Collections
using namespace System.Data.SqlClient

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    $RemainingArgs
)

Import-Module WebAdministration
Import-Module "$PSScriptRoot\Utils.psm1" -Prefix "WFG"
Import-Module "$PSScriptRoot\Auth.psm1"
Import-Module "$PSScriptRoot\Const.psm1" -Variable Constants

$ErrorActionPreference = "Stop"
Stop-Service WorkflowGenDirSyncService -ErrorAction SilentlyContinue `
    | Out-Null
Stop-Service WorkflowGenEngineService -ErrorAction SilentlyContinue `
    | Out-Null

#region Handle _FILE variables
[Environment]::GetEnvironmentVariables().GetEnumerator() `
    | Where-Object { $_.Key.EndsWith($global:Constants.ENV_VAR_FILE_SUFFIX) } `
    | ForEach-Object {
        $envVarName = $_.Key.Substring(0, $_.Key.Length - $global:Constants.ENV_VAR_FILE_SUFFIX.Length)

        if ([Environment]::GetEnvironmentVariable($envVarName)) {
            Write-WFGError "CONFIG: $( $_.Key ) and $envVarName are mutually exclusive."
            exit 1
        }

        if (-not (Test-Path $_.Value)) {
            Write-WFGError "CONFIG: The path ""$( $_.Value )"" does not exist."
            exit 1
        }

        Get-Content $_.Value -Raw -Encoding UTF8 `
            | ForEach-Object { [Environment]::SetEnvironmentVariable($envVarName, $_.Trim()) }
    }
#endregion

#region Initializations
# Special environment variables
$appWfgenAdminUsername                    = Get-WFGEnvVar "WFGEN_ADMIN_USERNAME" -DefaultValue "wfgen_admin" -TryAzureAppServices
$wfgenStartService                        = (Get-WFGEnvVar "WFGEN_START_SERVICE" -DefaultValue "all" -TryAzureAppServices).ToLower()
$genAppSymEncryptKey                      = Get-WFGEnvVar "WFGEN_GEN_APP_SYM_ENCRYPT_KEY" -DefaultValue "Y" -TryAzureAppServices
$appWfgenDatabaseConnectionString         = Get-WFGEnvVar "WFGEN_DATABASE_CONNECTION_STRING" -TryAzureAppServices
$appWfgenDatabaseReadonlyConnectionString = Get-WFGEnvVar "WFGEN_DATABASE_READONLY_CONNECTION_STRING" -TryAzureAppServices
$licenseFileName                          = Get-WFGEnvVar "WFGEN_LICENSE_FILE_NAME" -TryAzureAppServices
$machineKeyValidationKey                  = Get-WFGEnvVar "WFGEN_MACHINE_KEY_VALIDATION_KEY" -TryAzureAppServices
$machineKeyDecryptionKey                  = Get-WFGEnvVar "WFGEN_MACHINE_KEY_DECRYPTION_KEY" -TryAzureAppServices
$machineKeyValidationAlg                  = Get-WFGEnvVar "WFGEN_MACHINE_KEY_VALIDATION_ALG" -DefaultValue "HMACSHA256" -TryAzureAppServices
$machineKeyDecryptionAlg                  = Get-WFGEnvVar "WFGEN_MACHINE_KEY_DECRYPTION_ALG" -DefaultValue "AES" -TryAzureAppServices
$authModeName                             = Get-WFGEnvVar "WFGEN_AUTH_MODE" -DefaultValue "application" -TryAzureAppServices
$wfgenDependencyCheckInterval             = Get-WFGEnvVar "WFGEN_DEPENDENCY_CHECK_INTERVAL" -DefaultValue "1000" -TryAzureAppServices `
                                                | ForEach-Object { [Convert]::ToInt32($_) }
$wfgenDependencyCheckRetries              = Get-WFGEnvVar "WFGEN_DEPENDENCY_CHECK_RETRIES" -DefaultValue "10" -TryAzureAppServices `
                                                | ForEach-Object { [Convert]::ToInt32($_) }
$wfgenDependencyCheckEnabled              = Get-WFGEnvVar "WFGEN_DEPENDENCY_CHECK_ENABLED" -DefaultValue "Y" -TryAzureAppServices
$graphqlCorsEnabled                       = Get-WFGEnvVar "WFGEN_GRAPHQL_CORS_ENABLED" -DefaultValue "N" -TryAzureAppServices
$graphqlCorsAllowedOrigins                = Get-WFGEnvVar "WFGEN_GRAPHQL_CORS_ALLOWED_ORIGINS" -DefaultValue "*" -TryAzureAppServices

# Common paths
$webConfigPath        = Join-WFGPath "C:\", "inetpub", "wwwroot", "wfgen", "web.config"
$licensesPath         = Join-WFGPath "C:\", "wfgen", "licenses"
$wfgenBinPath         = Join-WFGPath "C:\", "inetpub", "wwwroot", "wfgen", "bin"

$webConfig = [xml](Get-Content $webConfigPath)
$forceSetAppSettingsWebConfig = { param ($Key, $Value)
    Set-WFGAppSettingsConfig `
        -Key $Key `
        -Value $Value `
        -XmlDocument $webConfig `
        -DocumentPath $webConfigPath `
        -Force
}
$customConnStringRegex = [regex]($global:Constants.WFGEN_CUSTOM_CONNECTION_STRING_REGEX)
$isWebServices = $wfgenStartService -eq $global:Constants.SERVICE_ALL -or
    $wfgenStartService -eq $global:Constants.SERVICE_WEB_APPS
#endregion

#region Dependency Check
if ($wfgenDependencyCheckEnabled -eq "Y") {
    Write-Host "DEPENDENCY: Beginning check on dependencies ... " -NoNewline

    if (-not $appWfgenDatabaseConnectionString) {
        Write-Host ([string]::Empty) # Adds a new line character to the output
        Write-WFGError "DEPENDENCY: A database connection string is needed in order for WorkflowGen to work."
        exit 1
    }

    New-WFGRetryPolicy `
        -RetryCount $wfgenDependencyCheckRetries `
        -IntervalMilliseconds $wfgenDependencyCheckInterval `
        -CatchException ([SqlException]) `
        -OutVariable RetryPolicy `
        | Invoke-WFGBlock -Block {
            [SqlConnection]$connection

            try {
                $connection = [SqlConnection]::new($appWfgenDatabaseConnectionString)
                $connection.Open()
            } finally {
                $connection.Dispose()
            }
        } -ErrorVariable PolicyBlockError -ErrorAction SilentlyContinue

    # Handle errors with stack trace
    if ($PolicyBlockError.Count -ge $RetryPolicy.Retry) {
        Write-Host ([string]::Empty)
        Write-WFGError "DEPENDENCY: Error when connecting to the database. Tried $( $RetryPolicy.Retry ) times."
        exit 1
    }

    Write-Host "done" -ForegroundColor Green
    Write-Host "DEPENDENCY: All dependencies are OK." -ForegroundColor Green
}
#endregion

#region Machine Key
if ($machineKeyDecryptionKey -and
    $machineKeyValidationKey -and
    -not $webConfig.SelectSingleNode("//machineKey")) {
    $machineKeyElement = $webConfig.CreateElement("machineKey")

    $machineKeyElement.SetAttribute("decryption", $machineKeyDecryptionAlg)
    $machineKeyElement.SetAttribute("decryptionKey", $machineKeyDecryptionKey)
    $machineKeyElement.SetAttribute("validation", $machineKeyValidationAlg)
    $machineKeyElement.SetAttribute("validationKey", $machineKeyValidationKey)
    $webConfig.configuration["system.web"].AppendChild($machineKeyElement) | Out-null
    $webConfig.Save($webConfigPath) | Out-Null
}
#endregion

#region Database sources
$mainDbSourceNode = $webConfig.SelectSingleNode("//add[@name=""MainDbSource""]")
$mainDbSourceNode.Attributes["connectionString"].Value = $appWfgenDatabaseConnectionString
$webConfig.Save($webConfigPath)

if (-not $webConfig.SelectSingleNode("//add[@name=""ReadonlyDbSource""]") -and
    $appWfgenDatabaseReadonlyConnectionString) {
    $addNode = $webConfig.CreateElement("add")

    $addNode.SetAttribute("name", "ReadonlyDbSource")
    $addNode.SetAttribute("providerName", "System.Data.SqlClient")
    $addNode.SetAttribute("connectionString", $appWfgenDatabaseReadonlyConnectionString)
    $webConfig.
        configuration.
        connectionStrings.
        AppendChild($addNode) | Out-Null
    $webConfig.Save($webConfigPath) | Out-Null
}

[Environment]::GetEnvironmentVariables().GetEnumerator() `
    | Where-Object {
        -not $_.Key.EndsWith($global:Constants.ENV_VAR_FILE_SUFFIX) -and
        $_.Key -match $global:Constants.WFGEN_CUSTOM_CONNECTION_STRING_REGEX
    } `
    | ForEach-Object -Begin { $accumulator = @{} } -Process {
        $match                = $customConnStringRegex.Match($_.Key)
        $connectionStringName = $match.Groups["conn_str_name"].Value
        $isProviderName       = [bool]$match.Groups["provider_name"].Value

        if (-not $connectionStringName) {
            return
        }

        if ($connectionStringName -notin $accumulator.Keys) {
            $accumulator[$connectionStringName] = @{}
        }

        if ($isProviderName) {
            $accumulator[$connectionStringName].ProviderName = $_.Value
        } else {
            $accumulator[$connectionStringName].ConnectionString = $_.Value
        }
    } -End { $accumulator.GetEnumerator() } `
    | Where-Object { -not $webConfig.SelectSingleNode("//add[@name=""$($_.Key)""]") } `
    | ForEach-Object {
        $providerName = if ($_.Value.ProviderName) { $_.Value.ProviderName } else { "System.Data.SqlClient" }
        $connAddNode = $webConfig.CreateElement("add")

        $connAddNode.SetAttribute("name", $_.Key)
        $connAddNode.SetAttribute("providerName", $providerName)
        $connAddNode.SetAttribute("connectionString", $_.Value.ConnectionString)

        return $connAddNode
    } `
    | ForEach-Object {
        $webConfig.
            configuration.
            connectionStrings.
            AppendChild($_) | Out-Null
        $webConfig.Save($webConfigPath) | Out-Null
        Write-Host "CONFIG: Added new connection string: $( $_.OuterXml )"
    }
#endregion

#region App Settings
if ($appWfgenAdminUsername) {
    Write-Host "CONFIG: Updating web.config settings for administrative account username ... " -NoNewline
    & $forceSetAppSettingsWebConfig "ApplicationConfigAllowedUsersLogin" $appWfgenAdminUsername
    & $forceSetAppSettingsWebConfig "EngineServiceImpersonificationUsername" $appWfgenAdminUsername
    & $forceSetAppSettingsWebConfig "ProcessesRuntimeWebServiceAllowedUsers" $appWfgenAdminUsername
    Write-Host "done" -ForegroundColor Green
}

$setAppSettingsFromEnv = { param ($Prefix, $Exclude=@())
    [Environment]::GetEnvironmentVariables().GetEnumerator() `
        | Where-Object {
            -not $_.Key.EndsWith($global:Constants.ENV_VAR_FILE_SUFFIX) -and
            $_.Key.StartsWith($Prefix)
        } `
        | ForEach-Object {
            $_.Key = $_.Key.Remove(0, $Prefix.Length)
            return $_
        } `
        | Where-Object Key -notin $Exclude `
        | ForEach-Object {
            Write-Host "CONFIG: Setting option ""$( $_.Key )"" ... " -NoNewline
            & $forceSetAppSettingsWebConfig $_.Key $_.Value
            Write-Host "done" -ForegroundColor Green
        }
}
$setIISNodeSettingsFromEnv = { param ($Prefix)
    [Environment]::GetEnvironmentVariables().GetEnumerator() `
        | Where-Object {
            -not $_.Key.EndsWith($global:Constants.ENV_VAR_FILE_SUFFIX) -and
            $_.Key.StartsWith($Prefix)
        } `
        | ForEach-Object {
            $applicationName, $attributeName = $_.Key.
                Remove(0, $Prefix.Length).
                Split("_")
            $applicationName = switch ($applicationName.ToUpper()) {
                "AUTH" { "Auth" }
                "GRAPHQL" { "GraphQL" }
                "HOOKS" { "Hooks" }
                "SCIM" { "SCIM" }
                default {
                    Write-WFGError "CONFIG: The given node application name doesn't exist."
                    exit 1
                }
            }

            return [PSCustomObject]@{
                Application=$applicationName
                Attribute=@{
                    Name=$attributeName
                    Value=$_.Value
                }
            }
        } `
        | ForEach-Object {
            Write-Host "CONFIG: Setting IISNode configuration ""$( $_.Attribute.Name )"" for application ""$( $_.Application )"" ... " -NoNewline
            Set-WFGIISNodeSetting $_.Attribute.Name $_.Attribute.Value -Application $_.Application
            Write-Host "done" -ForegroundColor Green
        }
}
$setIISNodeOptionFromEnv = { param($Prefix)
    [Environment]::GetEnvironmentVariables().GetEnumerator() `
        | Where-Object {
            -not $_.Key.EndsWith($global:Constants.ENV_VAR_FILE_SUFFIX) -and
            $_.Key.StartsWith($Prefix)
        } `
        | ForEach-Object {
            $applicationName = switch ($_.Key.Remove(0, $Prefix.Length)) {
                "AUTH" { "Auth" }
                "GRAPHQL" { "GraphQL" }
                "HOOKS" { "Hooks" }
                "SCIM" { "SCIM" }
                default {
                    Write-WFGError "CONFIG: The given node application name doesn't exist."
                    exit 1
                }
            }

            Write-Host "CONFIG: Setting IISNode option ""$($_.Value)"" for application ""$applicationName"" ... " -NoNewline
            Enable-WFGIISNodeOption -Name $_.Value -Application $applicationName | Out-Null
            Write-Host "done" -ForegroundColor Green
        }
}
$copyDefaultAppDataContent = {
    Join-WFGPath "C:\", "wfgen", "setup", "appdata" `
        | Get-ChildItem `
        | Copy-Item -Destination $global:Constants.APPLICATION_DATA_PATH -Recurse
}
$copyDefaultWfappsContent = {
    Join-WFGPath "C:\", "wfgen", "setup", "wfapps" `
        | Get-ChildItem `
        | Copy-Item -Destination $global:Constants.WFAPPS_PATH -Recurse
}

$excludedConfig = @(
    "ApplicationSecurityPasswordSymmetricEncryptionKey",
    "ApplicationDataPath",
    "ApplicationWebFormsPath"
)
& $setAppSettingsFromEnv -Prefix $global:Constants.WEB_CONFIG_PREFIX -Exclude $excludedConfig
& $setIISNodeSettingsFromEnv -Prefix $global:Constants.IISNODE_CONFIG_PREFIX
& $setIISNodeOptionFromEnv -Prefix $global:Constants.IISNODE_OPTION_PREFIX
& $forceSetAppSettingsWebConfig "ApplicationDataPath" $global:Constants.APPLICATION_DATA_PATH
& $forceSetAppSettingsWebConfig "ApplicationWebFormsPath" (Join-Path $global:Constants.WFAPPS_PATH "webforms")

#region CORS
$locationGql = $webConfig.
    configuration.
    SelectSingleNode("//location[@path=""graphql""]")

if (
    $graphqlCorsEnabled -eq "Y" -and
    -not (
        $locationGql -and
        $locationGql["system.webServer"] -and
        $locationGql["system.webServer"].cors
    )
) {
    $makeSimpleAdd = { param($AttributeName, $AttributeValue)
        $addElement = $webConfig.CreateElement("add")

        $addElement.SetAttribute($AttributeName, $AttributeValue)
        return $addElement
    }
    $makeAddMethod = { param($MethodName) return & $makeSimpleAdd "method" $MethodName }
    $makeAddHeader = { param($HeaderName) return & $makeSimpleAdd "header" $HeaderName }
    $makeAddOriginElement = { param($OriginName, $AddCrendentials=$false)
        $allowMethodsElement = $webConfig.CreateElement("allowMethods")
        $allowHeadersElement = $webConfig.CreateElement("allowHeaders")
        $addOriginElement = $webConfig.CreateElement("add")

        $allowMethodsElement.AppendChild((& $makeAddMethod "GET")) | Out-Null
        $allowMethodsElement.AppendChild((& $makeAddMethod "POST")) | Out-Null
        $allowMethodsElement.AppendChild((& $makeAddMethod "OPTIONS")) | Out-Null
        $allowMethodsElement.AppendChild((& $makeAddMethod "HEAD")) | Out-Null
        $allowHeadersElement.AppendChild((& $makeAddHeader "Accept")) | Out-Null
        $allowHeadersElement.AppendChild((& $makeAddHeader "Origin")) | Out-Null
        $allowHeadersElement.AppendChild((& $makeAddHeader "Authorization")) | Out-Null
        $allowHeadersElement.AppendChild((& $makeAddHeader "Content-Type")) | Out-Null
        $addOriginElement.SetAttribute("origin", $OriginName)

        if ($AddCrendentials) {
            $addOriginElement.SetAttribute("allowCredentials", "true")
        }

        $addOriginElement.AppendChild($allowMethodsElement) | Out-Null
        $addOriginElement.AppendChild($allowHeadersElement) | Out-Null

        return $addOriginElement
    }
    $corsElement = $webConfig.CreateElement("cors")

    $corsElement.SetAttribute("enabled", "true")
    $graphqlCorsAllowedOrigins -split "," `
        | ForEach-Object {
            Write-Host "CONFIG: Setting CORS on GraphQL for origin ""$_"" ... " -NoNewline
            $corsElement.AppendChild((& $makeAddOriginElement $_ ($_ -ne "*"))) | Out-Null
            Write-Host "done" -ForegroundColor Green
        }

    if ($locationGql -and $locationGql["system.webServer"]) {
        $locationGql["system.webServer"].AppendChild($corsElement) | Out-Null
    } elseif ($locationGql) {
        $systemWebServer = $webConfig.CreateElement("system.webServer")

        $systemWebServer.AppendChild($corsElement) | Out-Null
        $locationGql.AppendChild($systemWebServer) | Out-Null
    } else {
        $locationGql = $webConfig.CreateElement("location")
        $systemWebServer = $webConfig.CreateElement("system.webServer")

        $locationGql.SetAttribute("path", "graphql")
        $locationGql.SetAttribute("inheritInChildApplications", "false")
        $systemWebServer.AppendChild($corsElement) | Out-Null
        $locationGql.AppendChild($systemWebServer) | Out-Null
        $webConfig.configuration.AppendChild($locationGql) | Out-Null
    }

    $webConfig.Save($webConfigPath) | Out-Null
}

#region Trace configuration
[Environment]::GetEnvironmentVariables().GetEnumerator() `
    | ForEach-Object { @{
        Match = ([regex]$global:Constants.TRACE_OPTION_REGEX).Match($_.Key)
        Value = $_.Value
    } } `
    | Where-Object { $_.Match.Success } `
    | ForEach-Object -Begin { $acc = @{} } -Process {
        $serviceName = $_.Match.Groups["service_name"].Value
        $traceOption = $_.Match.Groups["option"].Value

        if ($serviceName -notin $acc.Keys) {
            $acc[$serviceName] = @{}
        }

        $acc[$serviceName] += @{
            $traceOption = $_.Value
        }
    } -End { $acc.GetEnumerator() } `
    | Where-Object {
        if ([string]::IsNullOrEmpty($_.Value[$global:Constants.TRACE_LEVEL])) {
            return $false
        }

        return $_.Value[$global:Constants.TRACE_LEVEL].ToUpper() -ne $global:Constants.TRACE_LEVEL_OFF
    } `
    | ForEach-Object {
        $name = $_.Key
        $level = if ($_.Value[$global:Constants.TRACE_LEVEL]) {
            $_.Value[$global:Constants.TRACE_LEVEL]
        } else { "Information" }
        $indent = if (-not [string]::IsNullOrEmpty($_.Value[$global:Constants.TRACE_INDENT])) {
            try {
                $indentVal = $_.Value[$global:Constants.TRACE_INDENT]
                $indentInt = [Convert]::ToInt32($indentVal)

                if (
                    $indentInt -gt $global:Constants.TRACE_MAX_INDENT -or
                    $indentInt -lt 0
                ) {
                    "4"
                } else {
                    $indentVal
                }
            } catch {
                "4"
            }
        } else { "4" }
        $traceConfigPath = switch ($name.ToUpper()) {
            $global:Constants.SERVICE_WEB_APPS.ToUpper() {
                $global:Constants.TRACE_WEB_APPS_PATH
            }
            "NODE" {
                $global:Constants.TRACE_NODE_PATH
            }
            $global:Constants.SERVICE_ENGINE.ToUpper() {
                $global:Constants.TRACE_ENGINE_PATH
            }
            $global:Constants.SERVICE_DIR_SYNC.ToUpper() {
                $global:Constants.TRACE_DIR_SYNC_PATH
            }
        }
        $traceConfig = [xml](Get-Content $traceConfigPath)

        Write-Host "CONFIG: Enabling trace for component $($name.ToUpper()) ... " -NoNewline
        $traceConfig["system.diagnostics"].
            switches.
            SelectSingleNode("//add[@name=""sourceSwitch""]").
            SetAttribute("value", $level) | Out-Null
        $traceConfig["system.diagnostics"].
            trace.
            SetAttribute("indentsize", $indent) | Out-Null
        $traceConfig.Save($traceConfigPath) | Out-Null
        Write-Host "done" -ForegroundColor Green
    }
#endregion
#endregion

#region Volumes management
if (-not (Test-Path ($global:Constants.APPLICATION_DATA_PATH))) {
    Write-Host "CONFIG: No ApplicationDataPath. Creating ... " -NoNewline
    New-Item $global:Constants.APPLICATION_DATA_PATH -ItemType Directory -Force | Out-Null
    & $copyDefaultAppDataContent
    Write-Host "done" -ForegroundColor Green
} elseif ((Get-ChildItem $global:Constants.APPLICATION_DATA_PATH | Measure-Object).Count -le 0) {
    Write-Host "CONFIG: ApplicationDataPath found but no content. Adding default content ... " -NoNewline
    & $copyDefaultAppDataContent
    Write-Host "done" -ForegroundColor Green
}

if (-not (Test-Path $global:Constants.WFAPPS_PATH)) {
    Write-Host "CONFIG: No Workflow Applications (WfApps) folder. Creating ... " -NoNewline
    New-Item $global:Constants.WFAPPS_PATH -ItemType Directory -Force | Out-Null
    & $copyDefaultWfappsContent
    Write-Host "done" -ForegroundColor Green
} elseif ((Get-ChildItem $global:Constants.WFAPPS_PATH | Measure-Object).Count -le 0) {
    Write-Host "CONFIG: Workflow Applications (WfApps) folder found but no content. Adding default content ... " -NoNewline
    & $copyDefaultWfappsContent
    Write-Host "done" -ForegroundColor Green
}

if ($isWebServices) {
    if ((Get-WebApplication -Site "wfgenroot" -Name "wfgen/wfapps/webforms").Count -le 0) {
        Write-Host "CONFIG: Web application for web forms not found. Creating ... " -NoNewline
        New-WebVirtualDirectory `
            -Site "wfgenroot" `
            -Name "wfapps" `
            -PhysicalPath $global:Constants.WFAPPS_PATH `
            -Application "wfgen" `
            | Out-Null
        ConvertTo-WebApplication -PSPath "IIS:\Sites\wfgenroot\wfgen\WfApps\WebForms" | Out-Null
        Write-Host "done" -ForegroundColor Green
    }
}
#endregion

#region Passwords Encryption
$encryptionKeyNode = $webConfig.
    configuration.
    appSettings.
    SelectSingleNode("//add[@key=""ApplicationSecurityPasswordSymmetricEncryptionKey""]")
$applicationSecurityPasswordSymmetricEncryptionKey =
    Get-WFGEnvVar "$( $global:Constants.WEB_CONFIG_PREFIX )ApplicationSecurityPasswordSymmetricEncryptionKey" -TryAzureAppServices

# Generate the symmetric encryption key if needed.
if ($applicationSecurityPasswordSymmetricEncryptionKey -and -not $encryptionKeyNode.Attributes["value"].Value) {
    Write-Host "CONFIG: Setting option ""ApplicationSecurityPasswordSymmetricEncryptionKey"" ... " -NoNewline

    if ($applicationSecurityPasswordSymmetricEncryptionKey.Length -ne 32) {
        Write-Host ([string]::Empty)
        Write-WFGError "CONFIG: The symmetric encryption key must be exactly 32 characters long."
        exit 1
    }

    $encryptionKeyNode.Attributes["value"].Value = $applicationSecurityPasswordSymmetricEncryptionKey
    $webConfig.Save($webConfigPath) | Out-Null
    Write-Host "done" -ForegroundColor Green
} elseif (-not $applicationSecurityPasswordSymmetricEncryptionKey -and
    -not $encryptionKeyNode.Attributes["value"].Value -and
    $genAppSymEncryptKey -eq "Y") {
    Write-Host "CONFIG: Generating the symmetric encryption key ... " -NoNewline
    $generatedKey = [guid]::NewGuid().ToString("N")
    $encryptionKeyNode.Attributes["value"].Value = $generatedKey
    $webConfig.Save($webConfigPath) | Out-Null
    Write-Host "done" -ForegroundColor Green
}
#endregion

#region Authentication
Write-Host "CONFIG: Setting the authentication mode to $authModeName ... " -NoNewline

switch -Regex ($authModeName.ToLower()) {
    $global:Constants.AUTH_MODE_APPLICATION {
        # Replaces the JWTAuthenticationModule with the AuthenticationModule when mode is application
        "global", "graphql" `
            | Remove-AuthenticationModule -DocumentPath $webConfigPath `
            | Out-Null
        "global", "graphql" `
            | Add-AuthenticationModule "Advantys.Security.Http.AuthenticationModule" -DocumentPath $webConfigPath `
            | Out-Null

        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WFGEN
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WS
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WFGEN -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WS -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WFGEN -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WS -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS -Disable
    }

    "$($global:Constants.AUTH_MODE_AZURE_V1)|$($global:Constants.AUTH_MODE_AUTH0)|$($global:Constants.AUTH_MODE_ADFS)|$($global:Constants.AUTH_MODE_OKTA)|$($global:Constants.AUTH_MODE_GARDIAN)|$($global:Constants.AUTH_MODE_MS_IDENTITY_V2)" {
        # Replaces the AuthenticationModule with the JWTAuthenticationModule when auth is an OIDC provider.
        "global" | Remove-AuthenticationModule -DocumentPath $webConfigPath | Out-Null
        "global" | Add-AuthenticationModule "Advantys.Security.Http.JWTAuthenticationModule" -DocumentPath $webConfigPath | Out-Null

        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WFGEN
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WS -Disable
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WFGEN -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WS -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WFGEN -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WS
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS -Disable
    }

    "$($global:Constants.AUTH_MODE_WINDOWS)" {
        "global", "graphql" `
            | Remove-AuthenticationModule -DocumentPath $webConfigPath `
            | Out-Null
        & "$env:windir\system32\inetsrv\appcmd.exe" `
            set AppPool DefaultAppPool "-processModel.identityType:NetworkService" `
            | Out-Null
        Restart-WebAppPool DefaultAppPool | Out-Null

        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WFGEN -Disable
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL -Disable
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WS -Disable
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WFGEN
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WS -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WFGEN -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WS
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS -Disable

        # Wait a certain amount of time in order for the identity change to be
        # registered correctly. Then, restart the pool to load it.
        Start-Job {
            Start-Sleep -Seconds 60
            Restart-WebAppPool DefaultAppPool | Out-Null
        } | Out-Null
    }

    "$($global:Constants.AUTH_MODE_BASIC)" {
        "global", "graphql" `
            | Remove-AuthenticationModule -DocumentPath $webConfigPath `
            | Out-Null

        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WFGEN -Disable
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL -Disable
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WS -Disable
        Set-IISAuthentication Anonymous -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WFGEN -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WS -Disable
        Set-IISAuthentication Windows -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS -Disable
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WFGEN
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_GRAPHQL
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WS
        Set-IISAuthentication Basic -Location $global:Constants.IIS_SITE_LOCATION_WEB_FORMS
    }
}

Write-Host "done" -ForegroundColor Green
#endregion

#region License
if (Test-Path $licensesPath) {
    Join-Path $wfgenBinPath "*.lic" `
        | Get-ChildItem `
        | ForEach-Object {
            Remove-Item $_.FullName
            Write-Debug "CONFIG: Removed license named ""$( $_.Name )"""
        }
    $proposedLicensesMeasure = Get-ChildItem $licensesPath -File `
        | Where-Object Extension -eq ".lic" `
        | Measure-Object

    if ($licenseFileName) {
        $licensePath = Join-Path $licensesPath $licenseFileName

        if (-not (Test-Path $licensePath)) {
            Write-WFGError "CONFIG: No license found at path: $licensePath"
            exit 1
        }

        Copy-Item $licensePath $wfgenBinPath -Force
        Write-Host "CONFIG: Added license named ""$licenseFileName"""
    } else {
        Get-ChildItem $licensesPath -File `
            | Where-Object Extension -eq ".lic" `
            | Select-Object -First 1 `
            | ForEach-Object {
                Copy-Item $_.FullName -Destination $wfgenBinPath -Force
                Write-Host "CONFIG: Added license named ""$($_.Name)"""
            }

        if ($proposedLicensesMeasure.Count -le 0) {
            Write-Warning "CONFIG: No license provided."
        }
    }
}
#endregion

Write-Host "CONFIG: WorkflowGen's configuration completed." -ForegroundColor Green

#region Start Services
switch -Regex ($wfgenStartService) {
    "$( $global:Constants.SERVICE_ALL )|$( $global:Constants.SERVICE_WIN_SERVICES )" {
        Write-Host "SERVICES: Starting WorkflowGenDirSyncService and WorkflowGenEngineService Windows services ... " -NoNewline
        Start-Service WorkflowGenDirSyncService | Out-Null
        Start-Service WorkflowGenEngineService | Out-Null
        Write-Host "done" -ForegroundColor Green
    }

    "$( $global:Constants.SERVICE_WIN_SERVICES )|$( $global:Constants.SERVICE_ENGINE )|$( $global:Constants.SERVICE_DIR_SYNC )" {
        Write-Host "SERVICES: Stopping W3SVC (Internet Information Services) service ... " -NoNewline
        Stop-Service W3SVC | Out-Null
        Write-Host "done" -ForegroundColor Green
    }

    "$( $global:Constants.SERVICE_ENGINE )" {
        Write-Host "SERVICES: Starting WorkflowGenEngineService Windows service ... " -NoNewline
        Start-Service WorkflowGenEngineService | Out-Null
        Write-Host "done" -ForegroundColor Green
    }

    "$( $global:Constants.SERVICE_DIR_SYNC )" {
        Write-Host "SERVICES: Starting WorkflowGenDirSyncService Windows service ... " -NoNewline
        Start-Service WorkflowGenDirSyncService | Out-Null
        Write-Host "done" -ForegroundColor Green
    }
}
#endregion

Write-Host "SERVICES: WorkflowGen's services started." -ForegroundColor Green

# Since Docker for Windows has bugs with ENTRYPOINT and CMD, this replaces
# the need for the CMD instruction. (Bugged since engine version 19.03)
# Now a warning is issued when using an ENTRYPOINT exec form with a CMD shell form.
# More details: https://github.com/moby/moby/issues/33373
if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
    Invoke-Expression ($RemainingArgs.ToArray() -join " ")
} else {
    & powershell.exe C:\monitor-services.ps1
}

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
