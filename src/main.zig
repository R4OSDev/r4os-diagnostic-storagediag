const r4os = @import("r4os");

const bus_storage: u8 = 4;
const storage_registry_driver = "storage/block";
const source_preload = "source=preload";
const source_disk = "source=disk";
const source_builtin = "source=built-in";
const StorageScan = struct {
    summary_total: u32 = 0,
    storage_records: u32 = 0,
    registry_records: u32 = 0,
    block_records: u32 = 0,
    preload_blocks: u32 = 0,
    disk_blocks: u32 = 0,
    builtin_blocks: u32 = 0,
    mounted_c: u32 = 0,
    mounted_data: u32 = 0,
    ahci_records: u32 = 0,
    nvme_records: u32 = 0,
    ata_records: u32 = 0,
    usb_records: u32 = 0,
    truncated: bool = false,
};

const App = struct {
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .dev = r4_app.devicesLowLevel() orelse return null,
        };
    }

    fn run(self: *App) i32 {
        self.sys.println("STORDIAG");
        var ok = true;
        ok = self.checkHardwareSummary() and ok;
        ok = (self.checkStorageInventory() orelse false) and ok;
        ok = self.checkDrive('C', true) and ok;
        ok = self.checkDrive('D', false) and ok;
        ok = self.checkFileSmoke() and ok;

        self.sys.write("STORDIAG result: ");
        self.sys.println(if (ok) "OK" else "FAILED");
        return if (ok) 0 else 1;
    }

    fn checkHardwareSummary(self: *App) bool {
        const hw = self.dev.hardwareSummary() orelse {
            self.sys.println("STORDIAG hardware: FAILED not available");
            return false;
        };

        self.sys.write("STORDIAG hardware: block=");
        self.sys.printU64(hw.block_devices);
        self.sys.write(" controllers=");
        self.sys.printU64(hw.storage_controllers);
        self.sys.write(" ahci=");
        self.sys.write(flagName(hw.flags, r4os.abi.hardware_summary_flag_ahci));
        self.sys.write(" nvme=");
        self.sys.write(flagName(hw.flags, r4os.abi.hardware_summary_flag_nvme));
        self.sys.write(" usb=");
        self.sys.write(flagName(hw.flags, r4os.abi.hardware_summary_flag_usb_configured));
        self.sys.println("");
        return hw.block_devices != 0;
    }

    fn checkStorageInventory(self: *App) ?bool {
        var summary: r4os.abi.DeviceInventorySummary = .{};
        if (self.dev.deviceInventorySummary(&summary) <= 0) {
            self.sys.println("STORDIAG inventory: FAILED not available");
            return null;
        }

        var scan = StorageScan{
            .summary_total = summary.total,
            .truncated = summary.truncated != 0,
        };

        var index: u32 = 0;
        while (index < summary.total) : (index += 1) {
            var rec: r4os.abi.DeviceInventoryRecord = .{};
            if (self.dev.deviceInventoryRecord(index, &rec) <= 0) continue;
            if (rec.bus != bus_storage) {
                self.countStorageController(&scan, rec);
                continue;
            }
            scan.storage_records += 1;
            self.printStorageRecord(index, rec);
            self.countStorageRecord(&scan, rec);
        }

        const ok = !scan.truncated and scan.registry_records != 0 and scan.block_records != 0 and
            scan.preload_blocks != 0 and scan.builtin_blocks == 0 and scan.mounted_c != 0;
        self.sys.write("STORDIAG inventory: ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" total=");
        self.sys.printU64(scan.summary_total);
        self.sys.write(" storage=");
        self.sys.printU64(scan.storage_records);
        self.sys.write(" blocks=");
        self.sys.printU64(scan.block_records);
        self.sys.write(" preload=");
        self.sys.printU64(scan.preload_blocks);
        self.sys.write(" disk=");
        self.sys.printU64(scan.disk_blocks);
        self.sys.write(" builtin=");
        self.sys.printU64(scan.builtin_blocks);
        self.sys.write(" mounted_c=");
        self.sys.printU64(scan.mounted_c);
        self.sys.write(" mounted_data=");
        self.sys.printU64(scan.mounted_data);
        self.sys.println("");

        self.printOptionalOwner("AHCI", scan.ahci_records);
        self.printOptionalOwner("NVMe", scan.nvme_records);
        self.printOptionalOwner("ATA-PIO", scan.ata_records);
        self.printOptionalOwner("USBMSC", scan.usb_records);
        return ok;
    }

    fn countStorageRecord(self: *App, scan: *StorageScan, rec: r4os.abi.DeviceInventoryRecord) void {
        _ = self;
        const driver = spanZ(rec.driver[0..]);
        const status = spanZ(rec.status[0..]);
        const note = spanZ(rec.note[0..]);
        const is_registry = equalsIgnoreCase(driver, storage_registry_driver);
        if (is_registry) {
            scan.registry_records += 1;
            return;
        }

        scan.block_records += 1;
        if (containsIgnoreCase(note, source_preload)) scan.preload_blocks += 1;
        if (containsIgnoreCase(note, source_disk)) scan.disk_blocks += 1;
        if (containsIgnoreCase(note, source_builtin) or containsIgnoreCase(note, "builtin storage") or containsIgnoreCase(note, "source=built-in")) scan.builtin_blocks += 1;
        if (equalsIgnoreCase(status, "mounted-C")) scan.mounted_c += 1;
        if (equalsIgnoreCase(status, "mounted-D") or equalsIgnoreCase(status, "mounted-E")) scan.mounted_data += 1;
        if (containsIgnoreCase(driver, "AHCI") or containsIgnoreCase(note, "AHCI")) scan.ahci_records += 1;
        if (containsIgnoreCase(driver, "NVME") or containsIgnoreCase(note, "NVME") or containsIgnoreCase(note, "NVMe")) scan.nvme_records += 1;
        if (containsIgnoreCase(driver, "ATA") or containsIgnoreCase(note, "ATAPIO") or containsIgnoreCase(note, "Legacy IDE")) scan.ata_records += 1;
        if (containsIgnoreCase(driver, "USBMSC") or containsIgnoreCase(note, "USBMSC")) scan.usb_records += 1;
    }

    fn countStorageController(self: *App, scan: *StorageScan, rec: r4os.abi.DeviceInventoryRecord) void {
        _ = self;
        if (rec.class_code != 0x01) return;
        const name = spanZ(rec.name[0..]);
        const driver = spanZ(rec.driver[0..]);
        const note = spanZ(rec.note[0..]);
        if (rec.subclass == 0x06 or containsIgnoreCase(name, "AHCI") or containsIgnoreCase(driver, "AHCI") or containsIgnoreCase(note, "AHCI")) scan.ahci_records += 1;
        if (rec.subclass == 0x08 or containsIgnoreCase(name, "NVME") or containsIgnoreCase(driver, "NVME") or containsIgnoreCase(note, "NVME") or containsIgnoreCase(note, "NVMe")) scan.nvme_records += 1;
        if (rec.subclass == 0x01 or containsIgnoreCase(name, "ATA") or containsIgnoreCase(driver, "ATA") or containsIgnoreCase(note, "ATAPIO") or containsIgnoreCase(note, "Legacy IDE")) scan.ata_records += 1;
    }

    fn printStorageRecord(self: *App, index: u32, rec: r4os.abi.DeviceInventoryRecord) void {
        self.sys.write("STORDIAG record #");
        self.sys.printU64(index);
        self.sys.write(" ");
        writeNonEmptyZ(&self.sys, rec.name[0..]);
        self.sys.write(" driver=");
        writeNonEmptyZ(&self.sys, rec.driver[0..]);
        self.sys.write(" status=");
        writeNonEmptyZ(&self.sys, rec.status[0..]);
        const note = spanZ(rec.note[0..]);
        if (note.len != 0) {
            self.sys.write(" note=");
            self.sys.write(note);
        }
        self.sys.println("");
    }

    fn printOptionalOwner(self: *App, name: []const u8, count: u32) void {
        self.sys.write("STORDIAG owner ");
        self.sys.write(name);
        self.sys.write(": ");
        if (count == 0) {
            self.sys.println("skipped");
        } else {
            self.sys.write("OK records=");
            self.sys.printU64(count);
            self.sys.println("");
        }
    }

    fn checkDrive(self: *App, letter: u8, required: bool) bool {
        const info = self.sys.driveInfo(letter - 'A') orelse {
            self.printDriveMissing(letter, required);
            return !required;
        };
        if (info.mounted == 0) {
            self.printDriveMissing(letter, required);
            return !required;
        }

        // The system volume is NTFS since 0.60.9; secondary data volumes
        // stay FAT32.  Accept both real on-disk kinds (2=FAT32, 3=NTFS).
        const ok = (info.kind == 2 or info.kind == 3) and info.bytes != 0;
        self.sys.write("STORDIAG drive ");
        self.sys.putc(letter);
        self.sys.write(": ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" kind=");
        self.sys.write(kindName(info.kind));
        self.sys.write(" role=");
        self.sys.write(roleName(info.role));
        self.sys.write(" bytes=");
        self.sys.printU64(info.bytes);
        self.sys.write(" free=");
        self.sys.printU64(info.free_bytes);
        self.sys.println("");
        return ok;
    }

    fn printDriveMissing(self: *App, letter: u8, required: bool) void {
        self.sys.write("STORDIAG drive ");
        self.sys.putc(letter);
        self.sys.write(": ");
        self.sys.println(if (required) "FAILED missing" else "skipped");
    }

    fn checkFileSmoke(self: *App) bool {
        const config = self.sys.fileInfo("C:\\R4OS\\CONFIG\\VERSION.R4S");
        const autoexec = self.sys.fileInfo("C:\\AUTOEXEC.BAT");
        var buffer: [128]u8 = undefined;
        const read = self.sys.fileReadAt("C:\\R4OS\\CONFIG\\VERSION.R4S", 0, buffer[0..]);
        const missing = self.sys.fileInfo("C:\\__STORDIAG_MISSING__.BIN");
        const ok = fileExists(config) and fileExists(autoexec) and read > 0 and !fileExists(missing);

        self.sys.write("STORDIAG file smoke: ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" version_read=");
        self.sys.printI32(read);
        self.sys.println("");
        return ok;
    }

};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    return app.run();
}

fn fileExists(info: ?r4os.abi.FileInfo) bool {
    if (info) |value| return value.exists != 0;
    return false;
}

fn flagName(flags: u32, bit: u32) []const u8 {
    return if ((flags & bit) != 0) "yes" else "no";
}

fn kindName(kind: u8) []const u8 {
    return switch (kind) {
        1 => "RAM",
        2 => "FAT32",
        3 => "NTFS",
        else => "NONE",
    };
}

fn roleName(role: u8) []const u8 {
    return switch (role) {
        1 => "system",
        2 => "data",
        3 => "ram",
        else => "general",
    };
}

fn writeNonEmptyZ(ctx: *const r4os.r4sys.Context, value: []const u8) void {
    const text = spanZ(value);
    ctx.write(if (text.len == 0) "-" else text);
}

fn spanZ(value: []const u8) []const u8 {
    var end: usize = 0;
    while (end < value.len and value[end] != 0) : (end += 1) {}
    return value[0..end];
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (a[index] != b[index]) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (equalsIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - ('a' - 'A');
    return c;
}
