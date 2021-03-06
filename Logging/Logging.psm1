#requires -Version 4

$NOTSET = 0
$DEBUG = 10
$INFO = 20
$WARNING = 30
$ERROR_ = 40

$LN = [hashtable]::Synchronized(@{
    $NOTSET = 'NOTSET'
    $ERROR_ = 'ERROR'
    $WARNING = 'WARNING'
    $INFO = 'INFO'
    $DEBUG = 'DEBUG'
    'NOTSET' = $NOTSET
    'ERROR' = $ERROR_
    'WARNING' = $WARNING
    'INFO' = $INFO
    'DEBUG' = $DEBUG
})

New-Variable -Name Dispatcher   -Value ([hashtable]::Synchronized(@{})) -Option ReadOnly
New-Variable -Name LevelNames   -Value $LN -Option ReadOnly
New-Variable -Name Logging      -Value ([hashtable]::Synchronized(@{})) -Option ReadOnly
New-Variable -Name LogTargets   -Value ([hashtable]::Synchronized(@{})) -Option ReadOnly
New-Variable -Name ScriptRoot   -Value (Split-Path $MyInvocation.MyCommand.Path) -Option ReadOnly
New-Variable -Name MessageQueue -Value ([System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList] @())) -Option ReadOnly

$Defaults = @{
    Level = $NOTSET
    Format = '[%{timestamp:+%Y-%m-%d %T%Z}] [%{level:-7}] %{message}'
    Timestamp = '%Y-%m-%dT%T%Z'
}

$Logging.Level      = $Defaults.Level
$Logging.Format     = $Defaults.Format
$Logging.Targets    = [hashtable] @{}

Function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 2,
                   Mandatory = $true)]
        [string] $Message,
        [Parameter(Position = 3,
                   Mandatory = $false)]
        [array] $Arguments,
        [Parameter(Position = 4,
                   Mandatory = $false)]
        [object] $Body
    )

    DynamicParam {
        $Level = New-Object System.Management.Automation.ParameterAttribute
        $Level.ParameterSetName = '__AllParameterSets'
        $Level.Mandatory = $true
        $Level.Position = 1
        $ValidateSetAttribute = New-Object System.Management.Automation.ValidateSetAttribute(Get-LevelsName)

        $AttributeCollection = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
        $AttributeCollection.Add($Level)
        $AttributeCollection.Add($ValidateSetAttribute)

        $LevelParam = New-Object System.Management.Automation.RuntimeDefinedParameter('Level', [string], $AttributeCollection)

        $RDPDic = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
        $RDPDic.Add('Level', $LevelParam)
        return $RDPDic
    }

    End {
        $LevelNo = Get-LevelNumber -Level $PSBoundParameters.Level
        if ($Arguments) {
            $text = $Message -f $Arguments
        } else {
            $text = $Message
        }

        $mess = [hashtable] @{
            timestamp = Get-Date -UFormat $Defaults.Timestamp
            levelno = $LevelNo
            level = Get-LevelName -Level $LevelNo
            message = $text
        }

        if ($Body) { $mess['body'] = $Body }

        [void] $MessageQueue.Add($mess)
    }
}


Function Get-LevelsName {
    [CmdletBinding()]
    param()

    return $LevelNames.Keys | Where-Object {$_ -isnot [int]} | Sort-Object
}


Function Get-LevelNumber {
    [CmdletBinding()]
    param(
        $Level
    )

    if ($Level -is [int] -and $Level -in $LevelNames.Keys) {return $Level}
    elseif ([string] $Level -eq $Level -and $Level -in $LevelNames.Keys) {return $LevelNames[$Level]}
    else {throw ('Level not a valid integer or a valid string: {0}' -f $Level)}
}


Function Get-LevelName {
    [CmdletBinding()]
    param(
        [int] $Level
    )

    $l = $LevelNames[$Level]
    if ($l) {return $l}
    else {return ('Level {0}' -f $Level)}
}


Function Replace-Token {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param(
        [string] $String,
        [object] $Source
    )

    $re = [regex] '%{(?<token>\w+?)?(?::?\+(?<datefmtU>(?:%[ABCDGHIMRSTUVWXYZabcdeghjklmnprstuwxy].*?)+))?(?::?\+(?<datefmt>(?:.*?)+))?(?::(?<padding>-?\d+))?}'
    $re.Replace($String, {
        param($match)
        $token = $match.Groups['token'].value
        $datefmt = $match.Groups['datefmt'].value
        $datefmtU = $match.Groups['datefmtU'].value
        $padding = $match.Groups['padding'].value

        if ($token -and -not $datefmt -and -not $datefmtU) {
            $var = $Source.$token
        } elseif ($token -and $datefmtU) {
            $var = Get-Date $Source.$token -UFormat $datefmtU
        } elseif ($token -and $datefmt) {
            $var = Get-Date $Source.$token -Format $datefmt
        } elseif ($datefmtU -and -not $token) {
            $var = Get-Date -UFormat $datefmtU
        } elseif ($datefmt -and -not $token) {
            $var = Get-Date -Format $datefmt
        }

        if ($padding) {
            $tpl = "{0,$padding}"
        } else {
            $tpl = '{0}'
        }

        return ($tpl -f $var)
    })
}


Function Add-LoggingLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $Level,
        [Parameter(Mandatory)]
        [string] $LevelName
    )

    if ($Level -notin $LevelNames.Keys -and $LevelName -notin $LevelNames.Keys) {
        $LevelNames[$Level] = $LevelName.ToUpper()
        $LevelNames[$LevelName] = $Level
    } elseif ($Level -in $LevelNames.Keys -and $LevelName -notin $LevelNames.Keys) {
        $LevelNames.Remove($LevelNames[$Level]) | Out-Null
        $LevelNames[$Level] = $LevelName.ToUpper()
        $LevelNames[$LevelNames[$Level]] = $Level
    } elseif ($Level -notin $LevelNames.Keys -and $LevelName -in $LevelNames.Keys) {
        $LevelNames.Remove($LevelNames[$LevelName]) | Out-Null
        $LevelNames[$LevelName] = $Level
    }
}

Function Set-LoggingDefaultLevel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    [CmdletBinding()]
    param()

    DynamicParam {
        $attributes = New-Object System.Management.Automation.ParameterAttribute
        $attributes.ParameterSetName = '__AllParameterSets'
        $attributes.Mandatory = $true
        $ValidateSetAttribute = New-Object System.Management.Automation.ValidateSetAttribute(Get-LevelsName)

        $attributeCollection = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
        $attributeCollection.Add($attributes)
        $attributeCollection.Add($ValidateSetAttribute)

        $dynParam1 = New-Object System.Management.Automation.RuntimeDefinedParameter('Level', [string], $attributeCollection)
        $dynParam1.Value = 'VERBOSE'

        $paramDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
        $paramDictionary.Add('Level', $dynParam1)
        return $paramDictionary
    }

    End {
        $Logging.Level = Get-LevelNumber -Level $PSBoundParameters.Level
    }
}


Function Get-LoggingDefaultLevel {
    [CmdletBinding()]
    param()

    return Get-LevelName -Level $Logging.Level
}


Function Get-LoggingDefaultFormat {
    [CmdletBinding()]
    param()

    return $Logging.Format
}


Function Set-LoggingDefaultFormat {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    [CmdletBinding()]
    param(
        [string] $Format = $Defaults.Format
    )
    Wait-Logging
    $Logging.Format = $Format
}


Function Get-LoggingTargetAvailable {
    [CmdletBinding()]
    param()

    return $LogTargets
}


Function Get-LoggingTarget {
    [CmdletBinding()]
    param()

    return $Logging.Targets
}

Function Initialize-LoggingTarget {
    [CmdletBinding()]
    param()

    $Targets = Get-ChildItem "$ScriptRoot\targets" -Filter '*.ps1'
    if ($Logging.CustomTargets) {
        if (Test-Path $Logging.CustomTargets) {
            $Targets += Get-ChildItem $Logging.CustomTargets -Filter '*.ps1'
        }
    }

    foreach ($Target in $Targets) {
        $Module = . $Target.FullName
        $LogTargets[$Module.Name] = @{
            Logger = $Module.Logger
            Description = $Module.Description
            Configuration = $Module.Configuration
            ParamsRequired = $Module.Configuration.GetEnumerator() | Where-Object {$_.Value.Required -eq $true} | Select-Object -ExpandProperty Name
        }
    }
}

Function Set-LoggingCustomTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({Test-Path -Path $_})]
        [string] $Path
    )
    Wait-Logging
    $Logging.CustomTargets = $Path
}


Function Assert-LoggingTargetConfiguration {
    [CmdletBinding()]
    param(
        $Target,
        $Configuration
    )

    $TargetName = $Target
    $TargetConf = $LogTargets[$Target]

    foreach ($Param in $TargetConf.ParamsRequired) {
        if ($Param -notin $Configuration.Keys) {
            throw ('Configuration {0} is required for target {2}; please provide one of type {1}' -f $Param, $TargetConf.Configuration[$Param].Type, $TargetName)
        }
    }

    foreach ($Conf in $Configuration.Keys) {
        if ($TargetConf.Configuration[$Conf] -and $Configuration[$Conf] -isnot $TargetConf.Configuration[$Conf].Type) {
            throw ('Configuration {0} has to be of type {1} for target {2}' -f $Conf, $TargetConf.Configuration[$Conf].Type, $TargetName)
        }
    }
}


Function Add-LoggingTarget {
    [CmdletBinding()]
    param(
        [Parameter(Position = 2)]
        [hashtable] $Configuration = @{}
    )

    DynamicParam {
        $attributes = New-Object System.Management.Automation.ParameterAttribute
        $attributes.ParameterSetName = '__AllParameterSets'
        $attributes.Mandatory = $true
        $attributes.Position = 1
        $ValidateSetAttribute = New-Object System.Management.Automation.ValidateSetAttribute($LogTargets.Keys)

        $attributeCollection = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
        $attributeCollection.Add($attributes)
        $attributeCollection.Add($ValidateSetAttribute)

        $NameParam = New-Object System.Management.Automation.RuntimeDefinedParameter('Name', [string], $attributeCollection)

        $DynParams = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
        $DynParams.Add('Name', $NameParam)

        return $DynParams
    }

    End {
        Assert-LoggingTargetConfiguration -Target $PSBoundParameters.Name -Configuration $Configuration
        $Logging.Targets[$PSBoundParameters.Name] = $Configuration
    }
}

Function Wait-Logging {
    [CmdletBinding()]
    [OutputType()]
    param()

    while ($MessageQueue.Count -gt 0) {
        Start-Sleep -Milliseconds 10
    }
}

Initialize-LoggingTarget

$InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$InitialSessionState.ApartmentState = 'MTA'

$InitialSessionState.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Replace-Token', (Get-Content Function:\Replace-Token)))
$InitialSessionState.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Initialize-LoggingTarget', (Get-Content Function:\Initialize-LoggingTarget)))
$InitialSessionState.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Get-LevelNumber', (Get-Content Function:\Get-LevelNumber)))

$InitialSessionState.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'ScriptRoot', $ScriptRoot, ''))
$InitialSessionState.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'Dispatcher', $Dispatcher, ''))
$InitialSessionState.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'LevelNames', $LevelNames, ''))
$InitialSessionState.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'LogTargets', $LogTargets, ''))
$InitialSessionState.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'Logging', $Logging, ''))
$InitialSessionState.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'MessageQueue', $MessageQueue, ''))
$InitialSessionState.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'ParentHost', $Host, ''))

$ScriptBlock = {
    $CustomTargets = $Logging.CustomTargets

    Initialize-LoggingTarget

    while ($Dispatcher.Flag -or $MessageQueue.Count -gt 0) {
        if ($CustomTargets -ne $Logging.CustomTargets) {
            $CustomTargets = $Logging.CustomTargets
            Initialize-LoggingTarget
        }

        if ($MessageQueue.Count -gt 0) {
            foreach ($Message in $MessageQueue) {
                if ($Logging.Targets.Count) {$Targets = $Logging.Targets}
                else {$Targets = $null}

                foreach ($TargetName in $Targets.Keys) {
                    $LoggerFormat = $Logging.Format
                    $LoggerLevel = Get-LevelNumber -Level $Logging.Level

                    $Target = $Targets[$TargetName]

                    if ($Target) {
                        if ($Target.Level) {$LoggerLevel = Get-LevelNumber -Level $Target.Level}
                        if ($Target.Format) {$LoggerFormat = $Target.Format}
                        $Configuration = $Target
                    }

                    if ($Message.LevelNo -ge $LoggerLevel) {
                        & $LogTargets[$TargetName].Logger $Message $LoggerFormat $Configuration
                    }
                }
                $MessageQueue.Remove($Message)
            }
        }
        Start-Sleep -Milliseconds 10
    }
}

$Dispatcher.Flag = $true
$Dispatcher.Host = $Host
$Dispatcher.RunspacePool = [RunspaceFactory]::CreateRunspacePool($InitialSessionState)
$Dispatcher.RunspacePool.SetMinRunspaces(1)
$Dispatcher.RunspacePool.SetMaxRunspaces([int] $env:NUMBER_OF_PROCESSORS + 1)
$Dispatcher.RunspacePool.Open()
$Dispatcher.Powershell = [Powershell]::Create().AddScript($ScriptBlock)
$Dispatcher.Powershell.RunspacePool = $Dispatcher.RunspacePool
$Dispatcher.Handle = $Dispatcher.Powershell.BeginInvoke()

#region Handle Module Removal
$ExecutionContext.SessionState.Module.OnRemove = {
    $Dispatcher.Flag = $false
    #Let sit for a second to make sure it has had time to stop
    Start-Sleep -Seconds 1
    if ($Dispatcher.Handle) {
        [void] $Dispatcher.PowerShell.EndInvoke($Dispatcher.Handle)
        [void] $Dispatcher.PowerShell.Dispose()
    }
    [System.GC]::Collect()
}
#endregion Handle Module Removal

# Exports
Export-ModuleMember -Function Add-LoggingLevel
Export-ModuleMember -Function Set-LoggingDefaultLevel
Export-ModuleMember -Function Get-LoggingDefaultLevel
Export-ModuleMember -Function Set-LoggingDefaultFormat
Export-ModuleMember -Function Get-LoggingDefaultFormat
Export-ModuleMember -Function Set-LoggingCustomTarget
Export-ModuleMember -Function Get-LoggingTargetAvailable
Export-ModuleMember -Function Get-LoggingTarget
Export-ModuleMember -Function Add-LoggingTarget
Export-ModuleMember -Function Write-Log
Export-ModuleMember -Function Wait-Logging
