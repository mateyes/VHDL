# AXI4-Lite 读写访问控制模块（MAC 管理接口）使用说明

本目录提供一套可直接综合、可仿真验证的 VHDL 代码，实现以太网 MAC IP 核管理接口所需的
**AXI4-Lite 从机读写控制模块**。寄存器映射、信号命名与时序行为均参照
《MAC IP 核中的 AXI LITE 控制接口》（Xilinx TEMAC 手册）中的：
Table 12（AXI4-Lite 信号）、Figure 61（写时序）、Figure 62（读时序）、
Table 76（MAC 地址映射）、Table 40~43（MDIO 寄存器）。

---

## 1. 文件清单

| 文件 | 说明 |
| --- | --- |
| `src/axi_lite_mac_ctrl.vhd` | 设计源码：AXI4-Lite 从机 + MAC 管理寄存器组 |
| `sim/tb_axi_lite_mac_ctrl.vhd` | 自检测试平台：内建 AXI4-Lite 主机 BFM、协议断言与寄存器回读比对 |
| `sim/run_xsim.bat` | Windows 一键编译 + 仿真脚本（Vivado xsim） |
| `README.md` | 本说明文档 |

---

## 2. 模块接口

### 2.1 泛型

| 泛型 | 默认值 | 说明 |
| --- | --- | --- |
| `G_AXI_ADDR_WIDTH` | 17 | 地址宽度。MAC 使能 AVB 端点时为 17（`awaddr[16:0]`）；未使能时为 12（`awaddr[11:0]`），本模块寄存器全部位于 0x0000~0x07FF，12 位地址足够 |
| `G_AXI_DATA_WIDTH` | 32 | 数据宽度，与 MAC 管理接口一致 |

### 2.2 AXI4-Lite 端口（与 Table 12 一一对应）

| 信号 | 方向 | 时钟域 | 说明 |
| --- | --- | --- | --- |
| `s_axi_aclk` | In | — | AXI4-Lite 时钟 |
| `s_axi_aresetn` | In | `s_axi_aclk` | 低有效复位（同步复位） |
| `s_axi_awaddr[16:0]` | In | `s_axi_aclk` | 写地址 |
| `s_axi_awvalid` | In | `s_axi_aclk` | 写地址有效 |
| `s_axi_awready` | Out | `s_axi_aclk` | 写地址就绪 |
| `s_axi_wdata[31:0]` | In | `s_axi_aclk` | 写数据 |
| `s_axi_wstrb[3:0]` | In | `s_axi_aclk` | 写字节选通 |
| `s_axi_wvalid` | In | `s_axi_aclk` | 写数据有效 |
| `s_axi_wready` | Out | `s_axi_aclk` | 写数据就绪 |
| `s_axi_bresp[1:0]` | Out | `s_axi_aclk` | 写响应（`00`=OKAY，`10`=SLVERR） |
| `s_axi_bvalid` | Out | `s_axi_aclk` | 写响应有效 |
| `s_axi_bready` | In | `s_axi_aclk` | 写响应就绪 |
| `s_axi_araddr[16:0]` | In | `s_axi_aclk` | 读地址 |
| `s_axi_arvalid` | In | `s_axi_aclk` | 读地址有效 |
| `s_axi_arready` | Out | `s_axi_aclk` | 读地址就绪 |
| `s_axi_rdata[31:0]` | Out | `s_axi_aclk` | 读数据 |
| `s_axi_rresp[1:0]` | Out | `s_axi_aclk` | 读响应 |
| `s_axi_rvalid` | Out | `s_axi_aclk` | 读数据/响应有效 |
| `s_axi_rready` | In | `s_axi_aclk` | 读数据/响应就绪 |

### 2.3 用户侧寄存器端口

| 信号 | 方向 | 说明 |
| --- | --- | --- |
| `i_core_id[31:0]` | In | 0x0000 核版本/ID（只读） |
| `o_mac_cfg[31:0]` | Out | 0x0400 MAC 配置寄存器当前值 |
| `o_mac_cfg_wr` | Out | 写 0x0400 时输出 1 拍使能脉冲 |
| `i_mac_status[31:0]` | In | 0x0404 MAC 状态（只读） |
| `o_mdio_setup[31:0]` | Out | 0x0500 MDIO Setup 字 |
| `o_mdio_ctrl[31:0]` | Out | 0x0504 MDIO Control 字（bit7 实时反映 `i_mdio_ready`，bit11 输出恒 0） |
| `o_mdio_init` | Out | 写 Control 字 Initiate(bit11)=1 时输出 1 拍启动脉冲 |
| `o_mdio_wdata[31:0]` | Out | 0x0508 MDIO 写数据（bit15:0 有效） |
| `i_mdio_rdata[15:0]` | In | 0x050C MDIO 读数据 |
| `i_mdio_ready` | In | MDIO ready，映射到 Control 字 bit7、Read Data 字 bit16 |
| `o_irq_enable[31:0]` | Out | 0x0600 中断使能 |
| `i_irq_status[31:0]` | In | 0x0604 中断状态（只读） |
| `o_frame_filter[63:0]` | Out | 0x0700/0x0704 帧过滤寄存器（高 32 bit + 低 32 bit） |

---

## 3. 寄存器映射

字地址 = 字节地址 / 4，访问时忽略 `addr[1:0]`（按 32 bit 对齐译码）。

| 字节地址 | 名称 | 访问 | 复位值 | 说明 |
| --- | --- | --- | --- | --- |
| 0x0000 | CORE_ID | RO | `i_core_id` | 核版本/ID，写返回 SLVERR |
| 0x0400 | MAC_CFG | RW | 0x0000_0000 | MAC 配置（流量控制、VLAN 等由用户定义） |
| 0x0404 | MAC_STATUS | RO | `i_mac_status` | MAC 状态，写返回 SLVERR |
| 0x0500 | MDIO_SETUP | RW | 0x0000_0000 | bit6=MDIO Enable，bit5:0=Clock Divide，bit31:7 读 0 |
| 0x0504 | MDIO_CTRL | RW/RO/WO | 0x0000_0000 | bit28:24=TX_PHYAD，bit20:16=TX_REGAD，bit15:14=TX_OP，bit11=Initiate(WO，读 0，写 1 产生 `o_mdio_init` 脉冲)，bit7=MDIO Ready(RO，实时反映 `i_mdio_ready`) |
| 0x0508 | MDIO_WDATA | RW | 0x0000_0000 | bit15:0 写数据，bit31:16 读 0 |
| 0x050C | MDIO_RDATA | RO | — | bit15:0 读数据，bit16=MDIO Ready |
| 0x0600 | IRQ_EN | RW | 0x0000_0000 | 中断使能 |
| 0x0604 | IRQ_STATUS | RO | `i_irq_status` | 中断状态 |
| 0x0700 | FF_LOW | RW | 0x0000_0000 | 帧过滤寄存器低 32 bit |
| 0x0704 | FF_HIGH | RW | 0x0000_0000 | 帧过滤寄存器高 32 bit |
| 其它 | 保留 | — | — | 未映射：写/读均返回 SLVERR |

> 说明：模块实现了 MAC 地址映射表中的一个示例子集，覆盖了配置类、状态类、
> MDIO 类、中断类与帧过滤类寄存器，用于完整演示 AXI4-Lite 读写控制。
> 如需扩展到统计计数器（0x200~0x3FC）等区域，只需在
> `p_wr_channel` 的 `WR_COMMIT` 分支与 `p_rd_channel` 的读译码 `case` 中增加分支。

---

## 4. 实现与协议要点

1. **通道独立**：写通道（AW/W/B）与读通道（AR/R）为两个独立状态机，可同时进行。
2. **AW/W 可乱序到达**：地址与数据可同拍到达、先地址后数据、先数据后地址，
   由内部 `aw_have/w_have` 暂存，二者齐备后进入唯一的提交点 `WR_COMMIT`，
   避免同一事务重复写寄存器。
3. **READY 独立**：`AWREADY/WREADY/ARREADY` 仅由内部状态决定，不组合依赖 VALID。
   某通道接收后立即拉低其 READY，防止重复握手。
4. **VALID 保持**：`BVALID/RVALID` 置位后保持不变，直到 `BREADY/RREADY` 有效；
   期间 `BRESP/RDATA/RRESP` 保持稳定。
5. **字节选通**：所有 RW 寄存器均按 `WSTRB` 逐字节更新，未选通字节保持原值。
6. **只读/只写位处理**：MDIO Control 的 Initiate(bit11) 为 WO（读回 0，写入 1 产生
   单拍启动脉冲）；bit7 为 RO（读回实时 `i_mdio_ready`）。
7. **错误响应**：未映射地址、对只读寄存器写，均返回 `SLVERR = 2'b10`，
   与文档中"非法访问产生错误指示"的要求一致；读错误时 `RDATA = 0`。
8. **时序延迟**：
   - 读：`AR` 握手后的下一拍 `RVALID=1` 且 `RDATA` 有效（1 拍读延迟）；
   - 写：`AW` 与 `W` 均握手后 1 拍给出 `BVALID`。
9. **复位**：`s_axi_aresetn` 低有效、同步于 `s_axi_aclk`；所有寄存器复位为 0。

---

## 5. 与 TEMAC IP 核对接

将本模块的 `s_axi_*` 端口与 MAC IP 的 AXI4-Lite 管理接口同名端口直连即可
（`s_axi_aclk` 接 MAC 的 `s_axi_aclk`，`s_axi_aresetn` 接 `s_axi_aresetn`）。

- MAC 使能 AVB 端点：`s_axi_awaddr` / `s_axi_araddr` 为 17 bit，保持默认泛型 `G_AXI_ADDR_WIDTH = 17`；
- MAC 未使能 AVB 端点：地址为 12 bit，将泛型改为 `12`（本模块寄存器均在 0x000~0x7FF 内，12 位可覆盖）。

用户侧端口即为"寄存器文件访问接口"：`o_*` 输出配置值/脉冲，`i_*` 输入状态，
可直接连接到 MAC 配置逻辑、MDIO 状态机（用 `o_mdio_init` 作为启动脉冲）等。

---

## 6. 仿真验证

### 6.1 一键运行（Windows + Vivado xsim）

```bat
cd <本目录>
sim\run_xsim.bat
```

脚本依次执行 `xvhdl → xelab → xsim -runall`。若 `xvhdl` 等不在 PATH 中，
请先设置环境变量 `XILINX_VIVADO`（指向 Vivado 安装目录），脚本会自动调用
`settings64.bat`。

### 6.2 手工命令（Vivado xsim）

```bat
xvhdl --2008 src/axi_lite_mac_ctrl.vhd
xvhdl --2008 sim/tb_axi_lite_mac_ctrl.vhd
xelab --debug typical --relax tb_axi_lite_mac_ctrl -s tb_sim
xsim tb_sim -runall
```

### 6.3 ModelSim / QuestaSim

```tcl
vlib work
vcom -2008 src/axi_lite_mac_ctrl.vhd
vcom -2008 sim/tb_axi_lite_mac_ctrl.vhd
vsim -c tb_axi_lite_mac_ctrl -do "run -all; quit -f"
```

### 6.4 Vivado 图形界面

1. 新建工程，`Add Sources` 加入 `src/axi_lite_mac_ctrl.vhd` 与 `sim/tb_axi_lite_mac_ctrl.vhd`；
2. 将 `tb_axi_lite_mac_ctrl` 设为仿真顶层；
3. `Run Simulation → Run Behavioral Simulation`，在波形窗口观察 `s_axi_*` 握手。

### 6.5 测试项覆盖

| 编号 | 测试内容 |
| --- | --- |
| T1 | 复位后读核 ID（RO 寄存器） |
| T2 | MAC 配置寄存器整字写/读 + `o_mac_cfg_wr` 脉冲 |
| T3 | WSTRB 字节选通（仅更新 bit31:24） |
| T4 | MDIO Setup 写/读，保留位读 0 |
| T5 | MDIO Control 写/读：Initiate 启动脉冲、bit7 只读 ready、bit11 读 0 |
| T6 | MDIO Write Data 写/读 |
| T7 | MDIO Read Data 只读（bit16=ready） |
| T8 | 中断使能写/读、中断状态只读 |
| T9 | 帧过滤双字写/读 + 64 bit 输出 |
| T10 | 未映射地址写/读 → SLVERR、读数据为 0 |
| T11 | 只读寄存器写 → SLVERR 且内容不变 |
| T12 | AW 先、W 后分离到达 |
| T13 | W 先、AW 后分离到达 |
| T14 | BREADY 延迟 4 拍，检查 BVALID 保持 + 半字选通 |
| T15 | RREADY 延迟 3 拍，检查 RVALID/RDATA 保持 |
| T16 | 背靠背连续写与回读 |

实际仿真结果（Vivado Simulator 2018.3）：

```
PASS [T1 core_id   ] = 0x4D414331
...
PASS [T16 mdio ctl ] = 0x00002080
==========================================================
  ALL TESTS PASSED  (checks = 48)
==========================================================
```

日志中任一 FAIL 会以 `severity error` 输出；全部通过时打印
`ALL TESTS PASSED (checks = 48)`，仿真约在 1.5 us 结束。

### 6.6 波形观察建议

- 写事务：`s_axi_awvalid/awready`、`s_axi_wvalid/wready`、`s_axi_bvalid/bready/bresp`，
  对应 Figure 61 的三段式（发地址 → 写数据 → 收响应）；
- 读事务：`s_axi_arvalid/arready`、`s_axi_rvalid/rready/rdata/rresp`，
  对应 Figure 62；
- 用户侧：`o_mac_cfg`、`o_mdio_ctrl`、`o_mdio_init` 脉冲宽度为 1 个 `s_axi_aclk` 周期。

---

## 7. 注意事项

1. 本模块为**单时钟、同步复位**设计；若系统需要异步复位同步释放，请在模块外添加复位同步器。
2. 写操作与读操作在寄存器层面无乱序保护（AXI4-Lite 不保证读写通道之间的顺序），
   软件应先收到写响应再发起相关读操作。
3. `WSTRB` 对只读寄存器无效；对只读寄存器或保留地址的写一律返回 SLVERR。
4. 扩展寄存器时，请保持"读译码"和"写提交"两处 `case` 的地址常量一致，
   并在 README 的寄存器表中同步更新。
