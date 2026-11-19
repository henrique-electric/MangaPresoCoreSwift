# MangaPreso Swift Core

`MangaPresoCore` is a dependency-free Swift 6 package for the MangaPreso catalog and reader API. It calls ManGeek, MangaFlix, Mediocre, and MangaDex directly. Open `Package.swift` in Xcode or add this directory as a local Swift package and link the `MangaPresoCore` product. The package targets iOS 16+, macOS 13+, and Linux.

```swift
import MangaPresoCore

let catalog = CatalogAPI()
let results = try await catalog.search(query: "One Piece")
let chapter = try await catalog.chapter(id: "mf_some-chapter-id")
let imageURLs = chapter["pages"].array?.compactMap(\.text) ?? []
```

`CatalogAPI` combines providers, caches home results for 45 seconds, and dispatches details and chapters by ID prefix. Each provider can also be called directly. Custom base URLs and an injectable HTTP transport support different deployments and offline tests.

| Provider | Default | ID prefix | Operations |
| --- | --- | --- | --- |
| ManGeek | On | Unprefixed | Home, title and tag search, manga, chapter |
| MangaFlix | On | `mf_` | Home, title search, manga, chapter, genres |
| Mediocre | Off | `md_` | Home, title search, manga, chapter |
| MangaDex | On | `mg_` | Title search, manga, chapter |

MangaFlix requests Portuguese content and receives the adult-content option on home, search, and genre requests. MangaDex uses Brazilian Portuguese availability for search and filters chapter feeds to that language. Media URLs are returned as strings. The default ManGeek endpoint uses plain HTTP, so an Apple host app needs a domain-specific App Transport Security exception or a compatible HTTPS base URL.

To enable Mediocre, inject credentials from the host's secret store or supply an existing access token. The provider keeps its session in memory and retries once after a 401 when credentials are available.

```swift
let catalog = CatalogAPI(
    mediocre: MediocreProvider(credentials: .init(email: email, password: password))
)
```

## HTTP integration

`CatalogRoutes` accepts an HTTP method and origin-form request target. It supports `/api/health`, `/api/providers`, `/api/home`, `/api/search`, `/api/manga/{id}`, and `/api/chapter/{id}`. It preserves the current Python provider-list response, which omits MangaDex even when MangaDex is active in search and ID routing.

```swift
import Foundation
import MangaPresoCore

let routes = CatalogRoutes()
let response = try await routes.handle(method: "GET", target: "/api/search?q=One+Piece")
let data = try JSONEncoder().encode(response.body)
// Send data as application/json with response.status from your HTTP framework.
```

The package is a library with a route adapter. For server deployments, the host supplies the HTTP listener and application authentication middleware. The Python service remains the entry point for Supabase authentication, profile and admin operations, image proxying, ZIP downloads, and SPA hosting.

## Request flow

1. [CatalogRoutes](Sources/MangaPresoCore/CatalogRoutes.swift) parses the HTTP request target and query flags. Swift callers can start with `CatalogAPI` directly.
2. [CatalogAPI](Sources/MangaPresoCore/CatalogAPI.swift) checks the home cache, runs searches across enabled sources, and uses the ID prefix to choose a provider for manga and chapter requests.
3. The provider builds its upstream request using [HTTP](Sources/MangaPresoCore/HTTP.swift). ManGeek returns its original fields, while the other providers map their data to the shared catalog keys.
4. The route adapter maps the result to a status and JSON body. The host server sends the response.

[CatalogTests](Tests/MangaPresoCoreTests/CatalogTests.swift) replaces the upstream transport with fixtures to exercise the same flow offline.

## Verification

Run from the repository root.

```sh
swift test --package-path swift
```

Tests inject mock HTTP responses and run without provider credentials or network access.
