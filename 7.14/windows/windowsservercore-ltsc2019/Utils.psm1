<#
.SYNOPSIS
    Contains common objects, functions and variables.
.NOTES
    File name: lib.psm1
#>
#requires -Version 5.1
using namespace System
using namespace System.Text
using namespace System.Collections.Generic
using namespace System.Security.AccessControl

function Set-AppSettingsConfig {
    <#
    .SYNOPSIS
        Set or add an <add> node typically in a web.config file based on
        a key with a given value.
    .PARAMETER Key
        The key of the <add> node.
    .PARAMETER Value
        The value of the <add> node.
    .PARAMETER XmlDocument
        The XML representation of the file.
    .PARAMETER DocumentPath
        The path to the document.
    .PARAMETER Force
        If the <add> node exists, overwrite its value.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,
        [Parameter(Mandatory=$true, Position=1)]
        [string]$Value,
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [xml]$XmlDocument,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DocumentPath,
        [Switch]$Force
    )
    $addNode = $XmlDocument.SelectSingleNode("//add[@key=""$Key""]")

    if ($addNode -eq $null) {
        $addElement = $XmlDocument.CreateElement("add")

        $addElement.SetAttribute("key", $Key)
        $addElement.SetAttribute("value", $Value)
        $XmlDocument.configuration.appSettings.AppendChild($addElement)
        $XmlDocument.Save($DocumentPath)
    } elseif ($addNode -ne $null -and $Force) {
        $addNode.Attributes["value"].Value = $Value
        $XmlDocument.Save($DocumentPath)
    }
}

function Set-IISNodeSetting {
    <#
    .SYNOPSIS
        Sets a IISNode property in the web.config of the specified node application.
    .PARAMETER Name
        The name of the property to set.
    .PARAMETER Value
        The value to set to the property.
    .PARAMETER Application
        The name of the node application.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [Parameter(Mandatory=$true, Position=1)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("Auth", "SCIM", "GraphQL", "Hooks")]
        [string]$Application
    )
    $nodeAppName = $Application.ToLower()
    $wfgenFolder = [io.path]::Combine("C:\", "inetpub", "wwwroot", "wfgen")
    $nodeAppConfigPath = [io.path]::Combine($wfgenFolder, $nodeAppName, "web.config")
    $nodeAppConfig = [xml](Get-Content $nodeAppConfigPath)

    $nodeAppConfig.
        configuration["system.webServer"].
        iisnode.Attributes[$Name].Value = $Value

    $nodeAppConfig.Save($nodeAppConfigPath)
}

function Enable-IISNodeOption {
    <#
    .SYNOPSIS
        Enables a special option for iisnode that needs custom code.
    .DESCRIPTION
        Some options are hard to generalized without asking for XML input from
        the user of the container because almost everything comes down to XML
        when configuring iisnode. Therefore, this function will expose some options
        and hide the underlying required XML.
    .PARAMETER Name
        The name of the option to enable.
    .PARAMETER ApplicationName
        The name of the node application to enable the option on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("ExposeLogs")]
        [string]$Name,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias("Application")]
        [string]$ApplicationName
    )
    $nodeAppName = $ApplicationName.ToLower()
    $wfgenFolder = [io.path]::Combine("C:\", "inetpub", "wwwroot", "wfgen")
    $nodeAppConfigPath = [io.path]::Combine($wfgenFolder, $nodeAppName, "web.config")
    $nodeAppConfig = [xml](Get-Content $nodeAppConfigPath)

    switch ($Name.ToLower()) {
        "exposelogs" {
            $iisnodeAddSegment = $nodeAppConfig.
                configuration["system.webServer"].
                security.
                requestFiltering.
                hiddenSegments.
                SelectSingleNode("//add[@segment=""iisnode""]")
            $iisnodeLogsRewriteRule = $nodeAppConfig.
                configuration["system.webServer"].
                rewrite.
                SelectSingleNode("//rule[@name=""LogFile""]")

            if ($iisnodeAddSegment) {
                $iisnodeAddSegment.ParentNode.RemoveChild($iisnodeAddSegment)
            }

            if (-not $iisnodeLogsRewriteRule) {
                $logsRewriteRule = $nodeAppConfig.CreateElement("rule")
                $match = $nodeAppConfig.CreateElement("match")
                $logsRewriteRule.SetAttribute("name", "LogFile")
                $logsRewriteRule.SetAttribute("patternSyntax", "ECMAScript")
                $logsRewriteRule.SetAttribute("stopProcessing", "true")
                $match.SetAttribute("url", "iisnode")
                $logsRewriteRule.AppendChild($match)
                $nodeAppConfig.
                    configuration["system.webServer"].
                    rewrite.
                    rules.
                    PrependChild($logsRewriteRule)
                $nodeAppConfig.Save($nodeAppConfigPath)
            }
        }
    }
}

function Get-EnvVar {
    <#
    .SYNOPSIS
        Get an env var based on its name.
    .PARAMETER Name
        The name of the env var.
    .PARAMETER TryAzureAppServices
        Tries to recover the env var by name. If it does not exist,
        tries to recover the env var by prefixing an Azure App Services
        specific string.
    .PARAMETER TryFile
        Tries to recover the env var by name. If it does not exist,
        tries to recover the env var by suffixing the env var name by _FILE
        and then retrieves the value from the path indicated in the env var value.
    .OUTPUTS
        Returns the value of the environement variable or null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Name,
        [string]$DefaultValue,
        [switch]$TryAzureAppServices,
        [switch]$TryFile
    )
    $isDefaultValueBound = $PSBoundParameters.ContainsKey("DefaultValue")
    $getValue = { param ([string]$EnvName)
        $value = [Environment]::GetEnvironmentVariable($EnvName)

        if ($TryFile) {
            $nameFile = $EnvName + "_FILE"
            $valueFile = [Environment]::GetEnvironmentVariable($nameFile)

            if ($value -and $valueFile) {
                Script:Write-Error "$EnvName and $nameFile are mutually exclusive."

                if ($PSBoundParameters.ErrorAction -eq "Stop" -or $ErrorActionPreference -eq "Stop") {
                    exit 1
                }
            } elseif ($valueFile) {
                return (Get-Content $valueFile -Raw -Encoding UTF8).Trim()
            }
        }

        return $value
    }
    $valueOrDefault = { param ($Value)
        if ($isDefaultValueBound -and ([string]::IsNullOrEmpty($Value))) {
            return $DefaultValue
        }

        return $Value
    }

    if ($TryAzureAppServices) {
        $prefixedName = "APPSETTING_$Name"
        $value = & $getValue -EnvName $Name

        if ($value) {
            return $value
        }

        return & $valueOrDefault -Value (& $getValue -EnvName $prefixedName)
    }

    return & $valueOrDefault -Value (& $getValue -EnvName $Name)
}

function Join-Path {
    <#
    .SYNOPSIS
        Overrides the Join-Path standard function to add PowerShell 6 feature
        of arbitrary number of path elements.
    .DESCRIPTION
        In PowerShell 6, one can pass an arbitrary number of path elements to
        the function so that all the elements can be combined into one path.
    .PARAMETER Path
        The path elements to be combined into one.
    .OUTPUTS
        A path represented as a string in which all path elements have been
        combined.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path
    )
    begin {
        $allPath = [List[string]]::new()
    }
    process {
        $allPath.AddRange($Path)
    }
    end {
        return [io.path]::Combine($allPath)
    }
}

function Write-Error {
    <#
    .SYNOPSIS
        Writes a message to the error output.
    .DESCRIPTION
        This is a simplified version of the standard Write-Output function
        that only writes a message to the standard error stream without a
        stack trace.
    .PARAMETER Message
        The message to be sent in the error stream.
    #>
    param (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        [string]$Message
    )
    process {
        [Console]::ForegroundColor = "red"
        [Console]::Error.WriteLine($Message)
        [Console]::ResetColor()
    }
}

function New-RetryPolicy {
    <#
    .SYNOPSIS
        Creates a retry policy to use with other functions. A retry policy gives
        a description of how many retries it should take and how much time to wait
        between retries.
    .PARAMETER RetryCount
        The maximum number of retries to take.
    .PARAMETER IntervalMilliseconds
        Time between retries.
    .PARAMETER CatchException
        A list of exceptions to catch that will trigger another retry.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [int]$RetryCount = 3,
        [int]$IntervalMilliseconds = 200,
        [ValidateScript({
            # Reducer than tests all values to be type of Exception
            $_ | ForEach-Object -Begin { $acc = $true } -Process {
                $acc = $acc -and ([Exception].IsAssignableFrom($_ -as [type]))
            } -End { $acc }
        })]
        $CatchException = @()
    )

    process {
        return [PSCustomObject]@{
            PSTypeName = "Advantys.WorkflowGen.Docker.RetryPolicy"
            Retry = $RetryCount
            Exceptions = $CatchException
            Interval = $IntervalMilliseconds
        }
    }
}

function Invoke-Block {
    <#
    .SYNOPSIS
        Invoke a block of code with a specific policy.
    .PARAMETER Block
        The ScriptBlock to execute.
    .PARAMETER PolicyDefinition
        The policy to apply while executing the block.
    .PARAMETER ErrorMessage
        Message to display when the policy is not fulfilled.
    #>
    [CmdletBinding()]
    [OutputType([Object], [Void])]
    param (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0)]
        [scriptblock]$Block,
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=1)]
        [ValidateNotNull()]
        [Alias("Policy")]
        [PSTypeName("Advantys.WorkflowGen.Docker.RetryPolicy")]$PolicyDefinition
    )

    process {
        $retryCount = 0

        while ($retryCount -lt $PolicyDefinition.Retry) {
            try {
                return $Block.InvokeReturnAsIs()
            } catch [Exception] {
                $exception = $_.Exception
                $exceptionMatching = $PolicyDefinition.Exceptions `
                    | ForEach-Object -Begin { $acc = $false } -Process {
                        $acc = $acc -or $exception -is $_
                    } -End { $acc }

                if (-not $exceptionMatching) {
                    throw $_.Exception
                }
            }

            $retryCount += 1
            Start-Sleep -Milliseconds $PolicyDefinition.Interval
        }

        Microsoft.Powershell.Utility\Write-Error "Policy enforcement on script block failed."
    }
}

function Invoke-OnPlatform {
    <#
    .SYNOPSIS
        Executes a scriptblock on a specific platform.
    .DESCRIPTION
        This command is useful for a multi-platform script.
    .PARAMETER Windows
        Block to execute on Windows platforms only.
    .PARAMETER Linux
        Block to execute on Unix platforms only including Linux and MacOS.
    .PARAMETER ArgumentList
        A list of arguments to pass to the scriptblock.
    .OUTPUTS
        Outputs anything that the scriptblock returns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [scriptblock]$Windows = {},
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [scriptblock]$Linux = {},
        [object[]]$ArgumentList = @()
    )

    if ($PSVersionTable.PSVersion.Major -le 5 -or $IsWindows) {
        return & $Windows $ArgumentList
    } elseif ($IsLinux) {
        return & $Linux $ArgumentList
    } else {
        Microsoft.Powershell.Utility\Write-Error "Unsupported platform."
    }
}

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
        [switch]$Exit
    )

    if ($LASTEXITCODE -ne 0) {
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

Export-ModuleMember -Function @(
    "Get-EnvVar",
    "Invoke-Block",
    "Set-AppSettingsConfig",
    "Set-IISNodeSetting",
    "Join-Path",
    "Write-Error",
    "New-RetryPolicy",
    "Test-Error",
    "Invoke-OnPlatform",
    "Enable-IISNodeOption"
)
