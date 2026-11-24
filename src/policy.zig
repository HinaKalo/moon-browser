pub const mib: u64 = 1024 * 1024;

pub const Settings = struct {
    warm_limit: usize = 6,
    idle_ms: u64 = 5 * 60 * 1000,
    high_bytes: u64 = 1024 * mib,
    target_bytes: u64 = 800 * mib,
};

pub const Tab = struct {
    last_used: u64 = 0,
    pid: u32 = 0,
    live: bool = true,
    protected: bool = false,
};

pub const Sample = struct { pid: u32, bytes: u64 };

pub fn totalCommit(samples: []const Sample) u64 {
    var bytes: u64 = 0;
    for (samples, 0..) |sample, index| {
        if (sample.pid == 0) continue;
        for (samples[0..index]) |previous| {
            if (previous.pid == sample.pid) break;
        } else bytes +|= sample.bytes;
    }
    return bytes;
}

pub fn underPressure(previous: bool, bytes: u64, low_memory: bool, settings: Settings) bool {
    return low_memory or bytes > if (previous) settings.target_bytes else settings.high_bytes;
}

pub fn choose(tabs: []const Tab, active: usize, now: u64, pressure: bool, settings: Settings) ?usize {
    var eligible: usize = 0;
    var oldest: ?usize = null;
    var oldest_reclaimable: ?usize = null;
    for (tabs, 0..) |tab, index| {
        if (index == active or !tab.live or tab.protected) continue;
        eligible += 1;
        if (oldest == null or tab.last_used < tabs[oldest.?].last_used) oldest = index;
        if (!pressure or tab.pid == 0) continue;
        for (tabs, 0..) |other, other_index| {
            if (other.live and other.pid == tab.pid and (other.protected or other_index == active)) break;
        } else {
            if (oldest_reclaimable == null or tab.last_used < tabs[oldest_reclaimable.?].last_used)
                oldest_reclaimable = index;
        }
    }
    const index = oldest orelse return null;
    if (pressure) return oldest_reclaimable orelse index;
    if (eligible > settings.warm_limit or now -| tabs[index].last_used >= settings.idle_ms) return index;
    return null;
}
