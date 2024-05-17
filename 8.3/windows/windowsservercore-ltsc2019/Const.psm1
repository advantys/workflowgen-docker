<#
.SYNOPSIS
    Contains the definition of constants used in scripts for WorkflowGen's
    Docker images.
.NOTES
    File Name: Const.psm1
#>
#requires -Version 5.1

$Constants = @{
    # Common constants
    DATABASE_SA_USERNAME                 = "sa"
    DATABASE_WFGEN_USER_USERNAME         = "WFGEN_USER"
    DATABASE_NAME                        = "WFGEN"
    WEB_CONFIG_PREFIX                    = "WFGEN_APP_SETTING_"
    IISNODE_CONFIG_PREFIX                = "WFGEN_IISNODE_"
    IISNODE_OPTION_PREFIX                = "WFGEN_ENABLE_IISNODE_OPTION_"
    ENV_VAR_FILE_SUFFIX                  = "_FILE"
    WFGEN_CUSTOM_CONNECTION_STRING_REGEX = "(?<=WFGEN_CUSTOM_CONNECTION_STRING_)(?<conn_str_name>[a-zA-Z0-9]*)?(?=(?<provider_name>_PROVIDER_NAME))?"
    APPLICATION_DATA_PATH                = ([io.path]::Combine("C:\", "wfgen", "data", "appdata"))
    WFAPPS_PATH                          = ([io.path]::Combine("C:\", "wfgen", "data", "wfapps"))
    CONTAINER_STATE_OFFLINE              = "offline"
    CONTAINER_STATE_ONLINE               = "online"

    # Trace Options
    TRACE_OPTION_REGEX  = "^WFGEN_TRACE_(?<service_name>[a-zA-Z0-9_]+)_(?<option>LEVEL|INDENT)$"
    TRACE_LEVEL_OFF     = "OFF"
    TRACE_LEVEL         = "LEVEL"
    TRACE_INDENT        = "INDENT"
    TRACE_MAX_INDENT    = 8
    TRACE_WEB_APPS_PATH = ([io.path]::Combine("C:\", "inetpub", "wwwroot", "wfgen", "trace.config"))
    TRACE_ENGINE_PATH   = ([io.path]::Combine("C:\", "Program Files", "Advantys", "WorkflowGen", "Services", "bin", "WfgWorkflowEngineService.exe.trace.config"))
    TRACE_DIR_SYNC_PATH = ([io.path]::Combine("C:\", "Program Files", "Advantys", "WorkflowGen", "Services", "bin", "WfgDirectoriesSyncService.exe.trace.config"))
    TRACE_NODE_PATH     = ([io.path]::Combine($env:ProgramFiles, "nodejs", "trace.config"))

    # WFGEN_START_SERVICE Constants
    SERVICE_WEB_APPS     = "web_apps"
    SERVICE_WIN_SERVICES = "win_services"
    SERVICE_ENGINE       = "engine"
    SERVICE_DIR_SYNC     = "dir_sync"
    SERVICE_ALL          = "all"

    # Authentication Modes
    AUTH_MODE_APPLICATION    = "application"
    AUTH_MODE_AZURE_V1       = "azure-v1"
    AUTH_MODE_MS_IDENTITY_V2 = "ms-identity-v2"
    AUTH_MODE_ADFS           = "adfs"
    AUTH_MODE_AUTH0          = "auth0"
    AUTH_MODE_OKTA           = "okta"
    AUTH_MODE_WINDOWS        = "windows"
    AUTH_MODE_BASIC          = "basic"

    # IIS Site Web Applications Locations
    IIS_SITE_LOCATION_WFGEN     = "wfgenroot/wfgen"
    IIS_SITE_LOCATION_GRAPHQL   = "wfgenroot/wfgen/graphql"
    IIS_SITE_LOCATION_WS        = "wfgenroot/wfgen/ws"
    IIS_SITE_LOCATION_WEB_FORMS = "wfgenroot/wfgen/WfApps/WebForms"
}.GetEnumerator() `
    | ForEach-Object -Begin { $constants = [PSCustomObject]::new() } -Process {
        $value = $_.Value
        $constants | Add-Member -Name $_.Key -Value { $value }.GetNewClosure() -MemberType ScriptProperty
    } -End { $constants }

Export-ModuleMember -Variable Constants
