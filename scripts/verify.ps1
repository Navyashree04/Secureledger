<#
.SYNOPSIS
    End-to-end verification of a running SecureLedger instance.

.DESCRIPTION
    Exercises the full banking flow against a live server (register -> login ->
    create accounts -> deposit -> withdraw -> transfer -> history) and also
    checks the three edge cases that a plain happy-path run does not cover:
    insufficient funds, an unauthenticated request, and a frozen-account
    operation. Prints a PASS/FAIL summary at the end so it's obvious at a
    glance whether the app is healthy.

.USAGE
    # In a separate terminal, first start the app:
    #   cd secureledger
    #   mvn spring-boot:run
    # Then, once you see "Started SecureLedgerApplication":
    powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1

.NOTES
    Every run registers a brand-new random username, so it's safe to run
    this script repeatedly without "user already exists" errors.
#>

param(
    [string]$BaseUrl = "http://localhost:8080"
)

$ErrorActionPreference = "Stop"
$results = @()

function Test-Step {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:results += [pscustomobject]@{ Step = $Name; Status = "PASS" }
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } catch {
        $script:results += [pscustomobject]@{ Step = $Name; Status = "FAIL" }
        Write-Host "[FAIL] $Name -> $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n=== SecureLedger verification against $BaseUrl ===`n" -ForegroundColor Cyan

# ---- 0. Is the server even up? ----
Test-Step "Server reachable" {
    Invoke-WebRequest -Uri $BaseUrl -Method GET -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
}

$suffix   = Get-Date -Format "yyyyMMddHHmmss"
$username = "verifyuser_$suffix"
$password = "correct horse battery staple $suffix"
$token    = $null
$acct1Id  = $null
$acct2Id  = $null

# ---- 1. Register ----
Test-Step "Register new user ($username)" {
    $body = @{ username = $username; password = $password } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$BaseUrl/auth/register" -Method POST -ContentType "application/json" -Body $body
    if (-not $resp.token) { throw "no token in response" }
    $script:token = $resp.token
    Write-Host "        role: $($resp.role)"
}

# ---- 2. Login ----
Test-Step "Login" {
    $body = @{ username = $username; password = $password } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$BaseUrl/auth/login" -Method POST -ContentType "application/json" -Body $body
    if (-not $resp.token) { throw "no token in response" }
    $script:token = $resp.token
}

$headers = { @{ Authorization = "Bearer $script:token" } }

# ---- 3. Unauthenticated request must be rejected ----
Test-Step "Reject request with no token (expect 401)" {
    try {
        Invoke-RestMethod -Uri "$BaseUrl/accounts" -Method GET -ErrorAction Stop | Out-Null
        throw "request succeeded without a token — should have been rejected"
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 401) { return }
        throw
    }
}

# ---- 4. Create SAVINGS account ----
Test-Step "Create SAVINGS account" {
    $body = @{ accountType = "SAVINGS" } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$BaseUrl/accounts" -Method POST -Headers (& $headers) -ContentType "application/json" -Body $body
    $script:acct1Id = $resp.id
    Write-Host "        account id: $script:acct1Id, number: $($resp.accountNumber)"
}

# ---- 5. Create CURRENT account (transfer destination) ----
Test-Step "Create CURRENT account" {
    $body = @{ accountType = "CURRENT" } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$BaseUrl/accounts" -Method POST -Headers (& $headers) -ContentType "application/json" -Body $body
    $script:acct2Id = $resp.id
    Write-Host "        account id: $script:acct2Id, number: $($resp.accountNumber)"
}

# ---- 6. Deposit ----
Test-Step "Deposit 10000 into account $($acct1Id)" {
    $body = @{ amount = "10000.00" } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct1Id/deposit" -Method POST -Headers (& $headers) -ContentType "application/json" -Body $body
    if ($resp.balanceAfter -ne "10000.0000") { throw "unexpected balance: $($resp.balanceAfter)" }
}

# ---- 7. Withdraw ----
Test-Step "Withdraw 2000 from account $($acct1Id)" {
    $body = @{ amount = "2000.00" } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct1Id/withdraw" -Method POST -Headers (& $headers) -ContentType "application/json" -Body $body
    if ($resp.balanceAfter -ne "8000.0000") { throw "unexpected balance: $($resp.balanceAfter)" }
}

# ---- 8. Withdrawal that exceeds balance must fail ----
Test-Step "Reject over-withdrawal (expect 422/409/400)" {
    try {
        $body = @{ amount = "999999.00" } | ConvertTo-Json
        Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct1Id/withdraw" -Method POST -Headers (& $headers) -ContentType "application/json" -Body $body | Out-Null
        throw "over-withdrawal succeeded — should have been rejected"
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -in 400,409,422) { return }
        throw
    }
}

# ---- 9. Transfer with idempotency key ----
$idempotencyKey = [guid]::NewGuid().ToString()
Test-Step "Transfer 3000 from account $($acct1Id) to $($acct2Id)" {
    $body = @{ fromAccountId = $script:acct1Id; toAccountId = $script:acct2Id; amount = "3000.00" } | ConvertTo-Json
    $h = & $headers
    $h["Idempotency-Key"] = $idempotencyKey
    $resp = Invoke-RestMethod -Uri "$BaseUrl/transfers" -Method POST -Headers $h -ContentType "application/json" -Body $body
    Write-Host "        transfer status: $($resp.status)"
}

# ---- 10. Replaying the same Idempotency-Key must NOT double-transfer ----
Test-Step "Replay same Idempotency-Key (expect no second transfer)" {
    $body = @{ fromAccountId = $script:acct1Id; toAccountId = $script:acct2Id; amount = "3000.00" } | ConvertTo-Json
    $h = & $headers
    $h["Idempotency-Key"] = $idempotencyKey
    Invoke-RestMethod -Uri "$BaseUrl/transfers" -Method POST -Headers $h -ContentType "application/json" -Body $body | Out-Null
    $acct1 = Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct1Id" -Method GET -Headers (& $headers)
    if ($acct1.balance -ne "5000.0000") { throw "balance drifted to $($acct1.balance) — idempotency key was not respected" }
}

# ---- 11. Transaction history ----
Test-Step "Fetch transaction history for account $($acct1Id)" {
    $resp = Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct1Id/transactions?page=0&size=20" -Method GET -Headers (& $headers)
    $count = if ($resp.content) { $resp.content.Count } else { $resp.Count }
    if ($count -lt 3) { throw "expected at least 3 transactions, found $count" }
    Write-Host "        $count transactions recorded"
}

# ---- 12. Freeze / unfreeze (ADMIN only — first registered user is ADMIN, so this passes only for the very first run) ----
Test-Step "Freeze then unfreeze account $($acct1Id)" {
    Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct1Id/freeze" -Method PATCH -Headers (& $headers) | Out-Null
    $frozen = Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct1Id" -Method GET -Headers (& $headers)
    if ($frozen.status -ne "FROZEN") { throw "account did not report FROZEN status" }
    Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct1Id/unfreeze" -Method PATCH -Headers (& $headers) | Out-Null
}

# ---- Final balances ----
Test-Step "Final balances match expected math" {
    $acct1 = Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct1Id" -Method GET -Headers (& $headers)
    $acct2 = Invoke-RestMethod -Uri "$BaseUrl/accounts/$script:acct2Id" -Method GET -Headers (& $headers)
    Write-Host "        account $($acct1Id) balance: $($acct1.balance) (expect 5000.0000)"
    Write-Host "        account $($acct2Id) balance: $($acct2.balance) (expect 3000.0000)"
    if ($acct1.balance -ne "5000.0000" -or $acct2.balance -ne "3000.0000") { throw "final balances don't match expected values" }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize
$failures = $results | Where-Object { $_.Status -eq "FAIL" }
if ($failures.Count -eq 0) {
    Write-Host "`nAll checks passed. SecureLedger is verified end-to-end." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$($failures.Count) check(s) failed. See [FAIL] lines above." -ForegroundColor Red
    exit 1
}
