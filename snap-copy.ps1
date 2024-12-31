
$script:ReturnError = 0

function Main {
  #Load settings file and check variables
  $settings = Get-Settings

  Write-Log "Beginning script"

  #Create snapshot
  $newSnap = New-Snapshot -Drive $settings.SourceDrive

  #Abort if snapshot was not created
  if (!($newSnap)) {
    Write-Log "Failed to create snapshot"
    exit 20
  }

  #Mount the snapshot folder
  $mount = Mount-Snapshot -SnapshotID $newSnap -Drive $settings.SourceDrive
  
  #If the mount fails set a return error and skip the backup job
  if (!($mount)) {
    Write-Log "Failed to mount snapshot"
    $script:ReturnError = 1
  } else {

    #Run the ROBOCOPY job
    Write-Log "Running: robocopy /mir /np /ndl /log+:`"$script:logfile`" `"$mount\$($settings.SourcePath)`" `"$($settings.destinationPath)\backup`""
    $null = robocopy /mir /np /ndl /log+:"$script:logfile" "$mount\$($settings.SourcePath)" "$($settings.destinationPath)\backup"
    Write-Log "Finished ROBOCOPY result: $LASTEXITCODE"
    
    #Clean up the mount point
    Write-Log "Removing mount point"
    Remove-Item -Path $mount -Force -Recurse

  }

  #Delete Snapshot
  $result = Remove-Snapshot $newSnap

  #Sync Disk
  if ($settings.syncDrive) {
    Write-Log "Flushing cached data to disk for drive $($settings.syncDrive)"
    & $PSScriptRoot\bin\sync64.exe -accepteula -r $settings.syncDrive
  }

  #Write to log file if removing the snapshot failed
  if (!($result)) {
    Write-Log "Failed to delete snapshot $newSnap"
  }

  #Check how many Snapshots remain
  $shadows = Get-ShadowCopies -Drive $settings.SourceDrive
  if ($shadows.count -gt $settings.maxShadowCopies) {
    Write-Log "Warning, too many shadow copies left $($shadows.count) > $($settings.maxShadowCopies)"
    $script:ReturnError = 15
  }

  #Finish script
  Write-Log "Finished script"
  Write-Log "Exit code: $($script:ReturnError)"

  #Send email if configured
  if (($script:ReturnError -ne 0 -AND $settings.mail.sendOnFailure) -OR $settings.mail.sendOnSuccess) {
    Write-Host "Sending email..."
    Send-LogMessage -Settings $settings.mail -Message (Get-Content -Raw -Path $script:logfile)
  }

  #Exit
  exit $script:ReturnError
}

function Send-LogMessage {
param(
    [object]$Settings,
    [string]$Message
)
  Send-MailMessage `
  -SmtpServer $settings.smtpServer `
  -Subject $settings.subject `
  -To $settings.recipients `
  -From $settings.sender `
  -Body $message
}

function Get-Settings {
  Write-Host "Loading Settings"

  if (Test-Path "$PSScriptRoot\snap-copy-config.json") {
    Write-Host "Found settings file"
  } else {
    Write-Host "Failed to load settings file $PSScriptRoot\snap-copy-config.json"
    exit 11
  }
  
  #Load Settings
  $settings = Get-Content "$PSScriptRoot\snap-copy-config.json" | ConvertFrom-Json
  
  if (!($settings)) {
    
    #Exit and return error if the JSON file didn't parse
    Write-Error "Failed to parse settings file snap-copy-config.json"
    exit 12

  } else {

    #Check for valid settings
    if (!($settings.destinationPath -is [string])) { Write-Error "JSON setting error: destinationPath is not a string"; exit 20 }
    if (!($settings.sourceDrive -is [string])) { Write-Error "JSON setting error: sourceDrive is not a string"; exit 20 }
    if (!($settings.sourcePath -is [string])) { Write-Error "JSON setting error: sourcePath is not a string"; exit 20 }
    if (!($settings.maxShadowCopies -is [int])) { Write-Error "JSON setting error: maxShadowCopies is not an integer"; exit 20 }
    if (!($settings.mail.sendOnFailure -is [bool])) { Write-Error "JSON setting error: mail.sendOnFailure is not true or false"; exit 20 }
    if (!($settings.mail.sendOnSuccess -is [bool])) { Write-Error "JSON setting error: mail.sendOnSuccess is not true or false"; exit 20 }


    #Make sure we can access the destination path
    if (!(Test-Path -Path $settings.destinationPath)) {
      $ParseError = "Cannot access $($settings.destinationPath). Aborting copy!"
      $script:ReturnError = 16
    } else {
      #Set log file path
      $datestamp = get-date -Format "yyyy-MM-dd-hh-mm-ss"
      $script:logfile = "$($settings.destinationPath)\backup-log-$datestamp.txt"
      Write-Host "Log file path: $script:logfile"
    }

    #Make sure we have a valid sourceDrive
    if ($settings.sourceDrive.length -ne 2) {
      $ParseError = "Invalid source drive $($settings.sourceDrive)"
      $script:ReturnError = 17
    }

    if (!(Test-Path -Path $settings.sourceDrive)) {
      $ParseError = "Failed to find source drive $($settings.sourceDrive)"
      $script:ReturnError = 18
    }

    #Make sure our sourcePath is a valid folder
    if (!(Test-Path -Path "$($settings.sourceDrive)\$($settings.sourcePath)")) {
      $ParseError = "Failed to find source folder $($settings.sourceDrive)\$($settings.sourcePath)"
      $script:ReturnError = 19
    }
  }

  if ($script:ReturnError -ne 0) {
    Send-LogMessage -Settings $settings.mail -Message $ParseError
    Write-Error $ParseError
    exit $script:ReturnError
  }
  return $settings
}
function Get-ShadowCopies {
param(
  [string]$Drive
)
  $shadows = vssadmin list shadows /for=$Drive
  $idlines= $shadows -match "Shadow Copy ID"
  $shadowids = $idlines -replace '.* Shadow Copy ID\: (.*)','$1'
  Write-Log -Text "There are $(@($shadowids).count) shadow copies for $sourceDrive"
  $shadowObjects = Get-WmiObject win32_shadowcopy | Where-Object ID -in $shadowids
  return $shadowObjects
}

function New-Snapshot {
param(
  [string]$Drive
)
  $result = (gwmi -list win32_shadowcopy).Create("$Drive\",'ClientAccessible')
  if ($result.ReturnValue -eq 0) {
    Write-Log "Successfully created Snapshot for $Drive"
    return $result.ShadowID
  } else {
    Write-Log "Failed to create Snapshot for $Drive. ReturnValue: $($result.ReturnValue)"
    $script:ReturnError = 2
    return $false
  }
}

function Remove-Snapshot {
param(
  [string]$SnapshotID
)
  Write-Log "Attempting to delete Snapshot ID $SnapshotID"
  $Snapshot = Get-WmiObject win32_shadowcopy | Where-Object ID -eq $SnapshotID
  if ($Snapshot) {
    try {
      $result = $Snapshot.Delete()
    }
    catch {
      Write-Log "An error occured deleting the snapshot"
      $script:ReturnError = 3
      return $false
    }
    return $true
  } else {
    Write-Log "No Snapshot was found with ID $SnapshotID"
    $script:ReturnError = 3
    return $false
  }
}

function Mount-Snapshot {
param (
  [string]$SnapshotID,
  [string]$Drive
)
  $shadow = Get-WmiObject win32_shadowcopy | Where-Object ID -eq $SnapshotID
  if ($shadow) {
    if (Test-Path "$Drive\$SnapshotID") {
      Write-Log "Path already exists: $Drive\$SnapshotID"
    } else {
      $result = cmd /c MKLINK /D $Drive\$SnapshotID "$($shadow.DeviceObject)\"
      if ($result -match "symbolic link created") {
        Write-Log "Successfully mounted snapshot $SnapshotID"
        return "$Drive\$SnapshotID"
      }
    }
  } else {
    Write-Log "Failed to find snapshot $SnapshotID"
    $script:ReturnError = 4
    return $false
  }

}



function Write-Log {
param(
  [string]$Text,
  [int]$Level
)
  $Time = get-date -Format "yyyy-MM-dd-hh-mm-ss"
  Write-Host $Text
  "$time[$Level]: $Text" | Out-File -Append -FilePath $script:logfile -Encoding utf8
}

Main