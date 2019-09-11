# escape=`
FROM mcr.microsoft.com:4.8-windowsservercore-ltsc2016

SHELL [ "powershell", "-Command", "$ErrorActionPreference = 'Stop';", "$ProgressPreference = 'SilentlyContinue';" ]

# Install required authentication methods
RUN Enable-WindowsOptionalFeature -Online -FeatureName IIS-WindowsAuthentication -Verbose; `
    Enable-WindowsOptionalFeature -Online -FeatureName IIS-BasicAuthentication -Verbose;

ENV NODE_VERSION=10.16.1
ENV NODE_SHA256=dc99f8c0be1e8bb1abfaa194113712ba85cc749bd32990f84cdcdd3b619f6a1c

# Install NodeJS
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; `
    Invoke-WebRequest `
        -Uri ('https://nodejs.org/dist/v{0}/node-v{0}-x64.msi' -f $env:NODE_VERSION) `
        -OutFile C:\node.msi `
        -Verbose; `
    if ((Get-FileHash C:\node.msi -Algorithm SHA256).Hash -ne $env:NODE_SHA256.ToUpper()) { `
        Write-Error 'Hash string does not match the one of the downloaded package.'; `
    }`
    Start-Process -FilePath C:\node.msi -Wait -Verbose; `
    Remove-Item -Path C:\node.msi -Force -Verbose

ENV IISNODE_VERSION=0.2.26

# Install iisnode
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; `
    Invoke-WebRequest `
        -Uri ('https://github.com/azure/iisnode/releases/download/v{0}/iisnode-full-v{0}-x64.msi' -f $env:IISNODE_VERSION) `
        -OutFile C:\iisnode.msi `
        -Verbose; `
    Start-Process -FilePath C:\iisnode.msi -Wait -Verbose; `
    Start-Sleep -Seconds 30 -Verbose; `
    Invoke-WebRequest `
        -Uri 'http://download.microsoft.com/download/C/9/E/C9E8180D-4E51-40A6-A9BF-776990D8BCA9/rewrite_amd64.msi' `
        -OutFile C:\rewrite.msi `
        -Verbose; `
    Start-Process -FilePath C:\rewrite.msi -Wait -Verbose; `
    Start-Sleep -Seconds 30 -Verbose; `
    Remove-Item -Path C:\rewrite.msi -Force -Verbose; `
    Remove-Item -Path C:\iisnode.msi -Force -Verbose

RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; `
    Invoke-WebRequest `
        -Uri 'https://github.com/advantys/workflowgen-releases/releases/download/7.16.0/manual.zip' `
        -OutFile C:\manual.zip; `
    Write-Host 'Extracting manual.zip...'; `
    Expand-Archive -Path C:\manual.zip -DestinationPath C:\manual; `
    Write-Host 'done'; `
    Join-Path 'C:\manual' 'Inetpub' | Copy-Item -Destination C:\ -Recurse -Force; `
    Join-Path 'C:\manual' 'Program Files' | Copy-Item -Destination C:\ -Recurse -Force; `
    Remove-Item C:\manual -Recurse -Force -ErrorAction SilentlyContinue; `
    Remove-Item C:\manual.zip -Force -ErrorAction SilentlyContinue

WORKDIR C:\inetpub\wwwroot\wfgen
# Install Node apps dependencies
RUN '.\auth', '..\scim', '..\hooks', '..\graphql' | `
    ForEach-Object { `
        Set-Location $_; `
        &npm install --production; `
    };

WORKDIR C:/
RUN Import-Module IISAdministration; `
    # App_Data and wfapps are moved to C:\wfgen\setup because it can be confusing
    # to leave them in C:\inetpub\wwwroot\wfgen because they are only used with volumes
    # in this image.
    if (-not (Test-Path C:\wfgen\setup)) { `
        New-Item C:\wfgen\setup -Type Directory -Force; `
    } `
    Move-Item `
        -Path C:\inetpub\wwwroot\wfgen\App_Data `
        -Destination C:\wfgen\setup; `
    Move-Item `
        -Path C:\inetpub\wwwroot\wfgen\wfapps `
        -Destination C:\wfgen\setup; `
    Rename-Item C:\wfgen\setup\App_data -NewName 'appdata'; `
    # Set access rights for WorkflowGen's folder
    & icacls.exe 'C:\Inetpub\wwwroot\wfgen' /T /inheritance:e /grant:r 'IIS_IUSRS:(OI)(CI)M' | Out-Null; `
    # Install WorkflowGen's Windows Services
    &('{0}\Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe' -f $env:windir) /i 'C:\Program Files\Advantys\WorkflowGen\Services\Bin\WfgDirectoriesSyncService.exe'; `
    &('{0}\Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe' -f $env:windir) /i 'C:\Program Files\Advantys\WorkflowGen\Services\Bin\WfgWorkflowEngineService.exe'; `
    Remove-WebSite -Name 'Default Web Site' -Verbose; `
    # Creating a new IIS website
    New-IISSite `
        -Name 'wfgenroot' `
        -PhysicalPath C:\inetpub\wwwroot `
        -BindingInformation '*:80:' `
        -Verbose; `
    # Creating web applications in IIS
    'IIS:\Sites\wfgenroot\wfgen', 'IIS:\Sites\wfgenroot\wfgen\ws', 'IIS:\Sites\wfgenroot\wfgen\graphql', 'IIS:\Sites\wfgenroot\wfgen\hooks', 'IIS:\Sites\wfgenroot\wfgen\auth', 'IIS:\Sites\wfgenroot\wfgen\scim' | `
        ForEach-Object { ConvertTo-WebApplication $_ -Verbose; }; `
    # Setting the authentication type of the website
    Set-WebConfiguration system.web/authentication 'IIS:\Sites\wfgenroot' `
        -Value @{mode='Windows'} `
        -Verbose; `
    Set-WebConfigurationProperty `
        -Filter /system.webServer/security/authentication/anonymousAuthentication `
        -Name enabled `
        -Value true `
        -PSPath 'IIS:\Sites\wfgenroot\wfgen' `
        -Verbose; `
    # Setting log output of IIS to a single file at a time
    Set-WebConfigurationProperty system.applicationHost/log `
        -Name centralLogFileMode `
        -Value CentralW3C `
        -PSPath 'MACHINE/WEBROOT/APPHOST'; `
    # 4GB is the highest value allowed
    Set-WebConfigurationProperty system.applicationHost/log/centralW3CLogFile `
        -Name truncateSize `
        -Value 4294967295 `
        -PSPath 'MACHINE/WEBROOT/APPHOST'; `
    Set-WebConfigurationProperty system.applicationHost/log/centralW3CLogFile `
        -Name period `
        -Value MaxSize `
        -PSPath 'MACHINE/WEBROOT/APPHOST'; `
    Set-WebConfigurationProperty system.applicationHost/log/centralW3CLogFile `
        -Name directory `
        -Value C:\iislog `
        -PSPath 'MACHINE/WEBROOT/APPHOST';

COPY .\healthcheck.ps1 C:\
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 `
    CMD [ "powershell", "C:\\healthcheck.ps1" ]

VOLUME [ `
    "C:\\wfgen\\licenses", `
    "C:\\wfgen\\appdata", `
    "C:\\wfgen\\wfapps" `
]
EXPOSE 80 443
ENV WFGEN_VERSION=7.16.0

COPY .\workflowgen\docker-entrypoint.ps1 `
    .\monitor-services.ps1 `
    .\Utils.psm1 `
    .\Const.psm1 `
    .\Auth.psm1 `
    C:\
ENTRYPOINT C:\docker-entrypoint.ps1
