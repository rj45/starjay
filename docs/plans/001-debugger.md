# Debugger Rewrite Plan

Vertical slices - each step produces testable functionality.

---

## Slice 1: Empty Window

Get a window on screen with basic layout structure.

- [ ] Initialize dvui/Raylib backend, open window
- [ ] Main render loop with vsync
- [ ] Two-column layout with placeholder panels
- [ ] Basic color constants (just enough for backgrounds)

**Test:** Window opens, shows two colored rectangles side by side.

---

## Slice 2: Hardcoded Disassembly View

Display bytes from memory as disassembly (no file loading yet).

- [ ] Create CpuState with zeroed memory
- [ ] Simple disassembly function (byte -> mnemonic)
- [ ] Render address + byte + mnemonic in left panel
- [ ] Highlight one row as "current PC"

**Test:** Window shows list of `0000: 00 nop` lines, one highlighted.

---

## Slice 3: Load and Display ROM

Load a binary file and show its disassembly.

- [ ] File menu with "Open ROM" item
- [ ] Native file dialog
- [ ] Load ROM bytes into memory
- [ ] Disassembly view updates to show ROM contents

**Test:** Open a .bin file, see actual instructions displayed.

---

## Slice 4: Step Through Code

Execute instructions one at a time.

- [ ] "Step Into" button in toolbar
- [ ] Wire button to `microcode.step()`
- [ ] Update PC highlight after each step
- [ ] Cycle counter in toolbar

**Test:** Click Step, PC moves, cycle count increments.

---

## Slice 5: Registers Panel

Show CPU register values.

- [ ] Registers panel in right column (PC, RA, AR, FP)
- [ ] Read values from CpuState
- [ ] Values update after stepping

**Test:** Step through code, watch register values change.

---

## Slice 6: Stack Panel

Show stack contents.

- [ ] Stack panel below registers
- [ ] Display TOS, NOS, ROS from registers
- [ ] Display depth counter
- [ ] Show spilled values from stack memory

**Test:** Step through `push` instructions, see stack grow.

---

## Slice 7: Listing File Support

Load assembler listing for source-level view.

- [ ] Listing parser (address | bytes | source text)
- [ ] "Open Listing" menu item
- [ ] Display source text column alongside disassembly
- [ ] Map PC to source line

**Test:** Load listing, see source code with addresses and bytes.

---

## Slice 8: Auto-Scroll and PC Tracking

Keep current instruction visible.

- [ ] Track PC changes between frames
- [ ] Scroll to keep PC in view (not at edge)
- [ ] Expand multi-byte instructions when PC is inside

**Test:** Step through long program, view follows automatically.

---

## Slice 9: Breakpoints

Set and hit breakpoints.

- [ ] Breakpoint column in source view
- [ ] Click to toggle breakpoint at address
- [ ] Store breakpoints in hashmap
- [ ] Visual indicator for breakpoint lines

**Test:** Click to set breakpoint, see marker appear.

---

## Slice 10: Run and Pause

Continuous execution with breakpoint stops.

- [ ] "Run" button (executes many cycles per frame)
- [ ] "Pause" button (stops execution)
- [ ] Check breakpoints during run loop
- [ ] Stop on breakpoint hit
- [ ] RUNNING/HALTED status indicator

**Test:** Set breakpoint, click Run, execution stops at breakpoint.

---

## Slice 11: Step Over

Step over function calls.

- [ ] Detect call instructions
- [ ] Track call depth
- [ ] Run until depth returns to original
- [ ] "Step Over" button

**Test:** Step over a `call`, execution stops after `ret`.

---

## Slice 12: Change Highlighting

Show what changed after each step.

- [ ] Track last micro-op executed
- [ ] Highlight changed registers in registers panel
- [ ] Highlight changed stack entries in stack panel

**Test:** Step an `add`, see TOS highlighted as changed.

---

## Slice 13: Polish

Final touches.

- [ ] Reset command (Debug menu)
- [ ] Keyboard shortcuts (F5, F10, F11)
- [ ] Zoom controls (View menu)
- [ ] Light/dark theme support
- [ ] Status flags display (KM, IE, TH)
- [ ] Exception registers (EPC, EVEC)

**Test:** Full debugger workflow with keyboard navigation.

---

## Notes

- dvui uses `@src()` for stable widget IDs
- Grid widget: last column width 0 = expand to fill
- Scroll state persists via `dvui.dataGetPtrDefault`
- MicroOp fields indicate what changed for highlighting
- Call depth for step-over uses `cpu.reg.depth`
