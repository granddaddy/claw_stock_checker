param(
    [string[]]$Symbols = @('AAPL', 'MSFT', 'AMZN', 'GOOGL', 'META', 'NVDA', 'TSLA', 'AMD', 'CRWV', 'ARM', 'MU')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$headers = @{ 'User-Agent' = 'Mozilla/5.0' }

function Invoke-TextRequest {
    param([string]$Uri)
    return (Invoke-WebRequest -Uri $Uri -UseBasicParsing -Headers $headers).Content
}

function Get-QuoteData {
    param([string[]]$Tickers)

    $joined = [string]::Join('|', $Tickers)
    $uri = "https://quote.cnbc.com/quote-html-webservice/quote.htm?symbols=$joined&requestMethod=quick&output=json"
    $json = Invoke-TextRequest -Uri $uri
    return ($json | ConvertFrom-Json).QuickQuoteResult.QuickQuote
}

$quotes = Get-QuoteData -Tickers $Symbols
$rows = foreach ($quote in $quotes) {
    [pscustomobject]@{
        Ticker = $quote.symbol
        Price = ('${0:N2}' -f [double]$quote.last)
        Intraday = ('{0:+0.00;-0.00;0.00}%' -f [double]$quote.change_pct)
    }
}

$lines = @(
    '| Ticker | Latest price | Intraday % |',
    '|---|---:|---:|'
)

foreach ($row in $rows) {
    $lines += "| **$($row.Ticker)** | $($row.Price) | **$($row.Intraday)** |"
}

$lines -join [Environment]::NewLine
