# 16x16 Streaming TPU PPA Optimization Plan

Current implementation update (Sep 20, 2026): see
[ARCHITECTURE_UPDATE_U300.md](ARCHITECTURE_UPDATE_U300.md). Setup uncertainty
is now 0.300 ns. Historical measurements below retain their original
constraints; no new synthesis/PPA result is claimed by the RTL update.

## Scope and execution rule

This plan optimizes the 16x16 output-stationary INT8/INT4 TPU for timing,
fanout, area, and physical implementation. Each phase is isolated: modify,
lint, regress, synthesize, run STA, compare against the same constraints, and
only then decide whether to proceed. A regression or PPA regression blocks the
next phase until it is understood or reverted.

## Current architecture

- 16x16 physical output-stationary PE array.
- Runtime M/N/K tiling, with INT32 partial sums retained in each PE across K
  tiles belonging to the same C tile.
- Independent 128-bit A and B ready/valid streams.
- INT8 uses one signed operand per byte; INT4 packs two adjacent signed K
  operands per byte and issues two MACs per PE per cycle.
- Two A and two B ping-pong banks allow the next K tile to load while the
  current bank computes.
- A and B propagate east and south; the current edge skew is generated with
  `packet_index = feed_cycle - lane`.
- A single 16x16x32-bit result bank captures the array row by row and drains
  through a 32-bit ready/valid output.

## Baseline evidence

The Sep 6, 2026 Genus run used the GPDK045 slow 0.9 V, 125 C library, a
1.000 ns clock, and 0.100 ns setup uncertainty. It produced a mapped netlist,
SDC, SDF, QoR, area, and gate reports, but stopped at an unsupported
`report_timing -late` option. Therefore the final top-10 detailed timing report
does not exist: `report_timing_setup.rpt` is empty. The optimization log only
contains snapshots of the current worst path, not ten distinct final paths.
Do not fabricate the missing top-10 table; regenerate it with the corrected
report command at the next synthesis checkpoint.

| Metric | Baseline |
|---|---:|
| Setup WNS | -1.952 ns |
| Setup TNS | -18,458.727 ns |
| Violating paths | 44,392 |
| Clock period / internal setup budget | 1.000 ns / 0.900 ns |
| Cell area | 758,537.652 um^2 |
| Leaf cells | 356,866 |
| Sequential cells | 36,193 |
| Combinational cells | 320,673 |
| Mux-family cells | 7,367 |
| Buffers | 8,011 |
| Inverters | 47,445 |
| Maximum reported fanout | 36,193 (`clk`, pre-CTS) |
| Remaining max-fanout DRC cost | 14,276 |
| Runtime | 5,417 s |

The repeated worst-path shape is:

```text
feed_cycle/state register
  -> per-lane subtract/compare and bank/address selection
  -> asynchronous tile-buffer mux
  -> PE mode/multiply logic
  -> product0 register
```

Observed endpoints include `u_pe_product0_reg[11:14]` across several rows and
columns. The final observed WNS was -1.952 ns. The previous netlist also used
truncated multiply expressions; the explicit operand-width fix must be treated
as a new arithmetic baseline because it can increase multiplier area/delay.

### Dynamic-index inventory

There are ten dynamic index expressions in nine statements:

1. A compute read: `a_tile_buffer[compute_bank][lane][packet_index]`.
2. B compute read: `b_tile_buffer[compute_bank][lane][packet_index]`.
3. A loader write: `a_tile_buffer[loader_bank][lane][a_load_count]`.
4. B loader write: `b_tile_buffer[loader_bank][lane][b_load_count]`.
5. Result drain read: `result_buffer[drain_row][drain_col]`.
6. Result capture write: `result_buffer[capture_row][column]`.
7. Array capture read: `array_result[capture_row][column]`.
8. `bank_ready[loader_bank]` write.
9. `bank_ready[compute_bank]` read.
10. `bank_ready[compute_bank]` write.

The first seven are data-array mux/decoder structures. The three bank-ready
accesses select only two control bits and are not a first-order PPA problem.
Generate indices and fixed byte/nibble selects are static after elaboration.

### High-fanout inventory

- `clk`: 36,193 sequential loads before CTS.
- `reset`, array `enable`, and `clear_acc`: broadcast into all 256 PEs and
  influence propagation, product, valid, and accumulator state.
- `precision_mode`: stable per job but broadcast to the PE mode selection and
  second-lane valid logic.
- `feed_cycle`, state decode, `compute_bank`, `k_steps`, and `k_len`: drive the
  replicated edge read mux and valid logic. `feed_cycle` and state bits are
  observed critical-path startpoints.
- `loader_bank`, A/B load counters, and loader fire signals: drive wide bank
  write enables and address decoders.
- `capture_row`, `drain_row`, and `drain_col`: drive result write decoding and
  the wide drain mux.

## Arithmetic and PE audit

- `clear_acc` has priority over `enable`, so it takes effect when `enable=0`.
- Reset currently covers propagation data/valid, product data/valid, and the
  accumulator. Reset reduction is intentionally deferred to phase four.
- `enable` gates propagation and accumulation; when disabled it clears valid
  state while retaining data and accumulator.
- INT8 and both INT4 nibbles are explicitly sign-extended before multiply.
- INT4 lane 1 is qualified by the odd-K valid bit at the array edge.
- The old hop/flush count covered edge skew, 15 east/south hops, and one product
  pipeline update, but was implicit and fragile. Phase one replaces it with an
  explicit last-token completion contract.

## Phase 1: feeder and skew refactor

### RTL organization

1. Store each bank as 16 packet entries of 128 bits:
   `a_buffer[bank][k_addr]` and `b_buffer[bank][k_addr]`.
2. Keep independent A/B loader counters and done flags. Each successful stream
   handshake writes exactly one 128-bit word.
3. Replace `feed_cycle - lane` with one common binary `k_read_addr` and a
   packet issue-valid signal.
4. The destination registers of the asynchronous wide-word read are skew stage
   zero. Every lane, including lane zero, crosses this register boundary.
5. Lane `i` has exactly `i+1` registered stages: stage zero is the buffer-read
   boundary and the remaining `i` stages implement skew. Do not add a separate
   vector-output register.
6. Propagate packed 8-bit data, two valid bits, and `last_k_token` through the
   same skew stages. Precision is job-static and remains configuration state.
7. Propagate last-token metadata east/south with the operands. The far-corner
   PE reports completion only when its registered final product is committed
   to the accumulator.
8. Remove `feed_cycle`, `packet_index`, and `WAVE_CYCLES` from completion
   control. Preserve the existing per-K-tile drain behavior and external packet
   protocol in this phase.
9. Make all procedural loop variables block-local or use generate variables.
10. Fix the physical specification at ARRAY_SIZE=16 with an elaboration-time
    check because the external packet width is fixed at 128 bits.

### Latency contract

```text
issue edge:
  common-address 128-bit A/B word -> lane skew stage 0

following edges:
  lane i packet advances through i additional skew stages
  A propagates east and B propagates south through PE registers

PE arrival edge:
  matching A/B token writes the registered product

next edge:
  registered product is committed to the local accumulator
  far-corner last token completes the K tile
```

### Expected effect

- Eliminate 32 replicated `feed_cycle-lane` address calculations.
- Replace lane-dependent asynchronous reads with one shared K address feeding
  two 128-bit read boundaries.
- Split the old counter-to-multiplier path into buffer-read and multiplier
  stages without reducing packet issue throughput.
- Add approximately 1,920 packed-data skew bits plus valid/last metadata.
  Some storage replaces logic previously used by subtractors, comparators, and
  duplicated mux control.
- Reduce feed-control fanout and make physical placement align with row/column
  structure.

### Functional risks

- Off-by-one completion at the final K packet or far-corner PE.
- Data/valid/last misalignment in a skew lane.
- Losing the first packet because lane zero was not registered.
- Switching compute banks before the last token commits.
- Incorrect odd-K lane-1 validity after skew.
- Loader overwrite of the active bank during independent A/B stalls.

### Phase-1 directed tests

- K = 1, 2, 15, 16, 17, 31, 32, 33 in INT8 and INT4.
- INT4 odd-K with nonzero high nibble padding to prove it is ignored.
- One-hot impulse for every physical row and column.
- Far-corner-only nonzero result to verify final-token latency.
- Independent randomized A and B stalls at every bank boundary.
- Consecutive K banks with a forced wait for the next bank.
- M/N = 1, 15, 16, 17 boundary masks.
- Signed minima/maxima: INT8 -128/127 and INT4 -8/7.
- Long result-output stall and consecutive jobs with different modes/sizes.
- Reset in IDLE, LOAD, COMPUTE, and DRAIN.

### Phase-1 acceptance criteria

- RTL lint clean except intentional testbench event-control notices.
- Full and directed regressions pass.
- Corrected Genus flow completes and produces a nonempty top-50 setup report.
- No path remains from `feed_cycle/packet_index` because those objects no
  longer exist.
- Compare WNS/TNS, critical path decomposition, fanout DRCs, mux/FF/buffer/
  inverter counts, area, and power against the table above.
- If the worst path merely becomes `k_read_addr -> wide buffer mux -> skew0`,
  quantify it before proceeding; do not claim closure from path relocation.

## Phase 2: continuous streaming across K banks

After phase one is accepted, allow bank N+1 packet zero to issue immediately
after bank N's final packet. Insert valid bubbles if the next bank is not ready.
Only the final K tile sends the job's final wave-drain token. Compare large-K
cycles, utilization, WNS, area, and power separately from phase one.

## Phase 3: result capture and drain

For FF storage, use static generated PE-to-result mappings with row enables and
end capture at `m_len-1`. Replace the direct 256:1x32 drain mux with row staging
and an elastic output register. For SRAM-oriented storage, retain binary row
addresses, use 16 column banks, synchronously read a complete row, then
serialize. Keep single-bank correctness first and preserve a clean ownership
interface for an optional second result bank.

### Phase-3 RTL implementation

- Capture now uses generated fixed `array_result[row][column]` to
  `result_buffer[row][column]` mappings selected by `capture_oh`, and terminates
  at `capture_row == m_len-1`.
- `S_DRAIN_LOAD` performs one registered 16-word row read. A row-local shift
  serializer then supplies `m_result_data` without a combinational result-bank
  selector on the output path.
- The serializer and registered valid/last flags advance only on
  `m_result_valid && m_result_ready`; a stalled output holds the full payload.
- `result_bank_full` now gates row loading and represents actual single-bank
  ownership. Dual-bank overlap remains deferred.
- This correctness-first implementation adds one load cycle per valid row.
  Regression and a fresh A0/A1 Genus/STA comparison are required before this
  phase is accepted.

## Phase 4: high-fanout controls

### Scheduler split implementation

- A0 is the primary PPA checkpoint; A1 remains an elaboration-time comparison.
- Registered M/N/K remaining counters replace repeated base/dimension
  subtraction and the add/compare form of last-tile detection.
- `S_PREP_LEN` clamps the registered remaining dimensions; `S_PREP_COUNT`
  derives the current K packet count and starts the initial loader.
- `S_PRELOAD_LEN` and `S_PRELOAD_COUNT` prepare the following K tile before
  current issue begins, preserving compute/load overlap without a nested
  `tile_len` plus `packet_count` path.
- Scheduler data registers have no more than eight architectural source
  alternatives in RTL. The post-synthesis mux tree and fanout report remain
  the acceptance authority because optimization may restructure this logic.

- Replace feed-cycle control with issue token/address flow (phase one).
- Evaluate removing global PE enable by continuously propagating valid bubbles
  and updating accumulators only on paired-valid products.
- Replace clear broadcast with first-product/acc-init tokens if verified.
- Decode/latch precision per row or quadrant, or decode operands at the array
  entrance, without changing lane timing.
- Remove reset from data/accumulator registers only after valid/control reset
  proves stale state cannot escape.
- Leave clock-tree construction to P&R; do not build an arbitrary RTL clock or
  reset tree.

### Phase-4 RTL implementation (Sep 7, 2026)

- A0 remains the primary implementation and A1 remains an elaboration-time
  comparison; PE arithmetic is unchanged in this checkpoint.
- Each A/B 16-entry packed bank is split into two explicit 8-entry sub-banks.
  Four fixed bank/half reads feed a 4-way selector, so no RTL memory read has
  more than eight dynamic entries. Independent A/B loader counters and write
  enables are retained.
- A common 128-bit A/B read-boundary register now replaces the former per-lane
  skew stage zero. Lane `i` contains exactly `i` additional delay registers,
  preserving the existing issue-to-PE latency.
- Boundary valid/first/last tokens are replicated per spatial lane. Valid is
  locally masked by M/N; last remains present on inactive lanes because the
  completion contract observes the far-corner PE.
- The result buffer is split into two 8-row halves with 16 fixed column banks.
  `S_DRAIN_LOAD` produces a registered load pulse and `S_DRAIN_ARM` exposes the
  newly loaded serializer row one cycle later. Row load is therefore an 8:1
  half read followed by a 2-way select rather than one 16-row expression.
- `result_row_shift` is updated in a reset-free payload block. It shifts on
  every successful output handshake, including a row/tile final beat whose
  post-handshake value is irrelevant; this removes dimension/end-of-row
  comparisons from its wide D-input control cone.
- Reset was removed from PE arithmetic/data registers, accumulator state,
  systolic operand data, row precision, tile-buffer data, and result payload.
  Valid/last/FSM/ownership controls remain reset so stale data cannot escape.
- This change adds one internal result-row arm cycle. The per-lane boundary
  tokens and two 128-bit data registers replace the same storage formerly held
  in the thirty-two lane stage-zero blocks, so feeder latency and boundary FF
  count are preserved. Packet throughput and the external result protocol do
  not change. Fresh A0/A1 Genus and STA results are required before phase four
  is accepted.

### Phase-4 R0/R1 read-pipeline follow-up (Sep 7, 2026)

- Split the former `8:1 + bank/half select -> packet register` path into R0
  four-candidate registers followed by a registered R1 4:1 selector.
- Issue selector, valid, M/N lane masks, first, last, and odd-K lane validity
  now cross the same R0/R1 boundaries as packet data.
- Renamed buffer availability to `bank_readable`: it is cleared by the final
  read entering R0, while K-tile scheduling advances only on the independent
  far-corner `bank_compute_done_event` token.
- No scheduler state uses a fixed R0/R1 latency adjustment. Functional
  regression and a fresh A0 Genus/STA run remain required.

## PE INT4 two-row integration (Sep 8, 2026)

- Replaced both radix-4 INT4 Booth datapaths with exact-width signed 4x4
  Baugh-Wooley matrices.  Correction bits are folded into otherwise-zero
  positions of the first partial-product row.
- M1 now reduces each INT4 lane's four rows through a balanced paired 4:2 and
  registers exactly `sum` and shifted `carry`; no INT4 CPA remains in M1.
- The existing M2 boundary now performs the two independent 8-bit product
  CPAs.  No pipeline stage or PE-hop latency was added.
- D no longer adds the two INT4 products.  It independently valid-masks and
  sign-extends them into `delta_sum_reg` and `delta_carry_reg`, allowing the
  A1 fused accumulator compressor to consume both lanes directly.  A0 remains
  functionally supported by its existing scalar `delta_sum + delta_carry`.
- INT8 E3 arithmetic, token timing, external result finalization, and R0/R1
  result storage/readout are unchanged.
- The folded Baugh-Wooley equations passed an exhaustive software-model check
  over all 256 signed 4x4 operand pairs.  Licensed RTL regression and a fresh
  A1 Genus/STA run remain pending.

## Result/write-control/PE follow-up (Sep 8, 2026)

Implemented as one explicitly requested four-item experiment, pending licensed
regression and Genus/STA:

- Replaced the inferred result upper-half expression with an explicit 16-bit
  4x4 segmented carry-select CPA. The carry from the registered low-half CPA
  is the upper adder's `cin`; it is no longer represented as a third operand.
- Added an always-loaded finalized-row boundary and a separate
  `S_DRAIN_COMMIT` state. The result CPA now terminates at
  `result_row_final_stage`; the serializer load/shift selection consumes only
  registered data. This adds one internal cycle per drained row and 512 payload
  FFs, without changing the external ready/valid protocol.
- Localized result capture with one fixed PE-to-word instance per result entry.
  Each 32-bit sum and carry word has its own registered enable, and
  `S_CAPTURE_FLUSH` accounts for that one-cycle command latency before result
  bank ownership changes.
- Localized each A/B tile-buffer write into a fixed physical 128-bit word.
  Four preserved registered enables per word independently drive fixed 32-bit
  quadrants. A common data-command stage remains shared, while bank readability
  is asserted only on the delayed physical-write commit event. A and B retain
  independent counters, stalls, and completion state.
- Changed the PE D stage to mode-exclusive masked merges. INT8's two CSA rows
  pass directly; INT4 product 0 and product 1 become the two accumulator rows.
  This removes the former wide precision/valid mux shape without adding a PE
  pipeline stage. Assertions check INT8/INT4 mode exclusion and INT4 high-lane
  validity.

The acceptance decision must compare the fresh report with checkpoint
`e3_i4_bw_twrow_a1` (WNS -162.6 ps, TNS -2.813 us, area 1,101,985.475 um^2).
In particular, verify that the old result upper-CPA-to-shift path and the
128-load tile-word enables disappear rather than merely move, and quantify the
area/power cost of the final-row and local-enable registers.

## Result quarter-read and local serializer follow-up (Sep 8, 2026)

- Freeze the accepted PE E3/mux-light datapath and the A/B tile-buffer loader;
  this patch changes only result storage/readout and its local control.
- Reorganize the single result bank as four fixed 4-row quarters. Each sum and
  carry column now has four parallel 4:1 quarter reads terminating at R0,
  followed by a registered 4:1 quarter selection at R1. No result read selector
  exceeds 4:1 in RTL.
- Retain the existing DRAIN_LOAD/ARM latency contract. The narrower R0 muxes do
  not require another state; one additional internal row-drain cycle remains
  architecturally permissible if post-synthesis timing still requires it.
- Replace the monolithic 16-word shift array with four 4-word serializer
  groups. Each group registers a local load command one phase early in
  `S_DRAIN_FINALIZE_HI`, then loads on `S_DRAIN_COMMIT`; output shifting still
  occurs only on the real ready/valid handshake.
- External result ordering, valid/backpressure behavior, tile-last/last flags,
  and the number of output handshakes are unchanged. The expected cost is
  roughly 2048 additional R0 candidate bits; regression and a new A1
  `e3_result_q4_serializer_a1` Genus/STA checkpoint are required.

## Phase 5: loader/capture address encoding

Decide binary versus one-hot using post-phase-3 implementation data. Wide-word
buffer writes already remove replicated byte-level write decoders. Preserve
independent A and B pointers. Prefer binary addresses if SRAM inference is a
goal; compare both encodings if the buffers remain FF arrays.

## Required assertions

- A compute bank is readable before every issued read.
- A loader never writes a bank while its read issuer is active; reuse after
  read-done is legal even if the old packet is still computing in the array.
- All buffer pointers and addresses remain in range.
- Any one-hot control satisfies `$onehot0`.
- INT4 lane 1 is invalid on an odd final K element.
- Output data and both last flags are stable while valid is stalled.
- Accepted A/B packet counts and emitted result counts match each job.
- No packet is lost or duplicated at a K-bank boundary.

## Zero-dimension and reset contract

The current RTL accepts a zero-dimensional configuration as a no-op and
returns immediately to ready without producing an explicit completion event.
This behavior must be documented or replaced by an error/done indication in a
separate interface patch. During reset, cfg/input/output ready-valid semantics
must be asserted so no apparent handshake can be silently discarded.

## Phase-1 implementation checkpoint (Sep 6, 2026)

Implemented, pending licensed simulation and synthesis:

- Replaced the lane-major byte arrays with two banks of 16x128-bit packed A
  words and two banks of 16x128-bit packed B words.
- Preserved fully independent A/B handshake counters and completion flags.
- Replaced all feeder `feed_cycle`, `packet_index`, and `WAVE_CYCLES` logic
  with one 4-bit `k_read_addr`, issue valid, and an explicit last-K token.
- Added one registered buffer-read boundary for every lane. Lane `i` has
  exactly `i+1` `operand_skew_lane` stages; packed data, both valid bits, and
  last metadata share every stage.
- Propagated the last token through each PE and changed tile completion to the
  far-corner token at the edge where its final registered product is committed.
- Kept the old per-K-tile wait/drain policy. Cross-bank continuous issue is not
  included and remains phase two.
- Added an ARRAY_SIZE=16 elaboration check and phase-one address, ownership,
  bank-readiness, and odd-K assertions.
- Gated interface ready/valid with reset as a separate safety fix, preventing
  an apparent handshake on an edge whose synchronous-reset branch discards it.
- Expanded the testbench across all requested K boundary values, M/N boundary
  values, both precisions, odd-K nonzero padding, signed extrema, independent
  deterministic pseudo-random input stalls, long output stalls, K-bank
  boundaries, consecutive jobs, full-array diagonal/far-corner skew, and reset
  in IDLE/LOAD/COMPUTE/DRAIN. Added packet/result-count and elastic-output
  assertions.
- Updated the Genus timing report to emit 50 full setup paths with split
  cell/net delay, fanout, load/capacitance, transition, and arrival fields.

Static `vlogan` parsing/lint passes. The only diagnostics are the testbench's
intentional event-control/null-statement notices. Full simulation and Genus
are intentionally left for the user because license execution was explicitly
excluded. Phase two must not start until those results are reviewed against
the baseline above.

## PE Booth/A0/A1 experiment (Sep 6, 2026)

- Replaced magnitude-based four-slice multiplication with a local M0, radix-4
  Booth M1, final-product M2, and registered D pipeline.
- M2 produces one signed 16-bit INT8 product and two independent signed 8-bit
  INT4 products. D masks odd-K lane 1 and forms one signed 16-bit delta.
- Propagated precision east with the A token, removing global mode selection
  from the multiplier input cone.
- Added `USE_CSA_ACCUM`: 0 selects the A0 conventional CPA recurrence; 1
  selects A1 carry-save recurrence and a K-tile-boundary final CPA.
- In both implementations, the first valid MAC initializes local state. No
  wide accumulator clear or accumulator-data reset was reintroduced.
- Delayed `tile_done` through the selected accumulator completion point so the
  controller cannot capture before the last delta or A1 final CPA commits.
- Genus uses `TPU_ACCUM_MODE=0/1` and writes the two variants into separate
  `pe_booth_a0` and `pe_booth_a1` checkpoint directories.
