# 架构收敛记录：浅流水、两段结果 CPA 与 0.300 ns setup uncertainty

> 历史记录：该版本的 Genus 结果为 WNS -427.2 ps，随后被
> [ARCHITECTURE_UPDATE_U100.md](ARCHITECTURE_UPDATE_U100.md) 取代。

当前默认综合/测试组合为 A1 CSA、`SCHED_IMPL=2`、`RESULT_IMPL=0`、
`FEEDER_IMPL=0`。综合 wrapper `tpu_stream_dse_arch` 固定选择这组参数。
原始 `tpu_stream_top` 的 `USE_CSA_ACCUM` 参数默认值仍保留为 0，便于继续做
A0 参考综合；测试和推荐综合入口显式选择 A1。

## 本轮收敛内容

- PE 的 M2 结果直接格式化后送入 A0/A1 累加器，删除原 D 级的两个 32-bit
  payload 寄存器以及 valid/init/last token 寄存器。按 RTL 状态位计，每个 PE
  减少 67 bit，16x16 阵列共减少 17152 bit；实际映射面积和功耗仍以综合为准。
- A1 保留 fused-CSA 累加反馈，A0 保留普通 CPA 参考。`done` 直接跟随完整传播到
  M2 的 last token，因此无效尾行/尾列不会更新累加器，但仍能让右下角完成检测结束。
- 结果终结器收敛为低 16-bit 加法和高 16-bit segmented carry-select 加法两级。
  先前四段 8-bit 串行实验已经从默认 RTL 删除，因为它增加两拍行准备延迟，不能
  提高 DRAIN 阶段每拍一个 32-bit 元素的吞吐率。
- 结果 bank 的 R0/R1 两级读选择继续保留，避免重新形成宽 result-bank 读 mux 路径。
  `S_ADVANCE_TILE` 也继续独立占一拍，隔离最后一次输出握手和下一 tile 的尺寸、bank
  所有权更新。
- feeder、skew 和 PE payload 寄存器仅在相应 operand/work 有效时更新；控制 token
  继续逐拍传播。这些是同步 enable，不代表已经插入或验证 ICG。
- setup uncertainty 为 0.300 ns，clock period 为 1.000 ns，hold uncertainty 为
  0.050 ns。历史 checkpoint/report 不修改，新综合使用独立 tag。

## 当前结果行时序

```text
LOAD -> ARM -> FINALIZE_LO -> FINALIZE_HI -> COMMIT -> DRAIN
```

进入连续输出前有 5 个准备周期，DRAIN 仍可每周期输出一个结果。在不计 capture、
tile advance 和外部反压时，16 列行的局部效率为 `16/(16+5)=76.2%`，单列行为
`1/(1+5)=16.7%`。已删除的四段 8-bit 方案分别为 69.6% 和 12.5%。

本轮没有同时加入下一行预取或跨 K-bank 连续发射。这两项都会改变所有权和在途
token 管理，应在当前浅流水取得新 STA/PPA 基线后分别实验，避免多个结构变化相互
掩盖。

## Verilator 验证

使用 Verilator 5.032、`--timing` 和 `--assert` 验证当前最终 RTL。A1 和 A0 均通过：

- 28 个端到端 GEMM 场景；
- 9 个 FSM 中间状态复位场景；
- 64x64 INT8、64x64 INT4；
- K=1/2/15/16/17/31/32/33、边界 tile、奇数 K padding；
- 独立 A/B 输入停顿、输出反压、连续 job 精度切换和 far-corner token 传播。

独立 RTL lint 也已通过。复现命令如下，其中 Verilator 路径可以替换为本机安装：

```sh
cd tb
make verilator \
  VERILATOR=/path/to/verilator
make verilator ACCUM_MODE=0 \
  VERILATOR=/path/to/verilator
```

验证摘要见 `tb/reports/arch_shallow_u300/README.md`。旧的
`tb/reports/arch_u300` 保留为四段 8-bit 实验的历史记录。

## 综合与功耗验证边界

本轮按要求只运行 Verilator，没有运行新的 Genus/Innovus，因此不能宣称 1 GHz 已经
收敛，也不能给出节电比例。0.300 ns uncertainty 后的名义 0.700 ns 还要覆盖
clk-to-Q、组合逻辑、setup 以及物理时钟和互连影响。

默认新综合 tag 为 `arch_shallow_dmerge_u300_a1`。Genus 后应重点检查：

1. M2 到 A1 累加反馈是否成为新关键路径，以及删除 D 级后 WNS/TNS 的变化；
2. result R0/R1、两段 CPA 和 serializer load 是否仍出现在关键路径中；
3. 删除 17152 个 RTL 状态位后映射寄存器、时钟树负载和 vectorless power 的变化；
4. payload enable 是否被识别为有效的 clock-gating/operand-isolation 机会。

后续结构实验按优先级分开进行：下一结果行读/finalize 与当前行输出重叠；跨 K-bank
连续发射；capture 时完成 CPA 并让 result bank 只保存最终 32-bit 值；最后才根据
新 STA 余量决定是否进一步合并 M1/M2。
