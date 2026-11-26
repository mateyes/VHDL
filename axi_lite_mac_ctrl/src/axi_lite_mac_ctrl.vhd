--------------------------------------------------------------------------------
-- 文件名   : axi_lite_mac_ctrl.vhd
-- 功能     : 以太网 MAC IP 核 AXI4-Lite 管理接口读写访问控制模块（AXI4-Lite 从机）
--
-- 参考依据 : 《MAC IP 核中的 AXI LITE 控制接口》
--            - Table 12 : Optional AXI4-Lite Signal Pinout
--            - Figure 61: Management Register Write Timing
--            - Figure 62: Management Register Read Timing
--            - Table 76 : MAC Registers (地址映射)
--            - Table 40~43 : MDIO Setup/Control/Write Data/Read Data 寄存器
--
-- 实现要点 :
--   1. 写通道（AW/W/B）与读通道（AR/R）各自独立状态机，互不阻塞；
--   2. AW 与 W 通道可任意先后到达，同一拍到达时直接提交；
--   3. 支持 WSTRB 字节选通，未选通字节保持原值；
--   4. BVALID / RVALID 一旦置位即保持，直到对应 READY 有效；
--   5. 未映射地址或对只读寄存器写，返回 SLVERR("10")；
--   6. 地址按字（32 bit）对齐译码，忽略 addr(1 downto 0)。
--
-- 语言     : VHDL-93 / VHDL-2008 兼容（推荐以 --2008 编译）
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_lite_mac_ctrl is
  generic (
    -- MAC 使能 AVB 端点时地址为 awaddr[16:0]；未使能时为 awaddr[11:0]
    G_AXI_ADDR_WIDTH : integer := 17;
    G_AXI_DATA_WIDTH : integer := 32
  );
  port (
    ----------------------------------------------------------------------------
    -- AXI4-Lite 全局信号
    ----------------------------------------------------------------------------
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;                     -- 低电平有效

    ----------------------------------------------------------------------------
    -- 写地址通道
    ----------------------------------------------------------------------------
    s_axi_awaddr  : in  std_logic_vector(G_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;

    ----------------------------------------------------------------------------
    -- 写数据通道
    ----------------------------------------------------------------------------
    s_axi_wdata   : in  std_logic_vector(G_AXI_DATA_WIDTH-1 downto 0);
    s_axi_wstrb   : in  std_logic_vector(G_AXI_DATA_WIDTH/8-1 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;

    ----------------------------------------------------------------------------
    -- 写响应通道
    ----------------------------------------------------------------------------
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;

    ----------------------------------------------------------------------------
    -- 读地址通道
    ----------------------------------------------------------------------------
    s_axi_araddr  : in  std_logic_vector(G_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;

    ----------------------------------------------------------------------------
    -- 读数据通道
    ----------------------------------------------------------------------------
    s_axi_rdata   : out std_logic_vector(G_AXI_DATA_WIDTH-1 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    ----------------------------------------------------------------------------
    -- 用户侧寄存器接口（映射到 MAC 管理寄存器空间）
    ----------------------------------------------------------------------------
    -- 0x0000 : 核版本/ID（只读）
    i_core_id      : in  std_logic_vector(31 downto 0);
    -- 0x0400 : MAC 配置寄存器
    o_mac_cfg      : out std_logic_vector(31 downto 0);
    o_mac_cfg_wr   : out std_logic;                    -- 写该寄存器时输出 1 拍脉冲
    -- 0x0404 : MAC 状态寄存器（只读）
    i_mac_status   : in  std_logic_vector(31 downto 0);
    -- 0x0500 : MDIO Setup Word
    o_mdio_setup   : out std_logic_vector(31 downto 0);
    -- 0x0504 : MDIO Control Word
    o_mdio_ctrl    : out std_logic_vector(31 downto 0);
    o_mdio_init    : out std_logic;                    -- 写 Initiate(bit11)=1 时输出 1 拍脉冲
    -- 0x0508 : MDIO Write Data
    o_mdio_wdata   : out std_logic_vector(31 downto 0);
    -- 0x050C : MDIO Read Data
    i_mdio_rdata   : in  std_logic_vector(15 downto 0);
    i_mdio_ready   : in  std_logic;
    -- 0x0600 / 0x0604 : 中断使能 / 中断状态
    o_irq_enable   : out std_logic_vector(31 downto 0);
    i_irq_status   : in  std_logic_vector(31 downto 0);
    -- 0x0700 / 0x0704 : 帧过滤寄存器（低 32 bit / 高 32 bit）
    o_frame_filter : out std_logic_vector(63 downto 0)
  );
end entity axi_lite_mac_ctrl;

architecture rtl of axi_lite_mac_ctrl is

  ------------------------------------------------------------------------------
  -- AXI 响应编码
  ------------------------------------------------------------------------------
  constant C_RESP_OKAY   : std_logic_vector(1 downto 0) := "00";
  constant C_RESP_SLVERR : std_logic_vector(1 downto 0) := "10";

  ------------------------------------------------------------------------------
  -- 寄存器字地址（字节地址 / 4），与 Table 76 的 MAC 地址映射一致
  ------------------------------------------------------------------------------
  constant C_REG_ID       : integer := 16#000#;   -- 0x0000 核 ID            RO
  constant C_REG_MAC_CFG  : integer := 16#100#;   -- 0x0400 MAC 配置        RW
  constant C_REG_MAC_STAT : integer := 16#101#;   -- 0x0404 MAC 状态        RO
  constant C_REG_MDIO_SET : integer := 16#140#;   -- 0x0500 MDIO Setup      RW
  constant C_REG_MDIO_CTL : integer := 16#141#;   -- 0x0504 MDIO Control    RW/RO/WO
  constant C_REG_MDIO_WD  : integer := 16#142#;   -- 0x0508 MDIO Write Data RW
  constant C_REG_MDIO_RD  : integer := 16#143#;   -- 0x050C MDIO Read Data  RO
  constant C_REG_IRQ_EN   : integer := 16#180#;   -- 0x0600 中断使能        RW
  constant C_REG_IRQ_ST   : integer := 16#181#;   -- 0x0604 中断状态        RO
  constant C_REG_FF_LO    : integer := 16#1C0#;   -- 0x0700 帧过滤低 32 bit RW
  constant C_REG_FF_HI    : integer := 16#1C1#;   -- 0x0704 帧过滤高 32 bit RW

  ------------------------------------------------------------------------------
  -- 写通道状态机
  ------------------------------------------------------------------------------
  type wr_state_t is (WR_IDLE, WR_COMMIT, WR_RESP);
  signal wr_state : wr_state_t;

  signal awready_r : std_logic;
  signal wready_r  : std_logic;
  signal bvalid_r  : std_logic;
  signal bresp_r   : std_logic_vector(1 downto 0);

  -- AW/W 通道分离到达时的暂存
  signal aw_have : std_logic;
  signal w_have  : std_logic;
  signal aw_lat  : std_logic_vector(G_AXI_ADDR_WIDTH-1 downto 0);
  signal wd_lat  : std_logic_vector(G_AXI_DATA_WIDTH-1 downto 0);
  signal ws_lat  : std_logic_vector(G_AXI_DATA_WIDTH/8-1 downto 0);

  -- 写提交信息
  signal commit_addr : std_logic_vector(G_AXI_ADDR_WIDTH-1 downto 0);
  signal commit_data : std_logic_vector(G_AXI_DATA_WIDTH-1 downto 0);
  signal commit_strb : std_logic_vector(G_AXI_DATA_WIDTH/8-1 downto 0);

  ------------------------------------------------------------------------------
  -- 读通道状态机
  ------------------------------------------------------------------------------
  type rd_state_t is (RD_IDLE, RD_RESP);
  signal rd_state : rd_state_t;

  signal arready_r : std_logic;
  signal rvalid_r  : std_logic;
  signal rdata_r   : std_logic_vector(G_AXI_DATA_WIDTH-1 downto 0);
  signal rresp_r   : std_logic_vector(1 downto 0);

  ------------------------------------------------------------------------------
  -- 寄存器实体
  ------------------------------------------------------------------------------
  signal mac_cfg_r     : std_logic_vector(31 downto 0);
  signal mdio_setup_r  : std_logic_vector(31 downto 0);
  signal mdio_ctrl_r   : std_logic_vector(31 downto 0);
  signal mdio_wdata_r  : std_logic_vector(31 downto 0);
  signal irq_en_r      : std_logic_vector(31 downto 0);
  signal ff_lo_r       : std_logic_vector(31 downto 0);
  signal ff_hi_r       : std_logic_vector(31 downto 0);

begin

  ------------------------------------------------------------------------------
  -- 写通道：AW/W 接收 -> 提交（寄存器写入 + 生成响应）-> 等待 BREADY
  ------------------------------------------------------------------------------
  p_wr_channel : process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        wr_state     <= WR_IDLE;
        awready_r    <= '1';
        wready_r     <= '1';
        bvalid_r     <= '0';
        bresp_r      <= C_RESP_OKAY;
        aw_have      <= '0';
        w_have       <= '0';
        aw_lat       <= (others => '0');
        wd_lat       <= (others => '0');
        ws_lat       <= (others => '0');
        commit_addr  <= (others => '0');
        commit_data  <= (others => '0');
        commit_strb  <= (others => '0');
        -- 寄存器复位
        mac_cfg_r    <= (others => '0');
        mdio_setup_r <= (others => '0');
        mdio_ctrl_r  <= (others => '0');
        mdio_wdata_r <= (others => '0');
        irq_en_r     <= (others => '0');
        ff_lo_r      <= (others => '0');
        ff_hi_r      <= (others => '0');
        o_mac_cfg_wr <= '0';
        o_mdio_init  <= '0';
      else
        -- 脉冲型输出默认清零
        o_mac_cfg_wr <= '0';
        o_mdio_init  <= '0';

        case wr_state is

          ----------------------------------------------------------------
          when WR_IDLE =>
            bvalid_r  <= '0';
            -- AW 与 W 通道各自独立给出 READY（已收到的一方不再拉高）
            if aw_have = '0' then
              awready_r <= '1';
            else
              awready_r <= '0';
            end if;
            if w_have = '0' then
              wready_r <= '1';
            else
              wready_r <= '0';
            end if;

            if (aw_have = '0') and (w_have = '0') and
               (s_axi_awvalid = '1') and (s_axi_wvalid = '1') then
              -- 地址与数据同一拍到达：直接提交
              commit_addr <= s_axi_awaddr;
              commit_data <= s_axi_wdata;
              commit_strb <= s_axi_wstrb;
              awready_r   <= '0';
              wready_r    <= '0';
              wr_state    <= WR_COMMIT;

            elsif (aw_have = '0') and (s_axi_awvalid = '1') then
              if w_have = '1' then
                -- 数据先到、地址后到：立即提交
                commit_addr <= s_axi_awaddr;
                commit_data <= wd_lat;
                commit_strb <= ws_lat;
                w_have      <= '0';
                awready_r   <= '0';
                wready_r    <= '0';
                wr_state    <= WR_COMMIT;
              else
                -- 仅地址到达：暂存
                aw_lat    <= s_axi_awaddr;
                aw_have   <= '1';
                awready_r <= '0';
              end if;

            elsif (w_have = '0') and (s_axi_wvalid = '1') then
              if aw_have = '1' then
                -- 地址先到、数据后到：立即提交
                commit_addr <= aw_lat;
                commit_data <= s_axi_wdata;
                commit_strb <= s_axi_wstrb;
                aw_have     <= '0';
                awready_r   <= '0';
                wready_r    <= '0';
                wr_state    <= WR_COMMIT;
              else
                -- 仅数据到达：暂存
                wd_lat   <= s_axi_wdata;
                ws_lat   <= s_axi_wstrb;
                w_have   <= '1';
                wready_r <= '0';
              end if;
            end if;

          ----------------------------------------------------------------
          when WR_COMMIT =>
            -- 唯一的寄存器写入点，保证同一事务只写一次
            awready_r <= '0';
            wready_r  <= '0';
            bvalid_r  <= '1';

            case to_integer(unsigned(commit_addr(G_AXI_ADDR_WIDTH-1 downto 2))) is

              when C_REG_MAC_CFG =>
                bresp_r <= C_RESP_OKAY;
                if commit_strb(0) = '1' then
                  mac_cfg_r(7 downto 0) <= commit_data(7 downto 0);
                end if;
                if commit_strb(1) = '1' then
                  mac_cfg_r(15 downto 8) <= commit_data(15 downto 8);
                end if;
                if commit_strb(2) = '1' then
                  mac_cfg_r(23 downto 16) <= commit_data(23 downto 16);
                end if;
                if commit_strb(3) = '1' then
                  mac_cfg_r(31 downto 24) <= commit_data(31 downto 24);
                end if;
                o_mac_cfg_wr <= '1';

              when C_REG_MDIO_SET =>
                bresp_r <= C_RESP_OKAY;
                if commit_strb(0) = '1' then
                  mdio_setup_r(6 downto 0) <= commit_data(6 downto 0);
                end if;

              when C_REG_MDIO_CTL =>
                bresp_r <= C_RESP_OKAY;
                if commit_strb(0) = '1' then
                  mdio_ctrl_r(6 downto 0) <= commit_data(6 downto 0);
                end if;
                if commit_strb(1) = '1' then
                  mdio_ctrl_r(10 downto 8)  <= commit_data(10 downto 8);
                  mdio_ctrl_r(15 downto 12) <= commit_data(15 downto 12);
                  -- Initiate(bit11) 为 WO 位：写入 1 产生启动脉冲
                  if commit_data(11) = '1' then
                    o_mdio_init <= '1';
                  end if;
                end if;
                if commit_strb(2) = '1' then
                  -- TX_REGAD(bit20:16)
                  mdio_ctrl_r(20 downto 16) <= commit_data(20 downto 16);
                end if;
                if commit_strb(3) = '1' then
                  -- TX_PHYAD(bit28:24)
                  mdio_ctrl_r(28 downto 24) <= commit_data(28 downto 24);
                end if;

              when C_REG_MDIO_WD =>
                bresp_r <= C_RESP_OKAY;
                if commit_strb(0) = '1' then
                  mdio_wdata_r(7 downto 0) <= commit_data(7 downto 0);
                end if;
                if commit_strb(1) = '1' then
                  mdio_wdata_r(15 downto 8) <= commit_data(15 downto 8);
                end if;

              when C_REG_IRQ_EN =>
                bresp_r <= C_RESP_OKAY;
                if commit_strb(0) = '1' then
                  irq_en_r(7 downto 0) <= commit_data(7 downto 0);
                end if;
                if commit_strb(1) = '1' then
                  irq_en_r(15 downto 8) <= commit_data(15 downto 8);
                end if;
                if commit_strb(2) = '1' then
                  irq_en_r(23 downto 16) <= commit_data(23 downto 16);
                end if;
                if commit_strb(3) = '1' then
                  irq_en_r(31 downto 24) <= commit_data(31 downto 24);
                end if;

              when C_REG_FF_LO =>
                bresp_r <= C_RESP_OKAY;
                if commit_strb(0) = '1' then
                  ff_lo_r(7 downto 0) <= commit_data(7 downto 0);
                end if;
                if commit_strb(1) = '1' then
                  ff_lo_r(15 downto 8) <= commit_data(15 downto 8);
                end if;
                if commit_strb(2) = '1' then
                  ff_lo_r(23 downto 16) <= commit_data(23 downto 16);
                end if;
                if commit_strb(3) = '1' then
                  ff_lo_r(31 downto 24) <= commit_data(31 downto 24);
                end if;

              when C_REG_FF_HI =>
                bresp_r <= C_RESP_OKAY;
                if commit_strb(0) = '1' then
                  ff_hi_r(7 downto 0) <= commit_data(7 downto 0);
                end if;
                if commit_strb(1) = '1' then
                  ff_hi_r(15 downto 8) <= commit_data(15 downto 8);
                end if;
                if commit_strb(2) = '1' then
                  ff_hi_r(23 downto 16) <= commit_data(23 downto 16);
                end if;
                if commit_strb(3) = '1' then
                  ff_hi_r(31 downto 24) <= commit_data(31 downto 24);
                end if;

              when C_REG_ID | C_REG_MAC_STAT | C_REG_MDIO_RD | C_REG_IRQ_ST =>
                -- 只读寄存器：写操作非法
                bresp_r <= C_RESP_SLVERR;

              when others =>
                -- 未映射地址（如保留区）：非法访问
                bresp_r <= C_RESP_SLVERR;

            end case;

            aw_have  <= '0';
            w_have   <= '0';
            wr_state <= WR_RESP;

          ----------------------------------------------------------------
          when WR_RESP =>
            bvalid_r  <= '1';
            if s_axi_bready = '1' then
              -- 响应完成，下一拍回到 IDLE 接收新事务
              bvalid_r  <= '0';
              awready_r <= '1';
              wready_r  <= '1';
              wr_state  <= WR_IDLE;
            else
              awready_r <= '0';
              wready_r  <= '0';
            end if;

        end case;
      end if;
    end if;
  end process p_wr_channel;

  ------------------------------------------------------------------------------
  -- 读通道：AR 接收 -> 一拍内给出 RDATA/RRESP -> 等待 RREADY
  ------------------------------------------------------------------------------
  p_rd_channel : process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        rd_state <= RD_IDLE;
        arready_r <= '1';
        rvalid_r  <= '0';
        rdata_r   <= (others => '0');
        rresp_r   <= C_RESP_OKAY;
      else
        case rd_state is

          ----------------------------------------------------------------
          when RD_IDLE =>
            arready_r <= '1';
            rvalid_r  <= '0';

            if s_axi_arvalid = '1' then
              arready_r <= '0';

              case to_integer(unsigned(s_axi_araddr(G_AXI_ADDR_WIDTH-1 downto 2))) is

                when C_REG_ID =>
                  rdata_r <= i_core_id;
                  rresp_r <= C_RESP_OKAY;

                when C_REG_MAC_CFG =>
                  rdata_r <= mac_cfg_r;
                  rresp_r <= C_RESP_OKAY;

                when C_REG_MAC_STAT =>
                  rdata_r <= i_mac_status;
                  rresp_r <= C_RESP_OKAY;

                when C_REG_MDIO_SET =>
                  rdata_r <= mdio_setup_r;
                  rresp_r <= C_RESP_OKAY;

                when C_REG_MDIO_CTL =>
                  -- bit31:29 保留；TX_PHYAD(28:24)；bit23:21 保留；TX_REGAD(20:16)；
                  -- bit11(Initiate, WO) 读 0；bit7(MDIO ready, RO) 实时反映 i_mdio_ready
                  rdata_r <= "000" & mdio_ctrl_r(28 downto 24) & "000" &
                             mdio_ctrl_r(20 downto 16) &
                             mdio_ctrl_r(15 downto 12) & '0' &
                             mdio_ctrl_r(10 downto 8) & i_mdio_ready &
                             mdio_ctrl_r(6 downto 0);
                  rresp_r <= C_RESP_OKAY;

                when C_REG_MDIO_WD =>
                  rdata_r <= mdio_wdata_r;
                  rresp_r <= C_RESP_OKAY;

                when C_REG_MDIO_RD =>
                  rdata_r <= "000000000000000" & i_mdio_ready & i_mdio_rdata;
                  rresp_r <= C_RESP_OKAY;

                when C_REG_IRQ_EN =>
                  rdata_r <= irq_en_r;
                  rresp_r <= C_RESP_OKAY;

                when C_REG_IRQ_ST =>
                  rdata_r <= i_irq_status;
                  rresp_r <= C_RESP_OKAY;

                when C_REG_FF_LO =>
                  rdata_r <= ff_lo_r;
                  rresp_r <= C_RESP_OKAY;

                when C_REG_FF_HI =>
                  rdata_r <= ff_hi_r;
                  rresp_r <= C_RESP_OKAY;

                when others =>
                  rdata_r <= (others => '0');
                  rresp_r <= C_RESP_SLVERR;

              end case;

              rvalid_r <= '1';
              rd_state <= RD_RESP;
            end if;

          ----------------------------------------------------------------
          when RD_RESP =>
            arready_r <= '0';
            rvalid_r  <= '1';
            if s_axi_rready = '1' then
              -- 读数据被接收，下一拍回到 IDLE 接收新读事务
              rvalid_r  <= '0';
              arready_r <= '1';
              rd_state  <= RD_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process p_rd_channel;

  ------------------------------------------------------------------------------
  -- AXI 通道输出
  ------------------------------------------------------------------------------
  s_axi_awready <= awready_r;
  s_axi_wready  <= wready_r;
  s_axi_bvalid  <= bvalid_r;
  s_axi_bresp   <= bresp_r;

  s_axi_arready <= arready_r;
  s_axi_rvalid  <= rvalid_r;
  s_axi_rdata   <= rdata_r;
  s_axi_rresp   <= rresp_r;

  ------------------------------------------------------------------------------
  -- 用户侧寄存器输出
  ------------------------------------------------------------------------------
  o_mac_cfg      <= mac_cfg_r;
  o_mdio_setup   <= mdio_setup_r;
  -- 输出控制字：bit7 实时反映 MDIO ready，bit11 保持 0（启动用脉冲）
  o_mdio_ctrl    <= "000" & mdio_ctrl_r(28 downto 24) & "000" &
                    mdio_ctrl_r(20 downto 16) &
                    mdio_ctrl_r(15 downto 12) & '0' &
                    mdio_ctrl_r(10 downto 8) & i_mdio_ready &
                    mdio_ctrl_r(6 downto 0);
  o_mdio_wdata   <= mdio_wdata_r;
  o_irq_enable   <= irq_en_r;
  o_frame_filter <= ff_hi_r & ff_lo_r;

end architecture rtl;
