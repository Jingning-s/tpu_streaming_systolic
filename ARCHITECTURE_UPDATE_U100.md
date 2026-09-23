# 架构优化记录：本地阶段命令、prefix16 与 0.100 ns uncertainty

当前默认组合仍为 A1 CSA、`SCHED_IMPL=2`、`RESULT_IMPL=0`、
`FEEDER_IMPL=0`，结果行周期数保持不变：

```text
LOAD -> ARM -> FINALIZE_LO -> FINALIZE_HI -> COMMIT -> DRAIN
```

根据 `arch_shallow_dmerge_u300_a1` 报告，本轮修改集中在实际关键路径：

- setup uncertainty 从 0.300 ns 恢复为 0.100 ns，周期仍为 1.000 ns；
- 删除 feeder R0 上冗余的 `state == S_COMPUTE` 译码，直接使用生命周期严格受控的
  `issue_active`；
- 为 result R0、R1、低半 finalize 和高半 finalize 各增加按列复制的本地命令寄存器，
  wide payload bank 不再直接使用全局 FSM state 和 reset 作为写使能；
- upper 16-bit 终结器从串行 carry-select 选择链改为四级 parallel-prefix CPA；
- 保留 M2 直接进入 A1 累加器的浅 PE，不重新加入 D 级，也没有增加结果等待状态。

Verilator A1/A0 均通过 28 个 GEMM 场景和 9 个中途复位场景，包含 64x64
INT8/INT4。独立 prefix16 测试通过 200005 组 directed/random 向量。上述结果只证明
功能等价；时序、面积和功耗需要用新 tag `arch_localcmd_prefix_u100_a1` 重新综合。
