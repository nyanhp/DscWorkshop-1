param
(
    # Project path
    [Parameter()]
    [System.String]
    $ProjectPath = (property ProjectPath $BuildRoot),

    # Source path
    [Parameter()]
    [System.String]
    $SourcePath = (property SourcePath 'source'),

    [Parameter()]
    # Base directory of all output (default to 'output')
    [System.String]
    $OutputDirectory = (property OutputDirectory (Join-Path -Path $BuildRoot -ChildPath output)),

    [Parameter()]
    [string]
    $DatumConfigDataDirectory = (property DatumConfigDataDirectory 'source'),

    [Parameter()]
    [string]
    $DscV3OutputFolder = (property DscV3OutputFolder 'DscV3'),

    # Build Configuration object
    [Parameter()]
    [System.Collections.Hashtable]
    $BuildInfo = (property BuildInfo @{ })
)

task CreateDscVersion3 {
    . Set-SamplerTaskVariable -AsNewBuild

    if (-not $BuildInfo.'Sampler.DscPipeline')
    {
        Write-Error -Message "There are no modules to import defined in the 'build.yml'. Expected the element 'Sampler.DscPipeline'"
    }
    if (-not $BuildInfo.'Sampler.DscPipeline'.DscCompositeResourceModules)
    {
        Write-Error -Message "There are no modules to import defined in the 'build.yml'. Expected the element 'Sampler.DscPipeline'.DscCompositeResourceModules"
    }
    if ($BuildInfo.'Sampler.DscPipeline'.DscCompositeResourceModules.Count -lt 1)
    {
        Write-Error -Message "There are no modules to import defined in the 'build.yml'. Expected at least one module defined under 'Sampler.DscPipeline'.DscCompositeResourceModules"
    }

    $DscV3OutputFolder = Get-SamplerAbsolutePath -Path $DscV3OutputFolder -RelativeTo $OutputDirectory

    #Compiling DSC V3 Configuration YAMLs from RSOP cache
    $rsopCache = Get-DatumRsopCache

    if ($node.Value.Ansible)
    {
        continue
    }

    $cd = @{}
    foreach ($node in $rsopCache.GetEnumerator())
    {
        $cd.AllNodes += @([hashtable]$node.Value)
    }

    $originalPSModulePath = $env:PSModulePath
    try
    {
        $env:PSModulePath = ($env:PSModulePath -split [System.IO.Path]::PathSeparator).Where({
                $_ -notmatch ([regex]::Escape('powershell\7\Modules')) -and
                $_ -notmatch ([regex]::Escape('Program Files\WindowsPowerShell\Modules')) -and
                $_ -notmatch ([regex]::Escape('Documents\PowerShell\Modules'))
            }) -join [System.IO.Path]::PathSeparator

        if (-not (Test-Path -Path $DscV3OutputFolder))
        {
            $null = New-Item -ItemType Directory -Path $DscV3OutputFolder
        }

        Write-Build Green -Object "Loading available resources"
        $resources = $BuildInfo.'Sampler.DscPipeline'.DscCompositeResourceModules | Foreach-Object { Get-DscResource -Module $_ }
        $ignoredKeys = @( # Mostly to ensure that the key environment does not accidentally get used as a resource name
            'Environment'
            'Location'
            'NodeName'
            'Name'
            'Role'
        )

        if ($cd.AllNodes)
        {
            $configYamls = foreach ($singleNode in $cd.AllNodes)
            {
                $resultYaml = @{
                    '$schema' = 'https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json'
                    resources = [System.Collections.ArrayList]::new()
                }

                foreach ($key in ($singleNode.Keys | Where-Object { $_ -in $resources.Name -and $_ -notin $ignoredKeys }))
                {
                    $moduleName = $resources.Where({ $_.Name -eq $key }).Module.Name

                    if ($null -eq $moduleName)
                    {
                        continue
                    }
                    $null = $resultYaml.resources.Add(
                        @{
                            name       = $key
                            type       = ('{0}/{1}' -f $moduleName, $key)
                            properties = $singleNode[$key]
                        }
                    )
                }

                $resultYaml | ConvertTo-Yaml -Force -OutFile (Join-Path -Path $DscV3OutputFolder -ChildPath "$($nodeEnvironment.Key)/$($singleNode.Name).yaml")
                Get-Item (Join-Path -Path $DscV3OutputFolder -ChildPath "$($nodeEnvironment.Key)/$($singleNode.Name).yaml")

            }

            if ($cd.AllNodes.Count -ne $configYamls.Count)
            {
                Write-Warning -Message 'Compiled DSC V3 Configuration YAMLs file count <> node count'
            }

            Write-Build Green "Successfully compiled $($configYamls.Count) DSC V3 Configuration YAMLs files."
        }
        else
        {
            Write-Build Green 'No data to compile DSC V3 Configuration YAMLs files'
        }
    }
    finally
    {
        $env:PSModulePath = $originalPSModulePath
    }
}
