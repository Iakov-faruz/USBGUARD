param(
    [string]$Output = "CODE_BUNDLE.txt",
    [bool]$IncludeWeb = $true
)

$ErrorActionPreference = "SilentlyContinue"
$root = $PSScriptRoot
if (-not $root) { $root = Get-Location }
$root = Resolve-Path $root

$excludeDirs = @('.git', '.kilo', '.pytest_cache', '__pycache__', 'node_modules', '.venv', 'venv')
if (-not $IncludeWeb) { $excludeDirs += 'web' }

$excludePathContains = @('/venv/', '/.venv/', '/site-packages/', '/__pycache__/', '/.git/', '/.kilo/', '/node_modules/', '/.pytest_cache/')

# סינון קשיח: רק סיומות אלו ייכללו
$allowedExt = @('.sh','.py','.yaml','.yml','.json','.txt','.md','.service','.timer','.rules','.conf','.html','.css','.js','.ini','.pyw','.csv','.rst','.sudoers','.desktop','.svg','Makefile','Dockerfile','.env','LICENSE','README','CHANGELOG','AUTHORS')

function Test-Allowed {
    param([string]$RelPath)
    $RelPath = $RelPath.Replace('\', '/')
    foreach ($d in $excludeDirs) {
        if ($RelPath -eq $d -or $RelPath.StartsWith("$d/")) { return $false }
    }
    foreach ($c in $excludePathContains) {
        if ($RelPath.Contains($c)) { return $false }
    }
    $fileName = [System.IO.Path]::GetFileName($RelPath)
    $fileExt = [System.IO.Path]::GetExtension($fileName).ToLower()
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName).ToLower()
    
    if ($fileExt -eq '') {
        if ($allowedExt -contains $baseName) { return $true }
        return $false
    }
    if ($allowedExt -contains $fileExt) { return $true }
    return $false
}

$allFiles = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue
$candidates = @()
foreach ($f in $allFiles) {
    $rel = $f.FullName.Substring($root.Path.Length + 1)
    if (Test-Allowed $rel) { $candidates += $f }
}

$outPath = Join-Path $root $Output
$sb = [System.Text.StringBuilder]::new()
$sb.AppendLine("=" * 68) | Out-Null
$sb.AppendLine(" USBGuard Approval Manager - Source Code Bundle") | Out-Null
$sb.AppendLine(" Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
$sb.AppendLine(" Project root: $root") | Out-Null
$sb.AppendLine(" File count: $($candidates.Count)") | Out-Null
$sb.AppendLine("=" * 68) | Out-Null
$sb.AppendLine("") | Out-Null

$count = 0
$sorted = $candidates | Sort-Object { $_.FullName.Substring($root.Path.Length + 1) }
foreach ($f in $sorted) {
    $rel = $f.FullName.Substring($root.Path.Length + 1).Replace('\', '/')
    try {
        $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    } catch {
        continue
    }
    $sb.AppendLine("-" * 68) | Out-Null
    $sb.AppendLine("FILE: $rel") | Out-Null
    $sb.AppendLine("-" * 68) | Out-Null
    $sb.AppendLine($content) | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("") | Out-Null
    $count++
}

$sb.AppendLine("=" * 68) | Out-Null
$sb.AppendLine(" Bundle complete: $count text files included.") | Out-Null
$sb.AppendLine(" Excluded: .git, .kilo, venv, site-packages, node_modules, binary files.") | Out-Null
$sb.AppendLine("=" * 68) | Out-Null

[System.IO.File]::WriteAllText($outPath, $sb.ToString(), [System.Text.Encoding]::UTF8)

$sizeMB = [math]::Round((Get-Item $outPath).Length / 1MB, 2)
Write-Host "Created: $outPath"
Write-Host "Text files bundled: $count / $($candidates.Count) candidates"
Write-Host "Size: $sizeMB MB"
