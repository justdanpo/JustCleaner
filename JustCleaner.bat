@set cbsclear_args=%* & set cbsclear_self=%~f0& powershell -c "(gc \"%~f0\") -replace '@set cbsclear_args.*','#' | Write-Host" | powershell -c - & goto :eof

Write-Host "Just cleaner by den_po"

function GetAdminRights {
  $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = New-Object System.Security.Principal.WindowsPrincipal($Identity)
  if (!($Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)))
  {
    if ((Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System).EnableLua -ne 0)
    {
      Start-Process "$env:ComSpec" -verb runas -argumentlist "/c ""$env:cbsclear_self"""
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
  ls $dirname |% { $totallen = $totallen + $_.Length }
  return $totallen
}

function Get-ComProperty ($object, $PropertyName, $params) {
  return $object.GetType().InvokeMember($PropertyName, "GetProperty", $null, $object, $params)
}

function Get-Formatted ($b) {
  return $b.ToString('N0')
}


GetAdminRights

# CBS log ------------------------------------------------------

$wasStarted = (Get-Service -Name TrustedInstaller).Status -ieq "running"
if ($wasStarted) {
  Stop-Service TrustedInstaller
}

$cbslen = GetDirLength "$env:SystemRoot\logs\cbs\*.*"
Remove-Item "$env:SystemRoot\logs\cbs\*.*"
$cbslen = $cbslen - (GetDirLength "$env:SystemRoot\logs\cbs\*.*")

if ($wasStarted) {
  Start-Service TrustedInstaller
}

# MSI patches --------------------------------------------------

$inst = New-Object -ComObject WindowsInstaller.Installer

$patchesList = @()
Get-ComProperty $inst Products @() |% {
  Get-ComProperty $inst Patches $_ |% {
    $patchesList += Get-ComProperty $inst PatchInfo @("$_", "LocalPackage")
  }
}

$msplen = 0
ls $env:windir\Installer\*.msp |% {
  $curfilelen = $_.Length
  if ( -not ($patchesList -icontains $_.FullName) ) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    Write-Host "Move to the Recycle Bin: "$_.FullName
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($_.FullName,'OnlyErrorDialogs','SendToRecycleBin')
    $msplen += $curfilelen
  }
}

# --------------------------------------------------------------

if ( $msplen+$cbslen ) {
  Write-Host "MSP:   "(Get-Formatted($msplen))" bytes"
  Write-Host "CBS:   "(Get-Formatted($cbslen))" bytes"
  Write-Host "`nTotal: "(Get-Formatted($msplen+$cbslen))" bytes`n"
}

Write-Host -NoNewLine "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
