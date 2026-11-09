# Ledgerline: iOS Architecture

## Context
Ledgerline is a shared-expenses app for small groups (flatmates, trips): add an expense, split it, see who owes whom, settle up. This architecture lets several developers work **in parallel with minimal overlap**, and keeps the app **modular and testable** from the first commit.

**Current state:** only the Tuist app shell exists (`App/`, `Project.swift`, and a `Makefile` with `generate`, `build`, `test`, `lint` and `clean`). None of the Swift packages below have been created yet. Section 7 lists what gets built next.

Decisions:
- **Sync:** an HTTP API backend. iOS is offline-first and the server is the authority.
- **UI pattern:** MVVM with SwiftUI and `@Observable`, using protocol-based dependency injection. No TCA.
- **Tooling:** Tuist generates the app shell, demo apps and schemes. Every module (core and features) is a **local Swift package**.
- **Persistence:** SwiftData, kept entirely inside `LedgerPersistence`.

Defaults (each is easy to change):
- iOS 18 minimum
- Swift 6 language mode with strict concurrency
- Swift Testing for unit tests, XCUITest for UI tests
- Tool versions pinned with `mise`

---

## 1. Module map

```
                         ┌──────────────────────────── App (Tuist target) ───────────────────────────┐
                         │ composition root · AppRouter · deep links · live/UI-test containers        │
                         └───┬──────────────┬───────────────┬───────────────┬──────────────┬──────────┘
                             │              │               │               │              │
   Features (1 pkg each) ►  AuthFeature  GroupsFeature  ExpensesFeature  BalancesFeature  SettleUpFeature
                             └──────┬───────┴───────┬───────┴───────┬───────┴──────┬───────┘
                                    ▼               ▼               ▼              ▼
   Packages/DesignSystem ►     DesignSystem   Packages/Core ►  LedgerClients (protocols) · LedgerRouting
                                                               LedgerFoundation · LedgerTestSupport (DEBUG)
                                                                        │
                                                                        ▼
                                                                  LedgerDomain (pure Swift, no deps)
                                                                        ▲
   Packages/Data (App-only) ►  LedgerAPI (OpenAPI) · LedgerPersistence (SwiftData) · LedgerSync · LedgerAuth
```

### Packages and their targets

| Package (path) | Targets | Platforms | Owner |
|---|---|---|---|
| `Packages/Core` | `LedgerDomain`, `LedgerFoundation`, `LedgerClients`, `LedgerRouting`, `LedgerTestSupport` | iOS 18, macOS 15 (so `swift test` runs fast on the host) | Platform |
| `Packages/DesignSystem` | `DesignSystem` | iOS 18 | Design-eng |
| `Packages/Data` | `LedgerAPI`, `LedgerPersistence`, `LedgerSync`, `LedgerAuth` | iOS 18, macOS 15 | Platform/Data |
| `Packages/Features/<Name>Feature` | `<Name>Feature`, `<Name>FeatureTests` | iOS 18 | One feature dev each |

### Dependency rules
SwiftPM enforces these, because a package can only import what its manifest declares. CI also checks them.

| Module | May depend on |
|---|---|
| `LedgerDomain` | nothing |
| `LedgerFoundation` (Clock, IDGenerator, Logger, FeatureFlags) | nothing |
| `LedgerClients` (repository and service protocols) | Domain, Foundation |
| `LedgerRouting` (`AppRoute`, `Navigator` protocol) | Domain (IDs only) |
| `LedgerTestSupport` (in-memory fakes, fixtures, `SpyNavigator`; whole target wrapped in `#if DEBUG`) | Clients, Domain, Foundation, Routing |
| `DesignSystem` | Domain (for `MoneyText` etc.) |
| `Data/*` | Clients, Domain, Foundation, SwiftData, plus the swift-openapi packages |
| `*Feature` | Domain, Foundation, Clients, Routing, DesignSystem, TestSupport (for previews and tests only) |
| **Features: never** | other features, or anything in `Data` |
| App | everything |

### Third-party dependencies (kept small)
- `apple/swift-openapi-generator`, `-runtime` and `-urlsession`: a typed API client generated from the backend contract.
- `pointfreeco/swift-snapshot-testing`: tests only, used for DesignSystem and key screens.
- SwiftLint and SwiftFormat run as tools through `mise`. They are not package dependencies.

### Why this shape
- **Dependencies point inward** (ports and adapters, also called Clean Architecture).
  - `LedgerDomain` sits at the centre.
  - `LedgerClients` holds the ports: protocols that describe what data is needed.
  - `Data` holds the adapters: the live API, storage and sync code.
  - Features depend only on the ports. The App is the composition root, the only place that knows concrete types.
- **A feature is a package with its own demo app and test support.** This mirrors Tuist's "Modular Architecture" (TMA), which pairs each feature with example and testing targets.
- **Interface and live code are split** so features compile and test without the real backend or database. Point-Free's isowords codebase and large-team iOS setups modularize the same way.
- **The rule for adding a boundary:** add one only where ownership differs or a test seam is needed. That's why there are three shared packages rather than a dozen.

### Small support modules
- **`LedgerFoundation`:** dependency-free environment services that every layer uses and tests need to control:
  - `LedgerClock` (the current time)
  - `IDGenerator` (UUIDs)
  - a `Logger` wrapper (os.Logger with privacy redaction)
  - `FeatureFlags`

  Injecting these makes tests deterministic, for example a fixed date and predictable IDs.
- **`LedgerRouting`:** the shared navigation vocabulary, so features can open each other's screens without importing each other.
  - `AppRoute` has one sub-enum per feature, for example `.expenses(.add(groupID))`.
  - The `Navigator` protocol has `push`, `present` and `dismiss`.
  - The App implements `Navigator` and maps each route to a view. Tests use `SpyNavigator` to check where a screen navigated.

---

## 2. Layer responsibilities

### LedgerDomain (the most critical code, with near-100% test coverage)
- **`Money`:** `amountMinor: Int64` plus a `Currency` (ISO 4217 code and minor units). Never use `Double`. In v1 each group has one currency, but `Money` is currency-aware from the start.
- **Entities:** `User`, `Group`, `Member`, `Expense`, `Settlement`, plus typed IDs (`Tagged<UUID>`-style).
  - A `Member` has an optional `userID`. That lets someone add a flatmate who hasn't signed up yet; the flatmate claims the slot later through an invite link.
- **`Expense`:**
  - Fields: `total`, `payers: [Member.ID: Money]` (more than one payer is allowed), `split: SplitStrategy`, `shares: [Member.ID: Money]` (computed), `date`, `category`, `note`, `version`.
  - `SplitStrategy` is one of `.equal(Set<Member.ID>)`, `.exact([ID: Money])`, `.percentage([ID: basisPoints])` or `.shares([ID: Int])`.
- **`Allocator.distribute(total:weights:)`:** one largest-remainder routine behind the equal, percentage and share splits. Leftover cents go out deterministically, ordered by member ID. For example, 10.00 split three ways gives 3.34, 3.33 and 3.33.
- **`BalanceCalculator`:** net per member = paid − owed + settlements sent − settlements received.
- **`DebtSimplifier`:** a greedy match of the largest debtor against the largest creditor. It produces at most n−1 transfers and breaks ties deterministically.
- **Invariants checked in tests:**
  - The shares add up to the total.
  - The payers add up to the total.
  - Net balances add up to 0.
  - Applying the simplified transfers takes every balance to 0.

### LedgerClients: the contracts that make parallel work possible
- Protocols are `Sendable` with async APIs, and reads come back as `AsyncStream` of domain values. Features never see DTOs or database rows.
- Shared protocols:
  - `GroupRepository`
  - `ExpenseRepository`
  - `SettlementRepository`
  - `SessionClient` (current user, Sign in with Apple, sign out)
  - `SyncStatusProvider`
  ```swift
  public protocol ExpenseRepository: Sendable {
      func expenses(in group: Group.ID) -> AsyncStream<[Expense]>
      func save(_ draft: ExpenseDraft) async throws -> Expense
      func delete(_ id: Expense.ID) async throws
  }
  ```
- **Rule:** a service that only one feature uses (a receipt scanner, say) is declared as a protocol inside that feature's package. The App supplies the implementation. Shared Core only grows when data really is shared.

### Data: live implementations, imported only by the App
- **LedgerAPI**
  - The OpenAPI build plugin generates the client from `openapi.yaml`, which is the contract shared with the backend team.
  - A mapping layer converts DTOs into Domain types, so generated types never leave this target.
  - An `AuthMiddleware` adds the bearer token and refreshes it on a 401.
- **LedgerPersistence (SwiftData)**
  - The `@Model` classes are **internal** to this target: `GroupRecord`, `MemberRecord`, `ExpenseRecord` (with payer and share child records), `SettlementRecord`, `OutboxMutation`, `SyncCursor`.
    - Each record has an `@Attribute(.unique)` UUID, so changes pulled from the server upsert cleanly.
    - Repositories map records to Domain structs. Records are non-Sendable reference types tied to a `ModelContext`, so they never leave this target.
  - Writes go through a `@ModelActor` actor, off the main thread. One save writes the record and its outbox entry together, then pokes the sync engine.
  - Reads come back as `AsyncStream`s that refetch when `ModelContext.didSave` fires.
    - Features don't use `@Query`. That's deliberate: it keeps them storage-agnostic and testable with fakes.
  - The schema is versioned with `VersionedSchema` and `SchemaMigrationPlan` from v1.
  - SwiftData's CloudKit integration stays off, because `LedgerSync` owns syncing with the server.
- **LedgerSync** (an `actor`)
  - Uses the outbox pattern. IDs are UUIDs generated on the client, which makes creating things offline safe and makes retries idempotent.
  - **Push:** `POST /sync/mutations` sends a batch, using each mutation's ID as its idempotency key.
  - **Pull:** `GET /sync?since=<cursor>` returns changed entities plus tombstones for deletions.
  - **Conflicts:** the server is authoritative. Each entity carries a `version`; on a mismatch the client refetches and tells the user it was edited elsewhere.
  - **When it runs:** on foreground, after local writes (debounced), on pull-to-refresh, and from `BGAppRefreshTask`. Silent push comes later.
- **LedgerAuth:** Sign in with Apple, exchanged for backend tokens through `POST /auth/apple`, with the tokens stored in the Keychain.
- **Balances** are always derived on the device from local data, so they work offline. They are never stored as a source of truth.

### Features (MVVM template)
```
Packages/Features/ExpensesFeature/
  Package.swift                 # swift-tools 6.2; swiftSettings: .defaultIsolation(MainActor.self)
  Sources/ExpensesFeature/
    ExpensesFeature.swift       # the ONLY public surface: Dependencies + entry-view factories
    ExpenseList/  ExpenseListView.swift, ExpenseListViewModel.swift
    AddExpense/   AddExpenseView.swift, AddExpenseViewModel.swift, SplitEditor/…
    Resources/    Localizable.xcstrings, Assets.xcassets
  Tests/ExpensesFeatureTests/   # Swift Testing; view models tested with fakes
  Demo/ExpensesDemoApp.swift    # demo app, built as a Tuist target, seeded with fakes
```
```swift
public enum ExpensesFeature {
    public struct Dependencies {            // declares exactly what this feature needs
        public var expenses: any ExpenseRepository
        public var groups: any GroupRepository
        public var clock: any LedgerClock
        public var ids: any IDGenerator
    }
    public static func expenseList(group: Group.ID, deps: Dependencies, navigator: any Navigator) -> some View
    public static func addExpense(group: Group.ID, deps: Dependencies, navigator: any Navigator) -> some View
}
```
- View models are `@Observable` classes isolated to the main actor. They expose a small `state`, consume `AsyncStream`s inside `.task {}`, and contain no SwiftUI types, so they unit-test cleanly.
- **Cross-feature navigation:**
  - Features call `navigator.push(.balances(.groupSummary(id)))` and never import the other feature.
  - `AppRoute` is split into one sub-enum per feature (`GroupsRoute`, `ExpensesRoute`, …), each in its own file inside `LedgerRouting`.
- **Embedding another feature's UI** (for example, Group Detail showing the expense list and a balances summary): Groups receives view-factory closures from the App (`expensesSection: (Group.ID) -> AnyView`). It never receives the other feature's types.

### Initial feature split (one owner each)

| Feature | Scope |
|---|---|
| `AuthFeature` | Onboarding, Sign in with Apple, profile name and avatar |
| `GroupsFeature` | Group list, create or join a group (invite code or universal link), members and placeholder members, group settings, the Group Detail container |
| `ExpensesFeature` | Expense list, add and edit expense, the split editor (equal, exact, percent, shares), expense detail |
| `BalancesFeature` | Who owes whom, simplified debts, per-member breakdown |
| `SettleUpFeature` | Recording a payment between members, settlement history |

`ActivityFeature`, receipt scanning, widgets and push notifications can be added later the same way. Extensions become Tuist targets that reuse the Core and Data packages.

### App (composition root, kept thin)
- `AppContainer.live()` builds the database, API client, sync engine and repositories.
- `AppContainer.uiTest()` uses `LedgerTestSupport` fakes seeded with fixtures. It is selected by the `--ui-testing` launch argument.
- **One file per feature:** `App/Sources/Composition/ExpensesComposition.swift` builds that feature's `Dependencies` and resolves its routes. Feature devs edit only their own file.
- `AppRouter` is `@Observable` and implements `Navigator`. It holds a `NavigationPath` and a sheet state, and its root `switch` has exactly one case per feature that delegates to that feature's composition file.

---

## 3. Repo layout
```
ledgerline/
├── Tuist.swift · Project.swift · Workspace.swift · Makefile · mise.toml · .xcode-version
├── Tuist/
│   ├── ProjectDescriptionHelpers/  # Features.swift (one line per feature), .demoApp(for:) helper, shared settings
│   └── Templates/feature/          # `tuist scaffold feature --name X` → full package skeleton + demo + tests
├── App/{Sources,Resources,Tests,UITests}
├── Packages/{Core,DesignSystem,Data}/   and   Packages/Features/<Name>Feature/
├── scripts/  check-module-boundaries.sh · test-all.sh
├── .github/workflows/ci.yml · .github/CODEOWNERS
└── docs/ARCHITECTURE.md · docs/adr/
```
- `Project.swift` lists each package with `packages: [.package(path:)]` (Xcode's native package integration), and the app links products with `.package(product:)`. Package sources stay live-editable in the workspace.
- The generated workspace has no schemes for the packages. Package tests run per package: `swift test --package-path …` for packages that also support macOS, or `xcodebuild` inside the package folder for iOS-only ones.
- The `.xcodeproj` and `.xcworkspace` files are generated and git-ignored. That means no `.pbxproj` merge conflicts.

---

## 4. How parallel work stays conflict-free

| Hotspot | Mitigation |
|---|---|
| Domain models and `LedgerClients` protocols | Frozen at the end of Phase 0. Later changes are additive only and reviewed by Platform through CODEOWNERS. |
| `AppRoute` | One sub-enum file per feature. The root enum gains one line per feature. |
| App composition | One composition file per feature. |
| Xcode project | Generated by Tuist, so there is no `.pbxproj`. `Features.swift` gains one line per feature, added by the scaffold template. |
| Strings and assets | A string catalog and asset catalog per package. Only shared tokens live in DesignSystem. |
| Fakes | One file per fake in `LedgerTestSupport`. |
| Backend not ready | Features build against fakes in their demo apps. The Data layer builds against `openapi.yaml`, with an optional Prism mock server for integration runs. |
| Unfinished work | Trunk-based development with short-lived branches. Incomplete flows hide behind `FeatureFlags` (in `LedgerFoundation`). |

CODEOWNERS maps each `Packages/...` directory to its owner. Changes to Core and Data need Platform's review.

---

## 5. Testing strategy

| Layer | How it's tested |
|---|---|
| Domain | Parameterized Swift Testing cases covering rounding, multiple payers, JPY (0 decimals) and BHD (3 decimals), plus the invariant tests over many generated inputs. Runs with `swift test` on macOS in seconds. |
| View models | Run on the main actor against in-memory fakes, a fixed `LedgerClock` and a sequential `IDGenerator`. `SpyNavigator` lets tests assert navigation. |
| Persistence | In-memory `ModelContainer` (`isStoredInMemoryOnly: true`): migrations, record↔Domain mapping, queries, upserts, and outbox entries written on save. |
| API | A mock `ClientTransport` from swift-openapi-runtime, covering DTO→Domain mapping and the auth refresh on 401. |
| Sync | A fake transport plus an in-memory database, covering offline queueing, retry and idempotency, cursor handling, tombstones and version conflicts. |
| DesignSystem | Snapshot tests in light, dark and large Dynamic Type. |
| App | Smoke tests that the composition wiring builds. A handful of XCUITest happy paths run against `AppContainer.uiTest()`: create a group, add an expense, see the balance, settle up. |

---

## 6. CI (GitHub Actions)
1. **Lint:** SwiftFormat and SwiftLint, `scripts/check-module-boundaries.sh`, and validation of the OpenAPI spec.
   - The boundary script fails the build if any `Packages/Features/*/Package.swift` has a path dependency on `Features/` or `Data`.
2. **Core and Data tests:** `swift test --package-path Packages/Core` (macOS host, fast), and the same for Data.
3. **Package tests:** a matrix of iOS Simulator runs, filtered by changed paths.
   - `scripts/test-all.sh` globs `Packages/**/Package.swift`, so a new feature is picked up with no shared file to edit.
   - A change to Core triggers every package's tests.
4. **App:** `tuist install && tuist generate`, then build the app and every demo app, then run the UI smoke tests.
5. **Flags:** CI runs `xcodebuild` with `-skipPackagePluginValidation` so the OpenAPI plugin can run.

---

## 7. Roadmap

**Phase 0: skeleton (Platform, about one week).** It creates:
1. **Tooling:** `mise.toml` (Tuist, SwiftLint, xcbeautify), `.gitignore` and the `Makefile` already exist. Still to add: SwiftFormat in `mise.toml`, and `.xcode-version`.
2. **Tuist:** `Tuist.swift` and `Project.swift` already exist (the `Ledgerline` app, `LedgerlineTests` and `LedgerlineUITests`). Still to add: demo apps from `Features.swift`, `Workspace.swift`, `ProjectDescriptionHelpers`, and the `Tuist/Templates/feature` template.
3. **`Packages/Core`:**
   - Domain types with the Allocator, BalanceCalculator and DebtSimplifier, plus their tests.
   - Foundation utilities.
   - The Client protocols.
   - The routing enums and the `Navigator` protocol.
   - TestSupport fakes and fixtures.
4. **`Packages/DesignSystem`:** tokens (color, type, spacing), `MoneyText`, `MemberAvatar`, `PrimaryButton`, and `AmountField`, with snapshot tests.
5. **`Packages/Data`:** a stub `openapi.yaml` (auth, groups, expenses, settlements, sync), the SwiftData `SchemaV1` with its migration plan, a `SyncEngine` skeleton, and a `LedgerAuth` skeleton.
6. **`Packages/Features/GroupsFeature`:** fully scaffolded as the reference implementation, including a view model, tests and a demo app.
   - The other four features are generated with `tuist scaffold feature` as empty shells, ready to hand off.
7. **App:** `LedgerlineApp`, `AppContainer` (live and uiTest), `AppRouter`, and the per-feature composition files.
8. **Repo:** `scripts/`, `.github/workflows/ci.yml`, `.github/CODEOWNERS` (placeholder team handles), `docs/ARCHITECTURE.md` (this plan, condensed), and `docs/adr/0001-module-structure.md`.

**Phase 1 (in parallel):**
- Each feature owner builds against fakes using their demo app.
- Platform/Data implements the API, persistence and sync against the spec.
- Design-eng grows the DesignSystem.

**Phase 2:**
- Switch to `AppContainer.live()` end to end.
- Integration runs against the mock or staging server.
- UI tests, then TestFlight.

---

## 8. Phase 0 acceptance checks
- `mise install && tuist install && tuist generate` opens `Ledgerline.xcworkspace` with no errors.
- `swift test --package-path Packages/Core` passes. The Domain tests cover the equal, exact, percent and share splits, the remainder distribution, the balance invariants and debt simplification.
- `xcodebuild test -scheme GroupsFeature -destination 'platform=iOS Simulator,name=iPhone 17'`, run from the package directory, passes.
- The `GroupsDemo` app and the main `Ledgerline` app (in `--ui-testing` mode) launch in the Simulator and show seeded groups.
- `scripts/check-module-boundaries.sh` passes. Adding a temporary `ExpensesFeature → GroupsFeature` dependency makes it fail.
- `tuist scaffold feature --name Sample` produces a package that builds, tests and runs its demo with no manual edits beyond the single `Features.swift` line.
- The CI workflow passes on a test PR.
