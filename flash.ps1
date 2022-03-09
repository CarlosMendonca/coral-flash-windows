<#
.SYNOPSIS
    Flashes Coral boards with supplied partition image files.
.PARAMETER DontReboot
    Prevents the automatic reboot of the connected board .
.PARAMETER OverwriteHomePartition
    Overwrites the home partition if one is detected (defaults to false).
.PARAMETER FilesDir
    Flashes files from $FilesDir (defaults to current dir).
.PARAMETER SerialNumber
    Only flashes the board with the given fastboot serial number.
.PARAMETER DetectRetries
    Number of times to retry waiting for a device (defaults to 0).
.PARAMETER Arch
    Sets the name of the userspace to flash (defaults to arm64).
.PARAMETER PathToFastBoot
    Uses fastboot specificed on $FastbootFilePath (defaults to fastboot.exe, on current dir or PATH).
.PARAMETER FlashTimeout
    Allows setting a longer timeout (in milliseconds) for flashing the board (defaults to 300000 or 5 minutes).
.EXAMPLE
    PS> .\flash.ps1
#>

param (
    [Alias('n')][switch]$DontReboot = $false,
    [Alias('H')][switch]$OverwriteHomePartition = $false,
    [Alias('d')]
        [string]
        [ValidateScript({ if (-not ($_ | Test-Path ) -or ($_ | Test-Path -PathType Leaf)) { throw "Folder ${_} does not exist" } return $true })]
        $FilesDir = '.\',
    [Alias('s')][string]$SerialNumber,
    [Alias('r')][int][ValidateRange(0,99)]$DetectRetries = 0,
    [Alias('u')][string]$Arch = 'arm64',
    [Alias('fb')]
        [string]
        [ValidateScript({ if (-not ($_ | Test-Path )) { throw "File ${_} does not exist" } return $true })]
        $PathToFastBoot = 'fastboot.exe',
    [Alias('fto')][int]$FlashTimeout = 300000 # 5 minutes of default timeout for flashing operations (flashing the last image takes a particularly long time)
)

Clear-Host


function Die([string]$message) {
    Write-Error $message
    exit 1
}

function DetectDeviceOrDie() {
    $totalIterations = $DetectRetries + 1
    Write-Host "Waiting up to ${totalIterations} second(s) for device '${SerialNumber}' to be detected by fastboot..."

    for ($counter = 0; $counter -lt $totalIterations; $counter++) {
        Start-Sleep -Milliseconds 1000

        $processResult = TryExecuteFastboot 'devices' -1 # this should not trigger a progress bar, which is not necessary since we're already showing one here
    
        if ($processResult.StandardOutput.Contains($SerialNumber)) {
            Write-Host "Found device ${SerialNumber}."
            return
        }

        $percentage = 100*$counter/$totalIterations;
        Write-Progress -Activity "Detecting devices..." -Status "$([math]::truncate($percentage))% complete:" -PercentComplete $percentage;
    }

    # Didn't detect it
    Die "Could NOT find device with serial '${SerialNumber}' in fastboot output."
}

function EnsureFlashFilesPresent {
    $files = (
        "u-boot.imx",
        "home.img",
        "partition-table-8gb.img",
        "partition-table-16gb.img",
        "partition-table-64gb.img",
        "boot_${Arch}.img",
        "rootfs_${Arch}.img")
    
    $foundAllFiles = $true;

    foreach ($file in $files) {
        if (-not (Join-Path $FilesDir $file | Test-Path)) {
            Write-Host "${file} is missing from ${FilesDir}."
            $foundAllFiles = $false
        }
    }

    if (-not $foundAllFiles) {
        Die "Required image files are missing. Cannot continue."
    }
    else {
        Write-Verbose "Found all $($files.Length) partition image files on '${FilesDir}'."
    }
}
function PartitionTableImage {
    [Int64]$emmcSize = GetEmmcSize

    if (($emmcSize -gt 7000000000) -and ($emmcSize -lt 8000000000)) {
        return "partition-table-8gb.img"
    }
    elseif (($emmcSize -gt 14000000000) -and ($emmcSize -lt 17000000000)) {
        return "partition-table-16gb.img"
    }
    elseif ($emmcSize -gt 60000000000) {
        return "partition-table-64gb.img"
    }
    else {
        Die "Unsupported emmc size. Fastboot reported $($emmcSize)."
    }
}

function PartitionPresent([string]$partition) {
    $processResult = TryExecuteFastboot "getvar partition-type:${partition}"

    return -not ($processResult.StandardOutput.Contains("FAILED"))
}

function GetEmmcSize {
    $processResult = TryExecuteFastboot 'getvar mmc_size'

    try {
        Write-Verbose "Trying to parse '$($processResult.StandardError)'..."
        $mmcSize = $processResult.StandardError.Split([Environment]::NewLine)[0].Split(' ')[1]
        Write-Verbose "Parse result is '$($mmcSize)'. Will try to convert to a 64-bit integer..."
        return $mmcSize.ToInt64($null)
    }
    catch {
        Write-Error "Can NOT get emmc size. Output was '$($processResult.StandardError)'.)"
        throw
    }
}

function Flash([string]$partition, [string]$file) {
    $fullPathToFile = (Resolve-Path $file).Path
    TryExecuteFastboot "flash ${partition} ${fullPathToFile}" $FlashTimeout | Out-Null
}

function ErasePartition([string]$partition) {
    TryExecuteFastboot "erase ${partition}" | Out-Null
}

function FlashPartitions {

    Write-Verbose 'Determining correct image file based on EMMC size.'
    $partitionTableImageFile = PartitionTableImage
    Write-Verbose "Will use ${partitionTableImageFile}"

    if (-not (Join-Path $FilesDir $partitionTableImageFile | Test-Path)) {
        Write-Host "${partitionTableImageFile} is missing from ${FilesDir}."
    }

    if ((PartitionPresent 'home')) {
        if ($OverwriteHomePartition) {
            Write-Host 'Existing home partition detected, but will overwrite it as requested. Data on home partition will be lost!'
        }
        else {
            Write-Host 'Existing home partition detected and will NOT flash home. This can be overriden with -H.'
        }
    }
    else {
        Write-Host 'No home partition detected. Will flash the home partition image.'
        $OverwriteHomePartition = $true # set the switch
    }

    Flash 'bootloader0' (Join-Path $FilesDir 'u-boot.imx')
    TryExecuteFastboot 'reboot-bootloader' | Out-Null
    Start-Sleep -Milliseconds 3000

    Flash 'gpt' (Join-Path $FilesDir $partitionTableImageFile)
    TryExecuteFastboot 'reboot-bootloader' | Out-Null
    Start-Sleep -Milliseconds 3000

    ErasePartition 'misc'

    if ($OverwriteHomePartition) {
        Flash 'home' (Join-Path $FilesDir 'home.img')
    }

    Flash 'boot' (Join-Path $FilesDir "boot_${Arch}.img")
    Flash 'rootfs' (Join-Path $FilesDir "rootfs_${Arch}.img")
}

# Default timeout to 10s, because fastboot, for the most part, waits indefinitely for devices, hanging the script
function TryExecuteFastboot([string]$fastbootParameters, [int]$timeout = 2000) {
    $showProgress = ($timeout -ge 10000)

    $processResult = ExecuteCommand $PathToFastBoot ($fastbootSerialNumberFilter + $fastbootParameters) $timeout $showProgress
    
    if ($processResult.HasTimedOut) {
        Die "Fastboot timed out after $($processResult.Timeout) milliseconds. Error output was '$($processResult.StandardError)' and standard output was '$($processResult.StandardOutput)'."
    }
    
    if ($processResult.ExitCode -ne 0) {
        Die "Unable to communicate with fastboot. Nonzero ($($processResult.ExitCode)) exit. Error output was '$($processResult.StandardError)'."
    }

    return $processResult
}

function ExecuteCommand([string]$commandPath, [string]$commandArguments, [int]$timeout = -1, [bool]$showProgress) {
    [int]$timeResolution = 500
    if ($timeout -ge 10000 -and (-not $showProgress)) {
        Write-Verbose "Executing '${commandPath}' with a long timeout (${timeout}); consider showing progress next time for a better user experience."
    }

    try {
        Write-Host "Trying to execute '${commandPath}' with args '${commandArguments}' and timeout set to ${timeout}..."

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $commandPath
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.Arguments = $commandArguments
        # $psi.WorkingDirectory = $pwd

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi

        $hasTimedOut = $false
        $p.Start()

        $standardOutputTask = $p.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $p.StandardError.ReadToEndAsync()

        if ($showProgress) {
            for ($timer = $timeout; $timer -ge 0; $timer -= $timeResolution) {
                Start-Sleep -Milliseconds $timeResolution

                Write-Progress -Activity "Running ${commandPath}..." -Status "$([math]::truncate($timer/1000))s remaining:" -PercentComplete (100*$timer/$timeout)

                if ($p.HasExited) {
                    Write-Host 'Command finished.'
                    break
                }
            }
            Write-Host 'Command timed out.'
        }
        else {
            $p.WaitForExit($timeout)
        }

        if (-not $p.HasExited) {
            Write-Verbose "Command '${commandPath}' (PID=$($p.Id)) with arguments '${commandArguments}' has timed out after ${timeout} milliseconds and will be killed."
            Write-Verbose "Killing PID=$($p.Id)..."
            $hasTimedOut = $true
            $p.Kill()
        }

        $processResult = [PSCustomObject]@{
            CommandPath = $commandPath
            Args = $commandArguments
            HasTimedOut = $hasTimedOut
            Timeout = $timeout
            StandardOutput = $standardOutputTask.Result.Trim()
            StandardError = $standardErrorTask.Result.Trim()
            ExitCode = $p.ExitCode
        }

        return $processResult
    }
    catch {
        Write-Error "Exception thrown trying to execute '${commandPath}' with arguments '${commandArguments}'."
        throw
    }
    finally {
        if ($null -ne $p -and (-not $p.HasExited)) {
            Write-Verbose "Killing PID=$($p.Id)..."
            $p.Kill()
        }
    }
}

#
# Main
#

if ($PSBoundParameters.ContainsKey('PathToFastBoot')) {
    # User is specifying a fastboot executable
    if (Get-Command $PathToFastBoot -ErrorAction Ignore) {
        # Command points to an executable that might be fastboot, so get the full path for the Process class
        $PathToFastBoot = Resolve-Path $PathToFastBoot
        Write-Verbose "Fastboot found in '${PathToFastBoot}'."
    }
    else {
        Die "'${PathToFastBoot}' is not a valid path to fastboot.exe. Make sure you're providing a valid path to the fastboot executable, not the folder where it's located."
    }
}
else {
    # User didn't specify a fastboot executable; look for one in PATH
    if (Get-Command $PathToFastBoot -ErrorAction Ignore) { # since the user didn't specify the parameter, using the default value defined in the param section
        Write-Verbose "Fastboot found in PATH."
    }
    else {
        Die 'Could NOT find fastboot.exe on your PATH variable. Did you install it and added it to PATH? You can also specify an executable with -fb.'
    }
}

# Enforce serial number filtering option
if ($PSBoundParameters.ContainsKey('SerialNumber')) {
    $fastbootSerialNumberFilter = "-s ${SerialNumber} "
    Write-Verbose "Will request fastboot to filter for device with serial number ${SerialNumber}." }
else {
    $fastbootSerialNumberFilter = ''
    Write-Verbose "Will NOT request fastboot to filter for a specific serial number."
}

if ($PSBoundParameters.ContainsKey('SerialNumber')) {
    Write-Verbose "Will try to detect device."
    DetectDeviceOrDie
}
else {
    Write-Verbose "Will NOT try to detect device. No serial number specified."
}

# Check for image files
Write-Verbose "Will now check for partition image files."
EnsureFlashFilesPresent

Write-Verbose "Will now flash partitions."
FlashPartitions

if (-not $DontReboot) {
    Write-Verbose "Will now reboot the board."
    TryExecuteFastboot 'reboot' | Out-Null
}
else {
    Write-Host 'Skipping reboot as requested. Manual reboot will be required.'
}

Write-Host 'Flash completed.'