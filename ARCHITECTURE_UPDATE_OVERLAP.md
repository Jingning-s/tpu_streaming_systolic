# K 分块重叠发射与结果行预取（u100）

本轮实现整体优化计划的前两项：减少 K 分块等待、隐藏结果行准备延迟。
setup uncertainty 仍为 0.100 ns。现有 128-bit A/B 输入、32-bit 结果接口保持兼容。
没有增加 PE 流水级，没有增加结果数据 bank；行预取复用原 R0/R1/low/final 寄存器，
新增 4-bit 行号、3-bit phase、1-bit ready 控制状态。

## K 数据流

原控制器在每个 K 分块末尾等待最远 PE 返回 done。现在非末尾 K 块以最后一个包进入
R0 为切换依据，释放输入 bank 并开始等待/发射下一 bank。多个同一 C tile 的 K 块
可以同时在阵列中传播。first 仍只属于第一 K 块；只有整个 C tile 最后 K 块的最后
一个包携带 last，捕获只等待这一个最终退休事件。因此不需要维护每个中间块的完成计数。

下一块必须经过 bank_readable 和描述符准备；输入不足仍会停顿，当前不是零气泡发射。
不同 C tile 仍串行执行，不会在上一 tile 的 accumulator 捕获前覆盖它。

## 结果数据流

首行保持 LOAD → ARM → FINALIZE_LO → FINALIZE_HI → COMMIT。
COMMIT 把当前行交给 serializer，同时为下一行发起 R0 → R1 → LO → HI 四相预取。
结果完成后 ready 保持到消费。serializer 只在行边界消费 ready 行，消费后才启动再下一行。

长行可隐藏后台准备，行与行之间保留一拍 COMMIT；短行尚未准备完时进入 S_WAIT_ROW。
读取地址与 drain 行号分离，row_is_last 在 COMMIT 更新。
输出背压期间 serializer 保持输出，预取结果也不会被覆盖。

每列本地 payload 命令仍保留。serializer 的 prepare_load 现在由首行 finalize 或
消费预取产生，终止于各组 load_pending；预取 finalize 本身不会重新装载正在输出的行。

## 验证与性能

Verilator 5.032，--timing --assert。A0 和 A1 都通过：

- 原 28 个 GEMM + 6 个 K=129/255/256 长任务，共 34 个；
- 原 9 个复位场景 + WAIT_ROW + 四个预取 phase + ready 被背压阻塞，共 15 个；
- 44 组性能测试（11 种形状 × INT8/INT4 × 理想/背压）；
- 68 组压力测试：N=1..16，跨三行，INT8/INT4、理想/背压，以及 A/B 独立长空隙供数；
- 逐元素结果、packet 数、last/tile_last、背压稳定性和 bank/prefetch ownership 断言。

两种累加器全部 44 组性能周期一致；原有 32 组可比用例没有周期退步。
详见 `tb/reports/arch_kstream_rowprefetch_u100/` 与 `bench/results_overlap_a*.csv`。

| 任务（理想流量） | INT8 原→新 | 加速 | INT4 原→新 | 加速 |
|---|---:|---:|---:|---:|
| 16×16×16 | 426→366 | 1.164× | 410→350 | 1.171× |
| 16×16×64 | 594→429 | 1.385× | 554→389 | 1.424× |
| 64×64×64 | 9519→6879 | 1.384× | 8879→6239 | 1.423× |
| 17×17×33 | 1180→836 | 1.411× | 1084→740 | 1.465× |
| 1×64×64 | 1059→639 | 1.657× | 899→479 | 1.877× |
| 64×1×64 | 1419→999 | 1.420× | 1259→839 | 1.501× |

按假设 1 GHz，64³ 分别约 76.22/84.03 GOPS。周期改善不是时序闭合或功耗下降证明。
新组合逻辑和控制扇出需要新综合；本轮没有运行 Genus。固定 32-bit 输出仍是下一阶段
主要瓶颈。输出宽化、结果双 bank、硬件 epilogue/算子扩展尚未实现，应独立评估其 PPA。

## 重现

从项目根目录：

```sh
make -C tb verilator VERILATOR=verilator VERILATOR_DIR=/tmp/sysa-overlap-a1
python3 bench/run_bench.py --binary /tmp/sysa-overlap-a1/Vtb_tpu_stream_top \
  --output bench/results_overlap_a1.csv --extended
python3 bench/run_overlap_stress.py --binary /tmp/sysa-overlap-a1/Vtb_tpu_stream_top \
  --output tb/reports/arch_kstream_rowprefetch_u100/stress_a1.log
```

A0 加 `ACCUM_MODE=0`，并使用独立 build/output 路径。测试机 Verilator 路径见 bench/README。
基线 `bench/results_a1.csv` 保留不覆盖。维度支持 1..256；计时定义仍为 cfg-to-final-output。

```sh
TPU_SYNTH_TOP=tpu_stream_dse_arch \
TPU_RUN_TAG=arch_kstream_rowprefetch_u100_a1 \
/tools/cadence/DDI231/bin/genus -batch \
  -files synthesis/scripts/syn_genus.tcl \
  -log synthesis/genus_arch_kstream_rowprefetch_u100_a1
```

重点检查：prefetch 控制到行读 mux 的路径、serializer 的 load_pending、local command
是否保留、控制逻辑面积变化，以及按真实 workload 注入活动后的能量。
