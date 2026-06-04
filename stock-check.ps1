param(
    [string[]]$Symbols = @('AAPL', 'MSFT', 'AMZN', 'GOOGL', 'META', 'NVDA', 'TSLA', 'AMD', 'CRWV', 'ARM', 'MU'),
    [int]$NewsPerTicker = 10,
    [string]$ArticleRoot = (Join-Path (Join-Path $env:USERPROFILE 'Documents') 'StockCheckArticles')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$headers = @{ 'User-Agent' = 'Mozilla/5.0' }
$today = (Get-Date).Date
$previousDay = $today.AddDays(-1)

$preferredSources = @(
    'marketwatch.com',
    'barrons.com'
)

if (-not (Test-Path -Path $ArticleRoot)) {
    New-Item -ItemType Directory -Path $ArticleRoot | Out-Null
}

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

function Get-MetaPublishedDate {
    param([string]$Html)

    $patterns = @(
        '<meta[^>]+property=["'']article:published_time["''][^>]+content=["'']([^"'']+)["'']',
        '<meta[^>]+name=["'']article.published["''][^>]+content=["'']([^"'']+)["'']',
        '<meta[^>]+name=["'']parsely-pub-date["''][^>]+content=["'']([^"'']+)["'']',
        '<time[^>]+datetime=["'']([^"'']+)["'']'
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

function Test-GenericQuotePageTitle {
    param(
        [string]$Title,
        [string]$CompanyName
    )

    $normalizedTitle = (($Title -replace '[^\p{L}\p{Nd}\s]', '') -replace '\s+', ' ').Trim()
    $normalizedCompany = (($CompanyName -replace '[^\p{L}\p{Nd}\s]', '') -replace '\s+', ' ').Trim()

    return (
        $normalizedTitle -eq $normalizedCompany -or
        $normalizedTitle -match '^\w+ \| .+ Stock Overview' -or
        $normalizedTitle -match '^\w+ \| .+ Stock Price'
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

    $articlePublished = $Article.Published
    if (-not (Test-NewsDateInScope -Published $articlePublished) -and -not [string]::IsNullOrWhiteSpace($articlePublished)) {
        return [pscustomobject]@{
            Status = 'Skipped: outside current/prior-day window'
            HtmlPath = ''
            TextPath = ''
            Summary = ''
            Title = $Article.Title
        }
    }

    if (-not (Test-Path -Path $ArticleRoot)) {
        New-Item -ItemType Directory -Path $ArticleRoot | Out-Null
    }

    $articleDate = ([datetimeoffset]::Parse($Article.Published)).LocalDateTime.ToString('yyyy-MM-dd')
    $safeTitle = Get-SafeFileName -Value $Article.Title
    $safeSource = Get-SafeFileName -Value $Article.Source
    $baseName = "$articleDate-$Ticker-$safeSource-$safeTitle"
    $htmlPath = Join-Path -Path $ArticleRoot -ChildPath "$baseName.html"
    $textPath = Join-Path -Path $ArticleRoot -ChildPath "$baseName.txt"

    if (-not (Test-Path -Path $htmlPath)) {
        try {
            $html = Invoke-TextRequest -Uri $Article.Link
            Set-Content -Path $htmlPath -Value $html -Encoding UTF8
        }
        catch {
            return [pscustomobject]@{
                Status = "Download failed: $($_.Exception.Message)"
                HtmlPath = ''
                TextPath = ''
                Summary = ''
                Title = $Article.Title
            }
        }
    }

    $htmlForDate = Get-Content -Path $htmlPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($articlePublished)) {
        $articlePublished = Get-MetaPublishedDate -Html $htmlForDate
    }

    if (-not (Test-NewsDateInScope -Published $articlePublished)) {
        return [pscustomobject]@{
            Status = 'Skipped: article page date outside current/prior-day window'
            HtmlPath = $htmlPath
            TextPath = ''
            Summary = ''
            Title = $Article.Title
        }
    }

    $needsTextExtraction = -not (Test-Path -Path $textPath)
    if (-not $needsTextExtraction) {
        $existingText = Get-Content -Path $textPath -Raw -Encoding UTF8
        $needsTextExtraction = Test-LowQualityArticleText -Text $existingText
    }

    if ($needsTextExtraction) {
        $html = $htmlForDate
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
        Status = 'Downloaded'
        HtmlPath = $htmlPath
        TextPath = $textPath
        Summary = Get-FirstWords -Text $summaryText -Count 100
        Title = $Article.Title
    }
}

function Get-QuotePageUrl {
    param(
        [string]$Ticker,
        [string]$Source
    )

    $lowerTicker = $Ticker.ToLowerInvariant()
    switch ($Source) {
        'marketwatch.com' { return "https://www.marketwatch.com/investing/stock/$lowerTicker`?mod=search_symbol" }
        'barrons.com' { return "https://www.barrons.com/market-data/stocks/$lowerTicker`?mod=searchresults_companyquotes&mod=searchbar&search_keywords=$lowerTicker&search_statement_type=suggested" }
        default { return '' }
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
        $quotePageUrl = Get-QuotePageUrl -Ticker $Ticker -Source $preferredSource
        if (-not [string]::IsNullOrWhiteSpace($quotePageUrl)) {
            try {
                $quotePageHtml = Invoke-TextRequest -Uri $quotePageUrl
                $linkMatches = [regex]::Matches($quotePageHtml, '<a[^>]+href=["'']([^"'']+)["''][^>]*>(.*?)</a>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
                $quotePageItems = @(
                    foreach ($match in $linkMatches) {
                        $link = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
                        $title = Convert-HtmlToText -Html $match.Groups[2].Value
                        if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($link)) {
                            continue
                        }
                        if ($link -notmatch '^https?://') {
                            $sourceRoot = if ($preferredSource -eq 'barrons.com') { 'https://www.barrons.com' } else { 'https://www.marketwatch.com' }
                            if ($link.StartsWith('/')) {
                                $link = "$sourceRoot$link"
                            }
                            else {
                                continue
                            }
                        }
                        if ($link -notlike "*$preferredSource*" -or $link -notmatch '/(articles|story|news)/') {
                            continue
                        }

                        $articlePublished = ''
                        $articleDescription = ''
                        try {
                            $articleHtml = Invoke-TextRequest -Uri $link
                            $articlePublished = Get-MetaPublishedDate -Html $articleHtml
                            $articleDescription = Get-MetaDescription -Html $articleHtml
                        }
                        catch {
                            continue
                        }

                        if (-not (Test-NewsDateInScope -Published $articlePublished)) {
                            continue
                        }

                        [pscustomobject]@{
                            Title = $title
                            Source = Get-SourceName -Source '' -Link $link
                            Description = $articleDescription
                            Published = $articlePublished
                            Link = $link
                        }
                    }
                )

                foreach ($item in ($quotePageItems | Select-Object -First $Limit)) {
                    $dedupeKey = if (-not [string]::IsNullOrWhiteSpace($item.Link)) { $item.Link } else { "$($item.Source)|$($item.Title)" }
                    if (-not $seen.ContainsKey($dedupeKey)) {
                        $seen[$dedupeKey] = $true
                        $allItems += $item
                    }
                }
            }
            catch {
                # Fall through to source-scoped news search below.
            }
        }

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
                    Test-NewsDateInScope -Published $_.Published
                } |
                Where-Object {
                    $searchText = "$($_.Title) $($_.Description)"
                    -not (Test-GenericQuotePageTitle -Title $_.Title -CompanyName $CompanyName) -and
                    (
                        $searchText -match [regex]::Escape($Ticker) -or
                        (-not [string]::IsNullOrWhiteSpace($companyKeyword) -and $searchText -match [regex]::Escape($companyKeyword))
                    )
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

function Format-ArticleTitles {
    param([object[]]$News)

    if (-not $News -or $News.Count -eq 0) {
        return ''
    }

    $items = $News |
        ForEach-Object {
            "$($_.Source): `"$($_.Title)`""
        }

    return [string]::Join('<br>', $items)
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

function Format-DownloadStatus {
    param([object[]]$SavedArticles)

    if (-not $SavedArticles -or $SavedArticles.Count -eq 0) {
        return ''
    }

    $items = $SavedArticles |
        ForEach-Object {
            if ($_.Status -eq 'Downloaded' -and -not [string]::IsNullOrWhiteSpace($_.TextPath)) {
                "Downloaded: $(Split-Path -Path $_.TextPath -Leaf)"
            }
            else {
                "$($_.Status): $($_.Title)"
            }
        }

    return [string]::Join('<br>', $items)
}

$quotes = Get-QuoteData -Tickers $Symbols
$rows = foreach ($quote in $quotes) {
    $pct = [double]$quote.change_pct
    $news = Get-NewsCatalysts -Ticker $quote.symbol -CompanyName $quote.name -Limit $NewsPerTicker
    $savedArticles = Save-ArticlesForTicker -Ticker $quote.symbol -News $news

    [pscustomobject]@{
        Ticker = $quote.symbol
        Price = ('${0:N2}' -f [double]$quote.last)
        Intraday = ('{0:+0.00;-0.00;0.00}%' -f $pct)
        ArticleTitles = Format-ArticleTitles -News $news
        DownloadStatus = Format-DownloadStatus -SavedArticles $savedArticles
    }
}

$lines = @(
    '| Ticker | Latest price | Intraday % | Article titles | Download status |',
    '|---|---:|---:|---|---|'
)

foreach ($row in $rows) {
    $lines += "| **$($row.Ticker)** | $($row.Price) | **$($row.Intraday)** | $($row.ArticleTitles) | $($row.DownloadStatus) |"
}

$lines -join [Environment]::NewLine
