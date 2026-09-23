# RTL 时序优化历程、结果与经验总结

## 1. 项目目标

本项目是一个 16×16 output-stationary streaming TPU。物理阵列固定为 16×16，通过 M/N/K tiling 支持至少 64×64 GEMM；硬件运行时支持 INT8 和 packed INT4。优化目标是 45 nm 工艺下接近或达到 1 GHz，同时控制面积、功耗、扇出和布局风险。

优化过程中始终采用“单阶段修改—回归—综合—STA—比较—再决定”的原则，而不是一次性叠加所有结构改动。

## 2. 初始问题

早期 RTL 的主要问题是：

- feeder 用 `feed_cycle - lane` 生成 `packet_index`，每个 lane 都有动态减法、比较和地址选择；
- tile buffer 是 lane-major 的多维 byte array，容易综合成大量异步 mux；
- `a_edge_reg/b_edge_reg` 实际位于组合逻辑中，没有真正切断 buffer 到 PE 的路径；
- result drain 使用 `result_buffer[drain_row][drain_col]`，可能形成接近 256:1、32-bit 的大 mux；
- `state`、`enable`、`clear_acc`、`precision_mode`、`feed_cycle` 和 result selector 在阵列中高扇出；
- 每个 K tile 都支付完整 wave flush，capture、drain 和下一 tile 计算未充分重叠；
- `result_bank_full` 没有实际参与 ownership/仲裁；
- capture 固定捕获 16 行，边界 tile 会产生无效工作；
- module-scope loop variable 和过宽 `integer packet_index` 增加仿真 race、位宽和综合不稳定风险；
- 早期乘法表达式有截断/位宽问题，修正后虽然功能正确，但可能增加真实算术面积和延迟。

早期 Genus 基线约为：WNS -1.952 ns、TNS -18,458.7 ns、44,392 条 setup 违例路径、cell area 758,537.7 um²。最差路径典型形状是：

```text
feed_cycle/state
  -> lane subtract/compare
  -> tile-buffer mux
  -> PE mode/multiply
  -> product register
```

## 3. 已完成的架构和 RTL 努力

### 3.1 Feeder 和 tile buffer 重构

- A/B buffer 改为 packet-major 宽字组织，每个 bank 由 16 个 128-bit packet entry 构成；
- A、B 保留独立 loader counter、fire、ready 和 bank ownership，允许两路输入独立 stall；
- 计算侧使用公共 `k_read_addr` 读取完整 A/B packet，去掉大规模 `feed_cycle - lane` 动态地址计算；
- 引入真正的 buffer-read R0 边界寄存器，并让 lane 0 也通过统一寄存器；
- 使用显式 per-lane skew pipeline，A row i 和 B column j 分别延迟 i 拍和 j 拍；
- data、valid、odd-K、first/last token 和 metadata 与 packet 同拍传播；
- 将 bank read done 和 compute done 分开，避免因为读完 packet 就过早覆盖仍在阵列传播的数据；
- 将状态机中散落的固定 `+1/+2` 补偿逐步改为事件/token 语义。

这一步的经验是：对 systolic 阵列而言，增加明确的寄存器边界通常比继续优化组合地址表达式更可靠；但必须先写清 latency contract，否则很容易出现 lane 0 丢包、last token 提前结束或 far-corner 少算一拍。

### 3.2 PE 算术 DSE 和局部重构

先把 PE 从全阵列隔离出来做单 PE/小阵列比较，尝试过以下方向：

- 4×4 signed 行为式乘法；
- 小位宽 Baugh-Wooley/array；
- Radix-4 Booth；
- INT8 M1 严格两行部分积；
- INT8 16-bit fast CPA；
- 32-bit accumulator fast CPA；
- fused CSA accumulator。

关键原则是：M1 结束后只能保留 `product_sum` 和 `product_carry_shifted` 两行，不能把多个 Booth partial product、correction 和 sign extension 写成串行 `pp0 + pp1 + ...`。否则综合会重新生成长 CPA 链。

后续采用了更偏结构化的方案：INT4 使用精确小位宽乘法/压缩，INT8 保持严格两行输出，accumulator 逐步尝试 CSA 化；同时保留传统 CPA 作为参考模式。通过 DSE 发现 PE 本身的最差路径逐渐降到约 -9~-20 ps 级别，已经不再是当前全芯片主要瓶颈。

经验教训：小位宽不必默认使用复杂 Booth；固定的 recode、负部分积和 correction 开销可能超过减少部分积的收益。真正影响全阵列时序的通常是 accumulator、全局控制和跨 PE 长连线，而不是一个孤立乘法器的 RTL 复杂度。

### 3.3 Result drain 多轮重构

result 侧先经历了 row capture、upper/lower CPA、serializer 和 mux 的多轮调整。最终采用的结构是：

```text
result buffer
  -> 4 个 group，每组 4 行
  -> group-local 4:1 candidate read
  -> R0 candidate registers
  -> registered quarter select
  -> row-local serializer
  -> low/high final CPA
  -> 32-bit elastic ready/valid output
```

同时完成了：

- 生成式固定 capture 映射，减少动态 RHS row mux；
- capture 在 `m_len` 行结束，避免尾 tile 固定捕获 16 行；
- serializer 只在 handshake 时移位；
- `valid && !ready` 时保持 data、tile_last、last；
- 用 load pending 将 serializer 的控制 token 和宽 payload 分开，避免把 reset/控制扇出重新接入宽数据路径；
- 为后续 dual-bank result buffer 预留 ownership 接口。

这一轮的最新结果是：

| 指标 | 上一版 | quarter-read + serializer 版 |
|---|---:|---:|
| WNS | -110.1 ps | **-85.4 ps** |
| TNS | -365.2 ns | **-140.6 ns** |
| setup 违例路径数 | 5,107 | 8,365 |
| cell area | 1,083,382.7 | 1,091,423.3 |
| sequential cells | 90,815 | 92,865 |
| vectorless power | 275.6 mW | 279.4 mW |
| max transition DRC count | 15,682 | 9,162 |
| max fanout DRC count | 1,052 | 1,504 |

Result R0 的 TNS 从约 -193.9 ns 降到约 -12.5 ns，最差从约 -110 ps 降到约 -22 ps；旧的 `result_row_shift` 长路径已经不在 top 50。代价是约 0.74% 面积和 1.39% 功耗增加，且新增了更多小幅负 slack endpoint。

经验教训：减少 mux 深度有效，但单纯增加寄存器会把问题转移到控制和算术路径；必须同时看 WNS、TNS、违例路径数量、fanout 和功耗，不能只看某一个数字。

## 4. 综合和 STA 中得到的关键经验

### 4.1 WNS、TNS 和违例路径数要一起看

最新版本的违例路径数增加，但 WNS 改善 24.7 ps、TNS 改善约 61.5%。这是因为结构化寄存器引入了更多 endpoint，使小幅负 slack 路径数量增加。当前主要问题已经从一条极长路径变成多个中等长度类别，说明方向正确但还没有闭合。

### 4.2 关键路径会迁移

消除 result 8:1/大动态读出后，top path 转移到了：

1. `state_reg -> k_base_reg/k_remaining` 的 scheduler/control；
2. `result_row_low_stage -> result_row_low_stage` 的 low-stage CPA；
3. upper/final result CSEL/CPA；
4. feeder R0 packet read 和 metadata 路径。

因此继续修改已经基本关闭的 PE，收益会很低；后续应该按 STA 分类的 TNS 和 top path 决定优化顺序。

### 4.3 全局控制比局部数据更危险

`enable`、`clear_acc`、`precision_mode`、state decode、capture/drain selector 和 bank control 的 fanout 会同时影响 timing、transition、buffer 数和布局拥塞。简单写一个 combinational alias 不会降低 fanout，综合通常会重新合并。有效的复制必须绑定 row/quadrant ownership，或者通过数据/valid/token 同步实现局部化。

### 4.4 工具报告必须先确认有效

早期脚本使用了目标 Genus 不支持的 `report_timing -late` 选项，导致所谓 top-10 详细报告为空。之后不能从缺失报告中猜路径，必须修正命令并确认 report 非空。最新一轮综合无 Error/Fatal，但仍有位宽 mismatch、unreachable case 和 `preserve` 属性被忽略的 warning，这些 warning 要区分“不会影响当前功能”和“会导致综合器忽略结构意图”。

### 4.5 preserve 不是扇出优化保证

RTL 中的 `preserve` 在当前 Genus 流程被忽略，不能据此假设寄存器副本或层级会被保留。应使用目标工具支持的 `set_db`、dont_touch、层级边界或物理约束，并在综合网表中检查是否真的存在复制结构。

### 4.6 物理实现结论不能由 Genus 单独得出

当前结果是 Genus setup 估算，尚未包含真实 Innovus placement、CTS、routing、congestion 和真实 clock tree。WNS -85.4 ps 对应约 1.085 ns 最小周期，等效约 922 MHz；因此还不能声称达到 45 nm、1 GHz。下一步必须在相同约束下同时看 setup、hold、transition、capacitance、拥塞和长线。

## 5. 当前瓶颈和下一步建议

当前不建议继续大改 PE。优先级为：

1. **Scheduler/control**：拆分 `state -> k_base/k_remaining/bank/drain` 路径，减少多状态条件共享和全局 selector；用预解码 token 或局部 next-state 控制。
2. **Result arithmetic**：继续检查 low-stage CPA、upper CSEL 是否能用更平衡的 16-bit segmented CPA 或减少 final-stage mux；注意不要重新引入宽动态选择。
3. **Feeder R0**：分析 packet read、bank/half select 和 metadata 对齐路径，保持 R0/R1 两级边界，不要让 mux 穿透到 PE。
4. **Fanout/transition**：定位当前最大 fanout 128 的真实 driver 和 endpoint；通过结构化 row/quadrant 控制或综合器合法的复制策略处理，而不是盲目加普通 register tree。
5. **结果吞吐**：只有在 timing 稳定后再评估 dual result bank 和 compute/drain overlap；32-bit 输出带宽仍是独立上限。

每一步都必须保留可回退 checkpoint，并完成 lint、完整回归、定向测试、综合和 STA。若 WNS/TNS 或物理拥塞退化，应分析退化原因并回退，而不是叠加下一阶段。

## 6. 当前结论

目前已经完成从“动态地址/大 mux 主导”向“packet 化、显式寄存器边界、局部读出和 token 对齐”的架构转变。Result drain 优化证明结构化 mux 分级是有效方向，PE 也已从首要瓶颈降为次要瓶颈。但全芯片仍受 scheduler、feeder 和 result arithmetic 共同限制，当前约 922 MHz 的 Genus setup 结果距离 1 GHz 尚有余量缺口，必须继续以 STA 证据驱动优化，并在 Innovus 中验证真实物理结果。
