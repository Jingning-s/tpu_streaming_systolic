# Microarchitecture

## Compute organization

The physical array is fixed at 16x16. The scheduler traverses output tiles in
`mt`, `nt`, `kt` order. The first valid MAC token of a new `(mt, nt)` tile
initializes each PE accumulator; no global accumulator-clear network is used.
The accumulators then retain partial sums across every K tile before capture.

The scheduler maintains registered `m_remaining`, `n_remaining`, and
`k_remaining` counters instead of repeatedly computing `dimension-base`.
Initial and new-C-tile setup runs through a clamp stage followed by a packet
count stage. Before a non-final K tile starts issuing, two short preload stages
derive the next K length and packet count; the next bank then loads while the
current tile computes. No state contains the previous
`packet_count(tile_len(cfg, base+len))` combinational chain.

For boundary tiles, `m_len`, `n_len`, and `k_len` are the registered remaining
dimension clamped to 16. Per-row, per-column, and per-K-lane valid bits prevent
padded operands from changing an accumulator.

## Packed tile buffers

A and B each contain two 256-byte ping-pong banks. A bank stores sixteen packed
128-bit K packets, physically expressed as two eight-entry sub-banks. The read
pipeline is structurally `buffer FF -> bank-local 8:1 mux -> R0 four-candidate
registers -> 4:1 bank/half mux -> R1 packet register`. Thus the address mux and
bank/half mux cannot collapse into one buffer-to-array timing path. During INT8
computation each byte is one operand; during INT4 computation its low and high
nibbles are two adjacent K operands.

The issued-packet selector, two-bit operand valid, M/N lane masks, first token,
and last token cross R0 and R1 with the corresponding data. R1 then splits the
packet into lanes; the edge aligners delay A row `i` and B column `j` by `i` and
`j` additional cycles. A packet propagates east and B propagates south,
aligning matching K packets at PE `(i,j)`.

Bank read ownership ends when the final packet is captured by R0. Non-final
K blocks advance at that event, so multiple blocks of the same C tile can be
in flight. The next bank still waits for its independent A/B write completion
and descriptor setup; this is not a promise of gap-free issue. Only the final
packet of the final K block carries the array last marker. Array compute
ownership ends when that marker reaches the far-corner PE. Scheduler transitions use these events rather than adding
fixed read/skew/PE latency constants, so inserting R0/R1 does not require an
FSM `+1/+2` compensation.

## SIMD PE

In INT8 mode the PE issues one signed 8x8 product. In INT4 mode it issues two
independent signed 4x4 products. M1 implements the selected E3 exact
Baugh-Wooley matrix and two paired direct 4:2 compressors. M2 reduces its four
registered rows to a strict two-row product without a CPA. D converts both
runtime precision modes into two accumulator rows. Precision propagates east
with A rather than driving every PE multiplier from one global mode net.

The synthesis/test default `USE_CSA_ACCUM=1` is the production candidate: a
fused 4:2 recurrence retains sum/carry state in each PE and moves the final CPA
outside the array. M2 products are formatted directly into the accumulator;
the former D payload/token register was removed. `USE_CSA_ACCUM=0` remains a
conventional CPA reference. Both modes use first-token initialization as their
architectural clear and retain accumulation state across K tiles.

At 1 GHz, peak array issue rates are 256 INT8 MAC/cycle and 512 INT4 MAC/cycle.
These are peak compute rates; sustained system throughput also depends on tile
reuse, output bandwidth, and physical timing closure.

## Results

One 16x16 result bank holds separate 32-bit sum and carry words (2 KiB
in total), arranged as four four-row quarters and sixteen fixed columns.
Capture uses static PE-to-word mappings and delayed local write enables;
`S_CAPTURE_FLUSH` commits the final row before ownership changes.

Each quarter has a 4:1 read captured in R0 during `S_DRAIN_LOAD`. A registered
quarter selector drives a 4:1 R1 read in `S_DRAIN_ARM`. Both stages hold data
outside their read commands. Sixteen finalizers consume the stable selected
row using a registered low 16-bit addition followed by an upper 16-bit
parallel-prefix addition:

The first row follows `LOAD -> ARM -> FINALIZE_LO -> FINALIZE_HI -> COMMIT -> DRAIN`.
At COMMIT the serializer takes the finalized current row and a four-phase
prefetch engine starts the next row. The existing R0/R1/low/final registers
are reused; only row, phase and ready control registers are added. The ready
row stays stable until consumed. A row boundary enters COMMIT immediately if
ready, otherwise WAIT_ROW holds output invalid until prefetch completes.
COMMIT still costs one cycle per row. Backpressure never reloads or overwrites
the active serializer; short rows can expose unhidden prefetch latency.

The four-byte CPA experiment was removed from the default after comparison
with the Coral NPU matrix datapath showed that its extra serial stages did not
increase row throughput. Serializer local load commands are registered in
FINALIZE_HI for the first row, or on prefetch consumption for later rows,
and consume the completed row in COMMIT. The four serializer groups
advance only on a real, reset-qualified output handshake.

The controller prepares last-row/last-column indices and last-M/last-N facts
before computation. A per-row last flag is captured in LOAD. Output last flags
use a precomputed penultimate-column index rather than an increment/compare
chain. After the final result handshake, `S_ADVANCE_TILE` updates dimensions
and ownership in a separate cycle (including one cycle before returning ready
on the final tile).

Capture and drain ownership are separated in the controller so a second result
bank can later be added. A dual-bank implementation can overlap capture of the
next C tile with draining the previous tile, although the 32-bit result stream
can still become the sustained-throughput bottleneck.

## Completion and payload enables

A final-C-tile last token traverses masked edge lanes and the full PE arithmetic-token
pipeline. Completion at PE[15][15] depends on that token, independently of
MAC valid; accumulator updates still require valid. This permits M/N tails to
finish without exposing inactive accumulator contents.

Feeder R0/R1, skew payload, PE forwarding, M0 and mode-specific M1/M2 payload
hold on bubbles or unused precision branches. Valid/first/last
metadata continue to move each cycle. These are synchronous data enables,
not hand-built gated clocks. ICG inference, CTS coverage and workload-based
power savings must be measured separately. Unselected M1 combinational logic
can still respond to shared M0 operand changes.

Setup uncertainty is 0.100 ns at a 1.000 ns period; the 0.900 ns remainder
also has to cover launch/capture cell timing and physical effects. Verilator
checks functional behavior, not timing closure or power.
