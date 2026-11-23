<img src="https://capsule-render.vercel.app/api?type=waving&color=0:0f2027,50:203a43,100:2c5364&height=180&section=header&text=SecureLedger&fontSize=50&fontColor=ffffff&fontAlignY=38&desc=Core%20banking%20transaction%20API%20%C2%B7%20Java%2017%20%C2%B7%20Spring%20Boot%203&descAlignY=60&descSize=16" width="100%"/>

<div align="center">

<img src="https://skillicons.dev/icons?i=java,spring,postgres,maven&theme=dark" />
<br/><br/>
<img src="https://img.shields.io/badge/Concurrency-pessimistic%20locking-00E5FF?style=flat-square" />
<img src="https://img.shields.io/badge/Transfers-idempotent-black?style=flat-square" />
<img src="https://img.shields.io/badge/Tested-25%20concurrent%20transfers-C21325?style=flat-square" />

</div>

> 📚 Short on time before an interview? Open the **Deep dive** at the bottom of this page.

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


---

<details>
<summary><b>📚 Deep dive: interview notes (click to expand)</b></summary>

### 1. Elevator pitch (30 seconds)
SecureLedger is a core banking REST API in Java 17 and Spring Boot 3. Users register, open accounts, deposit, withdraw and transfer money. The interesting part isn't the features; it's correctness under concurrency. Two transfers hitting the same account at the same moment must never lose money, double-spend, or deadlock, and a retried request must never move money twice.

### 2. Architecture and request flow
```text
Client ──JWT──► Spring Security filter (JwtAuthFilter)
                    │
                    ▼
        Controller (Auth / Account / Transfer)  ← thin: validation + HTTP mapping only
                    │
                    ▼
        Service layer (@Transactional)          ← ownership checks, frozen checks, balance checks
                    │
                    ▼
        Spring Data JPA repositories ──► PostgreSQL (NUMERIC(19,4) money columns)
                    │
                    └──► AuditService ──► audit_log (append-only)
```
**A transfer, step by step:**
1. `POST /transfers` arrives with an `Idempotency-Key` header and a JWT.
2. If a transaction with that key already exists, the original result is returned (`200`) and nothing moves.
3. Both accounts are locked with `SELECT … FOR UPDATE`, always **in ascending id order**.
4. Ownership, frozen status and sufficient funds are checked.
5. Balances are updated, and two rows are written: `TRANSFER_OUT` (key `{key}:OUT`) and `TRANSFER_IN` (key `{key}:IN`).
6. An audit row is appended, the transaction commits, and the locks are released.

**Endpoints:** `POST /auth/register` · `POST /auth/login` · `POST /accounts` · `GET /accounts` · `GET /accounts/{id}` · `POST /accounts/{id}/deposit` · `POST /accounts/{id}/withdraw` · `GET /accounts/{id}/transactions` · `PATCH /accounts/{id}/freeze` (ADMIN) · `PATCH /accounts/{id}/unfreeze` (ADMIN) · `POST /transfers`

### 3. Key design decisions and trade-offs
| Decision | Why | Trade-off |
|:--|:--|:--|
| `NUMERIC(19,4)` + `BigDecimal`, compared with `compareTo` | Floats can't represent 0.1 exactly; errors accumulate in a ledger. `BigDecimal.equals` also compares scale (100.00 ≠ 100.0000) | More verbose arithmetic |
| `READ COMMITTED` + `SELECT … FOR UPDATE` instead of `SERIALIZABLE` | Locks exactly the two rows a transfer touches; no surprise serialization aborts under contention | Correctness depends on taking the right locks in code |
| **Pessimistic** locks for money, **optimistic** (`@Version`) for freeze/unfreeze | "Retry the money movement" is a dangerous failure mode; status changes are rare and safe to retry | A busy account briefly blocks concurrent requests |
| Lock accounts in ascending id order | A→B and B→A at once would otherwise each hold one lock and wait forever (deadlock) | None worth mentioning |
| Idempotency key checked first **and** `UNIQUE` in the DB | The pre-check is only a fast path; two concurrent requests can both pass it, and the unique constraint is the real guarantee (second insert → `409`) | One key becomes 2 rows (`:OUT` / `:IN`) |
| Same key + different payload → `409` | Reusing a key for a different request is a client bug, not a retry | Clients must generate fresh keys |
| Append-only audit log | An editable audit trail isn't evidence | Production also needs `REVOKE UPDATE, DELETE` at DB level |
| First registered user becomes ADMIN | Simple bootstrap with no seed scripts | Not how you'd onboard admins in production |

### 4. Where the important code lives
- `service/TransferService.java`: locking order, idempotency, the transfer itself
- `repository/AccountRepository.java`: `findByIdForUpdate` with `@Lock(PESSIMISTIC_WRITE)`
- `config/SecurityConfig.java`, `JwtService.java`, `JwtAuthFilter.java`: stateless JWT auth
- `exception/GlobalExceptionHandler.java`: maps domain exceptions to clean HTTP errors
- `DESIGN.md`: the full reasoning behind every decision above
- `src/test/.../ConcurrentTransferTest.java`: the proof that it works

### 5. How I proved it works
`ConcurrentTransferTest` fires **25 transfers at once** (a `CountDownLatch` releases all threads together on a fixed thread pool). It then asserts that every transfer succeeded, both final balances are exactly right, and the total money across both accounts is unchanged, meaning no lost updates. `BankingFlowIntegrationTest` covers the end-to-end flow, including idempotent replay returning `200`.

### 6. Limitations and what I'd do next
- A single mutable `balance` column. A real ledger uses **double-entry bookkeeping**, with balance as a derived sum.
- The **outbox pattern** for notifying other systems, so "money moved" and "event published" can't drift apart.
- **Reconciliation jobs** that recompute balances from history and alert on drift.
- DB-level `REVOKE UPDATE, DELETE` on `audit_log`; Docker, Swagger and rate limiting were still to do.

### 7. Likely interview questions
- **Why not just use `SERIALIZABLE`?** Postgres implements it with optimistic conflict detection: under contention, transactions abort and the app must retry. Narrow row locks give the same guarantee for this workload with predictable latency.
- **How do you prevent deadlocks?** I always acquire locks in ascending account id, so two opposite transfers queue on the same first row instead of each holding one.
- **What if the client times out and retries a transfer?** Same `Idempotency-Key` → original result returned, no second debit. If two retries race, the DB unique constraint rejects the second insert.
- **Why `compareTo` instead of `equals` on `BigDecimal`?** `equals` also compares scale, so `100.00` and `100.0000` would be "different".
- **Optimistic vs pessimistic locking, when would you use each?** Optimistic for rare, low-contention writes where a retry is harmless (freeze). Pessimistic for hot rows where retrying is dangerous (money).
- **How would you scale this?** Stateless JWT means horizontal app scaling is easy. The bottleneck is hot account rows; beyond that, sharding by account and double-entry ledgers.

</details>
