--------------------------------------------------------------------------------
-- 文件名   : tb_axi_lite_mac_ctrl.vhd
-- 功能     : AXI4-Lite 读写控制模块自检测试平台（Testbench）
--
-- 验证内容 :
--   T1  复位后读取核 ID（RO 寄存器）
--   T2  MAC 配置寄存器 32 bit 全字写/读回
--   T3  WSTRB 字节选通写（仅写 bit31:24）
--   T4  MDIO Setup 寄存器写/读（保留位读 0）
--   T5  MDIO Control 寄存器写/读 + Initiate(bit11) 启动脉冲、
--       MDIO ready(bit7) 只读实时反映
--   T6  MDIO Write Data 写/读
--   T7  MDIO Read Data 只读（bit16 ready + 数据）
--   T8  中断使能写/读，中断状态只读
--   T9  帧过滤寄存器（两字）写/读 + 64 bit 输出
--   T10 未映射地址写/读 -> SLVERR
--   T11 只读寄存器写 -> SLVERR
--   T12 AW/W 分离到达（先地址后数据）
--   T13 AW/W 分离到达（先数据后地址）
--   T14 BREADY 延迟 4 拍，检查 BVALID 保持
--   T15 RREADY 延迟 3 拍，检查 RVALID/RDATA 保持
--   T16 背靠背连续写
--
-- 运行     : 见 sim/run_xsim.bat 或 README.md
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- VHDL-2008：用于在测试结束时正常结束仿真
library std;
use std.env.all;

entity tb_axi_lite_mac_ctrl is
end entity tb_axi_lite_mac_ctrl;

architecture sim of tb_axi_lite_mac_ctrl is

  constant C_CLK_PERIOD : time := 10 ns;

  constant C_RESP_OKAY   : std_logic_vector(1 downto 0) := "00";
  constant C_RESP_SLVERR : std_logic_vector(1 downto 0) := "10";

  ------------------------------------------------------------------------------
  -- AXI4-Lite 主机侧信号
  ------------------------------------------------------------------------------
  signal clk    : std_logic := '0';
  signal rstn   : std_logic := '0';

  signal awaddr  : std_logic_vector(16 downto 0) := (others => '0');
  signal awvalid : std_logic := '0';
  signal awready : std_logic;

  signal wdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb   : std_logic_vector(3 downto 0)  := (others => '0');
  signal wvalid  : std_logic := '0';
  signal wready  : std_logic;

  signal bresp   : std_logic_vector(1 downto 0);
  signal bvalid  : std_logic;
  signal bready  : std_logic := '0';

  signal araddr  : std_logic_vector(16 downto 0) := (others => '0');
  signal arvalid : std_logic := '0';
  signal arready : std_logic;

  signal rdata   : std_logic_vector(31 downto 0);
  signal rresp   : std_logic_vector(1 downto 0);
  signal rvalid  : std_logic;
  signal rready  : std_logic := '0';

  ------------------------------------------------------------------------------
  -- 用户侧寄存器输入
  ------------------------------------------------------------------------------
  signal core_id    : std_logic_vector(31 downto 0) := x"4D414331";  -- "MAC1"
  signal mac_status : std_logic_vector(31 downto 0) := x"00000005";
  signal mdio_rdata : std_logic_vector(15 downto 0) := x"BEEF";
  signal mdio_ready : std_logic := '1';
  signal irq_status : std_logic_vector(31 downto 0) := x"00000002";

  ------------------------------------------------------------------------------
  -- 用户侧寄存器输出
  ------------------------------------------------------------------------------
  signal o_mac_cfg       : std_logic_vector(31 downto 0);
  signal o_mac_cfg_wr    : std_logic;
  signal o_mdio_setup    : std_logic_vector(31 downto 0);
  signal o_mdio_ctrl     : std_logic_vector(31 downto 0);
  signal o_mdio_init     : std_logic;
  signal o_mdio_wdata    : std_logic_vector(31 downto 0);
  signal o_irq_enable    : std_logic_vector(31 downto 0);
  signal o_frame_filter  : std_logic_vector(63 downto 0);

  ------------------------------------------------------------------------------
  -- 辅助信号
  ------------------------------------------------------------------------------
  signal pulse_clr       : std_logic := '0';
  signal mac_cfg_wr_seen : std_logic := '0';
  signal mdio_init_seen  : std_logic := '0';
  signal sim_done        : std_logic := '0';

  ------------------------------------------------------------------------------
  -- 十六进制显示函数（兼容 VHDL-93，避免依赖 to_hstring）
  ------------------------------------------------------------------------------
  function to_hex(constant v : std_logic_vector) return string is
    constant H   : string := "0123456789ABCDEF";
    constant LEN : integer := (v'length + 3) / 4;
    variable res : string(1 to LEN) := (others => '0');
    variable b   : integer;
  begin
    for i in 0 to LEN-1 loop
      b := 0;
      for j in 0 to 3 loop
        if (i*4 + j) < v'length then
          if v(i*4 + j) = '1' then
            b := b + 2**j;
          end if;
        end if;
      end loop;
      res(LEN - i) := H(b + 1);
    end loop;
    return "0x" & res;
  end function to_hex;

begin

  ------------------------------------------------------------------------------
  -- 时钟
  ------------------------------------------------------------------------------
  p_clk : process
  begin
    clk <= '0';
    wait for C_CLK_PERIOD / 2;
    clk <= '1';
    wait for C_CLK_PERIOD / 2;
  end process p_clk;

  ------------------------------------------------------------------------------
  -- DUT
  ------------------------------------------------------------------------------
  u_dut : entity work.axi_lite_mac_ctrl
    generic map (
      G_AXI_ADDR_WIDTH => 17,
      G_AXI_DATA_WIDTH => 32
    )
    port map (
      s_axi_aclk    => clk,
      s_axi_aresetn => rstn,

      s_axi_awaddr  => awaddr,
      s_axi_awvalid => awvalid,
      s_axi_awready => awready,

      s_axi_wdata   => wdata,
      s_axi_wstrb   => wstrb,
      s_axi_wvalid  => wvalid,
      s_axi_wready  => wready,

      s_axi_bresp   => bresp,
      s_axi_bvalid  => bvalid,
      s_axi_bready  => bready,

      s_axi_araddr  => araddr,
      s_axi_arvalid => arvalid,
      s_axi_arready => arready,

      s_axi_rdata   => rdata,
      s_axi_rresp   => rresp,
      s_axi_rvalid  => rvalid,
      s_axi_rready  => rready,

      i_core_id      => core_id,
      o_mac_cfg      => o_mac_cfg,
      o_mac_cfg_wr   => o_mac_cfg_wr,
      i_mac_status   => mac_status,
      o_mdio_setup   => o_mdio_setup,
      o_mdio_ctrl    => o_mdio_ctrl,
      o_mdio_init    => o_mdio_init,
      o_mdio_wdata   => o_mdio_wdata,
      i_mdio_rdata   => mdio_rdata,
      i_mdio_ready   => mdio_ready,
      o_irq_enable   => o_irq_enable,
      i_irq_status   => irq_status,
      o_frame_filter => o_frame_filter
    );

  ------------------------------------------------------------------------------
  -- 脉冲输出监测
  ------------------------------------------------------------------------------
  p_pulse_mon : process(clk)
  begin
    if rising_edge(clk) then
      if pulse_clr = '1' then
        mac_cfg_wr_seen <= '0';
        mdio_init_seen  <= '0';
      else
        if o_mac_cfg_wr = '1' then
          mac_cfg_wr_seen <= '1';
        end if;
        if o_mdio_init = '1' then
          mdio_init_seen <= '1';
        end if;
      end if;
    end if;
  end process p_pulse_mon;

  ------------------------------------------------------------------------------
  -- 超时看门狗
  ------------------------------------------------------------------------------
  p_watchdog : process
  begin
    wait for 200 us;
    if sim_done /= '1' then
      report "TIMEOUT: simulation did not finish normally" severity failure;
    end if;
    wait;
  end process p_watchdog;

  ------------------------------------------------------------------------------
  -- 激励与自检
  ------------------------------------------------------------------------------
  p_stim : process

    variable v_errors : integer := 0;
    variable v_checks : integer := 0;
    variable v_data   : std_logic_vector(31 downto 0);
    variable v_resp   : std_logic_vector(1 downto 0);

    --------------------------------------------------------------------------
    -- 比较并记录结果
    --------------------------------------------------------------------------
    procedure check(constant name : in string;
                    constant got  : in std_logic_vector;
                    constant exp  : in std_logic_vector) is
    begin
      v_checks := v_checks + 1;
      if got /= exp then
        report "FAIL [" & name & "] got " & to_hex(got) &
               " expect " & to_hex(exp) severity error;
        v_errors := v_errors + 1;
      else
        report "PASS [" & name & "] = " & to_hex(got) severity note;
      end if;
    end procedure check;

    --------------------------------------------------------------------------
    -- AXI4-Lite 主机写事务
    --   mode = 0 : AW 与 W 同拍发起
    --   mode = 1 : 先 AW，后 W
    --   mode = 2 : 先 W，后 AW
    --   bhold    : BREADY 延迟拍数（期间检查 BVALID 保持）
    --------------------------------------------------------------------------
    procedure axi_write(constant addr  : in integer;
                        constant data  : in std_logic_vector(31 downto 0);
                        constant strb  : in std_logic_vector(3 downto 0);
                        constant mode  : in integer;
                        constant bhold : in integer;
                        resp           : out std_logic_vector(1 downto 0)) is
    begin
      awaddr <= std_logic_vector(to_unsigned(addr, 17));

      if mode = 1 then
        awvalid <= '1';
        wait until rising_edge(clk);
        while awready /= '1' loop
          wait until rising_edge(clk);
        end loop;
        awvalid <= '0';

        wdata <= data;
        wstrb <= strb;
        wvalid <= '1';
        wait until rising_edge(clk);
        while wready /= '1' loop
          wait until rising_edge(clk);
        end loop;
        wvalid <= '0';

      elsif mode = 2 then
        wdata <= data;
        wstrb <= strb;
        wvalid <= '1';
        wait until rising_edge(clk);
        while wready /= '1' loop
          wait until rising_edge(clk);
        end loop;
        wvalid <= '0';

        awvalid <= '1';
        wait until rising_edge(clk);
        while awready /= '1' loop
          wait until rising_edge(clk);
        end loop;
        awvalid <= '0';

      else
        wdata  <= data;
        wstrb  <= strb;
        awvalid <= '1';
        wvalid  <= '1';
        loop
          wait until rising_edge(clk);
          exit when (awready = '1') and (wready = '1');
        end loop;
        awvalid <= '0';
        wvalid  <= '0';
      end if;

      -- 等待写响应
      while bvalid /= '1' loop
        wait until rising_edge(clk);
      end loop;
      resp := bresp;

      -- BREADY 延迟期间 BVALID 必须保持
      for i in 1 to bhold loop
        assert bvalid = '1'
          report "FAIL: BVALID dropped while BREADY is low" severity error;
        if bvalid /= '1' then
          v_errors := v_errors + 1;
        end if;
        wait until rising_edge(clk);
      end loop;

      bready <= '1';
      wait until rising_edge(clk);
      bready <= '0';
    end procedure axi_write;

    --------------------------------------------------------------------------
    -- AXI4-Lite 主机读事务（rhold 为 RREADY 延迟拍数）
    --------------------------------------------------------------------------
    procedure axi_read(constant addr  : in integer;
                       constant rhold : in integer;
                       data           : out std_logic_vector(31 downto 0);
                       resp           : out std_logic_vector(1 downto 0)) is
    begin
      araddr <= std_logic_vector(to_unsigned(addr, 17));
      arvalid <= '1';
      wait until rising_edge(clk);
      while arready /= '1' loop
        wait until rising_edge(clk);
      end loop;
      arvalid <= '0';

      while rvalid /= '1' loop
        wait until rising_edge(clk);
      end loop;
      data := rdata;
      resp := rresp;

      -- RREADY 延迟期间 RVALID/RDATA 必须保持
      for i in 1 to rhold loop
        assert rvalid = '1'
          report "FAIL: RVALID dropped while RREADY is low" severity error;
        assert rdata = data
          report "FAIL: RDATA changed while waiting RREADY" severity error;
        if rvalid /= '1' then
          v_errors := v_errors + 1;
        end if;
        wait until rising_edge(clk);
      end loop;

      rready <= '1';
      wait until rising_edge(clk);
      rready <= '0';
    end procedure axi_read;

    --------------------------------------------------------------------------
    procedure clear_pulses is
    begin
      pulse_clr <= '1';
      wait until rising_edge(clk);
      pulse_clr <= '0';
      wait until rising_edge(clk);
    end procedure clear_pulses;

  begin
    --------------------------------------------------------------------------
    -- 复位
    --------------------------------------------------------------------------
    rstn    <= '0';
    awvalid <= '0';
    wvalid  <= '0';
    bready  <= '0';
    arvalid <= '0';
    rready  <= '0';
    wait for 100 ns;
    wait until rising_edge(clk);
    rstn <= '1';
    wait until rising_edge(clk);

    --------------------------------------------------------------------------
    -- T1 读取核 ID
    --------------------------------------------------------------------------
    axi_read(16#00000#, 0, v_data, v_resp);
    check("T1 core_id   ", v_data, x"4D414331");
    check("T1 resp      ", v_resp, C_RESP_OKAY);

    --------------------------------------------------------------------------
    -- T2 MAC 配置寄存器全字写/读
    --------------------------------------------------------------------------
    clear_pulses;
    axi_write(16#00400#, x"A5A5A5A5", "1111", 0, 0, v_resp);
    check("T2 resp      ", v_resp, C_RESP_OKAY);
    check("T2 cfg out   ", o_mac_cfg, x"A5A5A5A5");
    check("T2 cfg_wr pls", (0 => mac_cfg_wr_seen), "1");

    axi_read(16#00400#, 0, v_data, v_resp);
    check("T2 cfg rd    ", v_data, x"A5A5A5A5");

    --------------------------------------------------------------------------
    -- T3 字节选通：仅更新 bit31:24
    --------------------------------------------------------------------------
    axi_write(16#00400#, x"12345678", "1000", 0, 0, v_resp);
    check("T3 resp      ", v_resp, C_RESP_OKAY);
    axi_read(16#00400#, 0, v_data, v_resp);
    check("T3 strb rd   ", v_data, x"12A5A5A5");

    --------------------------------------------------------------------------
    -- T4 MDIO Setup (0x0500)：bit6 使能、bit5:0 分频
    --------------------------------------------------------------------------
    axi_write(16#00500#, x"00000047", "1111", 0, 0, v_resp);
    check("T4 resp      ", v_resp, C_RESP_OKAY);
    check("T4 setup out ", o_mdio_setup, x"00000047");
    axi_read(16#00500#, 0, v_data, v_resp);
    check("T4 setup rd  ", v_data, x"00000047");

    --------------------------------------------------------------------------
    -- T5 MDIO Control (0x0504)：PHYAD=1, REGAD=2, OP=01, Initiate=1
    --------------------------------------------------------------------------
    clear_pulses;
    axi_write(16#00504#, x"01024800", "1111", 0, 0, v_resp);
    check("T5 resp      ", v_resp, C_RESP_OKAY);
    check("T5 init pls  ", (0 => mdio_init_seen), "1");
    axi_read(16#00504#, 0, v_data, v_resp);
    -- bit11 为 WO 读 0；bit7 为只读 ready=1
    check("T5 ctrl rd   ", v_data, x"01024080");
    check("T5 ctrl out  ", o_mdio_ctrl, x"01024080");

    --------------------------------------------------------------------------
    -- T6 MDIO Write Data (0x0508)
    --------------------------------------------------------------------------
    axi_write(16#00508#, x"00001234", "1111", 0, 0, v_resp);
    check("T6 resp      ", v_resp, C_RESP_OKAY);
    axi_read(16#00508#, 0, v_data, v_resp);
    check("T6 wdata rd  ", v_data, x"00001234");
    check("T6 wdata out ", o_mdio_wdata, x"00001234");

    --------------------------------------------------------------------------
    -- T7 MDIO Read Data (0x050C)：只读，bit16 为 ready
    --------------------------------------------------------------------------
    axi_read(16#0050C#, 0, v_data, v_resp);
    check("T7 rdata rd  ", v_data, x"0001BEEF");
    check("T7 resp      ", v_resp, C_RESP_OKAY);

    --------------------------------------------------------------------------
    -- T8 中断使能 / 中断状态
    --------------------------------------------------------------------------
    axi_write(16#00600#, x"FFFF0001", "1111", 0, 0, v_resp);
    check("T8 resp      ", v_resp, C_RESP_OKAY);
    axi_read(16#00600#, 0, v_data, v_resp);
    check("T8 irqen rd  ", v_data, x"FFFF0001");
    check("T8 irqen out ", o_irq_enable, x"FFFF0001");

    axi_read(16#00604#, 0, v_data, v_resp);
    check("T8 irqst rd  ", v_data, x"00000002");

    --------------------------------------------------------------------------
    -- T9 帧过滤寄存器（两字）与 64 bit 输出
    --------------------------------------------------------------------------
    axi_write(16#00700#, x"11223344", "1111", 0, 0, v_resp);
    check("T9 resp      ", v_resp, C_RESP_OKAY);
    axi_write(16#00704#, x"55667788", "1111", 0, 0, v_resp);
    check("T9 resp      ", v_resp, C_RESP_OKAY);
    axi_read(16#00700#, 0, v_data, v_resp);
    check("T9 ff_lo rd  ", v_data, x"11223344");
    axi_read(16#00704#, 0, v_data, v_resp);
    check("T9 ff_hi rd  ", v_data, x"55667788");
    check("T9 ff64 out  ", o_frame_filter, x"5566778811223344");

    --------------------------------------------------------------------------
    -- T10 未映射地址（保留区 0x0800）读写均返回 SLVERR
    --------------------------------------------------------------------------
    axi_write(16#00800#, x"00000001", "1111", 0, 0, v_resp);
    check("T10 wr resp  ", v_resp, C_RESP_SLVERR);
    axi_read(16#00800#, 0, v_data, v_resp);
    check("T10 rd resp  ", v_resp, C_RESP_SLVERR);
    check("T10 rd data  ", v_data, x"00000000");

    --------------------------------------------------------------------------
    -- T11 对只读寄存器写（核 ID 0x0000）返回 SLVERR 且内容不变
    --------------------------------------------------------------------------
    axi_write(16#00000#, x"DEADBEEF", "1111", 0, 0, v_resp);
    check("T11 wr resp  ", v_resp, C_RESP_SLVERR);
    axi_read(16#00000#, 0, v_data, v_resp);
    check("T11 id keep  ", v_data, x"4D414331");

    --------------------------------------------------------------------------
    -- T12 AW/W 分离（先地址后数据）
    --------------------------------------------------------------------------
    axi_write(16#00400#, x"0F0F0F0F", "1111", 1, 0, v_resp);
    check("T12 resp     ", v_resp, C_RESP_OKAY);
    axi_read(16#00400#, 0, v_data, v_resp);
    check("T12 rd       ", v_data, x"0F0F0F0F");

    --------------------------------------------------------------------------
    -- T13 AW/W 分离（先数据后地址）
    --------------------------------------------------------------------------
    axi_write(16#00400#, x"00FF00FF", "1111", 2, 0, v_resp);
    check("T13 resp     ", v_resp, C_RESP_OKAY);
    axi_read(16#00400#, 0, v_data, v_resp);
    check("T13 rd       ", v_data, x"00FF00FF");

    --------------------------------------------------------------------------
    -- T14 BREADY 延迟 4 拍（检查 BVALID 保持 + 字节选通半边写）
    --------------------------------------------------------------------------
    axi_write(16#00400#, x"0011AABB", "0011", 0, 4, v_resp);
    check("T14 resp     ", v_resp, C_RESP_OKAY);
    axi_read(16#00400#, 0, v_data, v_resp);
    check("T14 strb rd  ", v_data, x"00FFAABB");

    --------------------------------------------------------------------------
    -- T15 RREADY 延迟 3 拍
    --------------------------------------------------------------------------
    axi_read(16#00400#, 3, v_data, v_resp);
    check("T15 rd       ", v_data, x"00FFAABB");
    check("T15 resp     ", v_resp, C_RESP_OKAY);

    --------------------------------------------------------------------------
    -- T16 背靠背连续写（每笔间隔 1 拍空闲）
    --------------------------------------------------------------------------
    axi_write(16#00500#, x"00000007", "1111", 0, 0, v_resp);
    check("T16 resp     ", v_resp, C_RESP_OKAY);
    axi_write(16#00508#, x"0000CAFE", "1111", 0, 0, v_resp);
    check("T16 resp     ", v_resp, C_RESP_OKAY);
    axi_write(16#00504#, x"00002000", "1111", 0, 0, v_resp);
    check("T16 resp     ", v_resp, C_RESP_OKAY);
    axi_read(16#00500#, 0, v_data, v_resp);
    check("T16 mdio set ", v_data, x"00000007");
    axi_read(16#00508#, 0, v_data, v_resp);
    check("T16 mdio wd  ", v_data, x"0000CAFE");
    axi_read(16#00504#, 0, v_data, v_resp);
    -- 写入 0x2000 表示 TX_OP=10(读)；读回时 bit7 反映 ready=1，故为 0x2080
    check("T16 mdio ctl ", v_data, x"00002080");

    --------------------------------------------------------------------------
    -- 汇总
    --------------------------------------------------------------------------
    if v_errors = 0 then
      report "==========================================================" severity note;
      report "  ALL TESTS PASSED  (checks = " & integer'image(v_checks) & ")" severity note;
      report "==========================================================" severity note;
    else
      report "  TESTS FAILED: " & integer'image(v_errors) & " error(s) / " &
             integer'image(v_checks) & " checks" severity failure;
    end if;

    sim_done <= '1';
    -- VHDL-2008：显式结束仿真，便于 xsim / ModelSim 以批处理方式退出
    finish;
  end process p_stim;

end architecture sim;
