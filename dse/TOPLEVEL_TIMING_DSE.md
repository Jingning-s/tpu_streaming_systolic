# Top-Level Timing DSE: S1/S2/R1/R2/F1/F3

Historical reports below describe the original A1 E3 experiments. Current
wrappers retain explicit selector choices, but share the completion, payload
enable and output-control fixes from the architecture update. They are not
frozen copies of the September 13 RTL. Current setup uncertainty is 0.300 ns;
old reports used 0.100 ns. Use fresh run tags for new comparisons.

All experiments use A1 (`USE_CSA_ACCUM=1`) and the 16×16 array.
Each is a separately named fixed synthesis root in `src/tpu_stream_dse_tops.sv`.
The wrappers prevent accidental composition of otherwise independent changes.

| Root | Change | Baseline-relative intent | Functional contract |
|---|---|---|---|
| `tpu_stream_dse_base` | Frozen E3 baseline | Reference under identical script/constraints | Existing protocol |
| `tpu_stream_dse_s1` | `first_k_tile` token | Remove `k_base==0` first-token compare and update cone | First valid packet of each C tile initializes PE accumulation |
| `tpu_stream_dse_s2` | S1 + current-tile descriptor | Register last-K and last-packet facts before issue | Packet count, bank lifetime, K accumulation unchanged |
| `tpu_stream_dse_r1` | Always-loaded CPA staging | Remove state-enable hold mux from low/upper result staging | Drain token alone permits serializer load/output |
| `tpu_stream_dse_r2` | R1 + CSEL low CPA | Compare lower-half segmented CSEL against inferred addition | Identical 32-bit sum/carry finalization |
| `tpu_stream_dse_f1` | One-hot 8-entry R0 selector | Compare explicit local decode/AND-OR tree against binary 8:1 mux | Same R0/R1 latency and metadata alignment |
| `tpu_stream_dse_f3` | 4:1 R0 + 8:1 R1 | Move one address bit through the R0 boundary | Same R0/R1 latency and metadata alignment |

`S2` contains the `S1` token replacement because the descriptor records the
same first/last tile facts. `R2` contains `R1` because CPA mapping must be
compared after the staging hold mux is removed. F1 and F3 are alternatives,
not cumulative changes.

The batch script writes a unique checkpoint and Genus log per root. Compare
WNS/TNS, top paths, constraint violations, area, sequential/combinational
count, transition/fanout DRC and power. A candidate advances only if its
functional regression passes and the new critical path is understood.

Suggested directed regressions:

- S1/S2: K=1, 16, 17, 31, 32, 33; multiple K tiles; consecutive jobs.
- R1/R2: all M/N tails, output backpressure, tile-last/last stability.
- F1/F3: INT8/INT4 odd K; independent A/B stalls; K-bank boundary and far
  corner last token completion.
