# Debugger Rewrite Plan

Vertical slices - each step produces testable functionality.

---

## Slice 1: Empty Window

Get a window on screen with basic layout structure.

- [x] Initialize dvui/sdl backend, open window
- [x] Main render loop with vsync
- [x] Three-column layout with placeholder panels

**Test:** Window opens, shows three panes side by side.

---

## Slice 2: Hardcoded Disassembly View

Display bytes from memory as disassembly (no file loading yet).

- [x] Create CpuState with zeroed memory
- [x] Simple disassembly function (byte -> mnemonic)
- [x] Render address + byte + mnemonic in middle panel
- [x] Highlight one row as "current PC"

**Test:** Window shows list of `0000: 00 halt` lines, one highlighted.

---

## Slice 3: Load and Display ROM

Load a binary file and show its disassembly.

- [x] File menu with "Open ROM" item
- [x] Native file dialog
- [x] Load ROM bytes into memory
- [x] Disassembly view updates to show ROM contents

**Test:** Open a .bin file, see actual instructions displayed.

---

## Slice 4: Step Through Code

Execute instructions one at a time.

- [x] "Step Into" button in toolbar
- [x] Wire button to `runForCycles`
- [x] Update PC highlight after each step
- [x] Cycle counter in toolbar

**Test:** Click Step, PC moves, cycle count increments.

---

## Slice 5: Auto-Scroll and PC Tracking

Keep current instruction visible.

- [x] Track PC changes between frames
- [x] Scroll to keep PC in view (not at edge)
- [ ] Expand multi-byte instructions when PC is inside

**Test:** Step through long program, view follows automatically.

---

## Slice 6: Breakpoints

Set and hit breakpoints.

- [x] Breakpoint column in source view
- [x] Click to toggle breakpoint at address
- [x] Store breakpoints in hashmap
- [x] Visual indicator for breakpoint lines

**Test:** Click to set breakpoint, see marker appear.

---

## Slice 7: Run and Pause

Continuous execution with breakpoint stops.

- [x] "Run" button (executes many cycles per frame)
- [x] "Pause" button (stops execution)
- [x] Check breakpoints during run loop
- [x] Stop on breakpoint hit
- [x] RUNNING/HALTED status indicator

**Test:** Set breakpoint, click Run, execution stops at breakpoint.

---

## Slice 8: Registers Panel

Show CPU register values.

- [ ] Registers panel in right column (PC, FP, RX, RY)
- [ ] Read values from CpuState
- [ ] Values update after stepping

**Test:** Step through code, watch register values change.

---

## Slice 9: Stack Panel

Show stack contents.

- [ ] Stack panel below registers
- [ ] Display TOS, NOS, ROS from registers
- [ ] Display depth counter
- [ ] Show spilled values from stack memory

**Test:** Step through `push` instructions, see stack grow.

---

## Slice 10: Listing File Support

Load assembler listing for source-level view.

- [ ] Listing parser (address | bytes | source text)
- [ ] "Open Listing" menu item
- [ ] Display source text column alongside disassembly
- [ ] Map PC to source line

**Test:** Load listing, see source code with addresses and bytes.

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
