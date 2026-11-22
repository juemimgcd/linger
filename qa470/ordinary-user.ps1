param([string]$Worker, [string]$Scratch, [string]$Digest)
$ErrorActionPreference = 'Stop'
if ($Worker) {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  if ($id.User.Value -ne $Worker -or ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'An ordinary user is required' }
  # Alternate credentials load the profile hive, but Start-Process inherits
  # the orchestrator's environment. Resolve Windows known folders as that user.
  $env:USERPROFILE = [Environment]::GetFolderPath('UserProfile')
  $env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData')
  $env:APPDATA = [Environment]::GetFolderPath('ApplicationData')
  $env:TEMP = Join-Path $env:LOCALAPPDATA Temp
  $env:TMP = $env:TEMP
  $env:USERNAME = $id.Name.Split('\')[-1]
  if ((Split-Path $env:USERPROFILE -Leaf) -notlike "$($env:USERNAME)*" -or !$env:LOCALAPPDATA.StartsWith("$env:USERPROFILE\", [StringComparison]::OrdinalIgnoreCase)) { throw 'Known folders do not belong to the ordinary user' }
  [IO.Directory]::CreateDirectory($env:TEMP) | Out-Null
  $app = Join-Path $env:LOCALAPPDATA 'Programs/Linger/Linger.exe'
  if (Test-Path $app) { throw 'An empty profile is required' }
  $setup = Join-Path $Scratch Setup.exe
  if ((Get-FileHash $setup).Hash -ne $Digest) { throw 'Unexpected Setup binary' }
  $p = Start-Process $setup -ArgumentList '/S' -PassThru
  if (!$p.WaitForExit(240000) -or $p.ExitCode -ne 0) { throw 'Ordinary-user installation failed' }
  $env:ELECTRON_RUN_AS_NODE = '1'
  $env:LINGER_HOME = Join-Path $env:LOCALAPPDATA 'LingerPackageSmoke'
  Write-Host "Non-admin: Setup exited 0; installed package version=$((Get-Item $app).VersionInfo.ProductVersion)"
  & $app (Join-Path $Scratch 'windows-pi-smoke.mjs') | Out-Host
  exit $LASTEXITCODE
}
$name = 'LingerQA' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$stage = Join-Path $env:ProgramData $name
$password = ConvertTo-SecureString ('Aa9!' + [Guid]::NewGuid().ToString('N')) -AsPlainText -Force
$user = New-LocalUser -Name $name -Password $password
try {
  New-Item -ItemType Directory $stage | Out-Null
  & icacls.exe $stage /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' "*$($user.SID.Value):(OI)(CI)RX" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Staging ACL failed' }
  $setup = Get-ChildItem candidate/*-setup.exe
  $line = Get-Content candidate/SHA256SUMS | Where-Object { $_.EndsWith($setup.Name) }
  if (!$line) { throw 'Setup digest missing' }
  $hash = ($line -split '\s+')[0]
  Copy-Item $PSCommandPath,scripts/ci/windows-pi-smoke.mjs -Destination $stage
  Copy-Item $setup.FullName (Join-Path $stage Setup.exe)
  $argsList = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$stage/ordinary-user.ps1`" -Worker $($user.SID.Value) -Scratch `"$stage`" -Digest $hash"
  $credential = [pscredential]::new("$env:COMPUTERNAME\$name",$password)
  $stdout = Join-Path $stage stdout.log
  $stderr = Join-Path $stage stderr.log
  $p = Start-Process (Join-Path $PSHOME pwsh.exe) -Credential $credential -LoadUserProfile -WorkingDirectory $stage -ArgumentList $argsList -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $null = $p.Handle
  $done = $p.WaitForExit(1140000)
  Get-Content $stdout,$stderr -Tail 40
  if (!$done -or $p.ExitCode -ne 0) { throw "Ordinary-user smoke failed (exit $($p.ExitCode))" }
} finally {
  Remove-LocalUser -SID $user.SID
}
