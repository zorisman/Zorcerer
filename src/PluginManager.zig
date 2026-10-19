const std = @import("std");

/// Каталог плагинов относительно текущего рабочего каталога процесса.
/// Если srcds запускается из корня сервера, путь обычно начинается с "tf/".
const plugins_directory = "tf/addons/zorcerer/plugins";

/// Ограничение на размер одного TOML-манифеста: 1 МиБ.
const max_config_size = 1024 * 1024;

/// Минимальный менеджер плагинов.
///
/// checkFiles() возвращает список путей к найденным файлам.
/// readConfig() возвращает список содержимого TOML-файлов: один элемент
/// на один манифест. Содержимое пока сохраняется как обычный текст без разбора TOML.
/// Результаты принадлежат менеджеру и освобождаются при следующем вызове
/// соответствующего метода или при deinit().
pub const Manager = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,

    // init() по заданной сигнатуре не получает std.Io извне. Для первого
    // прототипа используем single-threaded адаптер: конкурентный I/O не нужен.
    threaded_io: std.Io.Threaded = .init_single_threaded,

    files_result: ?[][]const u8 = null,
    config_result: ?[][]const u8 = null,

    pub fn init() @This() {
        return .{};
    }

    /// Освобождает все пути и содержимое манифестов, накопленные менеджером.
    /// Можно вызывать через defer.
    pub fn deinit(self: *@This()) void {
        self.clearFilesResult();
        self.clearConfigResult();
    }

    fn freeStringList(self: *@This(), strings: [][]const u8) void {
        for (strings) |string| {
            self.allocator.free(string);
        }
        self.allocator.free(strings);
    }

    fn clearFilesResult(self: *@This()) void {
        if (self.files_result) |files| {
            self.freeStringList(files);
            self.files_result = null;
        }
    }

    fn clearConfigResult(self: *@This()) void {
        if (self.config_result) |configs| {
            self.freeStringList(configs);
            self.config_result = null;
        }
    }

    /// Рекурсивно обходит plugins_directory и возвращает отдельный путь
    /// для каждого обычного файла. Возвращённый список принадлежит менеджеру.
    /// Он действителен до следующего вызова checkFiles() или deinit().
    pub fn checkFiles(self: *@This()) ![]const []const u8 {
        self.clearFilesResult();

        const io = self.threaded_io.io();
        var root = try std.Io.Dir.cwd().openDir(io, plugins_directory, .{ .iterate = true });
        defer root.close(io);

        var walker = try root.walk(self.allocator);
        defer walker.deinit();

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |path| {
                self.allocator.free(path);
            }
            result.deinit(self.allocator);
        }

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;

            const full_path = try std.Io.Dir.path.join(
                self.allocator,
                &.{ plugins_directory, entry.path },
            );
            result.append(self.allocator, full_path) catch |err| {
                self.allocator.free(full_path);
                return err;
            };
        }

        const owned_result = try result.toOwnedSlice(self.allocator);
        self.files_result = owned_result;
        return owned_result;
    }

    /// Находит все .toml-файлы в plugins_directory и читает их целиком.
    /// Каждый элемент результата — текст одного TOML-манифеста; порядок
    /// соответствует порядку обхода файловой системы и не гарантирован.
    /// Это пока не TOML-парсер: комментарии, ключи и значения сохраняются как есть.
    /// Результат принадлежит менеджеру и действителен до следующего вызова
    /// readConfig() или deinit().
    pub fn readConfig(self: *@This()) ![]const []const u8 {
        self.clearConfigResult();

        const files = try self.checkFiles();
        const io = self.threaded_io.io();

        var configs: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (configs.items) |contents| {
                self.allocator.free(contents);
            }
            configs.deinit(self.allocator);
        }

        for (files) |path| {
            if (!std.mem.endsWith(u8, path, ".toml")) continue;

            const contents = try std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                self.allocator,
                .limited(max_config_size),
            );
            configs.append(self.allocator, contents) catch |err| {
                self.allocator.free(contents);
                return err;
            };
        }

        const owned_result = try configs.toOwnedSlice(self.allocator);
        self.config_result = owned_result;
        return owned_result;
    }
};
