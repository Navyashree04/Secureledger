# SecureLedger

A core banking transaction API: account management, deposits, withdrawals,
atomic transfers, transaction history, JWT auth, and an append-only audit
trail. Built to demonstrate engineering judgment (correctness, concurrency
safety, clean layering) rather than feature breadth — see [DESIGN.md](DESIGN.md)
for the reasoning behind the isolation level, locking strategy, and
idempotency design.

## Stack

Java 17 · Spring Boot 3.3 · Spring Data JPA (Hibernate) · Spring Security
(self-issued JWT) · PostgreSQL 15+ · JUnit 5 · Maven

## Status

**Phase 1 (the "done" bar) is fully implemented and has been run end-to-end**
against a real local PostgreSQL instance: account CRUD, deposit/withdraw,
atomic transfers with idempotency and pessimistic locking, JWT auth, global
exception handling, and the required test suite (including the Phase-1
acceptance criterion around concurrent transfers). Docker/Swagger/rate-limiting
(Phase 3) are not yet built.

---

## 1. Prerequisites

| Tool | Version | Check |
|---|---|---|
| JDK | 17 | `java -version` and `javac -version` |
| Maven | 3.9+ | `mvn -version` |
| PostgreSQL | 15+ | `psql --version` |

**On Windows**, if `java`, `mvn`, or `psql` are "not recognized" even though
they're installed, it's a `PATH`/`JAVA_HOME` problem, not a missing install —
see [Troubleshooting](#5-troubleshooting-things-that-actually-came-up) below.

## 2. First-time setup (once per machine)

1. **Create the database.**
   ```bash
   psql -U postgres -c "CREATE DATABASE secureledger;"
   ```
   (If you don't remember your `postgres` superuser password, see
   [Troubleshooting](#5-troubleshooting-things-that-actually-came-up).)

2. **Set the connection env vars for** ***your*** **machine.** The app reads
   `DB_URL` / `DB_USERNAME` / `DB_PASSWORD` at startup — nothing is
   hardcoded, so a nonstandard port (see Troubleshooting) is just an env var,
   not a code change.

   PowerShell:
   ```powershell
   $env:DB_URL      = "jdbc:postgresql://localhost:5432/secureledger"
   $env:DB_USERNAME = "postgres"
   $env:DB_PASSWORD = "<your postgres password>"
   $env:JWT_SECRET  = "dev-only-secret-change-this-32-bytes-min"
   ```
   bash/zsh:
   ```bash
   export DB_URL="jdbc:postgresql://localhost:5432/secureledger"
   export DB_USERNAME="postgres"
   export DB_PASSWORD="<your postgres password>"
   export JWT_SECRET="dev-only-secret-change-this-32-bytes-min"
   ```
   These are **never committed** — `.env`/`*.env` are gitignored, and
   `application.yml` only contains placeholder defaults, so it's safe to push
   this repo publicly.

That's it — you don't repeat this section on future runs.

## 3. Run it (every time)

**Terminal 1 — start the server:**
```bash
cd secureledger        # the folder containing pom.xml
mvn spring-boot:run
```
Wait for `Started SecureLedgerApplication` in the logs. The API is now on
`http://localhost:8080`.

**Terminal 2 — verify it works:**

PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```
bash/zsh/Git Bash (requires `curl` + `jq`):
```bash
./scripts/verify.sh
```

This script drives the **entire flow end-to-end against the live server**:
register → login → reject-unauthenticated (401) → create SAVINGS account →
create CURRENT account → deposit → withdraw → reject-over-withdrawal →
transfer → replay the same `Idempotency-Key` and confirm no double-transfer
→ transaction history → freeze/unfreeze → final balance check. It prints a
`[PASS]`/`[FAIL]` line per step and a summary at the end, so a clean run is
unambiguous proof the app works — exactly what you want to be able to do
five minutes before an interview. It registers a fresh random username every
run, so it's safe to run repeatedly.

## 4. Run the automated test suite

```bash
mvn clean test
```
Tests run against an in-memory H2 database in Postgres-compatibility mode
(`spring.profiles.active=test`) — **no Postgres needed** to run this suite.
It includes an integration test that fires 25 concurrent transfer requests
at the same pair of accounts and asserts the final balance is exactly
correct (`ConcurrentTransferTest`) — the direct proof of the
pessimistic-locking claim in DESIGN.md. H2's locking behavior is a
reasonable stand-in but not a perfect substitute for Postgres; if you want
the strongest version of that proof, point the `test` profile at a real
Postgres instance.

## 5. Troubleshooting (things that actually came up)

- **`'java'`/`'mvn'`/`'psql'` not recognized (Windows):** the tool is
  installed but not on `PATH`. Find the install dir (commonly
  `C:\Program Files\Eclipse Adoptium\jdk-17.x.x-hotspot` for the JDK,
  `C:\Program Files\PostgreSQL\<version>\bin` for `psql`), set `JAVA_HOME`
  and add both to `PATH`, then open a **new** terminal.
- **Multiple PostgreSQL versions installed side by side:** each instance
  gets its own port — typically `5432` for the first install, `5433` for a
  second. Check which one has your database:
  ```powershell
  Get-Service postgresql* | Select Name, Status
  ```
  Then set `DB_URL` in step 2 to match the right port.
- **Forgot the `postgres` password:** temporarily edit `pg_hba.conf` to
  `trust` for local connections, restart the PostgreSQL service, connect
  with no password and reset it (`ALTER USER postgres WITH PASSWORD
  '...';`), then revert `pg_hba.conf` and restart again.
- **Project has a nested folder** (e.g. `Downloads\secureledger\secureledger`):
  make sure you `cd` into the inner folder — the one that directly contains
  `pom.xml` — before running `mvn`.
- **`curl.exe` in PowerShell mangles JSON with spaces/quotes:** use
  `Invoke-RestMethod` with a hashtable piped through `ConvertTo-Json`
  instead of hand-quoting JSON strings — this is exactly what
  `scripts/verify.ps1` does, and it's the reliable pattern for any manual
  API calls too:
  ```powershell
  $body = @{ username = "alice"; password = "correct horse battery staple" } | ConvertTo-Json
  Invoke-RestMethod -Uri "http://localhost:8080/auth/register" -Method POST -ContentType "application/json" -Body $body
  ```
- **500 error on `/auth/register` with no obvious cause:** almost always
  malformed JSON reaching the endpoint (see the `curl.exe` point above), not
  an application bug — check the raw request body first.

## 6. API walkthrough (curl, for manual/ad-hoc calls)

```bash
# Register (first user registered becomes ADMIN; rest are CUSTOMER)
curl -s -X POST localhost:8080/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"correct horse battery staple"}'
# → { "token": "...", "tokenType": "Bearer", "expiresInMs": 3600000, "username": "alice", "role": "ADMIN" }

TOKEN=<paste token from above>

# Login (subsequent sessions)
curl -s -X POST localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"correct horse battery staple"}'

# Create an account
curl -s -X POST localhost:8080/accounts \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"accountType":"SAVINGS"}'
# → { "id": 1, "accountNumber": "...", "balance": "0.0000", "status": "ACTIVE", ... }

# Deposit
curl -s -X POST localhost:8080/accounts/1/deposit \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"amount": "500.00"}'

# Withdraw
curl -s -X POST localhost:8080/accounts/1/withdraw \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"amount": "50.00"}'

# Transfer (Idempotency-Key strongly recommended — a client should generate
# one UUID per logical transfer attempt and reuse it on retry)
curl -s -X POST localhost:8080/transfers \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"fromAccountId": 1, "toAccountId": 2, "amount": "100.00"}'

# Transaction history (paginated)
curl -s "localhost:8080/accounts/1/transactions?page=0&size=20" \
  -H "Authorization: Bearer $TOKEN"

# Freeze / unfreeze an account (ADMIN only)
curl -s -X PATCH localhost:8080/accounts/1/freeze -H "Authorization: Bearer $TOKEN"
curl -s -X PATCH localhost:8080/accounts/1/unfreeze -H "Authorization: Bearer $TOKEN"
```

A full Postman collection covering every endpoint (including the
register → login → create account → deposit → transfer flow, plus the
insufficient-funds and no-token negative cases) is at
[`postman/SecureLedger.postman_collection.json`](postman/SecureLedger.postman_collection.json).
Import it, set the `baseUrl` and `token` collection variables (the login
request auto-populates `token` via a test script), and run the requests in
order.

## 7. What this project demonstrates → interview topics

| Feature | Interview topic |
|---|---|
| `NUMERIC(19,4)` / `BigDecimal` everywhere money is touched | Why floating point is wrong for currency |
| `SELECT ... FOR UPDATE` via `PESSIMISTIC_WRITE`, fixed lock ordering | Pessimistic vs. optimistic locking; deadlock avoidance |
| `READ COMMITTED` + explicit row locks, justified in DESIGN.md | Transaction isolation levels and their tradeoffs |
| `transactions.idempotency_key` UNIQUE constraint + pre-check | Idempotency under concurrent retries — DB constraint vs. app-level check |
| Two-row transfer (`TRANSFER_OUT` / `TRANSFER_IN`) in one `@Transactional` method | Atomicity — all-or-nothing money movement |
| `audit_log`, append-only by construction, written in the same transaction as the balance change | Auditability; why "log it afterward" is the wrong pattern |
| Self-issued JWT, `OncePerRequestFilter`, stateless sessions | Stateless auth design |
| `@PreAuthorize("hasRole('ADMIN')")` + ownership checks in the service layer | RBAC done declaratively, not with scattered `if` checks |
| `@ControllerAdvice` mapping every domain exception to `{timestamp,status,error,message,path}` | Consistent API error contracts |
| `@Version` optimistic locking on account status, pessimistic on balance | Choosing the right locking strategy per access pattern |

Full reasoning behind each of these is in [DESIGN.md](DESIGN.md) — read that
the night before an interview, not this file.

## 8. Project layout

```
src/main/java/com/secureledger/
  config/      JWT issuance/validation, security filter chain, CORS
  controller/  request/response mapping + validation only
  dto/         request/response records, Bean Validation constraints
  entity/      JPA entities, enums, balance-mutation guards
  exception/   domain exceptions + global handler
  repository/  Spring Data interfaces, the PESSIMISTIC_WRITE lock query
  service/     all business rules, @Transactional boundaries, locking
scripts/
  verify.ps1   end-to-end live verification (Windows / PowerShell)
  verify.sh    end-to-end live verification (Linux / macOS / Git Bash)
postman/
  SecureLedger.postman_collection.json
```

## 9. Pushing this to GitHub

This project is already a local git repository with a clean commit history.
To publish it:

1. Create an empty repo on GitHub (no README/license/gitignore — this repo
   already has them, and adding them on GitHub's side just creates a merge
   conflict on first push).
2. Point your local repo at it and push:
   ```bash
   cd secureledger        # the folder containing pom.xml and .git
   git remote add origin https://github.com/<your-username>/secureledger.git
   git branch -M main
   git push -u origin main
   ```
3. **Before pushing**, double check nothing sensitive is staged —
   `git status` should be clean, and secrets should only ever live in local
   env vars, never in a committed file:
   ```bash
   git status
   git log --oneline -1 -- .env        # should return nothing; .env is gitignored
   ```
   `.gitignore` already excludes `target/`, `.env`/`*.env`, IDE folders, and
   build artifacts, so `application.yml`'s `${DB_PASSWORD:...}`-style
   placeholders are the only "credentials" that will ever be visible in the
   repo — which is intentional and safe.

From then on, ordinary git workflow applies (`git add`, `git commit`,
`git push`) — no special handling needed.

## 10. What's *not* yet verified (be upfront about this in an interview)

The happy path plus the edge cases in `scripts/verify.*` (over-withdrawal,
no-token, idempotency replay, freeze/unfreeze) have been run against a real
Postgres instance. Not yet exercised on a live server (though covered by
`mvn clean test`, see `BankingFlowIntegrationTest` /
`ConcurrentTransferTest`):

- concurrent-transfer correctness under real Postgres row locking (only
  proven against H2 so far — see the note in section 4)
- ownership/authorization edge cases beyond ADMIN-only endpoints
- Postman collection's full negative-case suite
- Docker/Swagger/rate-limiting (explicitly out of scope for Phase 1)
