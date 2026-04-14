# Atlas Graph

A native codebase knowledge-graph tool built in Zig. It indexes Zig, C, C++, and Objective-C repositories into a queryable graph with an interactive REPL and a WebGPU-powered browser visualization.

## Features

- **Fast parallel indexing** — multi-threaded file parsing with in-memory index for O(1) lookups, cached prepared statements, and transactional SQLite writes. Indexes ~500 files in ~2 seconds.
- **Interactive REPL** — search symbols, trace callers/callees, inspect imports, browse nodes and edges.
- **WebGPU graph viewer** — embedded web UI with GPU-accelerated rendering, d3-force layout, zoom/pan, node selection, neighbor highlighting, search, and kind filters. Starts with `web` in the REPL.
- **SQLite persistence** — graph data stored locally for fast queries.
- **Multi-language support** — Zig (AST-based), C/C++/Objective-C (file-level classification with extension points for deeper indexing).

## Requirements

- Zig 0.15.2 or newer

No other dependencies — SQLite is compiled from a vendored source. Builds on Linux, macOS, and Windows.

## Run

```bash
zig build run -- /path/to/repo
```

If no path is provided, the app uses the current working directory.

## Test

```bash
zig build test
```

## REPL Commands

| Command | Description |
|---------|-------------|
| `find <name>` | Search symbols by name |
| `file <path>` | List symbols defined in a file |
| `imports <path>` | Show what a file imports |
| `importedby <path>` | Show what files import a file |
| `callers <name>` | Show functions that call a symbol |
| `callees <name>` | Show functions a symbol calls |
| `node <id>` | Show details for a node by ID |
| `edges <id>` | Show all edges for a node |
| `web [port]` | Start web UI (default port 8080) |
| `webstop` | Stop web UI |
| `stats` | Show graph statistics |
| `help` | Show help |
| `quit` | Exit |

## Web UI

Type `web` in the REPL to start the embedded web server, then open `http://127.0.0.1:8080/` in a WebGPU-capable browser (Chrome 113+, Edge 113+, Firefox 121+).

The web UI provides:

- Force-directed graph layout with GPU-accelerated rendering
- Color-coded nodes by kind (file, function, type, test, etc.)
- Directional arrows on edges
- Click to select nodes and inspect edges
- Hover to highlight connected subgraph (with dwell delay to prevent flicker)
- Search with zoom-to-result
- Node kind and edge kind filter checkboxes
- Files-only mode for large graphs
- Drag nodes to reposition, scroll to zoom, drag background to pan

## Project Structure

```
src/
  main.zig                 Entry point, CLI argument handling
  app/
    app.zig                Application coordinator, REPL loop
  graph/
    schema.zig             Node/edge kinds, language classification
  index/
    index_manager.zig      Parallel indexing pipeline, edge resolution
    zig_indexer.zig         Zig AST-based symbol extraction
  storage/
    store.zig              SQLite graph store, query methods
  ui/
    ui.zig                 Terminal UI, spinner animation
  web/
    server.zig             HTTP server, JSON API
    index.html             WebGPU single-page graph viewer
```

## API Endpoints

The web server exposes a JSON API:

| Endpoint | Description |
|----------|-------------|
| `GET /` | Web UI (embedded HTML) |
| `GET /api/stats` | Graph statistics |
| `GET /api/graph` | Full graph (all nodes and edges) |
| `GET /api/nodes?q=X` | Search symbols by name |
| `GET /api/node?id=X` | Get a single node by ID |
| `GET /api/edges?id=X` | Get outgoing/incoming edges for a node |
| `GET /api/callers?name=X` | Get callers of a symbol |
| `GET /api/callees?name=X` | Get callees of a symbol |
| `GET /api/imports?path=X` | Get imports of a file |
| `GET /api/importedby?path=X` | Get files that import a file |
| `GET /api/file/symbols?path=X` | Get symbols defined in a file |
