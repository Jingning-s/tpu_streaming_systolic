# TPU reference model

tpu_reference.py is the cycle-free architectural model for the RTL in
src/tpu_stream_top.sv. It is the numerical oracle for future CPU/NEMU and
SystemC models.

Run:

    python3 model/tpu_reference.py --self-test

Covered: 16x16 tiling, signed INT8, packed signed INT4, odd-K boundaries, and
the RTL tile-major output order. Cycle latency, ready/valid stalls, physical
placement, and the CPU command interface are intentionally left to later layers.

