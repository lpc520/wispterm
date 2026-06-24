//! Source guards for the P3.1/P3.1b AppWindow extraction boundaries.

const std = @import("std");

const appwindow_source = @embedFile("../AppWindow.zig");

const p3_1_markers = [_][]const u8{
    "fn buildRemoteLayoutJson",
    "fn buildCtlPanesJson",
    "const WeixinRequest",
    "const weixin_vtable",
    "const ctl_vtable",
    "fn remoteAiWrite",
    "fn remoteAiAgentOpen",
    "fn appendRemoteAiChatTabJson",
    "fn appendRemoteAiHistoryTabJson",
    "fn makeAgentToolSurface",
    "fn agentSpawnTab",
    "fn handleAgentTabNewRequest",
    "fn handleAgentTabCloseRequest",
    "fn handleAgentSshConnectRequest",
    "fn handleAgentSshSaveRequest",
};

const p3_1b_markers = [_][]const u8{
    "fn scMoveSel",
    "fn skillCenterStartEnumerate",
    "fn skillCenterStartInstall",
    "fn skillCenterToolManifestPath",
    "fn skillCenterManifestJsonWithEnabled",
    "fn skillCenterContinueToolImport",
    "fn skillCenterRunTransfer",
    "fn skillCenterPreviewServerSkill",
    "fn skillCenterDeployDecide",
    "fn skillCenterImportAct",
    "const SkillLibraryScanJob",
    "const SkillTransferJob",
    "const SkillInstallEnumerateJob",
    "const SkillInstallDownloadJob",
};

fn expectAbsent(marker: []const u8) !void {
    if (std.mem.indexOf(u8, appwindow_source, marker)) |offset| {
        std.debug.print("P3.1 boundary marker returned to src/AppWindow.zig: {s} at byte {d}\n", .{ marker, offset });
        return error.P3_1BoundaryRegression;
    }
}

test "P3.1 bridge and request implementations stay out of AppWindow" {
    inline for (p3_1_markers) |marker| {
        try expectAbsent(marker);
    }
}

test "P3.1b Skill Center action implementations stay out of AppWindow" {
    inline for (p3_1b_markers) |marker| {
        try expectAbsent(marker);
    }
}
