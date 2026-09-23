# TPU 整体优化、算子与性能测试

> 本文第 1–3 节为优化前的分析记录。K 分块重叠与结果行预取已实现，最新变化和实测
> 见 [ARCHITECTURE_UPDATE_OVERLAP.md](../ARCHITECTURE_UPDATE_OVERLAP.md)。
> `results_a1.csv` 保留原基线；新结果为 `results_overlap_a1.csv` / `results_overlap_a0.csv`。

## 1. 证据范围

2026-09-21：最新完整综合报告为
`synthesis/checkpoints/arch_shallow_dmerge_u300_a1/reports`。
当前 local-command/prefix/u100 RTL **尚无新综合结果**。
本目录 `results_a1.csv` 是当前 RTL 的 Verilator 周期实测，不是综合性能预测。

| 报告 | setup uncertainty | WNS | TNS | 违例路径 | Cell area | vectorless power |
|---|---:|---:|---:|---:|---:|---:|
| timing_dse_a1_s2 | 100 ps | -112.5 ps | -164.667 ns | 8,059 | 1,083,272.808 | 275.182 mW |
| arch_shallow_dmerge_u300_a1 | 300 ps | -427.2 ps | -17,584.619 ns | 72,808 | 1,258,247.019 | 316.606 mW |

两版约束、架构不同，不能直接归因于流水级变化。旧 u300 网表若仅放宽 uncertainty
200 ps，原最差路径 slack 约为 -227.2 ps，仍不能满足 1 GHz；这不是新 RTL 的预测。
area 单位按库面积单位解释。u300 数组面积 880,702.942，占总面积约 70%。
寄存器 90,822 个，register 类功耗 231.997 mW，占 73.28%；该类功耗包含寄存器内部
和输出翻转，不能全部解释成时钟功耗。报告 clock 为零不表示实现后的时钟树零功耗。

最差路径包含 upper finalizer、reset/FSM 到结果宽寄存器使能、FSM 到 feeder R0。
当前 prefix/local-command 修改针对这些路径，但必须新综合并检查复制使能是否被合并。
保持 period、uncertainty、PVT、IO、活动率一致，分别比较：浅流水基线、local-command、
prefix、两者组合。不要通过单纯降低 uncertainty 宣称架构时序改善。

## 2. 当前实测瓶颈与优化顺序

无输入停顿、输出 always-ready，计数从 cfg 握手后的第一拍到最后结果握手，含首尾开销：

| M,N,K | INT8 cycles | INT4 cycles | INT8 GOPS* | INT4 GOPS* |
|---|---:|---:|---:|---:|
| 16,16,16 | 426 | 410 | 19.23 | 19.98 |
| 16,16,64 | 594 | 554 | 55.16 | 59.15 |
| 64,64,64 | 9519 | 8879 | 55.08 | 59.05 |
| 17,17,33 | 1180 | 1084 | 16.16 | 17.60 |
| 1,64,64 | 1059 | 899 | 7.74 | 9.11 |
| 64,1,64 | 1419 | 1259 | 5.77 | 6.51 |

*按假设 1 GHz 折算；未达成 STA 签核。MAC=2 ops，INT4 每 PE 两个 MAC。
INT8 峰值 512 ops/cycle，INT4 峰值 1024 ops/cycle。
64³ 的任务级有效利用率分别仅 10.76%、5.77%；INT4 实际加速约 1.072 倍。

16³ INT8 的 426 拍分解：等待输入 bank 18、capture 17、结果行准备 80、
输出 drain 256、其余 55。issue 的 16 拍包含于其余阶段，不能再加一次。
64³ INT8：drain 4096 + 行准备 1280 = 5376 拍，占 56.48%。
这里的状态统计是控制器驻留时间；不等于所有 PE 的有效 MAC 周期。

建议按以下顺序做独立实验，逐版保存正确性、周期、WNS、面积、活动功耗：

1. **同约束建立时序基线**：先综合当前 u100。按数据算术、控制扇出、buffer mux 分类
   路径；不继续全阵列增加流水。局部加级只有在提高“实际频率 × 每拍有效吞吐”时才保留。
2. **结果行预取**：当前每行串行经历五拍准备再输出。增加 next-row staging，当前行
   drain 时预读/终结下一行。16 列行通常可隐藏五拍；N=1 无足够窗口，要单独评估。
   实现 row-valid/credit、背压保持、tile/row metadata 对齐，避免覆盖未消费行。
3. **连续 K 发射**：当前每个 K=16 块在 S_COMPUTE 等待 far-corner completion 才
   切换下一块，即使下一输入 bank 已装好。将 packet-reader ownership 与末端完成分离，
   bank 在最后读请求安全登记后释放；下一块可就绪即发射，同一 C tile 保留 accumulator。
   first 仅标记整个 C tile 的首 token，final-capture 仅在最后 K 块退休后执行。
   需要独立描述符队列/在途块计数，验证 bank 重用、K 奇数尾、复位和输入停顿。
4. **扩大有效输出带宽**：优先考虑 128-bit INT32 输出（4 个结果/拍），配合四 lane
   finalizer 和按行/字分银行。完整 tile 纯输出下限由 256 降到 64 拍；仍需优化准备阶段。
   若下一算子只需 INT8，可融合 requant 后以 128-bit 打包输出，完整 tile 下限 16 拍。
   不能仅改变接口位宽而保留内部每拍一个结果生产率。
5. **计算/输出重叠**：结果双 bank 与独立 drain controller，使下一 C tile 计算与上一
   tile 输出重叠。单靠双 bank 不提高稳态 32-bit 接口带宽，且复制 FF bank 增加面积和
   时钟负载；建议在结果宽化/存储组织确定后实现，使用信用控制防止满 bank 覆盖。
6. **数据复用和存储**：当前 M/N/K 遍历会为每个输出 tile 重传 A/B。增大 scratchpad
   并保留 B 跨 M、A 跨 N，或由 DMA/cache 复用；双 128-bit 输入要持续满发射，1 GHz
   下各需 16 GB/s（合计 32 GB/s）片上供数能力。若仍坚持 SRAM-free，先评估 FF
   成本，勿默认大缓存免费。结果 bank 的 sum/carry 共 2 KiB，可比较捕获时按行终结
   成 INT32 的 1 KiB bank，代价是 CPA 吞吐/捕获时序和端口需求。
7. **降低寄存器动态功耗**：对 bank、结果组、PE 行/列的真实 idle 窗口做 ICG 实验；
   enable 保持数据不等于关时钟。禁止手写 AND 时钟；用标准 ICG、检查门控时序及 CTS。
   排查未选精度乘法支路的组合翻转；小 M/N tile 做 operand isolation。测量完整 job
   能量和 idle 功耗，避免只看 active 瞬时功耗。小 batch GEMV 利用率先通过 batch 合并
   改善，是否拆分成多个子阵列需看实际工作负载占比。

## 3. 建议的算子接口和映射

现有硬件原生支持有符号 INT8×INT8、INT4×INT4 GEMM，INT32 输出。
INT4 没有独立输出通道加倍：两路处理相邻 K 的乘积并累加到同一输出。
以下为扩展设计；现有 benchmark 的 conv/attention 是对应 GEMM **形状测试**，
没有实现卷积前处理或完整 attention。

统一软件描述符建议：op、M/N/K、batch、dtype、A/B/C 地址与 stride、transpose、
padding/stride/dilation/groups、bias 地址、per-channel scale/shift 地址、输出 dtype、
activation。先由软件拆成现有 cfg+stream 作业，不立刻扩展 PE 指令集。

| 算子 | GEMM 映射 | TPU 外/后处理 | 优先级 |
|---|---|---|---|
| MatMul / Linear / FC | A[M,K] B[K,N] | B 的转置/打包、bias、requant | P0 |
| BatchMatMul | batch 个 GEMM | batch stride，队列化 | P0 |
| Conv 1×1 | M=B·Hout·Wout, N=Cout, K=Cin | 布局转换、bias/激活 | P0 |
| Conv 3×3 / 一般 Conv | M=B·Hout·Wout, N=Cout, K=Kh·Kw·Cin | im2col/滑窗生成 | P1 |
| GroupConv | 每组 GEMM，K=Kh·Kw·Cin/groups, N=Cout/groups | 分组寻址/合并 | P1 |
| QKᵀ、PV | Lq×d 乘 d×Lk；Lq×Lk 乘 Lk×dv | 转置、scale/mask/softmax、重新量化 | P1 |
| Depthwise Conv | 每通道独立点积 | 阵列利用率低，优先向量/专用滑窗单元 | P2 |
| Add/ReLU/Clamp/Requant | 输出流后处理 | 小向量 epilogue | P0 扩展 |
| Pooling/Softmax/LayerNorm/GELU | 非原生 GEMM | CPU/向量归约或后续专用单元 | P2 |

卷积基线先软件显式 im2col 验证；性能报告同时记录展开字节数和准备时间。
之后做 implicit im2col + line buffer，避免把重复数据物化到外存。
attention 的 QKᵀ、PV 只能分别称矩阵子算子性能；softmax 输出进入低比特 PV 前需
定义量化尺度并评估精度，不能把两个 GEMM 的耗时相加当完整 Transformer。

建议先做对称有符号量化（zero point=0）：
`acc32 = sum(a_q*b_q) + bias32[n]`；扩展 epilogue 使用足够宽乘积计算
`q = sat_dtype(round(acc32 * multiplier[n] / 2^shift[n]) + output_zp)`。
round 必须规定负数和 tie 行为（建议 nearest、ties-away-from-zero），ReLU 在量化
输出上以 output_zp 为下限。输出 INT32 模式旁路 requant。bias/乘积累加溢出策略必须
显式约定；当前 RTL 固定位宽按二补码截断。非零输入 zero point 需要行/列和修正，
现有乘加器没有实现该语义。测试通道独立 scale、饱和边界、负值和 K 尾部。

## 4. 可执行测试

从项目根目录运行（VERILATOR 可指定实际安装路径）：

```sh
make -C tb verilator-build VERILATOR=verilator VERILATOR_DIR=/tmp/sysa-perf-a1
python3 bench/run_bench.py --binary /tmp/sysa-perf-a1/Vtb_tpu_stream_top \
  --output bench/results_a1.csv --freq-mhz 1000
```

本机验证可将 `VERILATOR` 设为本地 Verilator 可执行文件的路径。

单次测试：

```sh
/tmp/sysa-perf-a1/Vtb_tpu_stream_top +bench +m=16 +n=16 +k=64 +int4=1
/tmp/sysa-perf-a1/Vtb_tpu_stream_top +bench +m=16 +n=16 +k=64 +int4=1 +stalls
```

目前维度范围 1..256。默认 8 个形状 × 2 种精度 × 2 种流量共 32 次；加 `--extended` 则包含 K=129/255/256，共 44 次，全部逐元素比对
golden，并检查包数、tile_last、last 和背压稳定性。ideal 无人为输入停顿且 always-ready；
stalled 沿用固定 LFSR 输入空隙和周期性输出背压，结果可复现，但不代表某个 DRAM 模型。
不加 +bench 保持原来的功能/复位回归。A0 另用 `ACCUM_MODE=0` 和独立 build/output 路径。

CSV 包含总周期、首结果、issue、wait_bank、capture、行准备、drain、其余状态、
输出阻塞、实际 A/B 包数、输出数、接口字节、GOPS、利用率。phase counters 互斥且和
等于 cycles；issue/output_stall 是重叠事件，不加入 phase 总和。最后输出到重新 cfg_ready
的收尾及软件配置开销不计入当前 latency，连续 job 的 initiation interval 需另测。

定义：useful_ops=2MNK；GOPS=useful_ops*f_MHz/(cycles*1000)；
utilization=useful_ops/(cycles*512*(INT4?2:1))。
接口字节按实际 128-bit 输入与 32-bit 输出计，包括 padding 和重复 tile 传输；
不是最小张量字节数，也不是 DRAM 流量。f_MHz 是用户假设，后续替换为实际闭合频率。

## 5. 从形状测试到算子/网络评测

第二阶段新增 Python 算子参考与向量文件：先验证 matmul→epilogue、1×1 conv、
3×3 conv（直接卷积参考 vs im2col GEMM）、batch matmul，然后测试注意力矩阵子算子。
文件记录输入、期望输出、布局、量化和随机 seed。增加 127/128/129、255/256/257 等边界
其中 256 以内已扩展 TB 存储与 watchdog；257 以上需进一步扩展，不能静默截断。

每算子分别报：纯 TPU cfg-to-last 延迟；数据准备/打包；DMA/排队；epilogue；端到端延迟。
选代表性 CNN/MLP/attention 层，按层出现次数累计 cycles/能量，再算网络吞吐，不能
算各层 GOPS 的简单平均。至少覆盖长 K、K 很短、M=1、小 N、尾块、独立 A/B starvation、
输出背压、稀疏/零数据和随机数据；最后再做真实 trace。

低功耗验证需另建 `--trace` Verilator binary 采集活动（现有 +dump hook；需另加编译
trace 选项），或门级仿真 SAIF/VCD 注入功耗工具，核对 RTL/门级名称映射和 annotation
coverage。分 idle、输入、compute、drain 窗口，计算 E_job=∫P(t)dt、pJ/useful-MAC。
不能将旧版 vectorless 316.6mW 直接乘新版 RTL 的周期当作实测能量；无 CTS 的报告也
不代表最终芯片功耗。最终优化验收同时要求数值正确、任务周期下降、时序满足约束、
面积/能量符合预算。

可用 `+a_gap=17 +b_gap=0` 或反向设置，单独验证 A/B 严重供数不足。
新 S_WAIT_ROW 的等待时间计入 CSV 的 other；row_prepare 是主 FSM 的准备时间，
后台预取与 drain 重叠，不应将其重复加到总周期。
