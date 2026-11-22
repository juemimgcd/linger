param([string]$Adapter, [string]$Probe = "qa470/fingerprint.py")
$ErrorActionPreference = 'Stop'
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "OS=$($os.Caption) build=$($os.BuildNumber) host=$([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
if ($os.Caption -notmatch 'Windows 11' -or $os.ProductType -ne 1) { throw 'Windows 11 client required' }
$pin = (Get-Content apps/desktop/distribution/win32-x64.json -Raw | ConvertFrom-Json).localmodelsTool
$dir = Join-Path $env:RUNNER_TEMP 'binding-dev45'
New-Item -ItemType Directory $dir -Force | Out-Null
$archive = Join-Path $dir 'kit.tgz'
curl.exe -fsSL --retry 3 $pin.mirrors[0] -o $archive
if ($LASTEXITCODE -ne 0 -or (Get-FileHash $archive).Hash -ne $pin.sha256) { throw 'Kit integrity check failed' }
tar.exe -xzf $archive -C $dir
if ($LASTEXITCODE -ne 0) { throw 'Kit extraction failed' }
$env:PYTHONPATH = Join-Path $dir 'package/modules'
$env:PYTHONDONTWRITEBYTECODE = '1'
& "$dir/package/python/python.exe" -P -s $Probe $Adapter
exit $LASTEXITCODE
