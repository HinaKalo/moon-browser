const std = @import("std");
const sdk = @import("moon_plugin");

pub const limit = 24;
pub const name_limit = 96;
pub const Group = struct {
    id: u32 = 0,
    name: [name_limit+1:0]u8 = @splat(0),
    color: sdk.TabGroupColor = .indigo,
    collapsed: bool = false,

    pub fn describe(self: *const Group) sdk.TabGroup {
        return .{ .id=self.id,.name=std.mem.sliceTo(&self.name,0),.color=self.color,.collapsed=self.collapsed };
    }
};
pub var groups: [limit]Group = @splat(.{});
var next_id: u32 = 1;

pub fn get(id: u32) ?*Group {
    if (id==0) return null;
    for (&groups) |*group| if (group.id==id) return group;
    return null;
}

pub fn validName(name: []const u8) bool {
    return name.len!=0 and name.len<=name_limit and std.unicode.utf8ValidateSlice(name) and
        std.mem.trim(u8,name," \t").len!=0 and std.mem.indexOfAny(u8,name,"\x00\r\n\t")==null;
}

pub fn setName(group: *Group, name: []const u8) void {
    @memcpy(group.name[0..name.len],name);
    group.name[name.len]=0;
}

pub fn create(saved: ?sdk.TabGroup) ?*Group {
    for (&groups) |*entry| {
        if (entry.id!=0) continue;
        const id=next_id;
        next_id+=1;
        entry.*=.{ .id=id,.color=@enumFromInt((id-1)%std.enums.values(sdk.TabGroupColor).len) };
        if (saved) |value| {
            setName(entry,value.name);
            entry.color=value.color;
            entry.collapsed=value.collapsed;
        } else {
            _=std.fmt.bufPrintSentinel(&entry.name,"标签组 {d}",.{id},0) catch unreachable;
        }
        return entry;
    }
    return null;
}
