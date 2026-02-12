const std = @import("std");
const starjay = @import("starjay");

export fn kmain() noreturn {
    const console = starjay.term.getWriter();

    console.print("Hello World!\r\n", .{}) catch {};
    console.flush() catch {}; // don't forget to flush!

    // This will quit the StarJay emulator.
    starjay.syscon.shutdown();
}
