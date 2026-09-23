# PE arithmetic DSE

The production checkpoint is frozen at
`checkpoints/rtl_phase4_r0r1_a0`.  Files in `dse/` are disposable experiments;
none are used by the full TPU until a winner is explicitly ported back.

## Isolated sweeps

All experiments use the same GPDK045 slow 0.9 V, 125 C library, 1.000 ns
clock, 100 ps setup uncertainty, I/O model, effort levels, transition limit,
fanout limit, and capacitance limit.

1. INT4 M1/M2: exact `$signed(4-bit) * $signed(4-bit)`, balanced 4x4
   Baugh-Wooley, and radix-4 Booth.  Every implementation presents exactly
   `product_sum` and `product_carry_shifted` to M2.
2. INT8 M1: behavioral signed 8x8 multiply and radix-4 Booth with all four
   partial products reduced to exactly two registered M1 rows.  No `tail` or
   correction row may cross into M2.
3. INT8 M2 16-bit CPA: inferred, four 4-bit carry-select segments,
   Brent-Kung, and Han-Carlson-style sparse prefix.
4. 32-bit accumulator CPA: inferred, four 8-bit carry-select segments,
   Brent-Kung, and Han-Carlson-style sparse prefix.  `first` selects zero at
   the CPA A input; valid is a register enable, so no control mux follows the
carry-propagate result.

The first isolated sweep completed with the following provisional winners:
INT4 radix-4 Booth, INT8 strict two-row Booth, and the 4x4-segment 16-bit
carry-select CPA.  Every conventional accumulator CPA missed timing, and its
worst path was polluted by `first` entering the carry chain.  Accumulator
implementation 4 therefore uses lean fused-CSA state.  Ordinary tokens update
two state rows through one 3:2 compressor; a final inferred CPA executes only
after `last` and adds one tile-completion cycle.

Run primitive equivalence before interpreting PPA.  The test is exhaustive for
both signed multiplier widths and randomized for all CPA implementations.

```sh
cd dse/tb
vcs -sverilog ../rtl/arith_primitives.sv tb_arith_primitives.sv \
    -top tb_arith_primitives -o simv
./simv
```

After choosing parameters, run the integrated token/accumulation test as well:

```sh
vcs -sverilog ../rtl/arith_primitives.sv ../rtl/arith_dse_tops.sv \
    tb_pe_candidate.sv -top tb_pe_candidate -o simv_pe
./simv_pe
```

Run the fused-CSA directed test:

```sh
cd dse/tb
vcs -sverilog ../rtl/arith_primitives.sv ../rtl/arith_dse_tops.sv \
    tb_fused_accumulator.sv -top tb_fused_accumulator -o simv_fused
./simv_fused
```

Run all isolated Genus experiments sequentially:

```sh
nohup dse/scripts/run_isolated_dse.sh \
    > dse/results/isolated_console.log 2>&1 &
```

## Selection rule

An implementation must first pass bit-exact equivalence.  Rank each stage by
setup slack, then area, transition/fanout, and vectorless power.  Do not select
an arithmetic block merely because its isolated WNS is good if a neighboring
stage becomes worse in the integrated PE.

After selecting one winner in each category, synthesize both a single PE and
four replicated PEs.  Example values below mean inferred INT4, two-row Booth
INT8, Han-Carlson 16-bit CPA, and carry-select accumulator:

```sh
dse/scripts/run_pe_candidate.sh 0 1 3 1 single
dse/scripts/run_pe_candidate.sh 0 1 3 1 array2x2
```

For the current provisional winners, run the isolated fused accumulator,
single PE, and 2x2 PE experiments as one sequential batch:

```sh
nohup dse/scripts/run_fused_csa_dse.sh \
    > dse/results/fused_csa_console.log 2>&1 &
```

The accumulator winner must retain at least +50 ps setup slack in the
integrated single-PE and 2x2 experiments.  If it does not, stop CPA tuning and
move to the lean fused-CSA accumulator: keep sum/carry state, fold delta and
first-token initialization into the compressor inputs, and perform one final
CPA only at the output-tile boundary.

The first fused experiment removed the recurrence CPA, but a per-PE final CPA
and result register doubled isolated accumulator area and became the new
critical path.  The next experiment keeps only `sum_state` and `carry_state`
in each PE.  Because production capture already advances by one 16-element PE
row per cycle, sixteen shared column finalizers replace 256 per-PE final CPAs.
Each finalizer uses registered low-16 and high-16 additions, preserving a
one-row-per-cycle acceptance rate.

This experiment also splits the INT8 Booth compression into M1a (recode plus
first compression) and M1b (last 3:2 compression).  INT4 rows and all token
metadata receive the matching delay.

The follow-up mux/control experiment keeps that arithmetic unchanged for an
A/B comparison.  `precision_mode` is decoded once at the array boundary into
mutually-exclusive `int8_token` and `int4_token[1:0]`; mode is no longer a PE
pipeline field.  At D, the old mode mux followed by an INT8-valid mux is
replaced by one one-hot merge of the two already registered result candidates.
This is the intended integration contract: the feeder/skew boundary produces
local work tokens alongside operands, rather than broadcasting precision into
all 256 PE arithmetic cones.

```sh
cd dse/tb
vcs -sverilog ../rtl/arith_primitives.sv ../rtl/arith_dse_tops.sv \
    ../rtl/arith_state_dse.sv tb_external_csa_state.sv \
    -top tb_external_csa_state -o simv_external_csa
./simv_external_csa

cd ../..
nohup dse/scripts/run_external_csa_dse.sh \
    > dse/results/external_csa_console.log 2>&1 &
```

To synthesize only the new single-PE and 2x2 mux-light cases, without rerunning
the four established external-CSA baselines:

```sh
DSE_MUXLIGHT_ONLY=1 nohup dse/scripts/run_external_csa_dse.sh \
    > dse/results/muxlight_console.log 2>&1 &
```

Only after the single-PE and 2x2 results pass timing and PPA review should all
four winners be ported together into `src/pe.sv`, followed by one full A0 array
regression and synthesis.  The full-array comparison baseline is WNS -231.6
ps, TNS -4,844,685.9 ps, area 897,619.972 um2, and vectorless power 215.700 mW.

## B-candidate Replica to Mesh screen

The former shared-input 2x2 harness allowed Genus to merge equivalent M0 and
token registers across PEs.  The replacement flow first synthesizes four
independent Replica nodes, each with unique A/B and valid ports:

- B0: current asymmetric radix-4 Booth compression.
- B1: balanced radix-4 Booth pair compression.
- B2: radix-2 signed partial products and balanced CSA tree; no Booth recoder.
- B3: behavioral signed 8x8 multiply baseline.

All candidates use the same M0, M1 and M2 register contract.  Candidates are
ranked by WNS, then TNS, then area.  Only the best two are elaborated in the
2x2 Mesh harness.  In Mesh, A and A-valid move only west-to-east; B and B-valid
move only north-to-south.  Each node consumes the same M0 registers that drive
its east/south neighbor and pairs the independent A/B valid bits locally.

Before synthesis, exhaustively verify all signed 8x8 operand combinations:

```sh
cd dse/tb
vcs -sverilog ../rtl/arith_primitives.sv ../rtl/b_mesh_dse.sv \
    tb_b_mesh_dse.sv -top tb_b_mesh_dse -o simv_b_mesh
./simv_b_mesh

vcs -sverilog ../rtl/arith_primitives.sv ../rtl/b_mesh_dse.sv \
    tb_b_mesh_dse.sv -top tb_b_mesh_connectivity -o simv_b_mesh_connectivity
./simv_b_mesh_connectivity
```

Then run the staged Replica-to-Mesh screen:

```sh
nohup dse/scripts/run_b_mesh_dse.sh \
    > dse/results/b_mesh_console.log 2>&1 &
```

### B2 refinement

After B2 wins the first Mesh screen at exactly 0 ps slack, isolate the two
remaining mapping choices as a 2x2 factorial experiment:

- C0: original conditional partial products + cascaded CSA reduction.
- C1: explicit AND-mask partial products + cascaded CSA reduction.
- C2: original conditional partial products + direct 4-to-2 equations.
- C3: explicit AND-mask partial products + direct 4-to-2 equations.

All four variants are exhaustively equivalent and retain identical M0/M1/M2
latency.  Run all four in Replica and only the best two in Mesh:

```sh
cd dse/tb
vcs -sverilog ../rtl/arith_primitives.sv ../rtl/b_mesh_dse.sv \
    tb_b_mesh_dse.sv -top tb_b2_refine -o simv_b2_refine
./simv_b2_refine

cd ../..
nohup dse/scripts/run_b2_refine_dse.sh \
    > dse/results/b2_refine_console.log 2>&1 &
```

The mapping-only refinement leaves C0 as the winner.  The next no-new-stage
screen compares its 18-bit implementation against exact-width structures:

- E0: frozen 18-bit B2/C0 baseline.
- E1: the same signed radix-2 decomposition entirely modulo 2^16.
- E2: exact 8x8 Baugh-Wooley matrix plus balanced Wallace-style CSA schedule.
- E3: the same matrix with two balanced direct 4-to-2 M1 groups.

E1/E2/E3 keep bits 15:0 as carry-save state and force bits 17:16 to zero.
After the final CPA, bit 15 is the signed-product extension bit.  No candidate
adds a register or changes the M0/M1/M2 latency.

```sh
cd dse/tb
vcs -sverilog ../rtl/arith_primitives.sv ../rtl/b_mesh_dse.sv \
    tb_b_mesh_dse.sv -top tb_b2_exact -o simv_b2_exact
./simv_b2_exact

cd ../..
nohup dse/scripts/run_b2_exact_dse.sh \
    > dse/results/b2_exact_console.log 2>&1 &
```
