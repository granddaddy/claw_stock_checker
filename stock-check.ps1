param(
    [string[]]$Symbols = @('AAPL', 'MSFT', 'AMZN', 'GOOGL', 'META', 'NVDA', 'TSLA', 'AMD', 'CRWV', 'ARM', 'MU'),
    [int]$NewsPerTicker = 3,
    [string]$ArticleRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'StockCheckArticles')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$headers = @{ 'User-Agent' = 'Mozilla/5.0' }
$today = (Get-Date).Date
$previousDay = $today.AddDays(-1)

$preferredSources = @(
    'wsj.com',
    'marketwatch.com',
    'barrons.com',
    'reuters.com',
    'finance.yahoo.com',
    'cnbc.com'
)

function Invoke-TextRequest {
    param([string]$Uri)
    return (Invoke-WebRequest -Uri $Uri -UseBasicParsing -Headers $headers).Content
}

function Get-SafeFileName {
    param([string]$Value)

    $invalid = [regex]::Escape(([System.IO.Path]::GetInvalidFileNameChars() -join ''))
    $safe = ($Value -replace "[$invalid]", '-') -replace '\s+', ' '
    $safe = $safe.Trim()
    if ($safe.Length -gt 120) {
        return $safe.Substring(0, 120).Trim()
    }

    return $safe
}

function Resolve-NewsLink {
    param([string]$Link)

    if ([string]::IsNullOrWhiteSpace($Link)) {
        return $Link
    }

    try {
        $uri = [uri]$Link
        $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
        $target = $query['url']
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            return [System.Web.HttpUtility]::UrlDecode($target)
        }
    }
    catch {
        return $Link
    }

    return $Link
}

function Convert-HtmlToText {
    param([string]$Html)

    $text = $Html -replace '(?is)<script.*?</script>', ' '
    $text = $text -replace '(?is)<style.*?</style>', ' '
    $text = $text -replace '(?is)<noscript.*?</noscript>', ' '
    $text = $text -replace '(?is)<[^>]+>', ' '
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    return (($text -replace '\s+', ' ').Trim())
}

function Get-MetaDescription {
    param([string]$Html)

    $patterns = @(
        '<meta[^>]+property=["'']og:description["''][^>]+content=["'']([^"'']+)["'']',
        '<meta[^>]+name=["'']description["''][^>]+content=["'']([^"'']+)["'']',
        '<meta[^>]+content=["'']([^"'']+)["''][^>]+property=["'']og:description["'']',
        '<meta[^>]+content=["'']([^"'']+)["''][^>]+name=["'']description["'']'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value).Trim()
        }
    }

    return ''
}

function Test-LowQualityArticleText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -lt 300) {
        return $true
    }

    return (
        $Text -match 'Oops, something went wrong' -or
        $Text -match 'Skip to navigation Skip to main content' -or
        $Text -match 'Enable JavaScript' -or
        $Text -match 'Subscribe to continue reading'
    )
}

function Get-FirstWords {
    param(
        [string]$Text,
        [int]$Count = 100
    )

    $words = @($Text -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($words.Count -le $Count) {
        return [string]::Join(' ', $words)
    }

    return ([string]::Join(' ', ($words | Select-Object -First $Count)) + '...')
}

function Test-NewsDateInScope {
    param([string]$Published)

    if ([string]::IsNullOrWhiteSpace($Published)) {
        return $false
    }

    try {
        $date = ([datetimeoffset]::Parse($Published)).LocalDateTime.Date
        return ($date -eq $today -or $date -eq $previousDay)
    }
    catch {
        return $false
    }
}

function Save-Article {
    param(
        [string]$Ticker,
        [object]$Article
    )

    if (-not (Test-NewsDateInScope -Published $Article.Published)) {
        return $null
    }

    if (-not (Test-Path -Path $ArticleRoot)) {
        New-Item -ItemType Directory -Path $ArticleRoot | Out-Null
    }

    $articleDate = ([datetimeoffset]::Parse($Article.Published)).LocalDateTime.ToString('yyyy-MM-dd')
    $safeTitle = Get-SafeFileName -Value $Article.Title
    $baseName = "$articleDate-$Ticker-$safeTitle"
    $htmlPath = Join-Path -Path $ArticleRoot -ChildPath "$baseName.html"
    $textPath = Join-Path -Path $ArticleRoot -ChildPath "$baseName.txt"

    if (-not (Test-Path -Path $htmlPath)) {
        try {
            $html = Invoke-TextRequest -Uri $Article.Link
            Set-Content -Path $htmlPath -Value $html -Encoding UTF8
        }
        catch {
            return $null
        }
    }

    $needsTextExtraction = -not (Test-Path -Path $textPath)
    if (-not $needsTextExtraction) {
        $existingText = Get-Content -Path $textPath -Raw -Encoding UTF8
        $needsTextExtraction = Test-LowQualityArticleText -Text $existingText
    }

    if ($needsTextExtraction) {
        $html = Get-Content -Path $htmlPath -Raw -Encoding UTF8
        $text = Convert-HtmlToText -Html $html
        $metaDescription = Get-MetaDescription -Html $html
        $fallback = (($Article.Title, $Article.Description, $metaDescription | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '. ')
        if (Test-LowQualityArticleText -Text $text) {
            $text = $fallback
        }
        Set-Content -Path $textPath -Value $text -Encoding UTF8
    }

    $summaryText = Get-Content -Path $textPath -Raw -Encoding UTF8
    return [pscustomobject]@{
        HtmlPath = $htmlPath
        TextPath = $textPath
        Summary = Get-FirstWords -Text $summaryText -Count 100
    }
}

function Get-QuoteData {
    param([string[]]$Tickers)

    $joined = [string]::Join('|', $Tickers)
    $uri = "https://quote.cnbc.com/quote-html-webservice/quote.htm?symbols=$joined&requestMethod=quick&output=json"
    $json = Invoke-TextRequest -Uri $uri
    return ($json | ConvertFrom-Json).QuickQuoteResult.QuickQuote
}

function Get-SourceName {
    param(
        [string]$Source,
        [string]$Link
    )

    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        return $Source
    }

    foreach ($domain in $preferredSources) {
        if ($Link -like "*$domain*") {
            switch ($domain) {
                'wsj.com' { return 'Wall Street Journal' }
                'marketwatch.com' { return 'MarketWatch' }
                'barrons.com' { return "Barron's" }
                'reuters.com' { return 'Reuters' }
                'finance.yahoo.com' { return 'Yahoo Finance' }
                'cnbc.com' { return 'CNBC' }
                default { return $domain }
            }
        }
    }

    return 'News search'
}

function Get-NewsCatalysts {
    param(
        [string]$Ticker,
        [string]$CompanyName,
        [int]$Limit
    )

    $companyKeyword = (($CompanyName -replace '\b(Inc|Corp|Corporation|Class A|PLC|Platforms|Technology|Technologies|Holdings|Advanced Micro Devices)\b', '') -replace '[^A-Za-z0-9 ]', ' ').Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) | Select-Object -First 1
    $allItems = @()
    $seen = @{}

    foreach ($preferredSource in $preferredSources) {
        $query = [uri]::EscapeDataString("$Ticker $CompanyName stock news analyst today site:$preferredSource")
        $uri = "https://www.bing.com/news/search?q=$query&format=RSS"

        try {
            [xml]$rss = Invoke-TextRequest -Uri $uri
        }
        catch {
            continue
        }

        $sourceItems = @(
            $rss.rss.channel.item |
                ForEach-Object {
                    $title = ($_.title -replace '\s+', ' ').Trim()
                    $link = Resolve-NewsLink -Link ([string]$_.link)
                    $source = Get-SourceName -Source $_.source.'#text' -Link $link
                    [pscustomobject]@{
                        Title = $title
                        Source = $source
                        Description = (Convert-HtmlToText -Html ([string]$_.description))
                        Published = [string]$_.pubDate
                        Link = $link
                    }
                } |
                Where-Object {
                    $_.Title -match [regex]::Escape($Ticker) -or
                    (-not [string]::IsNullOrWhiteSpace($companyKeyword) -and $_.Title -match [regex]::Escape($companyKeyword))
                } |
                Select-Object -First $Limit
        )

        foreach ($item in $sourceItems) {
            $dedupeKey = if (-not [string]::IsNullOrWhiteSpace($item.Link)) { $item.Link } else { "$($item.Source)|$($item.Title)" }
            if (-not $seen.ContainsKey($dedupeKey)) {
                $seen[$dedupeKey] = $true
                $allItems += $item
            }
        }
    }

    return $allItems
}

function Get-Sentiment {
    param(
        [double]$Pct,
        [double]$Ytd,
        [object[]]$News
    )

    $newsText = (($News | ForEach-Object { $_.Title }) -join ' ').ToLowerInvariant()

    if ($Pct -ge 2) {
        if ($newsText -match 'upgrade|raises|raised|buy|outperform|surges|jumps|rallies|ai|cloud|partnership|launch|beats') {
            return 'Bullish intraday'
        }
        return 'Bullish / momentum-driven'
    }

    if ($Pct -le -2) {
        if ($newsText -match 'downgrade|cuts|cut|falls|sinks|selloff|concern|probe|lawsuit|weak|miss|pressure') {
            return 'Bearish intraday'
        }
        return 'Bearish / profit-taking'
    }

    if ($Pct -gt 0) {
        if ($Ytd -gt 20) { return 'Bullish but consolidating' }
        return 'Mixed-to-positive'
    }

    if ($Pct -lt 0) {
        if ($Ytd -gt 20) { return 'Bullish longer-term, soft intraday' }
        return 'Mixed / cautious'
    }

    return 'Mixed / flat'
}

function Format-Catalysts {
    param([object[]]$News)

    if (-not $News -or $News.Count -eq 0) {
        return 'No clear fresh catalyst found; sentiment based on price action/technical context only.'
    }

    $items = $News |
        Select-Object -First 2 |
        ForEach-Object {
            "$($_.Source): `"$($_.Title)`""
        }

    return [string]::Join('; ', $items)
}

function Save-ArticlesForTicker {
    param(
        [string]$Ticker,
        [object[]]$News
    )

    $saved = @()
    foreach ($article in $News) {
        $savedArticle = Save-Article -Ticker $Ticker -Article $article
        if ($null -ne $savedArticle) {
            $saved += $savedArticle
        }
    }

    return $saved
}

function Format-ArticleSummary {
    param([object[]]$SavedArticles)

    if (-not $SavedArticles -or $SavedArticles.Count -eq 0) {
        return ''
    }

    $combined = (($SavedArticles | ForEach-Object { $_.Summary }) -join ' ')
    return Get-FirstWords -Text $combined -Count 100
}

$quotes = Get-QuoteData -Tickers $Symbols
$rows = foreach ($quote in $quotes) {
    $pct = [double]$quote.change_pct
    $ytd = if ($quote.FundamentalData.PDYTDPCHG) { [double]$quote.FundamentalData.PDYTDPCHG } else { 0 }
    $news = Get-NewsCatalysts -Ticker $quote.symbol -CompanyName $quote.name -Limit $NewsPerTicker
    $savedArticles = Save-ArticlesForTicker -Ticker $quote.symbol -News $news

    [pscustomobject]@{
        Ticker = $quote.symbol
        Price = ('${0:N2}' -f [double]$quote.last)
        Intraday = ('{0:+0.00;-0.00;0.00}%' -f $pct)
        Sentiment = Get-Sentiment -Pct $pct -Ytd $ytd -News $news
        Catalysts = Format-Catalysts -News $news
        ArticleSummary = Format-ArticleSummary -SavedArticles $savedArticles
    }
}

$lines = @(
    '| Ticker | Latest price | Intraday % | Sentiment | Concrete news / analyst catalysts | Article summary |',
    '|---|---:|---:|---|---|---|'
)

foreach ($row in $rows) {
    if ([string]::IsNullOrWhiteSpace($row.ArticleSummary)) {
        $lines += "| **$($row.Ticker)** | $($row.Price) | **$($row.Intraday)** | $($row.Sentiment) | $($row.Catalysts) |  |"
    }
    else {
        $lines += "| **$($row.Ticker)** | $($row.Price) | **$($row.Intraday)** | $($row.Sentiment) | $($row.Catalysts) | $($row.ArticleSummary) |"
    }
}

$lines -join [Environment]::NewLine
