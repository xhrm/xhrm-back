# 输入仓库信息
$Repo = Read-Host "Enter GitHub repository (format owner/repo)"
$Version = Read-Host "Enter Release version (default latest, press Enter to use latest)"
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = "latest" }

# 构建 API URL
$ApiUrl = if ($Version -eq "latest") {
    "https://api.github.com/repos/$Repo/releases/latest"
} else {
    "https://api.github.com/repos/$Repo/releases/tags/$Version"
}

# 获取 Release 信息
try {
    $ReleaseInfo = Invoke-RestMethod -Uri $ApiUrl -Headers @{ "User-Agent" = "PowerShell" }
} catch {
    Write-Host "Error: Unable to fetch Release information"
    Write-Host "Press Enter to exit..."
    Read-Host
    exit
}

if ($ReleaseInfo.assets.Count -eq 0) {
    Write-Host "This Release has no assets"
    Write-Host "Press Enter to exit..."
    Read-Host
    exit
}

# 下载目录
$Dir = ($Repo -replace '/', '_') + "_release"
if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }

# 定义下载函数（带重试）
function Download-Asset {
    param (
        [string]$Url,
        [string]$FilePath,
        [int]$RetryCount = 3
    )

    for ($i = 1; $i -le $RetryCount; $i++) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "PowerShell")
            $wc.DownloadFile($Url, $FilePath)
            $wc.Dispose()
            return $true
        } catch {
            $wc.Dispose()
            if ($i -lt $RetryCount) { Start-Sleep -Seconds 1 }
        }
    }
    return $false
}

# 初始化文件状态列表
$DownloadedFiles = @()
$FailedFiles = @()

# 循环下载每个文件
foreach ($asset in $ReleaseInfo.assets) {
    $Url = $asset.browser_download_url
    $FileName = $asset.name
    $FilePath = Join-Path $Dir $FileName

    Write-Host "Starting download: $FileName"
    if (Download-Asset -Url $Url -FilePath $FilePath) {
        Write-Host "Completed: $FileName"
        $DownloadedFiles += $FileName
    } else {
        Write-Host "Failed: $FileName"
        $FailedFiles += $FileName
    }
}

# 下载完成提示
Write-Host "`nDownload summary:"
if ($DownloadedFiles.Count -gt 0) {
    Write-Host "Successfully downloaded files:"
    $DownloadedFiles | ForEach-Object { Write-Host $_ }
}

if ($FailedFiles.Count -gt 0) {
    Write-Host "`nFailed to download files:"
    $FailedFiles | ForEach-Object { Write-Host $_ }
}

# 保持窗口打开
Write-Host "`nPress Enter to exit..."
Read-Host
