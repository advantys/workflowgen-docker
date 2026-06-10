<#
.SYNOPSIS
    Contains the definition of the functions that handles authentication setup.
.NOTES
    File Name: Auth.psm1
#>
#requires -Version 5.1

function Remove-AuthenticationModule {
    <#
    .SYNOPSIS
        Removes an <add> element from the xml tree in the sub-module specified.
    .PARAMETER ModuleName
        The name of the module where to remove the authentication module.
    .PARAMETER DocumentPath
        The path to the xml document where to apply the remove.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [ValidateSet("global", "auth", "scim", "hooks", "graphql")]
        [string]$ModuleName,
        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DocumentPath
    )
    process {
        $document = [xml](Get-Content $DocumentPath)

        if ($ModuleName -eq "global") {
            if (-not $document.configuration["system.webServer"]) {
                return
            }

            $addNode = $document.
                configuration["system.webServer"].
                SelectSingleNode("//add[@name=""ApplicationSecurityAuthenticationModule""]")

            if ($addNode) {
                $addNode.ParentNode.RemoveChild($addNode)
                $document.Save($DocumentPath)
            }
            return
        }

        $locationNode = $document.SelectSingleNode("//location[@path=""$ModuleName""]")

        if ($locationNode) {
            $addNode = $locationNode.SelectSingleNode("//add[@name=""ApplicationSecurityAuthenticationModule""]")

            if ($addNode) {
                $addNode.ParentNode.RemoveChild($addNode)
                $document.Save($DocumentPath)
            }
        }
    }
}

function Add-AuthenticationModule {
    <#
    .SYNOPSIS
        Adds the specified type as the authentication module for IIS.
    .PARAMETER Name
        The name of the .Net module (Full Type name) to add.
    .PARAMETER ModuleName
        The name of the sub-module where to apply the change.
    .PARAMETER DocumentPath
        The path to the xml document where to put the authentication module
        declaration.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [ValidateSet("global", "auth", "scim", "hooks", "graphql")]
        [string]$ModuleName,
        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DocumentPath
    )

    process {
        $document = [xml](Get-Content $DocumentPath)
        [System.Xml.XmlNode]$node

        if ($ModuleName -eq "global") {
            if (-not $document.configuration["system.webServer"]) {
                $document.configuration.AppendChild($document.CreateElement("system.webServer"))
            }

            $node = $document.configuration
        } else {
            $node = $document.SelectSingleNode("//location[@path=""$ModuleName""]")
        }

        $node = if ($node) { $node["system.webServer"] } else { return }
        $authenticationModuleNode = $node.SelectSingleNode("//add[@name=""ApplicationSecurityAuthenticationModule""]")

        if ($authenticationModuleNode) {
            $authenticationModuleNode.Attributes["type"].Value = $Name
        } elseif (-not $node.SelectSingleNode("modules")) {
            $modulesElement = $document.CreateElement("modules")
            $addElement = $document.CreateElement("add")

            $addElement.SetAttribute("name", "ApplicationSecurityAuthenticationModule")
            $addElement.SetAttribute("type", $Name)
            $modulesElement.AppendChild($addElement)
            $node.AppendChild($modulesElement)
        } else {
            $addElement = $document.CreateElement("add")

            $addElement.SetAttribute("name", "ApplicationSecurityAuthenticationModule")
            $addElement.SetAttribute("type", $Name)

            $node.SelectSingleNode("modules").AppendChild($addElement)
        }

        $document.Save($DocumentPath)
    }
}

function Set-IISAuthentication {
    <#
    .SYNOPSIS
        Set the authentication mode for IIS at the specified location.
    .DESCRIPTION
        This command is best used with multiple sub applications in your
        IIS website.
    .PARAMETER IISAuthModeName
        The name of the authentication mode to set.
    .PARAMETER Location
        The location of the web application.
    .PARAMETER Disable
        Set this switch to disable the given authentication mode.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("Basic", "Windows", "Anonymous")]
        [string]$IISAuthModeName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Location,
        [switch]$Disable
    )

    process {
        $filter = switch ($IISAuthModeName) {
            "Basic" { "/system.webServer/security/authentication/basicAuthentication" }
            "Windows" { "/system.webServer/security/authentication/windowsAuthentication" }
            "Anonymous" { "/system.webServer/security/authentication/anonymousAuthentication" }
        }

        Set-WebConfigurationProperty `
            -Filter $filter `
            -Name Enabled `
            -Value (-not $Disable) `
            -PSPath "IIS:/Sites" `
            -Location $Location | Out-Null
    }
}

Export-ModuleMember -Function @(
    "Remove-AuthenticationModule",
    "Add-AuthenticationModule",
    "Set-IISAuthentication"
)
