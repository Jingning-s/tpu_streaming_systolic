# Coral NPU 矩阵单元与当前 TPU 的流水对比

官方仓库：https://github.com/google-coral/coralnpu

本地路径：`/path/to/coralnpu`

阅读版本：`fedbe8d1e576d34ae955855918b87bf9c89c40b5`，提交日期 2026-09-18。
本次为源码分析，没有修改本项目 RTL，也没有运行 Coral 的综合或仿真。

## Coral 当前实现

主要源码位于 `hdl/verilog/rvv/design/Zvt/`。不能用标量乘法器文档
`doc/microarch/mlu.md` 的“三阶段”描述来代替矩阵单元的真实流水。

- `zvt_pe_array.sv:34`：MULBULKPIPENUM=3，ADDERPIPENUM=3。
- `zvt_pe_array.sv:311`：四个 block 的输入采用 0/1/1/2 拍的分块对齐；block
  内部从 va/vb 向多条运算 lane 广播，不是每个 scalar PE 一拍地穿过完整 16x16。
- `zvt_pe_block.sv:109`：每个 lane 实例化 mulbulk；其后有
  `handshake_ff` (`:222`)，再从 matrix-tile 存储读取累加值送入 adder。
- `zvt_pe_mulbulk.sv:85`：DISTRIBUTED、NUM_PIPE_REGS=3 对应输入/中间/输出
  各一个寄存边界。整数路径为输入寄存、乘积寄存、点积结果寄存。
- `zvt_pe_mulbulk_int_lane.sv:43`：整数乘法使用普通 `*` 表达式；INT8 时取四对
  对应 byte 的乘积并求和，INT16 时组合 byte partial products。它不是单个 INT8
  MAC，也没有本项目的双 INT4 lane。
- `zvt_pe_adder_int_lane.sv:25`：整数加法使用完整 32 位加法表达式；外层的三个
  分布式寄存边界不等于把加法拆成三个位段。
- `zvt_mt_reg.sv:25`：matrix-tile 存储在此实现中由 byte-enable FF 构成；不能
  因顶层有 TCM SRAM 就将该累加存储称为 SRAM。

所以可概括为“mul/dot 三个边界 → 一个 elastic buffer → adder 三个边界 → MT 写回”，
不含前端发射、块间对齐、目的存储写入和停顿。它并不是一个只有两三级的极浅 MAC。

规模由宏决定（`inc/rvv_backend_define.svh:198`）。以 VLEN=128 为例，TE=16，
四个 block，每 block 是 2x8 个 dot-product lane，总共 64 个 lane；每 lane 每次
做四个 INT8 乘积，因此算术峰值为 256 个 INT8 乘加项/周期。较大的逻辑 tile 按 cnt
分时处理；不能把逻辑 tile 尺寸直接当成物理 scalar PE 数量。

功耗方面，它同时采用 operand isolation 与 enabled FF。`common/edff.sv` 是同步
enable 的寄存器描述，不是显式 ICG；实际门控与功耗仍依赖综合和物理实现。

## 当前项目是否流水过多

需要分开评价：

1. PE 的 M0/M1/M2/A 边界不能直接用 Coral 的名字或阶段数判定过多。我们的每拍
   算术量、INT4 支持、CSA 状态、工艺库和时序约束不同。原 D 格式级已经并入 A，
   M1/M2 的压缩树边界保留，等待新 STA 判断是否还能合并。
2. 结果通路已经收敛回 LOAD、ARM、低/高两个 finalize 阶段和 COMMIT。四段 8 位
   方案已从默认 RTL 删除，因为新增串行等待没有提高行吞吐。
3. K-bank 切换等待 far-corner 完成后才发射下一 bank。对短 K tile，每次都支付
   边缘 skew、阵列传播和 PE 尾部排空时间，影响可能超过少一两个算术级。

结果 drain 的理想局部效率（不含 capture、计算、tile advance 和外部停顿）为：

| 方案 | 每行准备周期 | 16 列输出 | 1 列输出 |
|---|---:|---:|---:|
| 当前两段 16 位 CPA | 5 | 16/21 = 76.2% | 1/6 = 16.7% |
| 已移除四段 8 位 CPA | 7 | 16/23 = 69.6% | 1/8 = 12.5% |

四段化不意味着这里的 staging FF 翻倍：新中间 payload 为每列 8+16+24+3=51 bit；
旧低半结果、高半双操作数和进位为 16+16+16+1=49 bit。最终结果寄存器两者都存在。
由于新方案保留稳定的 R1 操作数，未再复制高位操作数。这里最明确的代价是多两个
串行准备周期，而不是大量新增 staging FF；映射后的实际数量仍需综合确认。

## 收敛结果与下一步

默认方案已经切换到两段 16 位结果 CPA，并删除 PE D 寄存边界。setup uncertainty
已经恢复为 0.100 ns；结果阶段采用局部命令寄存和并行前缀 upper CPA，仍需新 STA
决定是否继续减级。

建议先做这些独立比较：

- 将下一行读取/finalize 与本行输出重叠，或者改为与 32-bit 输出匹配的每拍一元素
  finalizer。优化目标是允许每拍接收新工作，而非增加等待状态。必须考虑尾列和反压。
- 比较 capture 时完成 CPA、结果 buffer 只存最终 32 位值的方案，减少 CSA 双份结果
  存储；它会改变 capture 吞吐和所有权，需作为结构实验验证。
- 根据新 STA 检查 M2 到累加器反馈路径；只有该路径仍有余量时才继续合并 M1/M2。
- 优先设计跨 K-bank 连续发射，用 bank-read-done 管理可覆盖性，单独追踪所有在途
  完成 token；不能直接删掉原来的 bank-compute-done 等待。

最值得借鉴 Coral 的是分块、局部广播、事务化累加存储和明确的 valid/ready 边界。
直接转换成其 outer-product + MT 架构会改变输入供给、累加相关性与存储带宽，属于
下一套架构，而不是删除现有几个寄存器即可完成。
