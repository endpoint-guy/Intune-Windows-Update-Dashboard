$ErrorActionPreference = "Stop"

$DataPath = "./Data"

if (-not (Test-Path $DataPath)) {
    New-Item -Path $DataPath -ItemType Directory -Force | Out-Null
}

$UpdateSources = @(
    @{
        Product = "Windows 11"
        Version = "24H2"
        Url = "https://support.microsoft.com/en-US/servicing/os/windows-11/2024/09/windows-11-version-24h2-update-history"
    },
    @{
        Product = "Windows 11"
        Version = "23H2"
        Url = "https://support.microsoft.com/en-US/servicing/os/windows-11/2023/09/windows-11-version-23h2-update-history"
    },
    @{
        Product = "Windows 10"
        Version = "22H2"
        Url = "https://support.microsoft.com/en-us/servicing/os/windows-10/2022/09/windows-10-update-history"
    }
)

function ConvertFrom-HtmlText {
    param(
        [string]$Text
    )

    if (:IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $Decoded = [System.Net.WebUtility]::HtmlDecode($Text)
    $NoTags = $Decoded -replace "<[^>]+>", " "
    $Clean = $NoTags -replace "\s+", " "

    return $Clean.Trim()
}

function Get-AbsoluteUrl {
    param(
        [string]$BaseUrl,
        [string]$Href
    )

    if ($Href -match "^https?://") {
        return $Href
    }

    $BaseUri = [System.Uri]$BaseUrl
    $AbsoluteUri = [System.Uri]::new($BaseUri, $Href)

    return $AbsoluteUri.AbsoluteUri
}

function Get-UpdateType {
    param(
        [string]$Title
    )

    if ($Title -match "(?i)preview") {
        return "Preview Update"
    }

    if ($Title -match "(?i)out-of-band|oob") {
        return "Out-of-Band Update"
    }

    return "Quality Update"
}

function Get-ReleaseDateFromText {
    param(
        [string]$Text
    )

    $DatePattern = "(January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}"
    $Match = :Match($Text, $DatePattern, "IgnoreCase")

    if ($Match.Success) {
        try {
            return (:Parse($Match.Value)).ToString("yyyy-MM-dd")
        }
        catch {
            return $null
        }
    }

    return $null
}

function Get-BuildsFromText {
    param(
        [string]$Text
    )

    $BuildMatches = :Matches($Text, "\b\d{5}\.\d{3,5}\b")

    $Builds = foreach ($Match in $BuildMatches) {
        $Match.Value
    }

    return $Builds | Select-Object -Unique
}

$AllUpdates = @()

foreach ($Source in $UpdateSources) {
    Write-Host "Processing $($Source.Product) $($Source.Version)"
    Write-Host "Source: $($Source.Url)"

    $Response = Invoke-WebRequest -Uri $Source.Url -UseBasicParsing
    $Html = $Response.Content

    $AnchorMatches = :Matches(
        $Html,
        '<a[^>]+href="(?<href>[^"]+)"[^>]*>(?<text>.*?)</a>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $UpdateLinks = foreach ($Anchor in $AnchorMatches) {
        $Href = $Anchor.Groups["href"].Value
        $Text = ConvertFrom-HtmlText -Text $Anchor.Groups["text"].Value

        if ($Href -match "(?i)kb\d{6,8}" -or $Text -match "(?i)kb\d{6,8}") {
            [PSCustomObject]@{
                Title = $Text
                Url = Get-AbsoluteUrl -BaseUrl $Source.Url -Href $Href
            }
        }
    }

    $UpdateLinks = $UpdateLinks |
        Where-Object { $_.Url -match "support\.microsoft\.com" } |
        Sort-Object Url -Unique

    Write-Host "Found $($UpdateLinks.Count) update links"

    foreach ($Link in $UpdateLinks) {
        try {
            Write-Host "Reading update page: $($Link.Url)"

            $DetailResponse = Invoke-WebRequest -Uri $Link.Url -UseBasicParsing
            $DetailHtml = $DetailResponse.Content

            $TitleMatch = :Match(
                $DetailHtml,
                "<title>(?<title>.*?)</title>",
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [System.Text.RegularExpressions.RegexOptions]::Singleline
            )

            if ($TitleMatch.Success) {
                $PageTitle = ConvertFrom-HtmlText -Text $TitleMatch.Groups["title"].Value
            }
            else {
                $PageTitle = $Link.Title
            }

            $CombinedText = "$($Link.Title) $PageTitle"

            $KbMatch = :Match($CombinedText, "(?i)KB\d{6,8}")

            if (-not $KbMatch.Success) {
                continue
            }

            $KB = $KbMatch.Value.ToUpper()
            $ReleaseDate = Get-ReleaseDateFromText -Text $CombinedText
            $Builds = Get-BuildsFromText -Text $CombinedText
            $UpdateType = Get-UpdateType -Title $CombinedText

            foreach ($Build in $Builds) {
                $BuildParts = $Build.Split(".")

                if ($BuildParts.Count -ne 2) {
                    continue
                }

                $BuildBranch = [int]$BuildParts[0]
                $UBR = [int]$BuildParts[1]

                $AllUpdates += [PSCustomObject]@{
                    Product = $Source.Product
                    Version = $Source.Version
                    KB = $KB
                    Build = $Build
                    BuildBranch = $BuildBranch
                    UBR = $UBR
                    ReleaseDate = $ReleaseDate
                    UpdateType = $UpdateType
                    Title = $PageTitle
                    SourceUrl = $Link.Url
                    SourceHistoryUrl = $Source.Url
                    GeneratedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                }
            }
        }
        catch {
            Write-Warning "Failed to process $($Link.Url): $($_.Exception.Message)"
        }
    }
}

$AllUpdates = $AllUpdates |
    Where-Object { $_.KB -and $_.Build -and $_.ReleaseDate } |
    Sort-Object Product, Version, BuildBranch, UBR, ReleaseDate -Unique

$AllUpdates |
    ConvertTo-Json -Depth 10 |
    Set-Content "$DataPath/WindowsUpdateCatalog.json" -Encoding UTF8

Write-Host "Saved WindowsUpdateCatalog.json"

$LatestQualityUpdates = $AllUpdates |
    Group-Object Product, Version, BuildBranch |
    ForEach-Object {
        $_.Group |
            Sort-Object UBR -Descending |
            Select-Object -First 1
    } |
    Sort-Object Product, Version, BuildBranch

$LatestQualityUpdates |
    ConvertTo-Json -Depth 10 |
    Set-Content "$DataPath/LatestQualityUpdates.json" -Encoding UTF8

Write-Host "Saved LatestQualityUpdates.json"

$UpdateSources |
    ConvertTo-Json -Depth 5 |
    Set-Content "$DataPath/UpdateSources.json" -Encoding UTF8

Write-Host "Saved UpdateSources.json"

Write-Host "Windows update catalog generation completed successfully."
