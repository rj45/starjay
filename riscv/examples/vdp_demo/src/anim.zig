const std = @import("std");

pub const anim = @This();

pub const Ctx = struct {
    // clint mtime since the start of the animation
    time: u64,

    // current frame number since the start of the animation
    frame: u32,

    // frame number to start executing the current keyframe on
    start: u32,

    // frame number to stop executing the current keyframe on
    end: u32,
};

pub fn Keyframe(State: type) type {
    return struct {
        delay: u32,
        duration: u32,
        do: *const fn (state: *State, ctx: *Ctx) void,
    };
}

pub fn Animation(State: type) type {
    return struct {
        keyframes: []const Keyframe(State),
        start_time: u64 = 0,
        total_duration: u32,
        current_keyframe: u32 = 0,
        state: *State,
        ctx: Ctx,

        pub fn init(state: *State, keyframes: []const Keyframe(State)) Animation(State) {
            var total_duration: u32 = 0;
            for (keyframes) |kf| {
                total_duration += kf.delay + kf.duration;
            }
            return Animation(State){
                .keyframes = keyframes,
                .total_duration = total_duration,
                .state = state,
                .ctx = Ctx{
                    .time = 0,
                    .frame = 0,
                    .start = keyframes[0].delay,
                    .end = keyframes[0].delay + keyframes[0].duration,
                },
            };
        }

        pub fn tick(self: *Animation(State), now: u64) void {
            if (self.start_time == 0 and self.current_keyframe == 0) {
                self.start_time = now;
            }

            self.ctx.time = now - self.start_time;
            self.ctx.frame += 1;

            if (self.ctx.frame >= self.ctx.end and self.current_keyframe < self.keyframes.len) {
                self.current_keyframe += 1;

                const kf = self.keyframes[self.current_keyframe];
                self.ctx.start = self.ctx.end + kf.delay;
                self.ctx.end = self.ctx.start + kf.duration;
            }

            if (self.ctx.frame >= self.ctx.start and self.ctx.frame < self.ctx.end) {
                self.keyframes[self.current_keyframe].do(self.state, &self.ctx);
            }
        }
    };
}
