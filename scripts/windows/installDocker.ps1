param(
    [ValidateNotNullOrEmpty()]
    [String]$DockerParentUrl = "https://master.dockerproject.org/windows/x86_64/"
)

$global:AdminPriviledges = $false
$global:DockerDataPath = Join-Path -Path $env:ProgramData -ChildPath "docker"
$global:DockerServiceName = "docker"

function
Copy-File
{
    [CmdletBinding()]
    param(
        [string]
        $SourcePath,
        
        [string]
        $DestinationPath
    )

    $currentSourcePath = $SourcePath
    
    try
    {
        if ($currentSourcePath -eq $DestinationPath)
        {
            return
        }
            
        if (Test-Path $currentSourcePath)
        {
            Copy-Item -Path $currentSourcePath -Destination $DestinationPath
        }
        elseif (($currentSourcePath -as [System.URI]).AbsoluteURI -ne $null)
        {
            # Ensure that all secure protocols are enabled (TLS 1.2 is not by default in some cases).
            $secureProtocols = @()
            $insecureProtocols = @([System.Net.SecurityProtocolType]::SystemDefault, [System.Net.SecurityProtocolType]::Ssl3)

            foreach ($protocol in [System.Enum]::GetValues([System.Net.SecurityProtocolType]))
            {
                if ($insecureProtocols -notcontains $protocol)
                {
                    $secureProtocols += $protocol
                }
            }

            [System.Net.ServicePointManager]::SecurityProtocol = $secureProtocols

            if ($PSVersionTable.PSVersion.Major -ge 5)
            {
                #
                # We disable progress display because it kills performance for large downloads (at least on 64-bit PowerShell)
                #
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $currentSourcePath -OutFile $DestinationPath -UseBasicParsing
                $ProgressPreference = 'Continue'
            }
            else
            {
                $webClient = New-Object System.Net.WebClient
                $webClient.DownloadFile($currentSourcePath, $DestinationPath)
            }
        }
        else
        {
            throw "Cannot copy from $currentSourcePath"
        }

        # If we get here, we've successfuly copied a file.
        return
    }
    catch
    {
        $innerException = $_
    }

    throw $innerException
}

function 
Test-Admin()
{
    # Get the ID and security principal of the current user account
    $myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
    $myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
  
    # Get the security principal for the Administrator role
    $adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
  
    # Check to see if we are currently running "as Administrator"
    if ($myWindowsPrincipal.IsInRole($adminRole))
    {
        $global:AdminPriviledges = $true
        return
    }
    else
    {
        #
        # We are not running "as Administrator"
        # Exit from the current, unelevated, process
        #
        throw "You must run this script as administrator"   
    }
}

function 
Start-Docker()
{
    Start-Service -Name $global:DockerServiceName
}

function 
Wait-Docker()
{
    Write-Output "Waiting for Docker daemon..."
    $dockerReady = $false
    $startTime = Get-Date

    while (-not $dockerReady)
    {
        try
        {
            docker version | Out-Null

            if (-not $?)
            {
                throw "Docker daemon is not running yet"
            }

            $dockerReady = $true
        }
        catch 
        {
            $timeElapsed = $(Get-Date) - $startTime

            if ($($timeElapsed).TotalMinutes -ge 1)
            {
                throw "Docker Daemon did not start successfully within 1 minute."
            } 

            # Swallow error and try again
            Start-Sleep -sec 1
        }
    }
    Write-Output "Successfully connected to Docker Daemon."
}

function 
Install-Docker()
{
    [CmdletBinding()]
    param(
        [string]
        [ValidateNotNullOrEmpty()]
        $DockerPath = $DockerParentUrl + "docker.exe",

        [string]
        [ValidateNotNullOrEmpty()]
        $DockerDPath = $DockerParentUrl + "dockerd.exe"
    )

    Test-Admin

    Write-Output "Installing Docker..."
    Copy-File -SourcePath $DockerPath -DestinationPath $env:windir\System32\docker.exe
        
    Write-Output "Installing Docker daemon..."
    Copy-File -SourcePath $DockerDPath -DestinationPath $env:windir\System32\dockerd.exe
    
    $dockerConfigPath = Join-Path $global:DockerDataPath "config"
    
    if (!(Test-Path $dockerConfigPath))
    {
        md -Path $dockerConfigPath | Out-Null
    }

    #
    # Register the docker service.
    # Configuration options should be placed at %programdata%\docker\config\daemon.json
    #
    $daemonSettings = New-Object PSObject
        
    # Default local host
    $daemonSettings | Add-Member NoteProperty hosts @("npipe://")

    $daemonSettingsFile = Join-Path $dockerConfigPath "daemon.json"

    $daemonSettings | ConvertTo-Json | Out-File -FilePath $daemonSettingsFile -Encoding ASCII
    
    & dockerd --register-service --service-name $global:DockerServiceName

    Start-Docker

    #
    # Waiting for docker to come to steady state
    #
    Wait-Docker

    Write-Output "The following images are present on this machine:"
    
    docker images -a | Write-Output

    Write-Output ""
}

Write-Host "Installing Docker"
Install-Docker

Write-Host "Done!"