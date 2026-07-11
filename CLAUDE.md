# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A Zig CLI (`github-stats`) that collects a user's GitHub statistics via the GitHub API and renders them into two SVG images (`overview.svg`, `languages.svg`). It is normally run from `.github/workflows/main.yml`, which commits the generated SVGs to the `generated` branch. Statistics can also be dumped to / loaded from JSON.

## Commands

Requires Zig 0.16.0 exactly (`minimum_zig_version` in `build.zig.zon`; CI pins 0.16.0). There are no external dependencies.

```bash
zig build                      # build to zig-out/bin/github-stats (default: ReleaseSafe)
zig build -Doptimize=Debug     # debug build with full stack traces
zig build test                 # run all tests (tests are inline in the source files)
zig build run -- --access-token TOKEN --debug   # build and run
zig build release              # cross-compile ~50 targets into zig-out/bin (used by the tag-triggered release workflow)
zig fmt src build.zig          # formatting; code sticks to 80-column lines
```

There is no per-test filter step wired up; `zig build test` compiles `src/main.zig` (which does `refAllDecls`) and runs every `test` block reachable from it.

Running the tool locally against the real API is the practical integration test:

```bash
zig build run -- --access-token "$TOKEN" --json-output-file stats.json --debug
zig build run -- --json-input-file stats.json     # re-render SVGs offline, no API calls
```

## Architecture

`src/main.zig` orchestrates: parse args → build a `Statistics` (from the API or from JSON) → optionally dump JSON → aggregate across repositories (applying exclusions) → fill both SVG templates → write files. A path of `-` means stdin/stdout in `readFile`/`writeFile`.

**`src/argparse.zig` — config comes from the `Args` struct, not a flag table.** Fields of `Args` in `main.zig` are reflected over at comptime to produce, in precedence order: CLI flags (`--kebab-case`), environment variables (case-insensitive match on the field name, e.g. `ACCESS_TOKEN`), then struct default values. Adding a config option means adding a field to `Args` — the CLI flag, env var, usage text, and freeing logic all follow automatically. Only `bool`, integer, and `[]const u8` (optionally wrapped in `?`) field types are supported; anything else is a compile error.

**`src/statistics.zig` — the data model and all GitHub API work.** `Statistics` is a top-level struct (file-as-struct) that is both the in-memory model and the JSON schema, so `--json-output-file` and `--json-input-file` round-trip through the same type. Notable behaviors:

- Repos are discovered per contribution year via GraphQL `contributionsCollection`. GitHub caps `commitContributionsByRepository` at 100, so when a year hits the cap, `getReposByYear` recursively subdivides the 12-month window by prime factors of 12 (2, then 3) and re-queries; when it can no longer subdivide it warns and proceeds with possibly-incomplete data.
- Contribution counts are accumulated twice: into the flat all-time totals on `Statistics`, and into `Statistics.yearly` (one `YearContributions` per contribution year, sorted oldest first) which drives the year chart. Because a year's window can be recursively subdivided, several `getReposByYear` calls add into the same `yearly` entry — the entry is passed down through `context.year_stats`. `yearly` defaults to empty so JSON dumped by older versions still parses.
- Lines changed come from the REST `/stats/contributors` endpoint, which GitHub has broken and heavily rate-limits. `getLinesChanged` drives a priority queue of repos keyed by retry timestamp with short random delays (deliberately *not* exponential backoff — short delays work better here). After `--max-retries` attempts it falls back to `src/git.zig`, which bare-clones the repo (`--filter=blob:limit=1m`) with the token in the URL and tallies `git log --numstat` filtered by the user's emails. Parse failures on that endpoint are logged and skipped rather than propagated.
- The user's emails come from `/user/emails` (needs the `user:email` token scope) and exist solely to attribute commits in that git fallback.

**`src/template.zig` — `{{field_name}}` substitution.** `fill` reflects over the passed struct's fields at comptime; unsigned ints render with thousands separators (`decimalToString`, also reused directly by `main.zig`), `[]const u8` renders verbatim, unknown placeholders return `error.InvalidField`. The templates in `src/templates/*.svg` are `@embedFile`d into the binary (overridable with `--overview-template` / `--languages-template`, and dumpable with `--dump-overview-template` / `--dump-languages-template`).

There are no loops or conditionals in the template language, so anything list- or chart-shaped is built as a raw HTML/SVG string in `main.zig` and injected as a single placeholder: `languages()` (the language bar and legend), `contributionBreakdown()` (`{{ contribution_progress }}` / `{{ contribution_list }}`), and `yearChart()` (`{{ year_chart }}`). Follow that pattern rather than extending the template engine. The cards live inside a `<foreignObject>`, i.e. they are HTML laid out by the browser, but the SVG's `width`/`height` and the `foreignObject`'s box are **fixed** — if you add content, content taller than that box is silently clipped. Both charts are sized as percentages so the SVG stays a fixed size regardless of how many years or languages a user has.

**`src/http_client.zig`** wraps `std.http.Client.fetch` with `graphql()` and `rest()` helpers. It retries `error.HttpConnectionClosing` by tearing down and recreating the whole client (a workaround for a Zig keep-alive bug). Response bodies are caller-freed with `client.allocator`.

**`src/glob.zig`** is a case-insensitive recursive-backtracking `*` matcher used for `--exclude-repos` and `--exclude-langs`. It does *not* treat `/` specially, so `jstrieb/*` works as a repo-owner filter.

## Zig 0.16 conventions used here

- `main` takes `std.process.Init`; the `std.Io` instance is threaded explicitly through every function that does I/O, sleeps, gets the clock, or spawns a process. Don't reach for global/blocking I/O.
- Memory is managed manually with an explicit allocator: long-lived data owned by `Statistics` is duped from the gpa and released in `deinit`; per-request scratch data goes in an `ArenaAllocator`. New allocations in `getReposByYear`/`getRepos` need matching `errdefer` cleanup in the same style as the existing code.
- Logging goes through the custom `logFn` in `main.zig`; the level is set at runtime by `--silent` / `--verbose` / `--debug`, and `std_options.log_level` is pinned to `.debug` so debug logs survive release builds.
