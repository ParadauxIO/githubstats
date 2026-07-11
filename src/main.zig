const builtin = @import("builtin");
const std = @import("std");
const version = @import("options").version;

const argparse = @import("argparse.zig");
const glob = @import("glob.zig");
const templateFill = @import("template.zig").fill;

const commify = @import("template.zig").decimalToString;

const HttpClient = @import("http_client.zig");
const Statistics = @import("statistics.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
    // Even though we change it later, this is necessary to ensure that debug
    // logs aren't stripped in release builds.
    .log_level = .debug,
};

var log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    else => .warn,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

const embedded_overview_template = @embedFile("templates/overview.svg");
const embedded_languages_template = @embedFile("templates/languages.svg");
const embedded_repositories_template = @embedFile("templates/repositories.svg");

/// How many repositories the repositories card lists. The card is a fixed size,
/// so more rows than this would be clipped.
const max_listed_repositories = 8;

const Args = struct {
    access_token: ?[]const u8 = null,
    json_input_file: ?[]const u8 = null,
    json_output_file: ?[]const u8 = null,
    silent: bool = false,
    debug: bool = false,
    verbose: bool = false,
    exclude_repos: ?[]const u8 = null,
    exclude_langs: ?[]const u8 = null,
    exclude_private: bool = false,
    exclude_forks: bool = false,
    overview_output_file: ?[]const u8 = null,
    languages_output_file: ?[]const u8 = null,
    repositories_output_file: ?[]const u8 = null,
    overview_template: ?[]const u8 = null,
    languages_template: ?[]const u8 = null,
    repositories_template: ?[]const u8 = null,
    max_retries: ?usize = 25,
    version: bool = false,
    dump_overview_template: ?[]const u8 = null,
    dump_languages_template: ?[]const u8 = null,
    dump_repositories_template: ?[]const u8 = null,

    const Self = @This();

    pub fn init(main_init: std.process.Init) !Self {
        return try argparse.parse(main_init, Self, struct {
            fn errorCheck(a: Self, stderr: *std.Io.Writer) !bool {
                if ((a.access_token == null or a.access_token.?.len == 0) and
                    a.json_input_file == null and !a.version)
                {
                    try stderr.print(
                        "You must pass an input file or a GitHub token.\n",
                        .{},
                    );
                    return false;
                }
                return true;
            }
        }.errorCheck);
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(Self).@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .optional => |optional| {
                    switch (@typeInfo(optional.child)) {
                        .pointer => |pointer| switch (pointer.size) {
                            .slice => if (@field(self, field.name)) |p|
                                allocator.free(p),
                            else => comptime unreachable,
                        },
                        .bool, .int => {},
                        else => comptime unreachable,
                    }
                },
                .pointer => |p| switch (p.size) {
                    .slice => allocator.free(@field(self, field.name)),
                    else => comptime unreachable,
                },
                .bool, .int => {},
                else => comptime unreachable,
            }
        }
    }
};

fn overview(
    arena: *std.heap.ArenaAllocator,
    stats: anytype,
    template: []const u8,
) ![]const u8 {
    const a = arena.allocator();
    return templateFill(a, template, stats);
}

fn languages(
    arena: *std.heap.ArenaAllocator,
    stats: anytype,
    template: []const u8,
) ![]const u8 {
    const a = arena.allocator();
    const progress = try a.alloc([]const u8, stats.languages.count());
    const lang_list = try a.alloc([]const u8, stats.languages.count());
    for (
        stats.languages.keys(),
        stats.languages.values(),
        progress,
        lang_list,
        0..,
    ) |language, count, *progress_s, *lang_s, i| {
        const color = stats.language_colors.get(language);
        const percent =
            100 * if (stats.languages_total == 0)
                0.0
            else
                @as(f64, @floatFromInt(count)) /
                    @as(f64, @floatFromInt(stats.languages_total));
        progress_s.* = try std.fmt.allocPrint(a,
            \\<span style="
            \\  background-color: {s}; 
            \\  width: {d:.3}%;
            \\" class="progress-item"></span>
        , .{ color orelse "#000", percent });
        lang_s.* = try std.fmt.allocPrint(a,
            \\<li style="animation-delay: {d}ms;">
            \\  <svg 
            \\      xmlns="http://www.w3.org/2000/svg" 
            \\      class="octicon"
            \\      style="fill: {s};" 
            \\      viewBox="0 0 16 16" 
            \\      version="1.1" 
            \\      width="16" 
            \\      height="16"
            \\  ><path 
            \\      fill-rule="evenodd" 
            \\      d="M8 4a4 4 0 100 8 4 4 0 000-8z"
            \\  ></path></svg>
            \\  <span class="lang">{s}</span>
            \\  <span class="percent">{d:.2}%</span>
            \\</li>
            \\
        , .{ (i + 1) * 150, color orelse "#000", language, percent });
    }
    return templateFill(
        a,
        template,
        struct { lang_list: []const u8, progress: []const u8 }{
            .lang_list = try std.mem.concat(a, u8, lang_list),
            .progress = try std.mem.concat(a, u8, progress),
        },
    );
}

/// Colors for each kind of contribution. Every kind is also labelled with text
/// and a count, so the color is never the only thing distinguishing them.
const contribution_kinds = [_]struct {
    label: []const u8,
    color: []const u8,
    field: []const u8,
}{
    .{ .label = "Commits", .color = "#2ea043", .field = "commits" },
    .{ .label = "Pull requests", .color = "#8957e5", .field = "prs" },
    .{ .label = "Reviews", .color = "#1f6feb", .field = "reviews" },
    .{ .label = "Issues", .color = "#db6d28", .field = "issues" },
    .{ .label = "Repos created", .color = "#d29922", .field = "new_repos" },
};

/// Split the single all-time contribution total into its five kinds, rendered
/// as a stacked bar plus a legend, reusing the markup that languages.svg uses.
fn contributionBreakdown(arena: *std.heap.ArenaAllocator, stats: anytype) !struct {
    progress: []const u8,
    list: []const u8,
} {
    const a = arena.allocator();
    const progress = try a.alloc([]const u8, contribution_kinds.len);
    const list = try a.alloc([]const u8, contribution_kinds.len);
    var total: usize = 0;
    inline for (contribution_kinds) |kind| {
        total += @field(stats, kind.field);
    }
    inline for (contribution_kinds, 0..) |kind, i| {
        const count: usize = @field(stats, kind.field);
        const percent =
            100 * if (total == 0)
                0.0
            else
                @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(total));
        progress[i] = try std.fmt.allocPrint(a,
            \\<span style="
            \\  background-color: {s};
            \\  width: {d:.3}%;
            \\" class="progress-item"></span>
        , .{ kind.color, percent });
        const pretty_count = try commify(a, count);
        defer a.free(pretty_count);
        list[i] = try std.fmt.allocPrint(a,
            \\<li style="animation-delay: {d}ms;">
            \\  <svg
            \\      xmlns="http://www.w3.org/2000/svg"
            \\      class="octicon"
            \\      style="fill: {s};"
            \\      viewBox="0 0 16 16"
            \\      version="1.1"
            \\      width="16"
            \\      height="16"
            \\  ><path
            \\      fill-rule="evenodd"
            \\      d="M8 4a4 4 0 100 8 4 4 0 000-8z"
            \\  ></path></svg>
            \\  <span class="lang">{s}</span>
            \\  <span class="percent">{s}</span>
            \\</li>
            \\
        , .{ (i + 1) * 150, kind.color, kind.label, pretty_count });
    }
    return .{
        .progress = try std.mem.concat(a, u8, progress),
        .list = try std.mem.concat(a, u8, list),
    };
}

/// A column chart of total contributions per year. Columns are sized as a
/// fraction of the chart, so the SVG stays a fixed size no matter how many
/// years of history the user has.
fn yearChart(
    arena: *std.heap.ArenaAllocator,
    yearly: []const Statistics.YearContributions,
) ![]const u8 {
    const a = arena.allocator();
    if (yearly.len == 0) {
        // Happens for a brand new user, or when rendering from a JSON file
        // dumped before per-year data was collected
        return
        \\<span class="year-label">No per-year data available.</span>
        ;
    }
    var max: u32 = 0;
    for (yearly) |year| {
        max = @max(max, year.total());
    }
    // Once there are too many years to label each column, label every other
    // one. Counting back from the end keeps the most recent year labelled.
    const label_every: usize = if (yearly.len > 12) 2 else 1;
    const columns = try a.alloc([]const u8, yearly.len);
    for (yearly, columns, 0..) |year, *column, i| {
        const total = year.total();
        const height =
            if (max == 0 or total == 0)
                0.0
            else
                // Give non-empty years a floor so they stay visible next to a
                // year that dwarfs them
                @max(3.0, 100 * @as(f64, @floatFromInt(total)) /
                    @as(f64, @floatFromInt(max)));
        const label =
            if ((yearly.len - 1 - i) % label_every == 0)
                try std.fmt.allocPrint(a, "'{d:02}", .{year.year % 100})
            else
                "";
        column.* = try std.fmt.allocPrint(a,
            \\<div class="year-col">
            \\  <div class="year-bar-wrap"><div
            \\      class="year-bar"
            \\      style="height: {d:.2}%; animation-delay: {d}ms;"
            \\  ></div></div>
            \\  <span class="year-label">{s}</span>
            \\</div>
            \\
        , .{ height, i * 100, label });
    }
    return try std.mem.concat(a, u8, columns);
}

const star_octicon =
    \\<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" version="1.1" width="12" height="12"><path fill-rule="evenodd" d="M8 .25a.75.75 0 01.673.418l1.882 3.815 4.21.612a.75.75 0 01.416 1.279l-3.046 2.97.719 4.192a.75.75 0 01-1.088.791L8 12.347l-3.766 1.98a.75.75 0 01-1.088-.79l.72-4.194L.818 6.374a.75.75 0 01.416-1.28l4.21-.611L7.327.668A.75.75 0 018 .25zm0 2.445L6.615 5.5a.75.75 0 01-.564.41l-3.097.45 2.24 2.184a.75.75 0 01.216.664l-.528 3.084 2.769-1.456a.75.75 0 01.698 0l2.77 1.456-.53-3.084a.75.75 0 01.216-.664l2.24-2.183-3.096-.45a.75.75 0 01-.564-.41L8 2.694v.001z"></path></svg>
;

const eye_octicon =
    \\<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" version="1.1" width="12" height="12"><path fill-rule="evenodd" d="M1.679 7.932c.412-.621 1.242-1.75 2.366-2.717C5.175 4.242 6.527 3.5 8 3.5c1.473 0 2.824.742 3.955 1.715 1.124.967 1.954 2.096 2.366 2.717a.119.119 0 010 .136c-.412.621-1.242 1.75-2.366 2.717C10.825 11.758 9.473 12.5 8 12.5c-1.473 0-2.824-.742-3.955-1.715C2.92 9.818 2.09 8.69 1.679 8.068a.119.119 0 010-.136zM8 2c-1.981 0-3.67.992-4.933 2.078C1.797 5.169.88 6.423.43 7.1a1.619 1.619 0 000 1.798c.45.678 1.367 1.932 2.637 3.024C4.329 13.008 6.019 14 8 14c1.981 0 3.67-.992 4.933-2.078 1.27-1.091 2.187-2.345 2.637-3.023a1.619 1.619 0 000-1.798c-.45-.678-1.367-1.932-2.637-3.023C11.671 2.992 9.981 2 8 2zm0 8a2 2 0 100-4 2 2 0 000 4z"></path></svg>
;

/// The repositories card, listing the most-viewed repositories by name.
///
/// Private repositories are deliberately never named here: they still count
/// toward the aggregate totals on the other cards, but naming them would
/// publish the names of private repos on a public profile. `repos` is expected
/// to already have private and excluded repositories filtered out.
fn repositories(
    arena: *std.heap.ArenaAllocator,
    repos: anytype,
    template: []const u8,
) ![]const u8 {
    const a = arena.allocator();
    if (repos.len == 0) {
        return templateFill(a, template, struct { repo_list: []const u8 }{
            .repo_list =
            \\<li><span class="empty">No public repositories found.</span></li>
            ,
        });
    }
    const rows = try a.alloc([]const u8, repos.len);
    for (repos, rows, 0..) |repo, *row, i| {
        const stars = try commify(a, repo.stars);
        defer a.free(stars);
        const views = try commify(a, repo.views);
        defer a.free(views);
        row.* = try std.fmt.allocPrint(a,
            \\<li style="animation-delay: {d}ms;">
            \\  <span class="repo-name">{s}</span>
            \\  <span class="repo-stat">{s}{s}</span>
            \\  <span class="repo-stat">{s}{s}</span>
            \\</li>
            \\
        , .{ i * 150, repo.name, star_octicon, stars, eye_octicon, views });
    }
    return templateFill(a, template, struct { repo_list: []const u8 }{
        .repo_list = try std.mem.concat(a, u8, rows),
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try Args.init(init);
    defer args.deinit(allocator);
    if (args.silent) {
        log_level = .err;
    } else if (args.debug) {
        log_level = .debug;
    } else if (args.verbose) {
        log_level = .info;
    }

    if (args.version) {
        const stdout = std.Io.File.stdout();
        var writer = stdout.writer(io, &.{});
        try writer.interface.print(
            \\GitHub Stats version {s}
            \\https://github.com/jstrieb/github-stats
            \\Created by Jacob Strieb
            \\
        , .{version});
        return;
    }

    if (args.dump_overview_template) |path| {
        try writeFile(io, path, embedded_overview_template);
        return;
    }

    if (args.dump_languages_template) |path| {
        try writeFile(io, path, embedded_languages_template);
        return;
    }

    if (args.dump_repositories_template) |path| {
        try writeFile(io, path, embedded_repositories_template);
        return;
    }

    const exclude_repos =
        if (args.exclude_repos) |exclude|
            try splitList(allocator, exclude, " ,\t\r\n|\"'\x00")
        else
            null;
    defer if (exclude_repos) |exclude| allocator.free(exclude);
    const exclude_langs =
        if (args.exclude_langs) |exclude|
            try splitList(allocator, exclude, ",\t\r\n|\"'\x00")
        else
            null;
    defer if (exclude_langs) |exclude| allocator.free(exclude);

    var stats: Statistics = if (args.json_input_file) |path| stats: {
        const data = try readFile(allocator, io, path);
        defer allocator.free(data);
        break :stats try Statistics.initFromJson(allocator, data);
    } else if (args.access_token) |access_token| stats: {
        std.log.info("Collecting statistics from GitHub API", .{});
        var client: HttpClient = try .init(allocator, io, access_token);
        defer client.deinit();
        break :stats try Statistics.init(
            &client,
            allocator,
            io,
            args.max_retries,
        );
    } else unreachable;
    defer stats.deinit(allocator);

    if (args.json_output_file) |path| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try writeFile(
            io,
            path,
            try std.json.Stringify.valueAlloc(
                arena.allocator(),
                stats,
                .{ .whitespace = .indent_2 },
            ),
        );
    }

    var aggregate_stats: struct {
        languages: std.array_hash_map.String(u64),
        language_colors: std.array_hash_map.String([]const u8),
        contributions: usize,
        name: []const u8,
        commits: usize,
        prs: usize,
        reviews: usize,
        issues: usize,
        new_repos: usize,
        languages_total: usize = 0,
        stars: usize = 0,
        forks: usize = 0,
        lines_changed: usize = 0,
        views: usize = 0,
        repos: usize = 0,
        // Markup built at render time, below
        contribution_progress: []const u8 = "",
        contribution_list: []const u8 = "",
        year_chart: []const u8 = "",
    } = .{
        .contributions = stats.repo_contributions +
            stats.issue_contributions +
            stats.commit_contributions +
            stats.pr_contributions +
            stats.review_contributions,
        .languages = try .init(allocator, &.{}, &.{}),
        .language_colors = try .init(allocator, &.{}, &.{}),
        .name = stats.name,
        .commits = stats.commit_contributions,
        .prs = stats.pr_contributions,
        .reviews = stats.review_contributions,
        .issues = stats.issue_contributions,
        .new_repos = stats.repo_contributions,
    };
    defer aggregate_stats.languages.deinit(allocator);
    defer aggregate_stats.language_colors.deinit(allocator);

    // The most-viewed repositories, for the repositories card. Repositories are
    // already sorted by views (then stars and forks), so taking a prefix is
    // enough. Private repositories count toward the aggregate totals above but
    // are never listed by name -- see repositories().
    var top_repos: std.ArrayList(@TypeOf(stats.repositories[0])) =
        try .initCapacity(allocator, max_listed_repositories);
    defer top_repos.deinit(allocator);

    for (stats.repositories) |repository| {
        if (glob.matchAny(exclude_repos orelse &.{}, repository.name) or
            (args.exclude_private and repository.private) or
            (args.exclude_forks and repository.fork))
        {
            continue;
        }
        if (!repository.private and
            top_repos.items.len < max_listed_repositories)
        {
            top_repos.appendAssumeCapacity(repository);
        }
        aggregate_stats.stars += repository.stars;
        aggregate_stats.forks += repository.forks;
        aggregate_stats.lines_changed += repository.lines_changed;
        aggregate_stats.views += repository.views;
        aggregate_stats.repos += 1;
        if (repository.languages) |langs| for (langs) |language| {
            if (glob.matchAny(exclude_langs orelse &.{}, language.name)) {
                continue;
            }
            if (language.color) |color| {
                try aggregate_stats.language_colors.put(
                    allocator,
                    language.name,
                    color,
                );
            }
            var total = aggregate_stats.languages.get(language.name) orelse 0;
            total += language.size;
            try aggregate_stats.languages.put(allocator, language.name, total);
            aggregate_stats.languages_total += language.size;
        };
    }
    aggregate_stats.languages.sort(struct {
        values: @TypeOf(aggregate_stats.languages.values()),
        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            // Sort in reverse order
            return self.values[a] > self.values[b];
        }
    }{ .values = aggregate_stats.languages.values() });

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const breakdown = try contributionBreakdown(&arena, aggregate_stats);
        aggregate_stats.contribution_progress = breakdown.progress;
        aggregate_stats.contribution_list = breakdown.list;
        aggregate_stats.year_chart = try yearChart(&arena, stats.yearly);

        try writeFile(
            io,
            args.overview_output_file orelse "overview.svg",
            try overview(
                &arena,
                aggregate_stats,
                if (args.overview_template) |template|
                    try readFile(arena.allocator(), io, template)
                else
                    embedded_overview_template,
            ),
        );

        try writeFile(
            io,
            args.languages_output_file orelse "languages.svg",
            try languages(
                &arena,
                aggregate_stats,
                if (args.languages_template) |template|
                    try readFile(arena.allocator(), io, template)
                else
                    embedded_languages_template,
            ),
        );

        try writeFile(
            io,
            args.repositories_output_file orelse "repositories.svg",
            try repositories(
                &arena,
                top_repos.items,
                if (args.repositories_template) |template|
                    try readFile(arena.allocator(), io, template)
                else
                    embedded_repositories_template,
            ),
        );
    }
}

test {
    std.testing.refAllDecls(@This());
}

fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    std.log.info("Reading data from '{s}'", .{path});
    const in =
        if (std.mem.eql(u8, path, "-"))
            std.Io.File.stdin()
        else
            try std.Io.Dir.cwd().openFile(io, path, .{});
    defer if (!std.mem.eql(u8, path, "-")) in.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = in.reader(io, &read_buffer);
    return try (&reader.interface).allocRemaining(allocator, .unlimited);
}

fn writeFile(
    io: std.Io,
    path: []const u8,
    data: []const u8,
) !void {
    std.log.info("Writing data to '{s}'", .{path});
    const out =
        if (std.mem.eql(u8, path, "-"))
            std.Io.File.stdout()
        else
            try std.Io.Dir.cwd().createFile(io, path, .{});
    defer if (!std.mem.eql(u8, path, "-")) out.close(io);
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = out.writer(io, &write_buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn splitList(
    allocator: std.mem.Allocator,
    original: []const u8,
    separators: []const u8,
) ![][]const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer list.deinit(allocator);
    var iterator = std.mem.tokenizeAny(u8, original, separators);
    while (iterator.next()) |pattern| {
        try list.append(allocator, std.mem.trim(u8, pattern, " "));
    }
    return try list.toOwnedSlice(allocator);
}
