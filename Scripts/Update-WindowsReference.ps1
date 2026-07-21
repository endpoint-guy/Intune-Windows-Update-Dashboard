$Updates = @(
    @{
        ReleaseDate = Get-Date -Format "yyyy-MM-dd"
        OSVersion   = "Windows 11 24H2"
        Build       = "26100.8653"
        KB          = "KB5062553"
    }
)

$Json = $Updates | ConvertTo-Json -Depth 5

$Json | Set-Content "./Data/QualityUpdates.json"

Write-Host "QualityUpdates.json updated"
