//! Vulkan crash guard (labelle-bgfx#172 D11): the SEAM only.
//!
//! D11: mark "Vulkan start in progress" in the app's internal storage before a
//! Vulkan init, clear it once the game has run stably, and start on GLES at
//! the next launch if the mark is still there. That work is
//! labelle-toolkit/labelle-android#28. Until it lands this is a stub that
//! never disables Vulkan, so `renderer.resolve` (#27) already consults the
//! guard in the right place (after the intent override, before the provider
//! setting) and #28 only has to replace the body below.
const std = @import("std");

/// True when a previous launch crashed during a Vulkan start and this launch
/// must use GLES instead. `activity` is the running `ANativeActivity*`
/// (opaque), for the internal-storage path #28 will need.
///
/// Stub: always "not disabled".
pub fn isVulkanDisabled(activity: ?*const anyopaque) bool {
    _ = activity;
    return false;
}

test "stub: Vulkan is never disabled" {
    try std.testing.expect(!isVulkanDisabled(null));
    try std.testing.expect(!isVulkanDisabled(@ptrFromInt(0x1000)));
}
