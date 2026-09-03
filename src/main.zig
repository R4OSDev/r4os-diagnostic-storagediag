const r4os = @import("r4os");

const bus_storage: u8 = 4;
const storage_registry_driver = "storage/block";
const source_preload = "source=preload";
const source_disk = "source=disk";
const source_builtin = "source=built-in";
const backing_store_path = "C:\\TEMP\\STORPAGE.BIN";
const missing_backing_store_path = "C:\\TEMP\\STORMISS.SWP";
const backing_store_bytes: u64 = 64 * 1024;
const backing_store_slot_count: u64 = backing_store_bytes / 4096;
const backing_store_slot_reserve: u64 = 4;
const backing_store_slot_owner: u32 = 0x53544F52;
const backing_store_gate_bytes: u64 = 8 * 4096;

fn storagePerformanceActive(info: r4os.abi.ProgramStoragePerformanceInfo) bool {
    return info.queue_high_water != 0 or
        info.queued_requests != 0 or
        info.dequeued_requests != 0 or
        info.completion_waits != 0 or
        info.completion_signals != 0 or
        info.worker_requests != 0 or
        info.read_ops != 0 or
        info.write_ops != 0 or
        info.flush_ops != 0;
}

fn storagePerformanceOk(info: r4os.abi.ProgramStoragePerformanceInfo) bool {
    if (info.sector_size == 0 or info.queue_depth == 0 or info.completion_timeouts != 0) return false;
    if (!storagePerformanceActive(info)) return true;
    const completion_path_ok =
        (info.worker_requests != 0 and info.worker_completions != 0) or
        (info.worker_requests == 0 and
            info.worker_completions == 0 and
            info.boot_inline_requests == info.queued_requests and
            info.boot_inline_completions == info.dequeued_requests);
    return info.queue_high_water != 0 and
        info.queued_requests != 0 and
        info.dequeued_requests != 0 and
        info.completion_waits != 0 and
        info.completion_signals != 0 and
        completion_path_ok;
}

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
        ok = self.checkStoragePerformance() and ok;

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

    fn checkStoragePerformance(self: *App) bool {
        if (!self.dev.hasFn("memory_page_io_probe")) {
            self.sys.println("STORDIAG pageIO: FAILED api unavailable");
            return false;
        }
        const before = self.dev.performanceSummary() orelse {
            self.sys.println("STORDIAG queue: FAILED performance unavailable");
            return false;
        };
        const payload = "stordiag-writeback-v119";
        const written = self.sys.fileWrite("C:\\TEMP\\STORWB.TXT", payload);
        var verify: [64]u8 = undefined;
        const read = self.sys.fileReadAt("C:\\TEMP\\STORWB.TXT", 0, verify[0..]);
        const summary = self.dev.performanceSummary() orelse {
            self.sys.println("STORDIAG queue: FAILED performance unavailable");
            return false;
        };
        const reclaim_probe = self.dev.memoryReclaimProbe(1) orelse {
            self.sys.println("STORDIAG globalReclaim: FAILED probe unavailable");
            return false;
        };
        const reclaim_summary = self.dev.performanceSummary() orelse {
            self.sys.println("STORDIAG globalReclaim: FAILED performance unavailable");
            return false;
        };
        const missing_backing = self.dev.memoryBackingStoreProbe(missing_backing_store_path, backing_store_bytes, 0) orelse {
            self.sys.println("STORDIAG backingStore: FAILED missing probe unavailable");
            return false;
        };
        if (!self.writeBackingStoreFile(backing_store_path, backing_store_bytes)) {
            self.sys.println("STORDIAG backingStore: FAILED create");
            return false;
        }
        const backing_probe = self.dev.memoryBackingStoreProbe(backing_store_path, backing_store_bytes, 0) orelse {
            self.sys.println("STORDIAG backingStore: FAILED probe unavailable");
            return false;
        };
        const backing_summary = self.dev.performanceSummary() orelse {
            self.sys.println("STORDIAG backingStore: FAILED performance unavailable");
            return false;
        };
        const missing_slots = self.dev.memoryBackingStoreSlotProbe(missing_backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_probe, 0, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG backingSlots: FAILED missing probe unavailable");
            return false;
        };
        const slot_capacity = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_probe, 0, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG backingSlots: FAILED capacity unavailable");
            return false;
        };
        const slot_over = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_reserve, slot_capacity.capacity_slots + 1, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG backingSlots: FAILED over-capacity unavailable");
            return false;
        };
        const slot_reserve = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_reserve, backing_store_slot_reserve, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG backingSlots: FAILED reserve unavailable");
            return false;
        };
        const slot_mark = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_mark_error, 0, slot_reserve.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG backingSlots: FAILED mark unavailable");
            return false;
        };
        const slot_recover = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_recover, 0, slot_reserve.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG backingSlots: FAILED recover unavailable");
            return false;
        };
        const slot_release = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_release, 0, slot_reserve.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG backingSlots: FAILED release unavailable");
            return false;
        };
        const slot_final = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_probe, 0, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG backingSlots: FAILED final unavailable");
            return false;
        };
        const slot_summary = self.dev.performanceSummary() orelse {
            self.sys.println("STORDIAG backingSlots: FAILED performance unavailable");
            return false;
        };
        const gate_region = self.sys.vmReserve(backing_store_gate_bytes * 2, 4096, r4os.abi.vm_region_flags_default) orelse {
            self.sys.println("STORDIAG pagerGates: FAILED reserve");
            return false;
        };
        var gate_release_needed = true;
        defer {
            if (gate_release_needed) _ = self.sys.vmRelease(gate_region.id);
        }
        const gate_empty = self.dev.memoryPagerGateProbe(backing_store_path, backing_store_bytes, gate_region.id, 0, 0) orelse {
            self.sys.println("STORDIAG pagerGates: FAILED empty unavailable");
            return false;
        };
        if (self.sys.vmCommit(gate_region.id, 0, backing_store_gate_bytes) != r4os.abi.vm_ok) {
            self.sys.println("STORDIAG pagerGates: FAILED commit");
            return false;
        }
        const gate_missing = self.dev.memoryPagerGateProbe(missing_backing_store_path, backing_store_bytes, gate_region.id, 0, 0) orelse {
            self.sys.println("STORDIAG pagerGates: FAILED missing unavailable");
            return false;
        };
        const gate_over = self.dev.memoryPagerGateProbe(backing_store_path, backing_store_bytes, gate_region.id, backing_store_bytes + 4096, 0) orelse {
            self.sys.println("STORDIAG pagerGates: FAILED over unavailable");
            return false;
        };
        const gate_ready = self.dev.memoryPagerGateProbe(backing_store_path, backing_store_bytes, gate_region.id, 0, 0) orelse {
            self.sys.println("STORDIAG pagerGates: FAILED ready unavailable");
            return false;
        };
        const gate_summary = self.dev.performanceSummary() orelse {
            self.sys.println("STORDIAG pagerGates: FAILED performance unavailable");
            return false;
        };
        const page_io_count: u64 = 2;
        const page_io_bytes: u64 = 8192;
        const page_slot = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_reserve, page_io_count, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG pageIO: FAILED slot unavailable");
            return false;
        };
        var page: [8192]u8 = undefined;
        var expected: [8192]u8 = undefined;
        var page_index: usize = 0;
        while (page_index < page.len) : (page_index += 1) {
            const value: u8 = @truncate(page_index *% 5 +% 0x24);
            page[page_index] = value;
            expected[page_index] = value;
        }
        const page_invalid = self.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_in, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_slot.generation, page[0..], 0) orelse {
            self.sys.println("STORDIAG pageIO: FAILED invalid unavailable");
            return false;
        };
        const page_out = self.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_slot.generation, page[0..], 0) orelse {
            self.sys.println("STORDIAG pageIO: FAILED out unavailable");
            return false;
        };
        const page_mark = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_mark_error, 0, page_slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG pageIO: FAILED mark unavailable");
            return false;
        };
        const page_error = self.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_in, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_mark.generation, page[0..], 0) orelse {
            self.sys.println("STORDIAG pageIO: FAILED error unavailable");
            return false;
        };
        const page_recover = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_recover, 0, page_slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG pageIO: FAILED recover unavailable");
            return false;
        };
        const page_retry = self.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_recover.generation, expected[0..], 0) orelse {
            self.sys.println("STORDIAG pageIO: FAILED retry unavailable");
            return false;
        };
        @memset(page[0..], 0);
        const page_in = self.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_in, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_retry.slot_generation, page[0..], 0) orelse {
            self.sys.println("STORDIAG pageIO: FAILED in unavailable");
            return false;
        };
        const page_release = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_release, 0, page_slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            self.sys.println("STORDIAG pageIO: FAILED release unavailable");
            return false;
        };
        _ = self.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_probe, 0, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0);
        if (self.sys.vmRelease(gate_region.id) != r4os.abi.vm_ok) {
            self.sys.println("STORDIAG pagerGates: FAILED release");
            return false;
        }
        gate_release_needed = false;
        const expected_len: i32 = @intCast(payload.len);
        const deferred_delta = delta(summary.fs_cache_deferred_write_requests, before.fs_cache_deferred_write_requests);
        const writeback_delta = delta(summary.fs_cache_writeback_sectors, before.fs_cache_writeback_sectors);
        const drain_delta = delta(summary.fs_cache_writeback_drains, before.fs_cache_writeback_drains);
        const flush_delta = delta(summary.fs_cache_writeback_flush_drains, before.fs_cache_writeback_flush_drains);
        const write_probe_ok = written == expected_len and
            read == expected_len and
            bytesEqual(verify[0..payload.len], payload) and
            deferred_delta > 0 and
            writeback_delta > 0 and
            drain_delta > 0 and
            flush_delta > 0;
        const expected_reclaim_bytes = @as(u64, reclaim_probe.returned_frames) * @as(u64, summary.fs_cache_payload_frame_bytes);
        const global_reclaim_ok = (summary.flags & r4os.abi.performance_flag_global_reclaim_ready) != 0 and
            reclaim_probe.version == r4os.abi.memory_reclaim_probe_version and
            reclaim_probe.size >= @sizeOf(r4os.abi.ProgramMemoryReclaimProbe) and
            reclaim_probe.reason == r4os.abi.memory_reclaim_reason_diagnostic and
            reclaim_probe.requested_frames == 1 and
            reclaim_probe.returned_frames > 0 and
            reclaim_probe.returned_bytes >= expected_reclaim_bytes and
            reclaim_probe.failed_drains == 0 and
            reclaim_summary.global_reclaim_attempts >= summary.global_reclaim_attempts + 1 and
            reclaim_summary.global_reclaim_successes >= summary.global_reclaim_successes + 1 and
            reclaim_summary.global_reclaim_returned_frames >= summary.global_reclaim_returned_frames + reclaim_probe.returned_frames and
            reclaim_summary.global_reclaim_last_reason == r4os.abi.memory_reclaim_reason_diagnostic and
            reclaim_summary.global_reclaim_last_requested_frames == 1 and
            reclaim_summary.global_reclaim_last_returned_frames == reclaim_probe.returned_frames and
            reclaim_summary.fs_cache_pmm_reclaimable_bytes +| reclaim_probe.fs_returned_bytes <= summary.fs_cache_pmm_reclaimable_bytes;
        const backing_store_ok = (backing_summary.flags & r4os.abi.performance_flag_memory_backing_store_ready) != 0 and
            missing_backing.status == r4os.abi.memory_backing_store_status_missing_file and
            (missing_backing.blockers & r4os.abi.memory_backing_store_blocker_missing_file) != 0 and
            backing_probe.version == r4os.abi.memory_backing_store_probe_version and
            backing_probe.size >= @sizeOf(r4os.abi.ProgramMemoryBackingStoreProbe) and
            backing_probe.status == r4os.abi.memory_backing_store_status_ready and
            backing_probe.blockers == 0 and
            backingStoreReadyFlagsOk(backing_probe.flags) and
            backing_probe.requested_bytes == backing_store_bytes and
            backing_probe.available_bytes >= backing_store_bytes and
            backing_probe.file_size >= backing_store_bytes and
            backing_probe.cluster_bytes >= 512 and
            backing_probe.first_cluster != 0 and
            backing_probe.pager_enabled == 0 and
            backing_probe.anonymous_paging_enabled == 0 and
            backing_summary.memory_backing_store_status == r4os.abi.memory_backing_store_status_ready and
            backing_summary.memory_backing_store_blockers == 0 and
            backing_summary.memory_backing_store_requested_bytes == backing_store_bytes and
            backing_summary.memory_backing_store_available_bytes >= backing_store_bytes and
            backing_summary.memory_backing_store_probe_count >= missing_backing.total_probes + 1 and
            backing_summary.memory_backing_store_ready_count > 0 and
            backing_summary.memory_backing_store_failure_count > 0 and
            backing_summary.memory_backing_store_pager_enabled == 0 and
            backing_summary.memory_backing_store_anonymous_paging_enabled == 0;
        const backing_slots_ok = (slot_summary.flags & r4os.abi.performance_flag_memory_backing_store_slots_ready) != 0 and
            missing_slots.status == r4os.abi.memory_backing_store_slot_status_backing_unavailable and
            (missing_slots.blockers & r4os.abi.memory_backing_store_slot_blocker_backing_not_ready) != 0 and
            slot_capacity.status == r4os.abi.memory_backing_store_slot_status_ready and
            backingStoreSlotFlagsOk(slot_capacity.flags) and
            slot_capacity.slot_bytes == 4096 and
            slot_capacity.capacity_slots >= backing_store_slot_count and
            slot_capacity.reserved_slots == 0 and
            slot_over.status == r4os.abi.memory_backing_store_slot_status_insufficient_capacity and
            (slot_over.blockers & r4os.abi.memory_backing_store_slot_blocker_insufficient_capacity) != 0 and
            slot_reserve.status == r4os.abi.memory_backing_store_slot_status_reserved and
            slot_reserve.reservation_id != 0 and
            slot_reserve.reserved_slots == backing_store_slot_reserve and
            slot_mark.status == r4os.abi.memory_backing_store_slot_status_error_marked and
            slot_mark.error_slots == backing_store_slot_reserve and
            slot_recover.status == r4os.abi.memory_backing_store_slot_status_recovered and
            slot_recover.error_slots == 0 and
            slot_release.status == r4os.abi.memory_backing_store_slot_status_released and
            slot_release.reserved_slots == 0 and
            slot_final.status == r4os.abi.memory_backing_store_slot_status_ready and
            slot_final.reserved_slots == 0 and
            slot_final.free_slots == slot_final.capacity_slots and
            slot_summary.memory_backing_store_slot_status == r4os.abi.memory_backing_store_slot_status_ready and
            slot_summary.memory_backing_store_slot_operation == r4os.abi.memory_backing_store_slot_operation_probe and
            slot_summary.memory_backing_store_slot_reserved == 0 and
            slot_summary.memory_backing_store_slot_error == 0 and
            slot_summary.memory_backing_store_slot_reserve_count > 0 and
            slot_summary.memory_backing_store_slot_release_count > 0 and
            slot_summary.memory_backing_store_slot_error_mark_count > 0 and
            slot_summary.memory_backing_store_slot_recovery_count > 0 and
            slot_summary.memory_backing_store_slot_failure_count > 0 and
            slot_summary.memory_backing_store_slot_pager_enabled == 0 and
            slot_summary.memory_backing_store_slot_eviction_enabled == 1 and
            slot_summary.memory_backing_store_slot_page_in_enabled == 1 and
            slot_summary.memory_backing_store_slot_page_out_enabled == 1;
        const pager_gates_ok = (gate_summary.flags & r4os.abi.performance_flag_memory_pager_gates_ready) != 0 and
            gate_empty.status == r4os.abi.memory_pager_gate_status_no_nonresident_commit and
            (gate_empty.blockers & r4os.abi.memory_pager_gate_blocker_no_nonresident_commit) != 0 and
            gate_missing.status == r4os.abi.memory_pager_gate_status_backing_unavailable and
            (gate_missing.blockers & r4os.abi.memory_pager_gate_blocker_backing_not_ready) != 0 and
            gate_over.status == r4os.abi.memory_pager_gate_status_insufficient_capacity and
            (gate_over.blockers & r4os.abi.memory_pager_gate_blocker_insufficient_capacity) != 0 and
            gate_ready.status == r4os.abi.memory_pager_gate_status_ready and
            pagerGateFlagsOk(gate_ready.flags) and
            gate_ready.requested_bytes == backing_store_gate_bytes and
            gate_ready.committed_bytes == backing_store_gate_bytes and
            gate_ready.resident_bytes == 0 and
            gate_ready.nonresident_bytes == backing_store_gate_bytes and
            gate_ready.prepared_slots == backing_store_gate_bytes / 4096 and
            gate_ready.free_after_slots == gate_ready.capacity_slots and
            gate_ready.reserved_after_slots == 0 and
            gate_ready.rollback_completed == 1 and
            gate_ready.pager_enabled == 0 and
            gate_ready.eviction_enabled == 1 and
            gate_ready.page_in_enabled == 0 and
            gate_ready.page_out_enabled == 0 and
            gate_summary.memory_pager_gate_status == r4os.abi.memory_pager_gate_status_ready and
            gate_summary.memory_pager_gate_prepared_slots == backing_store_gate_bytes / 4096 and
            gate_summary.memory_pager_gate_reserved_after_slots == 0 and
            gate_summary.memory_pager_gate_rollback_completed == 1 and
            gate_summary.memory_pager_gate_probe_count >= 4 and
            gate_summary.memory_pager_gate_ready_count > 0 and
            gate_summary.memory_pager_gate_failure_count > 0 and
            gate_summary.memory_pager_gate_pager_enabled == 0 and
            gate_summary.memory_pager_gate_eviction_enabled == 1 and
            gate_summary.memory_pager_gate_page_in_enabled == 0 and
            gate_summary.memory_pager_gate_page_out_enabled == 0;
        const page_io_ok = page_invalid.status == r4os.abi.memory_page_io_status_slot_not_valid and
            page_out.status == r4os.abi.memory_page_io_status_page_out_ok and
            page_out.page_count == page_io_count and
            page_out.transfer_bytes == page_io_bytes and
            @as(u64, page_out.io_bytes) == page_io_bytes and
            page_out.io_status == @as(i32, @intCast(page_io_bytes)) and
            page_mark.status == r4os.abi.memory_backing_store_slot_status_error_marked and
            page_error.status == r4os.abi.memory_page_io_status_slot_error and
            page_recover.status == r4os.abi.memory_backing_store_slot_status_recovered and
            page_retry.status == r4os.abi.memory_page_io_status_page_out_ok and
            page_retry.page_count == page_io_count and
            page_retry.transfer_bytes == page_io_bytes and
            page_in.status == r4os.abi.memory_page_io_status_page_in_ok and
            page_in.page_count == page_io_count and
            page_in.transfer_bytes == page_io_bytes and
            @as(u64, page_in.io_bytes) == page_io_bytes and
            page_in.io_status == @as(i32, @intCast(page_io_bytes)) and
            bytesEqual(page[0..], expected[0..]) and
            page_release.status == r4os.abi.memory_backing_store_slot_status_released;
        var ok = summary.storage_device_count != 0 and
            summary.storage_queue_high_water_total != 0 and
            summary.storage_queued_requests != 0 and
            summary.storage_dequeued_requests != 0 and
            summary.storage_completion_waits != 0 and
            summary.storage_completion_timeouts == 0 and
            (summary.flags & r4os.abi.performance_flag_storage_driver_completion_ready) != 0 and
            summary.storage_worker_started != 0 and
            summary.storage_worker_runtime_requests > 0 and
            summary.storage_worker_runtime_completions > 0 and
            summary.storage_completion_signals > 0 and
            summary.storage_boot_inline_requests > 0 and
            (summary.flags & r4os.abi.performance_flag_fs_page_cache_ready) != 0 and
            (summary.flags & r4os.abi.performance_flag_fs_writeback_ready) != 0 and
            (summary.flags & r4os.abi.performance_flag_fs_reclaim_ready) != 0 and
            (summary.flags & r4os.abi.performance_flag_fs_pmm_reclaim_ready) != 0 and
            (summary.flags & r4os.abi.performance_flag_global_reclaim_ready) != 0 and
            summary.fs_cache_capacity > 0 and
            summary.fs_cache_entries_used > 0 and
            summary.fs_cache_hits > 0 and
            summary.fs_cache_dirty_entries == 0 and
            summary.fs_cache_dirty_bytes == 0 and
            summary.fs_cache_writeback_queue_depth == 0 and
            summary.fs_cache_writeback_queue_high_water > 0 and
            summary.fs_cache_clean_reclaimable_entries > 0 and
            summary.fs_cache_clean_reclaimable_bytes > 0 and
            summary.fs_cache_payload_frame_bytes >= 4096 and
            summary.fs_cache_payload_frames >= summary.fs_cache_entries_used and
            summary.fs_cache_pmm_reclaimable_bytes >= summary.fs_cache_clean_reclaimable_bytes and
            summary.fs_cache_pmm_reclaimable_bytes > 0 and
            summary.fs_cache_pmm_dirty_bytes == 0 and
            summary.fs_cache_payload_allocations > 0 and
            summary.fs_cache_payload_allocation_failures == 0 and
            summary.fs_cache_payload_releases > 0 and
            summary.fs_cache_reclaim_returned_frames > 0 and
            summary.fs_cache_reclaim_returned_bytes >= summary.fs_cache_reclaim_returned_frames * @as(u64, summary.fs_cache_payload_frame_bytes) and
            summary.fs_cache_dirty_non_reclaimable_entries == summary.fs_cache_dirty_entries and
            summary.fs_cache_dirty_non_reclaimable_bytes == summary.fs_cache_dirty_bytes and
            summary.fs_cache_reclaim_scans > 0 and
            summary.fs_cache_reclaim_clean_entries > 0 and
            summary.fs_cache_reclaim_failed_drains == 0 and
            summary.fs_cache_pagefile_ready == 0 and
            pagefileBlockersOk(summary.fs_cache_pagefile_blockers) and
            summary.fs_cache_deferred_write_requests > 0 and
            summary.fs_cache_writeback_drains > 0 and
            summary.fs_cache_writeback_sectors > 0 and
            summary.fs_cache_writeback_flush_drains > 0 and
            summary.fs_cache_read_errors == 0 and
            summary.fs_cache_write_errors == 0 and
            summary.fs_cache_writeback_errors == 0 and
            write_probe_ok and
            global_reclaim_ok and
            backing_store_ok and
            backing_slots_ok and
            pager_gates_ok and
            page_io_ok;

        self.sys.write("STORDIAG queue: ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" devices=");
        self.sys.printU64(summary.storage_device_count);
        self.sys.write(" qUsed=");
        self.sys.printU64(summary.storage_queue_used_total);
        self.sys.write(" qHigh=");
        self.sys.printU64(summary.storage_queue_high_water_total);
        self.sys.write(" queued=");
        self.sys.printU64(summary.storage_queued_requests);
        self.sys.write(" done=");
        self.sys.printU64(summary.storage_dequeued_requests);
        self.sys.write(" waits=");
        self.sys.printU64(summary.storage_queue_full_waits);
        self.sys.write(" rejects=");
        self.sys.printU64(summary.storage_queue_full_rejections);
        self.sys.write(" cwait=");
        self.sys.printU64(summary.storage_completion_waits);
        self.sys.write(" ctimeout=");
        self.sys.printU64(summary.storage_completion_timeouts);
        self.sys.write(" cmax=");
        self.sys.printU64(summary.storage_completion_max_ticks);
        self.sys.write(" worker=");
        self.sys.printU64(summary.storage_worker_runtime_requests);
        self.sys.write("/");
        self.sys.printU64(summary.storage_worker_runtime_completions);
        self.sys.write(" signals=");
        self.sys.printU64(summary.storage_completion_signals);
        self.sys.write(" bootInline=");
        self.sys.printU64(summary.storage_boot_inline_requests);
        self.sys.println("");

        self.sys.write("STORDIAG cache: ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" entries=");
        self.sys.printU64(summary.fs_cache_entries_used);
        self.sys.write("/");
        self.sys.printU64(summary.fs_cache_capacity);
        self.sys.write(" hits=");
        self.sys.printU64(summary.fs_cache_hits);
        self.sys.write(" misses=");
        self.sys.printU64(summary.fs_cache_misses);
        self.sys.write(" dirty=");
        self.sys.printU64(summary.fs_cache_dirty_entries);
        self.sys.write(" q=");
        self.sys.printU64(summary.fs_cache_writeback_queue_depth);
        self.sys.write("/");
        self.sys.printU64(summary.fs_cache_writeback_queue_high_water);
        self.sys.write(" deferred=");
        self.sys.printU64(deferred_delta);
        self.sys.write(" wb=");
        self.sys.printU64(writeback_delta);
        self.sys.write(" drain=");
        self.sys.printU64(drain_delta);
        self.sys.write(" flush=");
        self.sys.printU64(flush_delta);
        self.sys.write(" wbErr=");
        self.sys.printU64(summary.fs_cache_writeback_errors);
        self.sys.write(" reclaim=");
        self.sys.printU64(summary.fs_cache_clean_reclaimable_bytes);
        self.sys.write(" pmm=");
        self.sys.printU64(summary.fs_cache_pmm_reclaimable_bytes);
        self.sys.write(" frames=");
        self.sys.printU64(summary.fs_cache_payload_frames);
        self.sys.write(" reclaimDrop=");
        self.sys.printU64(summary.fs_cache_reclaim_clean_entries);
        self.sys.write(" pagefileReady=");
        self.sys.printU64(summary.fs_cache_pagefile_ready);
        self.sys.write(" blockers=");
        self.sys.printU64(summary.fs_cache_pagefile_blockers);
        self.sys.println("");

        self.sys.write("STORDIAG globalReclaim: ");
        self.sys.write(if (global_reclaim_ok) "OK" else "FAILED");
        self.sys.write(" frames=");
        self.sys.printU64(reclaim_probe.returned_frames);
        self.sys.write(" bytes=");
        self.sys.printU64(reclaim_probe.returned_bytes);
        self.sys.write(" attempts=");
        self.sys.printU64(reclaim_summary.global_reclaim_attempts);
        self.sys.write(" last=");
        self.sys.printU64(reclaim_summary.global_reclaim_last_reason);
        self.sys.write("/");
        self.sys.printU64(reclaim_summary.global_reclaim_last_returned_frames);
        self.sys.println("");

        self.sys.write("STORDIAG backingStore: ");
        self.sys.write(if (backing_store_ok) "OK" else "FAILED");
        self.sys.write(" bytes=");
        self.sys.printU64(backing_probe.available_bytes);
        self.sys.write("/");
        self.sys.printU64(backing_probe.requested_bytes);
        self.sys.write(" cluster=");
        self.sys.printU64(backing_probe.cluster_bytes);
        self.sys.write(" first=");
        self.sys.printU64(backing_probe.first_cluster);
        self.sys.write(" probes=");
        self.sys.printU64(backing_summary.memory_backing_store_probe_count);
        self.sys.write(" ready=");
        self.sys.printU64(backing_summary.memory_backing_store_ready_count);
        self.sys.write(" fail=");
        self.sys.printU64(backing_summary.memory_backing_store_failure_count);
        self.sys.write(" pager=");
        self.sys.printU64(backing_summary.memory_backing_store_pager_enabled);
        self.sys.println("");

        self.sys.write("STORDIAG backingSlots: ");
        self.sys.write(if (backing_slots_ok) "OK" else "FAILED");
        self.sys.write(" cap=");
        self.sys.printU64(slot_final.capacity_slots);
        self.sys.write(" free=");
        self.sys.printU64(slot_final.free_slots);
        self.sys.write(" reserveOps=");
        self.sys.printU64(slot_summary.memory_backing_store_slot_reserve_count);
        self.sys.write(" releaseOps=");
        self.sys.printU64(slot_summary.memory_backing_store_slot_release_count);
        self.sys.write(" errOps=");
        self.sys.printU64(slot_summary.memory_backing_store_slot_error_mark_count);
        self.sys.write(" recoverOps=");
        self.sys.printU64(slot_summary.memory_backing_store_slot_recovery_count);
        self.sys.write(" pager=");
        self.sys.printU64(slot_summary.memory_backing_store_slot_pager_enabled);
        self.sys.write("/");
        self.sys.printU64(slot_summary.memory_backing_store_slot_eviction_enabled);
        self.sys.println("");

        self.sys.write("STORDIAG pagerGates: ");
        self.sys.write(if (pager_gates_ok) "OK" else "FAILED");
        self.sys.write(" slots=");
        self.sys.printU64(gate_ready.prepared_slots);
        self.sys.write("/");
        self.sys.printU64(gate_ready.capacity_slots);
        self.sys.write(" rollback=");
        self.sys.printU64(gate_ready.rollback_completed);
        self.sys.write(" probes=");
        self.sys.printU64(gate_summary.memory_pager_gate_probe_count);
        self.sys.write("/");
        self.sys.printU64(gate_summary.memory_pager_gate_failure_count);
        self.sys.write(" pageIO=");
        self.sys.printU64(gate_ready.page_in_enabled);
        self.sys.write("/");
        self.sys.printU64(gate_ready.page_out_enabled);
        self.sys.println("");

        self.sys.write("STORDIAG pageIO: ");
        self.sys.write(if (page_io_ok) "OK" else "FAILED");
        self.sys.write(" out=");
        self.sys.printU64(page_in.total_page_outs);
        self.sys.write(" in=");
        self.sys.printU64(page_in.total_page_ins);
        self.sys.write(" fail=");
        self.sys.printU64(page_in.total_failures);
        self.sys.write(" slot=");
        self.sys.printU64(page_in.backing_slot);
        self.sys.write(" offset=");
        self.sys.printU64(page_in.backing_offset);
        self.sys.write(" eviction=");
        self.sys.printU64(page_in.eviction_enabled);
        self.sys.write(" pages=");
        self.sys.printU64(page_in.page_count);
        self.sys.println("");

        var checked: u32 = 0;
        var active: u32 = 0;
        var nvme_devices: u32 = 0;
        var nvme_worker_requests: u64 = 0;
        var nvme_worker_completions: u64 = 0;
        var nvme_timeouts: u64 = 0;
        var index: u32 = 0;
        while (index < summary.storage_device_count and index < 8) : (index += 1) {
            const info = self.dev.performanceStorage(index) orelse {
                ok = false;
                continue;
            };
            checked += 1;
            self.printStoragePerformance(info);
            if (storagePerformanceActive(info)) active += 1;
            if (!storagePerformanceOk(info)) ok = false;
            if (info.bus == r4os.abi.storage_backend_bus_nvme) {
                nvme_devices += 1;
                nvme_worker_requests +%= info.worker_requests;
                nvme_worker_completions +%= info.worker_completions;
                nvme_timeouts +%= info.completion_timeouts;
            }
        }

        const nvme_runtime_ok = nvme_devices != 0 and nvme_worker_requests != 0 and
            nvme_worker_completions != 0 and nvme_timeouts == 0;
        self.sys.write("STORDIAG NVMe runtime: ");
        self.sys.write(if (nvme_runtime_ok) "OK" else "FAILED");
        self.sys.write(" devices=");
        self.sys.printU64(nvme_devices);
        self.sys.write(" work=");
        self.sys.printU64(nvme_worker_requests);
        self.sys.write("/");
        self.sys.printU64(nvme_worker_completions);
        self.sys.write(" timeouts=");
        self.sys.printU64(nvme_timeouts);
        self.sys.println("");

        return ok and checked != 0 and active != 0 and nvme_runtime_ok;
    }

    fn writeBackingStoreFile(self: *App, path: [*:0]const u8, total_bytes: u64) bool {
        if (self.sys.fileStreamBegin(path, r4os.abi.file_stream_open_replace) != r4os.abi.file_stream_result_ok) return false;
        var chunk: [4096]u8 = undefined;
        var i: usize = 0;
        while (i < chunk.len) : (i += 1) {
            chunk[i] = @as(u8, @truncate(i *% 13 +% 0x41));
        }
        var offset: u64 = 0;
        while (offset < total_bytes) {
            const remaining = total_bytes - offset;
            const len: usize = if (remaining > chunk.len) chunk.len else @intCast(remaining);
            const written = self.sys.fileStreamWrite(path, offset, chunk[0..len], 0);
            if (written != @as(i32, @intCast(len))) {
                _ = self.sys.fileStreamAbort(path);
                return false;
            }
            offset += @intCast(len);
        }
        return self.sys.fileStreamFinish(path, total_bytes, 0) == r4os.abi.file_stream_result_ok;
    }

    fn printStoragePerformance(self: *App, info: r4os.abi.ProgramStoragePerformanceInfo) void {
        self.sys.write("STORDIAG perf #");
        self.sys.printU64(info.index);
        self.sys.write(" ");
        writeNonEmptyZ(&self.sys, info.name[0..]);
        self.sys.write(" q=");
        self.sys.printU64(info.queue_depth);
        self.sys.write(" used=");
        self.sys.printU64(info.queue_used);
        self.sys.write(" high=");
        self.sys.printU64(info.queue_high_water);
        self.sys.write(" queued=");
        self.sys.printU64(info.queued_requests);
        self.sys.write(" done=");
        self.sys.printU64(info.dequeued_requests);
        self.sys.write(" cwait=");
        self.sys.printU64(info.completion_waits);
        self.sys.write(" ctimeout=");
        self.sys.printU64(info.completion_timeouts);
        self.sys.write(" cmax=");
        self.sys.printU64(info.completion_max_ticks);
        self.sys.write(" sig=");
        self.sys.printU64(info.completion_signals);
        self.sys.write(" work=");
        self.sys.printU64(info.worker_requests);
        self.sys.write("/");
        self.sys.printU64(info.worker_completions);
        self.sys.write(" boot=");
        self.sys.printU64(info.boot_inline_requests);
        self.sys.write(" err=");
        self.sys.printU64(info.last_error);
        self.sys.println("");
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

fn delta(after: u64, before: u64) u64 {
    return if (after >= before) after - before else 0;
}

fn pagefileBlockersOk(blockers: u32) bool {
    const required = r4os.abi.fs_cache_pagefile_blocker_no_pagefile |
        r4os.abi.fs_cache_pagefile_blocker_no_swap |
        r4os.abi.fs_cache_pagefile_blocker_no_pager;
    const forbidden = r4os.abi.fs_cache_pagefile_blocker_static_cache |
        r4os.abi.fs_cache_pagefile_blocker_no_global_reclaim;
    return (blockers & required) == required and (blockers & forbidden) == 0;
}

fn backingStoreReadyFlagsOk(flags: u32) bool {
    const required = r4os.abi.memory_backing_store_flag_file_backed |
        r4os.abi.memory_backing_store_flag_existing_file |
        r4os.abi.memory_backing_store_flag_fat32 |
        r4os.abi.memory_backing_store_flag_reserve_only |
        r4os.abi.memory_backing_store_flag_pager_disabled |
        r4os.abi.memory_backing_store_flag_uses_fs_api |
        r4os.abi.memory_backing_store_flag_no_second_io_path |
        r4os.abi.memory_backing_store_flag_page_aligned_request;
    return (flags & required) == required;
}

fn backingStoreSlotFlagsOk(flags: u32) bool {
    const required = r4os.abi.memory_backing_store_slot_flag_file_backed |
        r4os.abi.memory_backing_store_slot_flag_backing_ready |
        r4os.abi.memory_backing_store_slot_flag_metadata_only |
        r4os.abi.memory_backing_store_slot_flag_range_table |
        r4os.abi.memory_backing_store_slot_flag_page_sized_slots |
        r4os.abi.memory_backing_store_slot_flag_pager_disabled |
        r4os.abi.memory_backing_store_slot_flag_recovery_available;
    const forbidden = r4os.abi.memory_backing_store_slot_flag_eviction_disabled |
        r4os.abi.memory_backing_store_slot_flag_no_page_io;
    return (flags & required) == required and (flags & forbidden) == 0;
}

fn pagerGateFlagsOk(flags: u32) bool {
    const required = r4os.abi.memory_pager_gate_flag_file_backed |
        r4os.abi.memory_pager_gate_flag_backing_ready |
        r4os.abi.memory_pager_gate_flag_metadata_only |
        r4os.abi.memory_pager_gate_flag_vm_region_attached |
        r4os.abi.memory_pager_gate_flag_commit_gate |
        r4os.abi.memory_pager_gate_flag_fault_gate |
        r4os.abi.memory_pager_gate_flag_slot_reservation_tested |
        r4os.abi.memory_pager_gate_flag_rollback_complete |
        r4os.abi.memory_pager_gate_flag_pager_disabled |
        r4os.abi.memory_pager_gate_flag_no_page_io |
        r4os.abi.memory_pager_gate_flag_no_swap |
        r4os.abi.memory_pager_gate_flag_no_second_io_path |
        r4os.abi.memory_pager_gate_flag_page_sized_slots;
    return (flags & required) == required;
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
