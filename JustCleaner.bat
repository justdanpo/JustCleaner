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

if ( $total ) {
  Write-Host "MSI/MSP: "(Get-Formatted($msplen))" bytes"
  Write-Host "CBS:     "(Get-Formatted($cbslen))" bytes"
  Write-Host "`nTotal:   "(Get-Formatted($total))" bytes`n"
}

Write-Host -NoNewLine "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
