@set cbsclear_args=%* & set cbsclear_self=%~f0& powershell -c "(gc \"%~f0\") -replace '@set cbsclear_args.*','#' | Write-Host" | powershell -c - & goto :eof

Write-Host "Just cleaner by den_po"

function GetAdminRights {
  $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = New-Object System.Security.Principal.WindowsPrincipal($Identity)
  if (!($Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)))
  {
    if ((Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System).EnableLua -ne 0)
    {
      Start-Process "$env:ComSpec" -verb runas -argumentlist "/c ""$env:cbsclear_self"" $env:cbsclear_args"
    }
    else
    {
      Write-Error "You must be administrator to run this script"
    }
    exit
  }
}

function GetDirLength ([string] $dirname) {
  $totallen = 0
  ls -recurse -force $dirname |% { $totallen = $totallen + $_.Length }
  return $totallen
}

function Get-ComProperty ($object, $PropertyName, $params) {
  return $object.GetType().InvokeMember($PropertyName, "GetProperty", $null, $object, $params)
}

function Invoke-ComMethod ($object, $PropertyName, $params) {
  return $object.GetType().InvokeMember($PropertyName, "InvokeMethod", $null, $object, $params)
}

function Get-Formatted ($b) {
  return $b.ToString('N0')
}


GetAdminRights

$total = 0
# CBS log ------------------------------------------------------

$wasStarted = (Get-Service -Name TrustedInstaller).Status -ieq "running"
if ($wasStarted) {
  Stop-Service TrustedInstaller
}

$cbslen = GetDirLength "$env:SystemRoot\logs\cbs"
Remove-Item "$env:SystemRoot\logs\cbs\*.*"
$cbslen = $cbslen - (GetDirLength "$env:SystemRoot\logs\cbs")
$total += $cbslen

if ($wasStarted) {
  Start-Service TrustedInstaller
}

# MSI patches --------------------------------------------------

$inst = New-Object -ComObject WindowsInstaller.Installer

$patchesList = @()
Get-ComProperty $inst Products @() |% {
  try {
    $patchesList += Get-ComProperty $inst ProductInfo @("$_", "LocalPackage")
  }
  catch {
  }

  Get-ComProperty $inst Patches $_ |% {
    try {
      $patchesList += Get-ComProperty $inst PatchInfo @("$_", "LocalPackage")
    }
    catch {
    }
  }
}

$msplen = 0
ls $env:windir\Installer\*.msi,$env:windir\Installer\*.msp |% {
  $curfilelen = $_.Length
  if ( -not ($patchesList -icontains $_.FullName) ) {

    try {
      $extDatabaseModes = @{
        ".MSI" = 0  #msiOpenDatabaseModeReadOnly
        ".MSP" = 32 #msiOpenDatabaseModePatchFile
      } 

      $instDB = Invoke-ComMethod $inst "OpenDatabase" @($_.FullName, $extDatabaseModes[[System.IO.Path]::GetExtension($_).ToUpper()])
      $mspSummaryInfo = Get-ComProperty $instDB "SummaryInformation"
      $mspInfo = Get-ComProperty $mspSummaryInfo "Property" @(3) #PIDSI_SUBJECT = 3
      if ( -not $mspInfo ) { $mspInfo= Get-ComProperty $mspSummaryInfo "Property" @(2) } #PIDSI_TITLE = 2
      if ( $mspInfo ) { $mspInfo = "`n    ("+$mspInfo+")" }
    }
    catch {
      $mspInfo = ""
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject([System.__ComObject]$instDB) | out-null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    
    Add-Type -AssemblyName Microsoft.VisualBasic
    Write-Host "Move to the Recycle Bin: "$_.FullName$mspInfo
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($_.FullName,'OnlyErrorDialogs','SendToRecycleBin')
    $msplen += $curfilelen
  }
}
$total += $msplen

# --------------------------------------------------------------
$myusername=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
function rmd([string]$fname) {
  takeown.exe /f "$fname" /r /d y | out-null
  icacls.exe "$fname" /grant $myusername":(F)" /T /C /Q | out-null
  remove-item -recurse -force $fname
}

function rmcontentgetlen([string]$fname) {
  $len = 0
  if( Test-Path $fname ) {
    $len = GetDirLength $fname
    ls -force $fname |% {
      rmd $_.FullName
    }
    $len = $len - (GetDirLength $fname)
  }
  return $len
}

if($env:cbsclear_args -imatch "hardcore") {

  #-WinSXS -----------------------------------------------------
  $sxsgroups = @{}
  ls "$env:windir\winsxs" |% {
    $m = [regex]::Match($_.Name,"^(.*_\d+\.\d+\.\d+\.)\d+(_.*?)_.*?$")
    if ($m.Success)
    {
      $key = $m.Groups[1].Value+"*"+$m.Groups[2].Value
      if(!$sxsgroups[$key]) {
        $sxsgroups[$key] = @{}
      }
      $sxsgroups[$key][$_.Name]=$_.FullName
    }
  }

  $sxslen = 0
  $sxsgroups.Keys |% {
    $group = $_
    $sxsgroups[$group].GetEnumerator() | Sort-Object Key -descending | select -skip 1 | select -skip 1 -last $sxsgroups[$group].count| Sort-Object Key |% {
      Write-Host "removing  "$_.Value
      $sxslen += GetDirLength $_.Value
      rmd $_.Value
    }
  }
  $total += $sxslen

  #-Downloaded Installations------------------------------------
  $dl1len = rmcontentgetlen "$env:windir\Downloaded Installations"
  $total += $dl1len

  #-SoftwareDistribution----------------------------------------
  $wuauservWasStarted = (Get-Service -Name wuauserv).Status -ieq "running"
  $bitsWasStarted = (Get-Service -Name bits).Status -ieq "running"
  if ($wuauservWasStarted) {
    Stop-Service wuauserv
  }
  if ($bitsWasStarted) {
    Stop-Service bits
  }
  $dl2len = rmcontentgetlen "$env:windir\SoftwareDistribution\Download"
  $total += $dl2len
  if ($wuauservWasStarted) {
    Start-Service wuauserv
  }
  if ($bitsWasStarted) {
    Start-Service bits
  }

  #-$PatchCache$------------------------------------------------
  $pcslen = rmcontentgetlen "$env:windir\Installer\`$PatchCache`$\Managed"
  $total += $pcslen

}

# --------------------------------------------------------------

if ( $total ) {
  Write-Host "MSI/MSP: "(Get-Formatted($msplen))" bytes"
  Write-Host "CBS:     "(Get-Formatted($cbslen))" bytes"
  if( $sxslen ) {
    Write-Host "WinSXS:  "(Get-Formatted($sxslen))" bytes"
  }
  if( $dl1len ) {
    Write-Host "DL1:     "(Get-Formatted($dl1len))" bytes"
  }
  if( $dl2len ) {
    Write-Host "DL2:     "(Get-Formatted($dl2len))" bytes"
  }
  if( $pcslen ) {
    Write-Host "PCache:  "(Get-Formatted($pcslen))" bytes"
  }
  Write-Host "`nTotal:   "(Get-Formatted($total))" bytes`n"
}

Write-Host -NoNewLine "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
