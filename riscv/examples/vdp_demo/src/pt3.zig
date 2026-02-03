// PT3 Player - Zig port matching C reference implementation by Bulba/Volutar
// Original C code: https://github.com/Volutar/pt3player
// Copyright (c) 2023 Volutar, MIT License
// Modified (mostly adding dual AY3 and converting to zig):
//   Copyright (c) 2026 Ryan "rj45" Sanche, MIT License
const std = @import("std");

const ay38910 = @import("ay38910.zig").ay38910;

pub const pt3 = @This();

pub const Pt3Player = struct {
    // File data
    data: []const u8,
    header: Pt3Header,

    // Playback state
    state: [2]ChipState, // For TurboSound: [0] = chip 0, [1] = chip 1
    is_turbosound: bool,
    ts_offset: u8, // 0x20 = not TurboSound, else pattern offset for chip 1
    version: u8,

    // Position tracking
    positions: []const u8,

    // Output registers
    output: ay38910.TurboSoundRegs,

    pub const CommonState = struct {
        env_base: u16 = 0,
        cur_env_slide: i16 = 0,
        env_slide_add: i16 = 0,
        cur_env_delay: i8 = 0, // Signed!
        env_delay: i8 = 0, // Signed!
        noise_base: u8 = 0,
        add_to_noise: u8 = 0,
        delay: u8 = 0, // Tempo
        delay_counter: u8 = 1,
        current_position: u8 = 0,
    };

    pub const ChipState = struct {
        channels: [3]ChannelState = [_]ChannelState{.{}} ** 3,
        common: CommonState = .{},
        envelope_shape_set: bool = false, // Flag for envelope shape change this frame
    };

    pub const ChannelState = struct {
        address_in_pattern: u16 = 0, // Pattern data pointer
        ornament_pointer: u16 = 0, // Points past header to data
        sample_pointer: u16 = 0, // Points past header to data
        ton: u16 = 0, // Computed tone output
        loop_ornament_position: u8 = 0,
        ornament_length: u8 = 0,
        position_in_ornament: u8 = 0,
        loop_sample_position: u8 = 0,
        sample_length: u8 = 0,
        position_in_sample: u8 = 0,
        volume: u8 = 15,
        amplitude: u8 = 0, // Computed output
        number_of_notes_to_skip: u8 = 0,
        note_skip_counter: i8 = 1, // Signed!
        note: u8 = 0,
        slide_to_note: u8 = 0, // Portamento target
        envelope_enabled: bool = false,
        enabled: bool = false,
        simple_gliss: bool = true, // false for portamento
        current_amplitude_sliding: i16 = 0,
        current_noise_sliding: i16 = 0,
        current_envelope_sliding: i16 = 0,
        ton_slide_count: i16 = 0,
        current_on_off: i16 = 0, // Tremolo counter
        on_off_delay: i16 = 0,
        off_on_delay: i16 = 0,
        ton_slide_delay: i16 = 0,
        current_ton_sliding: i16 = 0,
        ton_accumulator: i16 = 0, // i16 not i32!
        ton_slide_step: i16 = 0,
        ton_delta: i16 = 0, // For portamento
    };

    pub fn init(self: *Pt3Player, file_data: []const u8) !void {
        self.* = .{
            .data = file_data,
            .header = std.mem.zeroes(Pt3Header),
            .state = [_]ChipState{.{}} ** 2,
            .is_turbosound = false,
            .ts_offset = 0x20,
            .version = 6,
            .positions = undefined,
            .output = ay38910.TurboSoundRegs.init(),
        };

        try Pt3Header.parse(&self.header, file_data);

        // Validate signature
        if (std.mem.eql(u8, self.header.songinfo[0..13], "ProTracker 3.")) {
            self.version = if (self.header.songinfo[13] >= '0' and self.header.songinfo[13] <= '9')
                self.header.songinfo[13] - '0'
            else
                6;
        } else if (std.mem.eql(u8, self.header.songinfo[0..21], "Vortex Tracker II 1.0")) {
            self.version = 6;
        } else {
            return error.InvalidSignature;
        }

        // Find position list
        const pos_start: u32 = Pt3Header.SIZE;
        var pos_end = pos_start;
        while (pos_end < file_data.len and file_data[pos_end] != 0xFF) {
            pos_end += 1;
        }

        // TODO: this is not how you handle turbosound mode properly...
        self.is_turbosound = self.header.mode != 0x20;
        self.ts_offset = self.header.mode;
        self.positions = file_data[pos_start..pos_end];

        // Initialize chip 0
        self.state[0].common.delay = self.header.tempo;
        self.state[0].common.delay_counter = 1;
        self.state[0].common.current_position = 0;

        // Initialize channels for chip 0
        self.initChannels(0);

        // Load first pattern for chip 0
        self.loadPatternAddresses(0);

        // Initialize chip 1 for TurboSound
        if (self.is_turbosound) {
            self.state[1].common.delay = self.header.tempo;
            self.state[1].common.delay_counter = 1;
            self.state[1].common.current_position = 0;
            self.initChannels(1);
            self.loadPatternAddresses(1);
        }
    }

    fn initChannels(self: *Pt3Player, chip: usize) void {
        for (0..3) |chan| {
            var state = &self.state[chip].channels[chan];

            // Load ornament 0
            state.ornament_pointer = self.header.ornament_offsets[0];
            state.loop_ornament_position = self.data[state.ornament_pointer];
            state.ornament_pointer += 1;
            state.ornament_length = self.data[state.ornament_pointer];
            state.ornament_pointer += 1;

            // Load sample 1
            state.sample_pointer = self.header.sample_offsets[1];
            state.loop_sample_position = self.data[state.sample_pointer];
            state.sample_pointer += 1;
            state.sample_length = self.data[state.sample_pointer];
            state.sample_pointer += 1;

            state.volume = 15;
            state.note_skip_counter = 1;
            state.enabled = false;
            state.envelope_enabled = false;
            state.note = 0;
            state.ton = 0;
        }
    }

    fn loadPatternAddresses(self: *Pt3Player, chip: usize) void {
        var i: usize = self.positions[self.state[chip].common.current_position];

        // TurboSound pattern mirroring
        if (self.ts_offset != 0x20 and chip == 1) {
            i = @as(usize, self.ts_offset) * 3 - 3 - i;
        }

        for (0..3) |chan| {
            const addr = std.mem.readInt(u16, self.data[self.header.patterns_offset + (i + chan) * 2 ..][0..2], .little);
            self.state[chip].channels[chan].address_in_pattern = addr;
        }
    }

    pub fn playFrame(self: *Pt3Player) *const ay38910.TurboSoundRegs {
        // Reset envelope shape flags for this frame
        self.state[0].envelope_shape_set = false;
        self.state[1].envelope_shape_set = false;

        // Process chip 0
        self.state[0].common.delay_counter -= 1;
        if (self.state[0].common.delay_counter == 0) {
            // Channel A triggers pattern advance check
            self.state[0].channels[0].note_skip_counter -= 1;
            if (self.state[0].channels[0].note_skip_counter == 0) {
                if (self.data[self.state[0].channels[0].address_in_pattern] == 0) {
                    self.advancePosition(0);
                }
                self.parseChannel(0, 0);
            }

            // Channels B, C
            for (1..3) |chan| {
                self.state[0].channels[chan].note_skip_counter -= 1;
                if (self.state[0].channels[chan].note_skip_counter == 0) {
                    self.parseChannel(0, chan);
                }
            }

            self.state[0].common.delay_counter = self.state[0].common.delay;
        }

        // TurboSound chip 1
        if (self.is_turbosound) {
            self.state[1].common.delay_counter -= 1;
            if (self.state[1].common.delay_counter == 0) {
                self.state[1].channels[0].note_skip_counter -= 1;
                if (self.state[1].channels[0].note_skip_counter == 0) {
                    if (self.data[self.state[1].channels[0].address_in_pattern] == 0) {
                        self.advancePosition(1);
                    }
                    self.parseChannel(1, 0);
                }

                for (1..3) |chan| {
                    self.state[1].channels[chan].note_skip_counter -= 1;
                    if (self.state[1].channels[chan].note_skip_counter == 0) {
                        self.parseChannel(1, chan);
                    }
                }

                self.state[1].common.delay_counter = self.state[1].common.delay;
            }
        }

        self.synthesize();
        return &self.output;
    }

    fn advancePosition(self: *Pt3Player, chip: usize) void {
        self.state[chip].common.current_position += 1;
        if (self.state[chip].common.current_position >= self.positions.len) {
            self.state[chip].common.current_position = self.header.loop_position;
        }

        var i: usize = self.positions[self.state[chip].common.current_position];
        if (self.ts_offset != 0x20 and chip == 1) {
            i = @as(usize, self.ts_offset) * 3 - 3 - i;
        }

        for (0..3) |chan| {
            const addr = std.mem.readInt(u16, self.data[self.header.patterns_offset + (i + chan) * 2 ..][0..2], .little);
            self.state[chip].channels[chan].address_in_pattern = addr;
        }

        self.state[chip].common.noise_base = 0;
    }

    fn parseChannel(self: *Pt3Player, chip: usize, chan: usize) void {
        var state = &self.state[chip].channels[chan];
        var offset: usize = state.address_in_pattern;

        // Capture previous values for portamento
        const pr_note = state.note;
        const pr_sliding = state.current_ton_sliding;

        var flags = std.mem.zeroes([0x10]u8);
        var count: u8 = 0;

        while (offset < self.data.len) {
            const cmd = self.data[offset];
            offset += 1;

            if (cmd >= 0xf0) {
                // Set ornament + sample
                const orn_idx = cmd - 0xf0;
                state.ornament_pointer = self.header.ornament_offsets[orn_idx];
                state.loop_ornament_position = self.data[state.ornament_pointer];
                state.ornament_pointer += 1;
                state.ornament_length = self.data[state.ornament_pointer];
                state.ornament_pointer += 1;
                state.position_in_ornament = 0;

                // Read sample from next byte (divide by 2!)
                const sample_idx = self.data[offset] / 2;
                offset += 1;
                state.sample_pointer = self.header.sample_offsets[sample_idx];
                state.loop_sample_position = self.data[state.sample_pointer];
                state.sample_pointer += 1;
                state.sample_length = self.data[state.sample_pointer];
                state.sample_pointer += 1;
                state.envelope_enabled = false;
            } else if (cmd >= 0xd1) {
                // Set sample
                const sample_idx = cmd - 0xd0;
                state.sample_pointer = self.header.sample_offsets[sample_idx];
                state.loop_sample_position = self.data[state.sample_pointer];
                state.sample_pointer += 1;
                state.sample_length = self.data[state.sample_pointer];
                state.sample_pointer += 1;
            } else if (cmd == 0xd0) {
                // Keep note - quit
                break;
            } else if (cmd >= 0xc1) {
                // Set volume
                state.volume = @truncate(cmd - 0xc0);
            } else if (cmd == 0xc0) {
                // Rest
                state.position_in_sample = 0;
                state.current_amplitude_sliding = 0;
                state.current_noise_sliding = 0;
                state.current_envelope_sliding = 0;
                state.position_in_ornament = 0;
                state.ton_slide_count = 0;
                state.current_ton_sliding = 0;
                state.ton_accumulator = 0;
                state.current_on_off = 0;
                state.enabled = false;
                break;
            } else if (cmd >= 0xb2) {
                // Set envelope
                state.envelope_enabled = true;
                self.output.chip(chip).envelope_shape = @truncate(cmd - 0xb1);
                self.state[chip].envelope_shape_set = true;
                // C reads hi then lo (big endian)
                self.state[chip].common.env_base = (@as(u16, self.data[offset]) << 8) | self.data[offset + 1];
                offset += 2;
                state.position_in_ornament = 0;
                self.state[chip].common.cur_env_slide = 0;
                self.state[chip].common.cur_env_delay = 0;
            } else if (cmd == 0xb1) {
                // Skip lines - NO subtract!
                state.number_of_notes_to_skip = self.data[offset];
                offset += 1;
            } else if (cmd == 0xb0) {
                // Disable envelope
                state.envelope_enabled = false;
                state.position_in_ornament = 0;
            } else if (cmd >= 0x50) {
                // Set note
                state.note = @truncate(cmd - 0x50);
                state.position_in_sample = 0;
                state.current_amplitude_sliding = 0;
                state.current_noise_sliding = 0;
                state.current_envelope_sliding = 0;
                state.position_in_ornament = 0;
                state.ton_slide_count = 0;
                state.current_ton_sliding = 0;
                state.ton_accumulator = 0;
                state.current_on_off = 0;
                state.enabled = true;
                break;
            } else if (cmd >= 0x40) {
                // Set ornament
                const orn_idx = cmd - 0x40;
                state.ornament_pointer = self.header.ornament_offsets[orn_idx];
                state.loop_ornament_position = self.data[state.ornament_pointer];
                state.ornament_pointer += 1;
                state.ornament_length = self.data[state.ornament_pointer];
                state.ornament_pointer += 1;
                state.position_in_ornament = 0;
            } else if (cmd >= 0x20) {
                // Set noise base
                self.state[chip].common.noise_base = @truncate(cmd - 0x20);
            } else if (cmd >= 0x11) {
                // Set envelope + sample
                self.output.chip(chip).envelope_shape = @truncate(cmd - 0x10);
                self.state[chip].envelope_shape_set = true;
                self.state[chip].common.env_base = (@as(u16, self.data[offset]) << 8) | self.data[offset + 1];
                offset += 2;
                self.state[chip].common.cur_env_slide = 0;
                self.state[chip].common.cur_env_delay = 0;
                state.envelope_enabled = true;

                // Load sample from next byte (divide by 2!)
                const sample_idx = self.data[offset] / 2;
                offset += 1;
                state.sample_pointer = self.header.sample_offsets[sample_idx];
                state.loop_sample_position = self.data[state.sample_pointer];
                state.sample_pointer += 1;
                state.sample_length = self.data[state.sample_pointer];
                state.sample_pointer += 1;
                state.position_in_ornament = 0;
            } else if (cmd == 0x10) {
                // Disable envelope + set sample
                state.envelope_enabled = false;
                const sample_idx = self.data[offset] / 2;
                offset += 1;
                state.sample_pointer = self.header.sample_offsets[sample_idx];
                state.loop_sample_position = self.data[state.sample_pointer];
                state.sample_pointer += 1;
                state.sample_length = self.data[state.sample_pointer];
                state.sample_pointer += 1;
                state.position_in_ornament = 0;
            } else if (cmd == 9 or cmd == 8 or (cmd >= 1 and cmd <= 5)) {
                count += 1;
                flags[cmd] = count;
            }
        }

        // Process commands in reverse order
        while (count > 0) {
            if (count == flags[1]) {
                // Glissando
                state.ton_slide_delay = self.data[offset];
                offset += 1;
                state.ton_slide_count = state.ton_slide_delay;
                state.ton_slide_step = std.mem.readInt(i16, self.data[offset..][0..2], .little);
                offset += 2;
                state.simple_gliss = true;
                state.current_on_off = 0;
                if (state.ton_slide_count == 0 and self.version >= 7) {
                    state.ton_slide_count = 1;
                }
            } else if (count == flags[2]) {
                // Portamento
                state.simple_gliss = false;
                state.current_on_off = 0;
                state.ton_slide_delay = self.data[offset];
                offset += 1;
                state.ton_slide_count = state.ton_slide_delay;
                offset += 2; // Skip limit
                state.ton_slide_step = @intCast(@abs(std.mem.readInt(i16, self.data[offset..][0..2], .little)));
                offset += 2;
                state.ton_delta = @as(i16, @intCast(@as(i32, self.getFreq(state.note)) - @as(i32, self.getFreq(pr_note))));
                state.slide_to_note = state.note;
                state.note = pr_note;
                if (self.version >= 6) {
                    state.current_ton_sliding = pr_sliding;
                }
                if (state.ton_delta - state.current_ton_sliding < 0) {
                    state.ton_slide_step = -state.ton_slide_step;
                }
            } else if (count == flags[3]) {
                // Sample offset
                state.position_in_sample = self.data[offset];
                offset += 1;
            } else if (count == flags[4]) {
                // Ornament offset
                state.position_in_ornament = self.data[offset];
                offset += 1;
            } else if (count == flags[5]) {
                // Tremolo
                state.on_off_delay = self.data[offset];
                offset += 1;
                state.off_on_delay = self.data[offset];
                offset += 1;
                state.current_on_off = state.on_off_delay;
                state.ton_slide_count = 0;
                state.current_ton_sliding = 0;
            } else if (count == flags[8]) {
                // Envelope slide
                self.state[chip].common.env_delay = @intCast(self.data[offset]);
                offset += 1;
                self.state[chip].common.cur_env_delay = self.state[chip].common.env_delay;
                self.state[chip].common.env_slide_add = std.mem.readInt(i16, self.data[offset..][0..2], .little);
                offset += 2;
            } else if (count == flags[9]) {
                // Tempo
                self.state[chip].common.delay = self.data[offset];
                offset += 1;
            }
            count -= 1;
        }

        state.address_in_pattern = @intCast(offset);
        state.note_skip_counter = @intCast(state.number_of_notes_to_skip);
    }

    fn synthesize(self: *Pt3Player) void {
        var add_to_env: i16 = 0;
        var temp_mixer: u8 = 0;

        // Process chip 0 channels
        for (0..3) |chan| {
            add_to_env += self.changeRegisters(0, chan, &temp_mixer);
        }

        // Set chip 0 registers
        self.output.psg1.tone_a = @truncate(self.state[0].channels[0].ton);
        self.output.psg1.tone_b = @truncate(self.state[0].channels[1].ton);
        self.output.psg1.tone_c = @truncate(self.state[0].channels[2].ton);

        self.output.psg1.noise_period = @truncate((self.state[0].common.noise_base +% self.state[0].common.add_to_noise) & 0x1f);
        self.output.psg1.mixer = @bitCast(temp_mixer);

        self.output.psg1.volume_a = @bitCast(self.state[0].channels[0].amplitude);
        self.output.psg1.volume_b = @bitCast(self.state[0].channels[1].amplitude);
        self.output.psg1.volume_c = @bitCast(self.state[0].channels[2].amplitude);

        const env0: u16 = @bitCast(@as(i16, @truncate(@as(i32, self.state[0].common.env_base) +
            add_to_env + self.state[0].common.cur_env_slide)));
        self.output.psg1.envelope_period = env0;

        // Envelope slide for chip 0
        if (self.state[0].common.cur_env_delay > 0) {
            self.state[0].common.cur_env_delay -= 1;
            if (self.state[0].common.cur_env_delay == 0) {
                self.state[0].common.cur_env_delay = self.state[0].common.env_delay;
                self.state[0].common.cur_env_slide += self.state[0].common.env_slide_add;
            }
        }

        // Process chip 1 for TurboSound
        if (self.is_turbosound) {
            add_to_env = 0;
            temp_mixer = 0;

            for (0..3) |chan| {
                add_to_env += self.changeRegisters(1, chan, &temp_mixer);
            }

            self.output.psg2.tone_a = @truncate(self.state[1].channels[0].ton);
            self.output.psg2.tone_b = @truncate(self.state[1].channels[1].ton);
            self.output.psg2.tone_c = @truncate(self.state[1].channels[2].ton);

            self.output.psg2.noise_period = @truncate((self.state[1].common.noise_base +% self.state[1].common.add_to_noise) & 0x1f);
            self.output.psg2.mixer = @bitCast(temp_mixer);

            self.output.psg2.volume_a = @bitCast(self.state[1].channels[0].amplitude);
            self.output.psg2.volume_b = @bitCast(self.state[1].channels[1].amplitude);
            self.output.psg2.volume_c = @bitCast(self.state[1].channels[2].amplitude);

            const env1: u16 = @bitCast(@as(i16, @truncate(@as(i32, self.state[1].common.env_base) +
                add_to_env + self.state[1].common.cur_env_slide)));
            self.output.psg2.envelope_period = env1;

            if (self.state[1].common.cur_env_delay > 0) {
                self.state[1].common.cur_env_delay -= 1;
                if (self.state[1].common.cur_env_delay == 0) {
                    self.state[1].common.cur_env_delay = self.state[1].common.env_delay;
                    self.state[1].common.cur_env_slide += self.state[1].common.env_slide_add;
                }
            }
        }
    }

    fn changeRegisters(self: *Pt3Player, chip: usize, chan: usize, temp_mixer: *u8) i16 {
        var state = &self.state[chip].channels[chan];
        var add_to_env: i16 = 0;

        if (state.enabled) {
            const sample_base = state.sample_pointer + @as(usize, state.position_in_sample) * 4;
            const b0 = self.data[sample_base + 0];
            const b1 = self.data[sample_base + 1];
            state.ton = std.mem.readInt(u16, self.data[sample_base + 2 ..][0..2], .little);

            state.ton +%= @bitCast(state.ton_accumulator);
            if (b1 & 0x40 != 0) state.ton_accumulator = @bitCast(state.ton);

            const orn_value: i8 = @bitCast(self.data[state.ornament_pointer + state.position_in_ornament]);
            var j: i16 = @as(i16, state.note) + orn_value;
            // Handle signed comparison like C: j >= 128 means negative in C's uint8 context
            if (j < 0) j = 0 else if (j > 95) j = 95;

            const w = self.getFreq(@intCast(j));
            state.ton = @truncate((@as(u32, state.ton) +% @as(u32, @bitCast(@as(i32, state.current_ton_sliding))) +% w) & 0xfff);

            // Tone sliding
            if (state.ton_slide_count > 0) {
                state.ton_slide_count -= 1;
                if (state.ton_slide_count == 0) {
                    state.current_ton_sliding += state.ton_slide_step;
                    state.ton_slide_count = state.ton_slide_delay;
                    if (!state.simple_gliss) {
                        if ((state.ton_slide_step < 0 and state.current_ton_sliding <= state.ton_delta) or
                            (state.ton_slide_step >= 0 and state.current_ton_sliding >= state.ton_delta))
                        {
                            state.note = state.slide_to_note;
                            state.ton_slide_count = 0;
                            state.current_ton_sliding = 0;
                        }
                    }
                }
            }

            // Amplitude
            state.amplitude = b1 & 0x0f;
            if (b0 & 0x80 != 0) {
                if (b0 & 0x40 != 0) {
                    if (state.current_amplitude_sliding < 15) state.current_amplitude_sliding += 1;
                } else {
                    if (state.current_amplitude_sliding > -15) state.current_amplitude_sliding -= 1;
                }
            }
            var amp: i16 = @as(i16, state.amplitude) + state.current_amplitude_sliding;
            // Handle like C: amp >= 128 means negative
            if (amp < 0) amp = 0 else if (amp > 15) amp = 15;
            state.amplitude = @intCast(amp);

            // Volume table (version <= 4!)
            if (self.version <= 4) {
                state.amplitude = VOL_TABLE_33_34[@as(usize, state.volume) * 16 + state.amplitude];
            } else {
                state.amplitude = VOL_TABLE_35[@as(usize, state.volume) * 16 + state.amplitude];
            }

            // Envelope enable
            if ((b0 & 1) == 0 and state.envelope_enabled) state.amplitude |= 0x10;

            // Noise vs Envelope offset
            if (b1 & 0x80 != 0) {
                var env_off: i8 = undefined;
                if (b0 & 0x20 != 0) {
                    env_off = @bitCast((b0 >> 1) | 0xF0);
                } else {
                    env_off = @intCast((b0 >> 1) & 0x0F);
                }
                const j_env: i16 = @as(i16, env_off) + state.current_envelope_sliding;
                if (b1 & 0x20 != 0) state.current_envelope_sliding = j_env;
                add_to_env += j_env;
            } else {
                self.state[chip].common.add_to_noise = @truncate((b0 >> 1) +% @as(u8, @bitCast(@as(i8, @truncate(state.current_noise_sliding)))));
                if (b1 & 0x20 != 0) state.current_noise_sliding = @as(i16, @intCast(@as(i8, @bitCast(self.state[chip].common.add_to_noise))));
            }

            // Mixer
            temp_mixer.* = ((b1 >> 1) & 0x48) | temp_mixer.*;

            // Advance positions
            state.position_in_sample += 1;
            if (state.position_in_sample >= state.sample_length) state.position_in_sample = state.loop_sample_position;
            state.position_in_ornament += 1;
            if (state.position_in_ornament >= state.ornament_length) state.position_in_ornament = state.loop_ornament_position;
        } else {
            state.amplitude = 0;
        }

        temp_mixer.* >>= 1;

        // Tremolo
        if (state.current_on_off > 0) {
            state.current_on_off -= 1;
            if (state.current_on_off == 0) {
                state.enabled = !state.enabled;
                state.current_on_off = if (state.enabled) state.on_off_delay else state.off_on_delay;
            }
        }

        return add_to_env;
    }

    fn getFreq(self: *const Pt3Player, note: u8) u16 {
        return switch (self.header.freq_table_num) {
            0 => if (self.version <= 3) TABLE_PT_33_34R[note] else TABLE_PT_34_35[note],
            1 => TABLE_ST[note],
            2 => if (self.version <= 3) TABLE_ASM_34R[note] else TABLE_ASM_34_35[note],
            else => if (self.version <= 3) TABLE_REAL_34R[note] else TABLE_REAL_34_35[note],
        };
    }
};

// ============================================================================
// PT3 File Header
// ============================================================================

pub const Pt3Header = struct {
    pub const SIZE = 0x62 + 1 + 1 + 1 + 1 + 1 + 2 + (32 * 2) + (16 * 2);

    songinfo: [0x62]u8,
    mode: u8, // 0x20 = single AY, else TurboSound pattern offset
    freq_table_num: u8, // 0-4
    tempo: u8, // Initial tempo (ticks per row)
    length: u8, // Song length (unused)
    loop_position: u8, // Loop position index
    patterns_offset: u16, // Little-endian offset to pattern table
    sample_offsets: [32]u16, // Little-endian offsets
    ornament_offsets: [16]u16, // Little-endian offsets
    // Followed by: position list (pattern_num * 3), terminated by 0xFF

    pub const SINGLE_AY_MODE: u8 = 0x20;

    pub fn parse(dest: *Pt3Header, data: []const u8) !void {
        if (data.len < SIZE) {
            return error.FileTooSmall;
        }

        var offset: usize = 0;
        @memcpy(dest.songinfo[0..], data[offset .. offset + 0x62]);
        offset += 0x62;

        dest.mode = data[offset];
        offset += 1;

        dest.freq_table_num = data[offset];
        offset += 1;

        dest.tempo = data[offset];
        offset += 1;

        dest.length = data[offset];
        offset += 1;

        dest.loop_position = data[offset];
        offset += 1;

        dest.patterns_offset = readInt16(data[offset..]);
        offset += 2;

        for (&dest.sample_offsets) |*elem| {
            elem.* = readInt16(data[offset..]);
            offset += 2;
        }
        for (&dest.ornament_offsets) |*elem| {
            elem.* = readInt16(data[offset..]);
            offset += 2;
        }
    }
};

fn readInt16(data: []const u8) u16 {
    return @as(u16, data[0]) | (@as(u16, data[1]) << 8);
}

// ============================================================================
// Frequency Tables
// ============================================================================

pub const FrequencyTable = [96]u16;

// Table #0 of Pro Tracker 3.3x - 3.4r
pub const TABLE_PT_33_34R: FrequencyTable = .{
    0xC21, 0xB73, 0xACE, 0xA33, 0x9A0, 0x916, 0x893, 0x818, 0x7A4, 0x736, 0x6CE, 0x66D,
    0x610, 0x5B9, 0x567, 0x519, 0x4D0, 0x48B, 0x449, 0x40C, 0x3D2, 0x39B, 0x367, 0x336,
    0x308, 0x2DC, 0x2B3, 0x28C, 0x268, 0x245, 0x224, 0x206, 0x1E9, 0x1CD, 0x1B3, 0x19B,
    0x184, 0x16E, 0x159, 0x146, 0x134, 0x122, 0x112, 0x103, 0x0F4, 0x0E6, 0x0D9, 0x0CD,
    0x0C2, 0x0B7, 0x0AC, 0x0A3, 0x09A, 0x091, 0x089, 0x081, 0x07A, 0x073, 0x06C, 0x066,
    0x061, 0x05B, 0x056, 0x051, 0x04D, 0x048, 0x044, 0x040, 0x03D, 0x039, 0x036, 0x033,
    0x030, 0x02D, 0x02B, 0x028, 0x026, 0x024, 0x022, 0x020, 0x01E, 0x01C, 0x01B, 0x019,
    0x018, 0x016, 0x015, 0x014, 0x013, 0x012, 0x011, 0x010, 0x00F, 0x00E, 0x00D, 0x00C,
};

// Table #0 of Pro Tracker 3.4x - 3.5x
pub const TABLE_PT_34_35: FrequencyTable = .{
    0xC22, 0xB73, 0xACF, 0xA33, 0x9A1, 0x917, 0x894, 0x819, 0x7A4, 0x737, 0x6CF, 0x66D,
    0x611, 0x5BA, 0x567, 0x51A, 0x4D0, 0x48B, 0x44A, 0x40C, 0x3D2, 0x39B, 0x367, 0x337,
    0x308, 0x2DD, 0x2B4, 0x28D, 0x268, 0x246, 0x225, 0x206, 0x1E9, 0x1CE, 0x1B4, 0x19B,
    0x184, 0x16E, 0x15A, 0x146, 0x134, 0x123, 0x112, 0x103, 0x0F5, 0x0E7, 0x0DA, 0x0CE,
    0x0C2, 0x0B7, 0x0AD, 0x0A3, 0x09A, 0x091, 0x089, 0x082, 0x07A, 0x073, 0x06D, 0x067,
    0x061, 0x05C, 0x056, 0x052, 0x04D, 0x049, 0x045, 0x041, 0x03D, 0x03A, 0x036, 0x033,
    0x031, 0x02E, 0x02B, 0x029, 0x027, 0x024, 0x022, 0x020, 0x01F, 0x01D, 0x01B, 0x01A,
    0x018, 0x017, 0x016, 0x014, 0x013, 0x012, 0x011, 0x010, 0x00F, 0x00E, 0x00D, 0x00C,
};

// Table #1 of Pro Tracker 3.3x - 3.5x
pub const TABLE_ST: FrequencyTable = .{
    0xEF8, 0xE10, 0xD60, 0xC80, 0xBD8, 0xB28, 0xA88, 0x9F0, 0x960, 0x8E0, 0x858, 0x7E0,
    0x77C, 0x708, 0x6B0, 0x640, 0x5EC, 0x594, 0x544, 0x4F8, 0x4B0, 0x470, 0x42C, 0x3FD,
    0x3BE, 0x384, 0x358, 0x320, 0x2F6, 0x2CA, 0x2A2, 0x27C, 0x258, 0x238, 0x216, 0x1F8,
    0x1DF, 0x1C2, 0x1AC, 0x190, 0x17B, 0x165, 0x151, 0x13E, 0x12C, 0x11C, 0x10A, 0x0FC,
    0x0EF, 0x0E1, 0x0D6, 0x0C8, 0x0BD, 0x0B2, 0x0A8, 0x09F, 0x096, 0x08E, 0x085, 0x07E,
    0x077, 0x070, 0x06B, 0x064, 0x05E, 0x059, 0x054, 0x04F, 0x04B, 0x047, 0x042, 0x03F,
    0x03B, 0x038, 0x035, 0x032, 0x02F, 0x02C, 0x02A, 0x027, 0x025, 0x023, 0x021, 0x01F,
    0x01D, 0x01C, 0x01A, 0x019, 0x017, 0x016, 0x015, 0x013, 0x012, 0x011, 0x010, 0x00F,
};

// Table #2 of Pro Tracker 3.4r
pub const TABLE_ASM_34R: FrequencyTable = .{
    0xD3E, 0xC80, 0xBCC, 0xB22, 0xA82, 0x9EC, 0x95C, 0x8D6, 0x858, 0x7E0, 0x76E, 0x704,
    0x69F, 0x640, 0x5E6, 0x591, 0x541, 0x4F6, 0x4AE, 0x46B, 0x42C, 0x3F0, 0x3B7, 0x382,
    0x34F, 0x320, 0x2F3, 0x2C8, 0x2A1, 0x27B, 0x257, 0x236, 0x216, 0x1F8, 0x1DC, 0x1C1,
    0x1A8, 0x190, 0x179, 0x164, 0x150, 0x13D, 0x12C, 0x11B, 0x10B, 0x0FC, 0x0EE, 0x0E0,
    0x0D4, 0x0C8, 0x0BD, 0x0B2, 0x0A8, 0x09F, 0x096, 0x08D, 0x085, 0x07E, 0x077, 0x070,
    0x06A, 0x064, 0x05E, 0x059, 0x054, 0x050, 0x04B, 0x047, 0x043, 0x03F, 0x03C, 0x038,
    0x035, 0x032, 0x02F, 0x02D, 0x02A, 0x028, 0x026, 0x024, 0x022, 0x020, 0x01E, 0x01D,
    0x01B, 0x01A, 0x019, 0x018, 0x015, 0x014, 0x013, 0x012, 0x011, 0x010, 0x00F, 0x00E,
};

// Table #2 of Pro Tracker 3.4x - 3.5x
pub const TABLE_ASM_34_35: FrequencyTable = .{
    0xD10, 0xC55, 0xBA4, 0xAFC, 0xA5F, 0x9CA, 0x93D, 0x8B8, 0x83B, 0x7C5, 0x755, 0x6EC,
    0x688, 0x62A, 0x5D2, 0x57E, 0x52F, 0x4E5, 0x49E, 0x45C, 0x41D, 0x3E2, 0x3AB, 0x376,
    0x344, 0x315, 0x2E9, 0x2BF, 0x298, 0x272, 0x24F, 0x22E, 0x20F, 0x1F1, 0x1D5, 0x1BB,
    0x1A2, 0x18B, 0x174, 0x160, 0x14C, 0x139, 0x128, 0x117, 0x107, 0x0F9, 0x0EB, 0x0DD,
    0x0D1, 0x0C5, 0x0BA, 0x0B0, 0x0A6, 0x09D, 0x094, 0x08C, 0x084, 0x07C, 0x075, 0x06F,
    0x069, 0x063, 0x05D, 0x058, 0x053, 0x04E, 0x04A, 0x046, 0x042, 0x03E, 0x03B, 0x037,
    0x034, 0x031, 0x02F, 0x02C, 0x029, 0x027, 0x025, 0x023, 0x021, 0x01F, 0x01D, 0x01C,
    0x01A, 0x019, 0x017, 0x016, 0x015, 0x014, 0x012, 0x011, 0x010, 0x00F, 0x00E, 0x00D,
};

// Table #3 of Pro Tracker 3.4r
pub const TABLE_REAL_34R: FrequencyTable = .{
    0xCDA, 0xC22, 0xB73, 0xACF, 0xA33, 0x9A1, 0x917, 0x894, 0x819, 0x7A4, 0x737, 0x6CF,
    0x66D, 0x611, 0x5BA, 0x567, 0x51A, 0x4D0, 0x48B, 0x44A, 0x40C, 0x3D2, 0x39B, 0x367,
    0x337, 0x308, 0x2DD, 0x2B4, 0x28D, 0x268, 0x246, 0x225, 0x206, 0x1E9, 0x1CE, 0x1B4,
    0x19B, 0x184, 0x16E, 0x15A, 0x146, 0x134, 0x123, 0x113, 0x103, 0x0F5, 0x0E7, 0x0DA,
    0x0CE, 0x0C2, 0x0B7, 0x0AD, 0x0A3, 0x09A, 0x091, 0x089, 0x082, 0x07A, 0x073, 0x06D,
    0x067, 0x061, 0x05C, 0x056, 0x052, 0x04D, 0x049, 0x045, 0x041, 0x03D, 0x03A, 0x036,
    0x033, 0x031, 0x02E, 0x02B, 0x029, 0x027, 0x024, 0x022, 0x020, 0x01F, 0x01D, 0x01B,
    0x01A, 0x018, 0x017, 0x016, 0x014, 0x013, 0x012, 0x011, 0x010, 0x00F, 0x00E, 0x00D,
};

// Table #3 of Pro Tracker 3.4x - 3.5x
pub const TABLE_REAL_34_35: FrequencyTable = .{
    0xCDA, 0xC22, 0xB73, 0xACF, 0xA33, 0x9A1, 0x917, 0x894, 0x819, 0x7A4, 0x737, 0x6CF,
    0x66D, 0x611, 0x5BA, 0x567, 0x51A, 0x4D0, 0x48B, 0x44A, 0x40C, 0x3D2, 0x39B, 0x367,
    0x337, 0x308, 0x2DD, 0x2B4, 0x28D, 0x268, 0x246, 0x225, 0x206, 0x1E9, 0x1CE, 0x1B4,
    0x19B, 0x184, 0x16E, 0x15A, 0x146, 0x134, 0x123, 0x112, 0x103, 0x0F5, 0x0E7, 0x0DA,
    0x0CE, 0x0C2, 0x0B7, 0x0AD, 0x0A3, 0x09A, 0x091, 0x089, 0x082, 0x07A, 0x073, 0x06D,
    0x067, 0x061, 0x05C, 0x056, 0x052, 0x04D, 0x049, 0x045, 0x041, 0x03D, 0x03A, 0x036,
    0x033, 0x031, 0x02E, 0x02B, 0x029, 0x027, 0x024, 0x022, 0x020, 0x01F, 0x01D, 0x01B,
    0x01A, 0x018, 0x017, 0x016, 0x014, 0x013, 0x012, 0x011, 0x010, 0x00F, 0x00E, 0x00D,
};

// ============================================================================
// Volume Tables
// ============================================================================

pub const VolumeTable = [256]u8;

// PT3.3, 3.4 volume table
pub const VOL_TABLE_33_34: VolumeTable = .{
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,
    0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,
    0,  0,  0,  0,  1,  1,  1,  1,  2,  2,  2,  2,  3,  3,  3,  3,
    0,  0,  0,  0,  1,  1,  1,  2,  2,  2,  3,  3,  3,  4,  4,  4,
    0,  0,  0,  1,  1,  1,  2,  2,  3,  3,  3,  4,  4,  4,  5,  5,
    0,  0,  0,  1,  1,  2,  2,  3,  3,  3,  4,  4,  5,  5,  6,  6,
    0,  0,  1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  6,  7,  7,
    0,  0,  1,  1,  2,  2,  3,  3,  4,  5,  5,  6,  6,  7,  7,  8,
    0,  0,  1,  1,  2,  3,  3,  4,  5,  5,  6,  6,  7,  8,  8,  9,
    0,  0,  1,  2,  2,  3,  4,  4,  5,  6,  6,  7,  8,  8,  9,  10,
    0,  0,  1,  2,  3,  3,  4,  5,  6,  6,  7,  8,  9,  9,  10, 11,
    0,  0,  1,  2,  3,  4,  4,  5,  6,  7,  8,  8,  9,  11, 11, 12,
    0,  0,  1,  2,  3,  4,  5,  6,  7,  7,  8,  9,  10, 11, 12, 13,
    0,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14,
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
};

// PT3.5+ volume table
pub const VOL_TABLE_35: VolumeTable = .{
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,
    0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,
    0,  0,  0,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  3,  3,  3,
    0,  0,  1,  1,  1,  1,  2,  2,  2,  2,  3,  3,  3,  3,  4,  4,
    0,  0,  1,  1,  1,  2,  2,  2,  3,  3,  3,  4,  4,  4,  5,  5,
    0,  0,  1,  1,  2,  2,  2,  3,  3,  4,  4,  4,  5,  5,  6,  6,
    0,  0,  1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  6,  7,  7,
    0,  1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  6,  7,  7,  8,
    0,  1,  1,  2,  2,  3,  4,  4,  5,  5,  6,  7,  7,  8,  8,  9,
    0,  1,  1,  2,  3,  3,  4,  5,  5,  6,  7,  7,  8,  9,  9,  10,
    0,  1,  1,  2,  3,  4,  4,  5,  6,  7,  7,  8,  9,  10, 10, 11,
    0,  1,  2,  2,  3,  4,  5,  6,  6,  7,  8,  9,  10, 10, 11, 12,
    0,  1,  2,  3,  3,  4,  5,  6,  7,  8,  9,  10, 10, 11, 12, 13,
    0,  1,  2,  3,  4,  5,  6,  7,  7,  8,  9,  10, 11, 12, 13, 14,
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
};
