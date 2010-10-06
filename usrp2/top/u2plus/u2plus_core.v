// ////////////////////////////////////////////////////////////////////////////////
// Module Name:    u2_core
// ////////////////////////////////////////////////////////////////////////////////

module u2plus_core
  (// Clocks
   input dsp_clk,
   input wb_clk,
   output clock_ready,
   input clk_to_mac,
   input pps_in,
   
   // Misc, debug
   output [7:0] leds,
   output [31:0] debug,
   output [1:0] debug_clk,

   // Expansion
   input exp_pps_in,
   output exp_pps_out,
   
   // GMII
   //   GMII-CTRL
   input GMII_COL,
   input GMII_CRS,

   //   GMII-TX
   output [7:0] GMII_TXD,
   output GMII_TX_EN,
   output GMII_TX_ER,
   output GMII_GTX_CLK,
   input GMII_TX_CLK,  // 100mbps clk

   //   GMII-RX
   input [7:0] GMII_RXD,
   input GMII_RX_CLK,
   input GMII_RX_DV,
   input GMII_RX_ER,

   //   GMII-Management
   inout MDIO,
   output MDC,
   input PHY_INTn,   // open drain
   output PHY_RESETn,

   // SERDES
   output ser_enable,
   output ser_prbsen,
   output ser_loopen,
   output ser_rx_en,
   
   output ser_tx_clk,
   output [15:0] ser_t,
   output ser_tklsb,
   output ser_tkmsb,

   input ser_rx_clk,
   input [15:0] ser_r,
   input ser_rklsb,
   input ser_rkmsb,
   
   input por,
   output config_success,
   
   // ADC
   input [13:0] adc_a,
   input adc_ovf_a,
   output adc_on_a,
   output adc_oe_a,
   
   input [13:0] adc_b,
   input adc_ovf_b,
   output adc_on_b,
   output adc_oe_b,
   
   // DAC
   output [15:0] dac_a,
   output [15:0] dac_b,

   // I2C
   input scl_pad_i,
   output scl_pad_o,
   output scl_pad_oen_o,
   input sda_pad_i,
   output sda_pad_o,
   output sda_pad_oen_o,
   
   // Clock Gen Control
   output [1:0] clk_en,
   output [1:0] clk_sel,
   input clk_func,        // FIXME is an input to control the 9510
   input clk_status,

   // Generic SPI
   output sclk,
   output mosi,
   input miso,
   output sen_clk,
   output sen_dac,
   output sen_adc,
   output sen_tx_db,
   output sen_tx_adc,
   output sen_tx_dac,
   output sen_rx_db,
   output sen_rx_adc,
   output sen_rx_dac,
   
   // GPIO to DBoards
   inout [15:0] io_tx,
   inout [15:0] io_rx,

   // External RAM
   inout [35:0] RAM_D,
   output [20:0] RAM_A,
   output RAM_CE1n,
   output RAM_CENn,
   output RAM_CLK,
   output RAM_WEn,
   output RAM_OEn,
   output RAM_LDn,
   
   // Debug stuff
   output [3:0] uart_tx_o, 
   input [3:0] uart_rx_i,
   output [3:0] uart_baud_o,
   input sim_mode,
   input [3:0] clock_divider,
   input button,
   
   output spiflash_cs, output spiflash_clk, input spiflash_miso, output spiflash_mosi
   );

   localparam SR_BUF_POOL = 64;   // Uses 1 reg
   localparam SR_UDP_SM   = 96;   // 64 regs
   localparam SR_RX_DSP   = 160;  // 16
   localparam SR_RX_CTRL  = 176;  // 16
   localparam SR_TIME64   = 192;  //  3
   localparam SR_SIMTIMER = 198;  //  2
   localparam SR_TX_DSP   = 208;  // 16
   localparam SR_TX_CTRL  = 224;  // 16

   // FIFO Sizes, 9 = 512 lines, 10 = 1024, 11 = 2048
   // all (most?) are 36 bits wide, so 9 is 1 BRAM, 10 is 2, 11 is 4 BRAMs
   localparam DSP_TX_FIFOSIZE = 10;
   localparam DSP_RX_FIFOSIZE = 10;
   localparam ETH_TX_FIFOSIZE = 10;
   localparam ETH_RX_FIFOSIZE = 11;
   localparam SERDES_TX_FIFOSIZE = 9;
   localparam SERDES_RX_FIFOSIZE = 9;  // RX currently doesn't use a fifo?
   
   wire [7:0] 	set_addr, set_addr_dsp;
   wire [31:0] 	set_data, set_data_dsp;
   wire 	set_stb, set_stb_dsp;
   
   wire 	wb_rst, dsp_rst;

   wire [31:0] 	status, status_b0, status_b1, status_b2, status_b3, status_b4, status_b5, status_b6, status_b7;
   wire 	bus_error, spi_int, i2c_int, pps_int, onetime_int, periodic_int, buffer_int;
   wire 	proc_int, overrun, underrun;
   wire [3:0] 	uart_tx_int, uart_rx_int;

   wire [31:0] 	debug_gpio_0, debug_gpio_1;
   wire [31:0] 	atr_lines;

   wire [31:0] 	debug_rx, debug_mac, debug_mac0, debug_mac1, debug_tx_dsp, debug_txc,
		debug_serdes0, debug_serdes1, debug_serdes2, debug_rx_dsp, debug_udp;

   wire [15:0] 	ser_rx_occ, ser_tx_occ, dsp_rx_occ, dsp_tx_occ, eth_rx_occ, eth_tx_occ, eth_rx_occ2;
   wire 	ser_rx_full, ser_tx_full, dsp_rx_full, dsp_tx_full, eth_rx_full, eth_tx_full, eth_rx_full2;
   wire 	ser_rx_empty, ser_tx_empty, dsp_rx_empty, dsp_tx_empty, eth_rx_empty, eth_tx_empty, eth_rx_empty2;
	
   wire 	serdes_link_up;
   wire 	epoch;
   wire [31:0] 	irq;
   wire [63:0] 	vita_time;
   wire 	run_rx, run_tx;
   
   // ///////////////////////////////////////////////////////////////////////////////////////////////
   // Wishbone Single Master INTERCON
   localparam 	dw = 32;  // Data bus width
   localparam 	aw = 16;  // Address bus width, for byte addressibility, 16 = 64K byte memory space
   localparam	sw = 4;   // Select width -- 32-bit data bus with 8-bit granularity.  
   
   wire [dw-1:0] m0_dat_o, m0_dat_i;
   wire [dw-1:0] s0_dat_o, s1_dat_o, s0_dat_i, s1_dat_i, s2_dat_o, s3_dat_o, s2_dat_i, s3_dat_i,
		 s4_dat_o, s5_dat_o, s4_dat_i, s5_dat_i, s6_dat_o, s7_dat_o, s6_dat_i, s7_dat_i,
		 s8_dat_o, s9_dat_o, s8_dat_i, s9_dat_i, sa_dat_o, sa_dat_i, sb_dat_i, sb_dat_o,
		 sc_dat_i, sc_dat_o, sd_dat_i, sd_dat_o, se_dat_i, se_dat_o, sf_dat_i, sf_dat_o;
   wire [aw-1:0] m0_adr,s0_adr,s1_adr,s2_adr,s3_adr,s4_adr,s5_adr,s6_adr,s7_adr,s8_adr,s9_adr,sa_adr,sb_adr,sc_adr, sd_adr, se_adr, sf_adr;
   wire [sw-1:0] m0_sel,s0_sel,s1_sel,s2_sel,s3_sel,s4_sel,s5_sel,s6_sel,s7_sel,s8_sel,s9_sel,sa_sel,sb_sel,sc_sel, sd_sel, se_sel, sf_sel;
   wire 	 m0_ack,s0_ack,s1_ack,s2_ack,s3_ack,s4_ack,s5_ack,s6_ack,s7_ack,s8_ack,s9_ack,sa_ack,sb_ack,sc_ack, sd_ack, se_ack, sf_ack;
   wire 	 m0_stb,s0_stb,s1_stb,s2_stb,s3_stb,s4_stb,s5_stb,s6_stb,s7_stb,s8_stb,s9_stb,sa_stb,sb_stb,sc_stb, sd_stb, se_stb, sf_stb;
   wire 	 m0_cyc,s0_cyc,s1_cyc,s2_cyc,s3_cyc,s4_cyc,s5_cyc,s6_cyc,s7_cyc,s8_cyc,s9_cyc,sa_cyc,sb_cyc,sc_cyc, sd_cyc, se_cyc, sf_cyc;
   wire 	 m0_err, m0_rty;
   wire 	 m0_we,s0_we,s1_we,s2_we,s3_we,s4_we,s5_we,s6_we,s7_we,s8_we,s9_we,sa_we,sb_we,sc_we,sd_we,se_we,sf_we;
   
   wb_1master #(.decode_w(8),
		.s0_addr(8'b0000_0000),.s0_mask(8'b1110_0000),  // 0-8K, Boot RAM
		.s1_addr(8'b0100_0000),.s1_mask(8'b1100_0000),  // 16K-32K, Buffer Pool
 		.s2_addr(8'b0011_0000),.s2_mask(8'b1111_1111),  // SPI
		.s3_addr(8'b0011_0001),.s3_mask(8'b1111_1111),  // I2C
		.s4_addr(8'b0011_0010),.s4_mask(8'b1111_1111),  // GPIO
		.s5_addr(8'b0011_0011),.s5_mask(8'b1111_1111),  // Readback
		.s6_addr(8'b0011_0100),.s6_mask(8'b1111_1111),  // Ethernet MAC
		.s7_addr(8'b0010_0000),.s7_mask(8'b1111_0000),  // 8-12K, Settings Bus (only uses 1K)
		.s8_addr(8'b0011_0101),.s8_mask(8'b1111_1111),  // PIC
		.s9_addr(8'b0011_0110),.s9_mask(8'b1111_1111),  // Unused
		.sa_addr(8'b0011_0111),.sa_mask(8'b1111_1111),  // UART
		.sb_addr(8'b0011_1000),.sb_mask(8'b1111_1111),  // ATR
		.sc_addr(8'b0011_1001),.sc_mask(8'b1111_1111),  // Unused
		.sd_addr(8'b0011_1010),.sd_mask(8'b1111_1111),  // ICAP
		.se_addr(8'b0011_1011),.se_mask(8'b1111_1111),  // SPI Flash
		.sf_addr(8'b1000_0000),.sf_mask(8'b1000_0000),  // 32-64K, Main RAM
		.dw(dw),.aw(aw),.sw(sw)) wb_1master
     (.clk_i(wb_clk),.rst_i(wb_rst),       
      .m0_dat_o(m0_dat_o),.m0_ack_o(m0_ack),.m0_err_o(m0_err),.m0_rty_o(m0_rty),.m0_dat_i(m0_dat_i),
      .m0_adr_i(m0_adr),.m0_sel_i(m0_sel),.m0_we_i(m0_we),.m0_cyc_i(m0_cyc),.m0_stb_i(m0_stb),
      .s0_dat_o(s0_dat_o),.s0_adr_o(s0_adr),.s0_sel_o(s0_sel),.s0_we_o	(s0_we),.s0_cyc_o(s0_cyc),.s0_stb_o(s0_stb),
      .s0_dat_i(s0_dat_i),.s0_ack_i(s0_ack),.s0_err_i(0),.s0_rty_i(0),
      .s1_dat_o(s1_dat_o),.s1_adr_o(s1_adr),.s1_sel_o(s1_sel),.s1_we_o	(s1_we),.s1_cyc_o(s1_cyc),.s1_stb_o(s1_stb),
      .s1_dat_i(s1_dat_i),.s1_ack_i(s1_ack),.s1_err_i(0),.s1_rty_i(0),
      .s2_dat_o(s2_dat_o),.s2_adr_o(s2_adr),.s2_sel_o(s2_sel),.s2_we_o	(s2_we),.s2_cyc_o(s2_cyc),.s2_stb_o(s2_stb),
      .s2_dat_i(s2_dat_i),.s2_ack_i(s2_ack),.s2_err_i(0),.s2_rty_i(0),
      .s3_dat_o(s3_dat_o),.s3_adr_o(s3_adr),.s3_sel_o(s3_sel),.s3_we_o	(s3_we),.s3_cyc_o(s3_cyc),.s3_stb_o(s3_stb),
      .s3_dat_i(s3_dat_i),.s3_ack_i(s3_ack),.s3_err_i(0),.s3_rty_i(0),
      .s4_dat_o(s4_dat_o),.s4_adr_o(s4_adr),.s4_sel_o(s4_sel),.s4_we_o	(s4_we),.s4_cyc_o(s4_cyc),.s4_stb_o(s4_stb),
      .s4_dat_i(s4_dat_i),.s4_ack_i(s4_ack),.s4_err_i(0),.s4_rty_i(0),
      .s5_dat_o(s5_dat_o),.s5_adr_o(s5_adr),.s5_sel_o(s5_sel),.s5_we_o	(s5_we),.s5_cyc_o(s5_cyc),.s5_stb_o(s5_stb),
      .s5_dat_i(s5_dat_i),.s5_ack_i(s5_ack),.s5_err_i(0),.s5_rty_i(0),
      .s6_dat_o(s6_dat_o),.s6_adr_o(s6_adr),.s6_sel_o(s6_sel),.s6_we_o	(s6_we),.s6_cyc_o(s6_cyc),.s6_stb_o(s6_stb),
      .s6_dat_i(s6_dat_i),.s6_ack_i(s6_ack),.s6_err_i(0),.s6_rty_i(0),
      .s7_dat_o(s7_dat_o),.s7_adr_o(s7_adr),.s7_sel_o(s7_sel),.s7_we_o	(s7_we),.s7_cyc_o(s7_cyc),.s7_stb_o(s7_stb),
      .s7_dat_i(s7_dat_i),.s7_ack_i(s7_ack),.s7_err_i(0),.s7_rty_i(0),
      .s8_dat_o(s8_dat_o),.s8_adr_o(s8_adr),.s8_sel_o(s8_sel),.s8_we_o	(s8_we),.s8_cyc_o(s8_cyc),.s8_stb_o(s8_stb),
      .s8_dat_i(s8_dat_i),.s8_ack_i(s8_ack),.s8_err_i(0),.s8_rty_i(0),
      .s9_dat_o(s9_dat_o),.s9_adr_o(s9_adr),.s9_sel_o(s9_sel),.s9_we_o	(s9_we),.s9_cyc_o(s9_cyc),.s9_stb_o(s9_stb),
      .s9_dat_i(s9_dat_i),.s9_ack_i(s9_ack),.s9_err_i(0),.s9_rty_i(0),
      .sa_dat_o(sa_dat_o),.sa_adr_o(sa_adr),.sa_sel_o(sa_sel),.sa_we_o(sa_we),.sa_cyc_o(sa_cyc),.sa_stb_o(sa_stb),
      .sa_dat_i(sa_dat_i),.sa_ack_i(sa_ack),.sa_err_i(0),.sa_rty_i(0),
      .sb_dat_o(sb_dat_o),.sb_adr_o(sb_adr),.sb_sel_o(sb_sel),.sb_we_o(sb_we),.sb_cyc_o(sb_cyc),.sb_stb_o(sb_stb),
      .sb_dat_i(sb_dat_i),.sb_ack_i(sb_ack),.sb_err_i(0),.sb_rty_i(0),
      .sc_dat_o(sc_dat_o),.sc_adr_o(sc_adr),.sc_sel_o(sc_sel),.sc_we_o(sc_we),.sc_cyc_o(sc_cyc),.sc_stb_o(sc_stb),
      .sc_dat_i(sc_dat_i),.sc_ack_i(sc_ack),.sc_err_i(0),.sc_rty_i(0),
      .sd_dat_o(sd_dat_o),.sd_adr_o(sd_adr),.sd_sel_o(sd_sel),.sd_we_o(sd_we),.sd_cyc_o(sd_cyc),.sd_stb_o(sd_stb),
      .sd_dat_i(sd_dat_i),.sd_ack_i(sd_ack),.sd_err_i(0),.sd_rty_i(0),
      .se_dat_o(se_dat_o),.se_adr_o(se_adr),.se_sel_o(se_sel),.se_we_o(se_we),.se_cyc_o(se_cyc),.se_stb_o(se_stb),
      .se_dat_i(se_dat_i),.se_ack_i(se_ack),.se_err_i(0),.se_rty_i(0),
      .sf_dat_o(sf_dat_o),.sf_adr_o(sf_adr),.sf_sel_o(sf_sel),.sf_we_o(sf_we),.sf_cyc_o(sf_cyc),.sf_stb_o(sf_stb),
      .sf_dat_i(sf_dat_i),.sf_ack_i(sf_ack),.sf_err_i(0),.sf_rty_i(0));
      
   //////////////////////////////////////////////////////////////////////////////////////////
   // Reset Controller
   
   // /////////////////////////////////////////////////////////////////////////
   // Processor
   wire [31:0] 	 if_dat;
   wire [15:0] 	 if_adr;

   aeMB_core_BE #(.ISIZ(16),.DSIZ(16),.MUL(0),.BSF(1))
     aeMB (.sys_clk_i(wb_clk), .sys_rst_i(wb_rst),
	   // Instruction Wishbone bus to I-RAM
	   .if_adr(if_adr),
	   .if_dat(if_dat),
	   // Data Wishbone bus to system bus fabric
	   .dwb_we_o(m0_we),.dwb_stb_o(m0_stb),.dwb_dat_o(m0_dat_i),.dwb_adr_o(m0_adr),
	   .dwb_dat_i(m0_dat_o),.dwb_ack_i(m0_ack),.dwb_sel_o(m0_sel),.dwb_cyc_o(m0_cyc),
	   // Interrupts and exceptions
	   .sys_int_i(proc_int),.sys_exc_i(bus_error) );
   
   assign 	 bus_error = m0_err | m0_rty;
   
   // /////////////////////////////////////////////////////////////////////////
   // Dual Ported Boot RAM -- D-Port is Slave #0 on main Wishbone
   // Dual Ported Main RAM -- D-Port is Slave #F on main Wishbone
   // I-port connects directly to processor

   wire [31:0] 	 if_dat_boot, if_dat_main;
   assign if_dat = if_adr[15] ? if_dat_main : if_dat_boot;
   
   bootram bootram(.clk(wb_clk), .reset(wb_rst),
		   .if_adr(if_adr[12:0]), .if_data(if_dat_boot), 
		   .dwb_adr_i(s0_adr[12:0]), .dwb_dat_i(s0_dat_o), .dwb_dat_o(s0_dat_i),
		   .dwb_we_i(s0_we), .dwb_ack_o(s0_ack), .dwb_stb_i(s0_stb), .dwb_sel_i(s0_sel));

////blinkenlights v0.1
//defparam bootram.RAM0.INIT_00=256'hbc32fff0_aa43502b_b00000fe_30630001_80000000_10600000_a48500ff_10a00000;
//defparam bootram.RAM0.INIT_01=256'ha48500ff_b810ffd0_f880200c_30a50001_10830000_308000ff_be23000c_a4640001;

////bootloader 10/5/10 for 32/64Mbit FLASH
defparam bootram.RAM0.INIT_00=256'h00000000_00000000_00000000_b80801c0_00000000_b8081210_00000000_b8080050;
defparam bootram.RAM0.INIT_01=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_b8081218;
defparam bootram.RAM0.INIT_02=256'h3020ffe0_b0000000_30401920_31a01948_00000000_00000000_00000000_00000000;
defparam bootram.RAM0.INIT_03=256'h3021ffe4_e060f800_b0000000_b8000000_30a30000_b9f4047c_80000000_b9f400cc;
defparam bootram.RAM0.INIT_04=256'he8830000_e8601928_80000000_99fc2000_f8601928_b8000044_bc030014_f9e10000;
defparam bootram.RAM0.INIT_05=256'h80000000_99fc1800_30a0193c_bc030010_30600000_b0000000_30630004_be24ffec;
defparam bootram.RAM0.INIT_06=256'h30600000_b0000000_3021001c_b60f0008_e9e10000_f060f800_b0000000_30600001;
defparam bootram.RAM0.INIT_07=256'h80000000_99fc1800_bc03000c_30c0f804_b0000000_30a0193c_f9e10000_3021ffe4;
defparam bootram.RAM0.INIT_08=256'h80000000_99fc2000_bc04000c_30a01940_bc030014_30800000_b0000000_e8601940;
defparam bootram.RAM0.INIT_09=256'h06463800_20e01948_20c01948_f9e10000_2021ffec_3021001c_b60f0008_e9e10000;
defparam bootram.RAM0.INIT_0A=256'hb0000000_20c0f800_b0000000_bc92fff4_06463800_20c60004_f8060000_bc720014;
defparam bootram.RAM0.INIT_0B=256'hb9f410ac_bc92fff4_06463800_20c60004_f8060000_bc720014_06463800_20e0f82c;
defparam bootram.RAM0.INIT_0C=256'h32630000_20a00000_b9f4014c_20e00000_20c00000_80000000_b9f4122c_80000000;
defparam bootram.RAM0.INIT_0D=256'h20210014_b60f0008_30730000_c9e10000_80000000_b9f41078_80000000_b9f41234;
defparam bootram.RAM0.INIT_0E=256'he9e10000_f9610004_fa410010_95608001_fa21000c_f9610008_f9e10000_3021ffec;
defparam bootram.RAM0.INIT_0F=256'hbc050018_30210014_b62e0000_ea410010_ea21000c_e9610008_940bc001_e9610004;
defparam bootram.RAM0.INIT_10=256'h3021ff2c_80000000_b60f0008_bc32fff4_16432800_30630001_80000000_10600000;
defparam bootram.RAM0.INIT_11=256'hb9f40440_32c1001c_3261004c_f8610028_f9e10000_fac100d0_fa6100cc_3061002c;
defparam bootram.RAM0.INIT_12=256'h22407fff_e8610024_bc230038_30a01438_10b30000_b9f40a18_10d60000_10b30000;
defparam bootram.RAM0.INIT_13=256'h30a01438_bc120040_aa430001_30a01400_e061001c_10a30000_be520034_16439003;
defparam bootram.RAM0.INIT_14=256'he8e10020_e8c10028_b800ffa8_80000000_b9f404d4_b800ffb4_80000000_b9f404e0;
defparam bootram.RAM0.INIT_15=256'h80000000_b9f404a8_b800ff88_80000000_b9f404b4_30a01400_80000000_b9f41010;
defparam bootram.RAM0.INIT_16=256'hb800ff60_80000000_b9f4048c_30a01404_80000000_b9f40e5c_30a08000_b0000000;
defparam bootram.RAM0.INIT_17=256'h30a0a120_b0000007_9403c001_ac640002_94808001_fa61001c_f9e10000_3021ffe0;
defparam bootram.RAM0.INIT_18=256'hb9f40b9c_80000000_b9f406c0_f800200c_80000000_b9f4fef4_f860200c_306000ff;
defparam bootram.RAM0.INIT_19=256'h30a01504_bc04013c_a4842000_e8803334_80000000_b9f40438_30a0143c_80000000;
defparam bootram.RAM0.INIT_1A=256'h30a01568_bc23010c_80000000_b9f40e58_30a00000_b0000018_80000000_b9f40420;
defparam bootram.RAM0.INIT_1B=256'h30a015b8_bc030058_80000000_b9f40dec_30a00000_b0000030_80000000_b9f40400;
defparam bootram.RAM0.INIT_1C=256'h30c07c00_b9f40b58_30a00000_b0000030_30e08000_b0000000_80000000_b9f403e0;
defparam bootram.RAM0.INIT_1D=256'he9e10000_80000000_b9f403ac_30a015e4_80000000_b9f40d7c_30a08000_b0000000;
defparam bootram.RAM0.INIT_1E=256'hb000003f_80000000_b9f4038c_30a01620_30210020_b60f0008_30600001_ea61001c;
defparam bootram.RAM0.INIT_1F=256'h80000000_b9f40368_30a014ac_12630000_be230030_80000000_b9f40d78_30a00000;
defparam bootram.RAM0.INIT_20=256'hb0000000_30210020_b60f0008_ea61001c_e9e10000_10730000_80000000_b9f4fe1c;
defparam bootram.RAM0.INIT_21=256'hb9f40ce8_30a08000_b0000000_30c07c00_b9f40ac4_30a00000_b000003f_30e08000;
defparam bootram.RAM0.INIT_22=256'hb60f0008_30600001_ea61001c_e9e10000_80000000_b9f40318_30a01470_80000000;
defparam bootram.RAM0.INIT_23=256'h80000000_b9f402e8_30a01450_b800feec_80000000_b9f402f8_30a01530_30210020;
defparam bootram.RAM0.INIT_24=256'h80000000_b9f402c8_30a014ac_bc23001c_80000000_b9f40cd4_30a00000_b000003f;
defparam bootram.RAM0.INIT_25=256'hb9f40a34_30a00000_b000003f_30e08000_b0000000_b800fe94_80000000_b9f4fd7c;
defparam bootram.RAM0.INIT_26=256'h80000000_b9f40288_30a01470_80000000_b9f40c58_30a08000_b0000000_30c07c00;
defparam bootram.RAM0.INIT_27=256'h3021ffd0_80000000_b60f0008_80000000_b9f4fb84_f9e10000_3021ffe4_b800fe5c;
defparam bootram.RAM0.INIT_28=256'h13260000_12e70000_13050000_12660000_fb21002c_fb010028_fae10024_fa61001c;
defparam bootram.RAM0.INIT_29=256'hbcb2002c_16572001_bc120030_aa43ffff_12c00000_b810001c_f9e10000_fac10020;
defparam bootram.RAM0.INIT_2A=256'hbe32ffd4_aa43000a_f0730000_10960000_90630060_10b80000_b9f405ec_32730001;
defparam bootram.RAM0.INIT_2B=256'heae10024_eac10020_ea61001c_e9e10000_10640000_f0130000_14999800_32d60001;
defparam bootram.RAM0.INIT_2C=256'hfb010028_fae10024_fa61001c_3021ffd0_30210030_b60f0008_eb21002c_eb010028;
defparam bootram.RAM0.INIT_2D=256'hb8100014_f9e10000_fac10020_13260000_12e70000_13050000_12660000_fb21002c;
defparam bootram.RAM0.INIT_2E=256'h10960000_90630060_10b80000_b9f4051c_32730001_bcb2002c_16572001_12c00000;
defparam bootram.RAM0.INIT_2F=256'he9e10000_10640000_f0130000_14999800_32d60001_be32ffdc_aa43000a_f0730000;
defparam bootram.RAM0.INIT_30=256'h3021ffd8_30210030_b60f0008_eb21002c_eb010028_eae10024_eac10020_ea61001c;
defparam bootram.RAM0.INIT_31=256'hb9f404b0_12660000_f9e10000_12e60000_12c50000_fae10024_fac10020_fa61001c;
defparam bootram.RAM0.INIT_32=256'hf0130000_3273ffff_32730001_be32ffec_aa43000a_f0730000_90630060_10b60000;
defparam bootram.RAM0.INIT_33=256'h10c50000_30210028_b60f0008_eae10024_eac10020_ea61001c_e9e10000_10770000;
defparam bootram.RAM0.INIT_34=256'h3021ffe4_3021001c_b60f0008_e9e10000_10a00000_b9f4ff94_f9e10000_3021ffe4;
defparam bootram.RAM0.INIT_35=256'hf9e10000_3021ffe4_3021001c_b60f0008_e9e10000_80000000_b9f40448_f9e10000;
defparam bootram.RAM0.INIT_36=256'hfac10020_fa61001c_3021ffdc_3021001c_b60f0008_e9e10000_10a00000_b9f4ffdc;
defparam bootram.RAM0.INIT_37=256'hb9f40324_10b60000_12c50000_be060024_90c30060_12660000_e0660000_f9e10000;
defparam bootram.RAM0.INIT_38=256'heac10020_ea61001c_e9e10000_10b60000_be26fff0_90c30060_e0730000_32730001;
defparam bootram.RAM0.INIT_39=256'h12c50000_b9f4ff9c_f9e10000_fac1001c_3021ffe0_30210024_b60f0008_10600000;
defparam bootram.RAM0.INIT_3A=256'h30210020_b60f0008_10600000_eac1001c_e9e10000_30c0000a_b9f402dc_10b60000;
defparam bootram.RAM0.INIT_3B=256'h3021001c_b60f0008_e9e10000_10a00000_b9f4ffc0_f9e10000_3021ffe4_10c50000;
defparam bootram.RAM0.INIT_3C=256'h3021001c_b60f0008_e9e10000_10a00000_b9f4ff48_f9e10000_3021ffe4_10c50000;
defparam bootram.RAM0.INIT_3D=256'h3021ffe0_3021001c_b60f0008_e9e10000_30c0000a_b9f40278_f9e10000_3021ffe4;
defparam bootram.RAM0.INIT_3E=256'he9e10000_10760000_10d60000_b9f40250_f9e10000_10a00000_12c50000_fac1001c;
defparam bootram.RAM0.INIT_3F=256'h12c60000_b9f40228_f9e10000_fac1001c_3021ffe0_30210020_b60f0008_eac1001c;
defparam bootram.RAM1.INIT_00=256'hb9f401b8_f9e10000_3021ffe4_30210020_b60f0008_eac1001c_e9e10000_10760000;
defparam bootram.RAM1.INIT_01=256'hb0000000_9404c001_ac870002_94e08001_3021001c_b60f0008_e9e10000_80000000;
defparam bootram.RAM1.INIT_02=256'hf860f81c_b0000000_f860200c_80633000_84632000_84c62800_a866ffff_e880f81c;
defparam bootram.RAM1.INIT_03=256'h94608001_80000000_b60f0008_9404c001_80843800_ac840002_94808001_a4e70002;
defparam bootram.RAM1.INIT_04=256'hf8a0f81c_b0000000_f8a0200c_88a52000_e880f81c_b0000000_9406c001_acc30002;
defparam bootram.RAM1.INIT_05=256'h94e08001_80000000_b60f0008_9404c001_80841800_ac840002_94808001_a4630002;
defparam bootram.RAM1.INIT_06=256'h80633000_84632000_84c62800_a866ffff_e880f820_b0000000_9404c001_ac870002;
defparam bootram.RAM1.INIT_07=256'h9404c001_80843800_ac840002_94808001_a4e70002_f860f820_b0000000_f8602020;
defparam bootram.RAM1.INIT_08=256'hfac10020_f9e10000_fb010028_fae10024_fa61001c_3021ffd4_80000000_b60f0008;
defparam bootram.RAM1.INIT_09=256'h32600001_be670038_12660000_be060040_90c30060_13050000_12e60000_e0660000;
defparam bootram.RAM1.INIT_0A=256'hc0779800_10b80000_b9f400cc_10730000_be120028_16569800_32c70001_b8100014;
defparam bootram.RAM1.INIT_0B=256'heac10020_ea61001c_e9e10000_10730000_3273ffff_32730001_be26ffe4_90c30060;
defparam bootram.RAM1.INIT_0C=256'hb9f40084_f9e10000_10a00000_3021ffe4_3021002c_b60f0008_eb010028_eae10024;
defparam bootram.RAM1.INIT_0D=256'h10c63000_80000000_b60f0008_f0c5192c_3021001c_b60f0008_e9e10000_30c0000a;
defparam bootram.RAM1.INIT_0E=256'hf9e10000_fa61001c_3021ffe0_80000000_b60f0008_f8653700_64a50405_e4661660;
defparam bootram.RAM1.INIT_0F=256'h32730001_10b30000_e0d3165c_90c60060_b9f4ffc4_10b30000_e0d3192c_12600000;
defparam bootram.RAM1.INIT_10=256'h30210020_b60f0008_ea61001c_e9e10000_bc32ffd8_aa530003_90c60060_b9f4ffbc;
defparam bootram.RAM1.INIT_11=256'h12650000_be120030_aa46000a_12c60000_f9e10000_fac10020_fa61001c_3021ffdc;
defparam bootram.RAM1.INIT_12=256'heac10020_ea61001c_e9e10000_fac5000c_bc03fffc_e8650004_30a33700_64730405;
defparam bootram.RAM1.INIT_13=256'hb810ffc8_30c0000d_b9f4ffac_bc32ffd0_aa430001_e065192c_30210024_b60f0008;
defparam bootram.RAM1.INIT_14=256'hbe120030_aa46000a_12c60000_f9e10000_fac10020_fa61001c_3021ffdc_64730405;
defparam bootram.RAM1.INIT_15=256'hea61001c_e9e10000_fac3000c_bc040008_e8830004_30633700_64730405_12650000;
defparam bootram.RAM1.INIT_16=256'hb9f4ff44_30c0000d_be32ffd0_aa430001_e065192c_30210024_b60f0008_eac10020;
defparam bootram.RAM1.INIT_17=256'he8650010_bc03fffc_e8650008_30a53700_64a50405_64730405_b810ffc4_80000000;
defparam bootram.RAM1.INIT_18=256'he8850008_e8650010_bc030014_e8650008_30a53700_64a50405_80000000_b60f0008;
defparam bootram.RAM1.INIT_19=256'hf9e10000_fac10020_3021ffdc_64a50405_80000000_b60f0008_90630060_be24fff8;
defparam bootram.RAM1.INIT_1A=256'hbe120034_aa53012d_b8000010_32600001_be230040_e8760008_32c53700_fa61001c;
defparam bootram.RAM1.INIT_1B=256'h3240012b_3273ffff_32730001_be03ffe8_e8760008_30a00001_b9f40040_3060ffff;
defparam bootram.RAM1.INIT_1C=256'hb60f0008_eac10020_ea61001c_e9e10000_e8760010_3060ffff_be52000c_16539001;
defparam bootram.RAM1.INIT_1D=256'hbe650048_bc430054_e8601930_bc260054_a4c30000_b0008000_e8603324_30210024;
defparam bootram.RAM1.INIT_1E=256'h80000000_80000000_80000000_80000000_10800000_bc660030_e8c01930_10660000;
defparam bootram.RAM1.INIT_1F=256'h16432800_30630001_bc32ffdc_16443000_30840001_80000000_80000000_80000000;
defparam bootram.RAM1.INIT_20=256'hf8801930_e483166c_10631800_a4630007_e8603324_80000000_b60f0008_bc32ffc8;
defparam bootram.RAM1.INIT_21=256'h3065ffc9_a46300ff_be520024_16459001_3240005a_3065ffa9_90a50060_b800ff9c;
defparam bootram.RAM1.INIT_22=256'h80000000_b60f0008_a46400ff_3085ffd0_be52000c_16459001_32400039_a46300ff;
defparam bootram.RAM1.INIT_23=256'hfae10024_fac10020_fa61001c_f9e10000_fb610034_13250000_fb21002c_3021ffc8;
defparam bootram.RAM1.INIT_24=256'h10650000_30a0ffff_be120034_aa43003a_13660000_e0790000_fb410030_fb010028;
defparam bootram.RAM1.INIT_25=256'heb610034_eb410030_eb21002c_eb010028_eae10024_eac10020_ea61001c_e9e10000;
defparam bootram.RAM1.INIT_26=256'hbe04001c_90840060_30650001_c085c800_30a00001_e8c01934_30210038_b60f0008;
defparam bootram.RAM1.INIT_27=256'hb9f4ff28_e0b90001_30a0fffe_b810ffac_bc23ffe4_a4630044_c0662000_a4a300ff;
defparam bootram.RAM1.INIT_28=256'h10791800_fa7b0004_10739800_12761800_66c30404_b9f4ff1c_e0b90002_80000000;
defparam bootram.RAM1.INIT_29=256'he0b90003_13530000_b9f4fef0_e0b90005_30a0fffd_be38ff74_93040060_e083000b;
defparam bootram.RAM1.INIT_2A=256'hb9f4fec8_64630408_e0b90006_66c3040c_b9f4fed8_e0b90004_66e30404_b9f4fee4;
defparam bootram.RAM1.INIT_2B=256'he0b90008_80000000_b9f4feb0_e0b90007_fafb0008_12f7b000_12d61800_12d61800;
defparam bootram.RAM1.INIT_2C=256'hea7b000c_13580000_10f30000_be130060_f07b0000_1063b000_66c30404_b9f4fea4;
defparam bootram.RAM1.INIT_2D=256'hb9f4fe68_e0b60001_12d9b000_b9f4fe74_c0b6c800_a6d600ff_32d60009_12d8c000;
defparam bootram.RAM1.INIT_2E=256'ha70400ff_c073c000_30980001_e8fb0004_ea7b000c_d0789800_1063b800_66e30404;
defparam bootram.RAM1.INIT_2F=256'h64760008_12e73800_e09b0000_eadb0008_a74300ff_be52ffb8_1647c003_107a1800;
defparam bootram.RAM1.INIT_30=256'he0b7000a_12d61800_b9f4fe10_107a1800_12c7b000_10632000_e0b70009_12f9b800;
defparam bootram.RAM1.INIT_31=256'hbe32fe60_1643b000_a46300ff_a6d600ff_1063c000_16d60000_67030404_b9f4fe04;
defparam bootram.RAM1.INIT_32=256'h80000000_b60f0008_bc23fff8_a4630100_e8603b10_10a00000_b810fe58_30a0fffb;
defparam bootram.RAM1.INIT_33=256'hbc23fff8_a4630100_e8603b10_a4a500ff_80884800_a1292000_a508007f_a5290600;
defparam bootram.RAM1.INIT_34=256'h10650000_be050018_f8803b10_a0840100_f8603b18_a46600ff_f8803b10_f8e03b00;
defparam bootram.RAM1.INIT_35=256'h10e60000_10c00000_80000000_b60f0008_e8603b00_bc23fff8_a4630100_e8603b10;
defparam bootram.RAM1.INIT_36=256'hb9f4ff84_f8603b14_30600001_31200400_31000008_10a00000_f9e10000_3021ffe4;
defparam bootram.RAM1.INIT_37=256'hfa61002c_12c50000_fac10030_3021ffc4_3021001c_b60f0008_e9e10000_80000000;
defparam bootram.RAM1.INIT_38=256'hf8003b18_30600400_12670000_b9f4ff3c_fae10034_13060000_f9e10000_fb010038;
defparam bootram.RAM1.INIT_39=256'h30800428_f8603b18_30600001_fac03b00_f8603b04_3060000b_66d60408_f8603b10;
defparam bootram.RAM1.INIT_3A=256'h12e00000_12d30000_be18009c_80000000_b9f4ff00_f8603b10_30600528_f8803b10;
defparam bootram.RAM1.INIT_3B=256'he8803b0c_80000000_b9f4fed8_f8803b10_30800500_f8603b10_30600400_3261001c;
defparam bootram.RAM1.INIT_3C=256'hf8610028_e8603b00_f8810024_e8803b04_f8610020_e8603b08_f881001c_14b7c000;
defparam bootram.RAM1.INIT_3D=256'h30840001_d0762000_c0732000_30a00010_10800000_beb20034_16459003_22400010;
defparam bootram.RAM1.INIT_3E=256'hbc25ffd8_b800ff8c_12d62800_beb20020_1658b803_12f72800_bc32fff0_16442800;
defparam bootram.RAM1.INIT_3F=256'heac10030_ea61002c_e9e10000_f8003b18_12d62800_be52ff7c_1658b803_12f72800;
defparam bootram.RAM2.INIT_00=256'h30a00001_3021ffe4_30e00000_b0009f00_3021003c_b60f0008_eb010038_eae10034;
defparam bootram.RAM2.INIT_01=256'ha463ffff_b00000ff_e9e10000_31200400_b9f4fe34_f9e10000_31000020_30c00001;
defparam bootram.RAM2.INIT_02=256'he9e10000_bc030010_f9e10000_3021ffe4_e860f828_b0000000_3021001c_b60f0008;
defparam bootram.RAM2.INIT_03=256'hbe120010_aa440020_a48400ff_64830008_80000000_b9f4ffa8_3021001c_b60f0008;
defparam bootram.RAM2.INIT_04=256'h16439001_32400018_bcb2fff0_16439001_32400015_80000000_b9f40170_a46300ff;
defparam bootram.RAM2.INIT_05=256'hf9e10000_3021ffe4_e860f824_b0000000_b800ffb0_f860f828_b0000000_bc52ffe4;
defparam bootram.RAM2.INIT_06=256'ha48400ff_64830008_80000000_b9f4ff40_3021001c_b60f0008_e9e10000_bc030010;
defparam bootram.RAM2.INIT_07=256'hbcb2fff0_16459001_32400015_80000000_b9f40108_a4a300ff_be120010_aa440020;
defparam bootram.RAM2.INIT_08=256'hf860f824_b0000000_f8a0f828_b0000000_e0651666_bc52ffe4_16459001_32400018;
defparam bootram.RAM2.INIT_09=256'hb9f40174_f9e10000_10b60000_10c50000_12c00000_fac1001c_3021ffe0_b800ffa4;
defparam bootram.RAM2.INIT_0A=256'h3021ffd4_30210020_b60f0008_eac1001c_e9e10000_80000000_99fcb000_30e00024;
defparam bootram.RAM2.INIT_0B=256'h30c01680_10b60000_30c00006_b9f4fd80_f9e10000_10f60000_32c1001c_fac10028;
defparam bootram.RAM2.INIT_0C=256'h6464001f_eac10028_e9e10000_a884ffff_80841800_14830000_30e00006_b9f400b0;
defparam bootram.RAM2.INIT_0D=256'hb9f4fd34_f9e10000_10f60000_32c1001c_fac10028_3021ffd4_3021002c_b60f0008;
defparam bootram.RAM2.INIT_0E=256'ha884ffff_80841800_14830000_30e00006_b9f40064_30c01688_10b60000_30c00006;
defparam bootram.RAM2.INIT_0F=256'hf9e10000_3021ffe4_30a01690_3021002c_b60f0008_6464001f_eac10028_e9e10000;
defparam bootram.RAM2.INIT_10=256'h80000000_b6910000_80000000_b6110000_30a0ffff_b9f4ee68_80000000_b9f4f580;
defparam bootram.RAM2.INIT_11=256'h80653000_beb2005c_16479003_22400003_80000000_b60f0008_80000000_b60f0008;
defparam bootram.RAM2.INIT_12=256'h30a50004_30e7fffc_bc320040_16432000_e8660000_e8850000_bc230050_a4630003;
defparam bootram.RAM2.INIT_13=256'he1050000_bc120028_aa47ffff_30e7ffff_30c60004_be52ffe0_16479003_22400003;
defparam bootram.RAM2.INIT_14=256'hbc32ffe0_aa47ffff_30e7ffff_30c60001_30a50001_be320020_16434000_e0660000;
defparam bootram.RAM2.INIT_15=256'h10850000_beb20018_16479003_2240000f_14634000_b60f0008_10600000_b60f0008;
defparam bootram.RAM2.INIT_16=256'he0660000_10e72000_11040000_bc070024_11050000_be030034_a4630003_80662800;
defparam bootram.RAM2.INIT_17=256'he8860000_10650000_b60f0008_30c60001_be32fff0_16474000_31080001_f0680000;
defparam bootram.RAM2.INIT_18=256'h30c60010_e866000c_f8880008_e8860008_f8680004_e8660004_f8880000_30e7fff0;
defparam bootram.RAM2.INIT_19=256'hbcb2002c_16479003_22400003_31080010_be52ffd0_16479003_2240000f_f868000c;
defparam bootram.RAM2.INIT_1A=256'h30840004_be52ffec_16479003_22400003_d8682000_30e7fffc_c8662000_10800000;
defparam bootram.RAM2.INIT_1B=256'hf9e10000_fa61001c_3021ffe0_e86013f0_10880000_b810ff68_11044000_10c43000;
defparam bootram.RAM2.INIT_1C=256'hbc32fff0_aa43ffff_e8730000_3273fffc_99fc1800_bc120018_aa43ffff_326013f0;
defparam bootram.RAM2.INIT_1D=256'h80000000_b9f4ed20_d9e00800_3021fff8_30210020_b60f0008_ea61001c_e9e10000;
defparam bootram.RAM2.INIT_1E=256'hb9f4ec98_d9e00800_3021fff8_30210008_b60f0008_c9e00800_80000000_b9f4ffb0;
defparam bootram.RAM2.INIT_1F=256'h00000000_ffffffff_00000000_ffffffff_30210008_b60f0008_c9e00800_80000000;
defparam bootram.RAM2.INIT_20=256'h65642120_7475726e_65207265_696d6167_61696e20_523a206d_4552524f_4f4b0000;
defparam bootram.RAM2.INIT_21=256'h55535250_4e4f4b00_64652e00_64206d6f_206c6f61_49484558_20696e20_4261636b;
defparam bootram.RAM2.INIT_22=256'h50322b20_20555352_74696e67_53746172_720a0000_6f616465_6f6f746c_322b2062;
defparam bootram.RAM2.INIT_23=256'h6e206672_65747572_523a2072_4552524f_2e000000_6d6f6465_61666520_696e2073;
defparam bootram.RAM2.INIT_24=256'h206e6576_6f756c64_73207368_20546869_72616d21_70726f67_61696e20_6f6d206d;
defparam bootram.RAM2.INIT_25=256'h69726d77_66652066_6f207361_523a206e_4552524f_6e210000_61707065_65722068;
defparam bootram.RAM2.INIT_26=256'h62726963_6d206120_20492061_626c652e_61696c61_65206176_696d6167_61726520;
defparam bootram.RAM2.INIT_27=256'h2052414d_5820746f_20494845_6c6f6164_20746f20_66726565_65656c20_6b2e2046;
defparam bootram.RAM2.INIT_28=256'h6374696f_726f6475_69642070_2076616c_20666f72_6b696e67_43686563_2e000000;
defparam bootram.RAM2.INIT_29=256'h74696f6e_6f647563_64207072_56616c69_2e2e2e00_6d616765_47412069_6e204650;
defparam bootram.RAM2.INIT_2A=256'h6720746f_7074696e_7474656d_642e2041_666f756e_61676520_4120696d_20465047;
defparam bootram.RAM2.INIT_2B=256'h46504741_696f6e20_64756374_2070726f_616c6964_4e6f2076_742e0000_20626f6f;
defparam bootram.RAM2.INIT_2C=256'h6c6f6164_20746f20_74696e67_74656d70_2e0a4174_6f756e64_67652066_20696d61;
defparam bootram.RAM2.INIT_2D=256'h64207072_56616c69_2e2e2e00_77617265_6669726d_696f6e20_64756374_2070726f;
defparam bootram.RAM2.INIT_2E=256'h64696e67_204c6f61_756e642e_6520666f_6d776172_20666972_74696f6e_6f647563;
defparam bootram.RAM2.INIT_2F=256'h70726f67_61696e20_6f6d206d_6e206672_65747572_523a2052_4552524f_2e2e2e00;
defparam bootram.RAM2.INIT_30=256'h6e210000_61707065_65722068_206e6576_6f756c64_73207368_20546869_72616d21;
defparam bootram.RAM2.INIT_31=256'h20666f75_77617265_6669726d_696f6e20_64756374_2070726f_616c6964_4e6f2076;
defparam bootram.RAM2.INIT_32=256'h05050400_2e2e2e00_77617265_6669726d_61666520_6e672073_54727969_6e642e20;
defparam bootram.RAM2.INIT_33=256'h10101200_06820594_09c407d0_13880d05_00002710_01b200d9_05160364_14580a2c;
defparam bootram.RAM2.INIT_34=256'h00202020_00000000_6f72740a_0a0a6162_aa990000_ffffffff_b8080000_b0000000;
defparam bootram.RAM2.INIT_35=256'h20881010_20202020_20202020_20202020_20202020_28282820_20202828_20202020;
defparam bootram.RAM2.INIT_36=256'h10104141_10101010_04040410_04040404_10040404_10101010_10101010_10101010;
defparam bootram.RAM2.INIT_37=256'h10104242_10101010_01010101_01010101_01010101_01010101_01010101_41414141;
defparam bootram.RAM2.INIT_38=256'h20000000_10101010_02020202_02020202_02020202_02020202_02020202_42424242;
defparam bootram.RAM2.INIT_39=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM2.INIT_3A=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM2.INIT_3B=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM2.INIT_3C=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM2.INIT_3D=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM2.INIT_3E=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM2.INIT_3F=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM3.INIT_00=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM3.INIT_01=256'h20202020_20202020_20202020_20202020_28282020_20282828_20202020_20202020;
defparam bootram.RAM3.INIT_02=256'h10101010_04041010_04040404_04040404_10101010_10101010_10101010_88101010;
defparam bootram.RAM3.INIT_03=256'h10101010_01010110_01010101_01010101_01010101_01010101_41414101_10414141;
defparam bootram.RAM3.INIT_04=256'h10101020_02020210_02020202_02020202_02020202_02020202_42424202_10424242;
defparam bootram.RAM3.INIT_05=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM3.INIT_06=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM3.INIT_07=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM3.INIT_08=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
defparam bootram.RAM3.INIT_09=256'h00000000_00000000_00001820_ffffffff_01010100_000013fc_00000000_00000000;
defparam bootram.RAM3.INIT_0A=256'h00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000;

   ram_harvard2 #(.AWIDTH(15),.RAM_SIZE(32768))
   sys_ram(.wb_clk_i(wb_clk),.wb_rst_i(wb_rst),	     
	   .if_adr(if_adr[14:0]), .if_data(if_dat_main), 
	   .dwb_adr_i(sf_adr[14:0]), .dwb_dat_i(sf_dat_o), .dwb_dat_o(sf_dat_i),
	   .dwb_we_i(sf_we), .dwb_ack_o(sf_ack), .dwb_stb_i(sf_stb), .dwb_sel_i(sf_sel));
   
   // /////////////////////////////////////////////////////////////////////////
   // Buffer Pool, slave #1
   wire 	 rd0_ready_i, rd0_ready_o;
   wire 	 rd1_ready_i, rd1_ready_o;
   wire 	 rd2_ready_i, rd2_ready_o;
   wire 	 rd3_ready_i, rd3_ready_o;
   wire [3:0] 	 rd0_flags, rd1_flags, rd2_flags, rd3_flags;
   wire [31:0] 	 rd0_dat, rd1_dat, rd2_dat, rd3_dat;

   wire 	 wr0_ready_i, wr0_ready_o;
   wire 	 wr1_ready_i, wr1_ready_o;
   wire 	 wr2_ready_i, wr2_ready_o;
   wire 	 wr3_ready_i, wr3_ready_o;
   wire [3:0] 	 wr0_flags, wr1_flags, wr2_flags, wr3_flags;
   wire [31:0] 	 wr0_dat, wr1_dat, wr2_dat, wr3_dat;
   
   buffer_pool #(.BUF_SIZE(9), .SET_ADDR(SR_BUF_POOL)) buffer_pool
     (.wb_clk_i(wb_clk),.wb_rst_i(wb_rst),
      .wb_we_i(s1_we),.wb_stb_i(s1_stb),.wb_adr_i(s1_adr),.wb_dat_i(s1_dat_o),   
      .wb_dat_o(s1_dat_i),.wb_ack_o(s1_ack),.wb_err_o(),.wb_rty_o(),
   
      .stream_clk(dsp_clk), .stream_rst(dsp_rst),
      .set_stb(set_stb_dsp), .set_addr(set_addr_dsp), .set_data(set_data_dsp),
      .status(status),.sys_int_o(buffer_int),

      .s0(status_b0),.s1(status_b1),.s2(status_b2),.s3(status_b3),
      .s4(status_b4),.s5(status_b5),.s6(status_b6),.s7(status_b7),

      // Write Interfaces
      .wr0_data_i(wr0_dat), .wr0_flags_i(wr0_flags), .wr0_ready_i(wr0_ready_i), .wr0_ready_o(wr0_ready_o),
      .wr1_data_i(wr1_dat), .wr1_flags_i(wr1_flags), .wr1_ready_i(wr1_ready_i), .wr1_ready_o(wr1_ready_o),
      .wr2_data_i(wr2_dat), .wr2_flags_i(wr2_flags), .wr2_ready_i(wr2_ready_i), .wr2_ready_o(wr2_ready_o),
      .wr3_data_i(wr3_dat), .wr3_flags_i(wr3_flags), .wr3_ready_i(wr3_ready_i), .wr3_ready_o(wr3_ready_o),
      // Read Interfaces
      .rd0_data_o(rd0_dat), .rd0_flags_o(rd0_flags), .rd0_ready_i(rd0_ready_i), .rd0_ready_o(rd0_ready_o),
      .rd1_data_o(rd1_dat), .rd1_flags_o(rd1_flags), .rd1_ready_i(rd1_ready_i), .rd1_ready_o(rd1_ready_o),
      .rd2_data_o(rd2_dat), .rd2_flags_o(rd2_flags), .rd2_ready_i(rd2_ready_i), .rd2_ready_o(rd2_ready_o),
      .rd3_data_o(rd3_dat), .rd3_flags_o(rd3_flags), .rd3_ready_i(rd3_ready_i), .rd3_ready_o(rd3_ready_o)
      );

   wire [31:0] 	 status_enc;
   priority_enc priority_enc (.in({16'b0,status[15:0]}), .out(status_enc));
   
   // /////////////////////////////////////////////////////////////////////////
   // SPI -- Slave #2
   spi_top shared_spi
     (.wb_clk_i(wb_clk),.wb_rst_i(wb_rst),.wb_adr_i(s2_adr[4:0]),.wb_dat_i(s2_dat_o),
      .wb_dat_o(s2_dat_i),.wb_sel_i(s2_sel),.wb_we_i(s2_we),.wb_stb_i(s2_stb),
      .wb_cyc_i(s2_cyc),.wb_ack_o(s2_ack),.wb_err_o(),.wb_int_o(spi_int),
      .ss_pad_o({sen_adc, sen_tx_db,sen_tx_adc,sen_tx_dac,sen_rx_db,sen_rx_adc,sen_rx_dac,sen_dac,sen_clk}),
      .sclk_pad_o(sclk),.mosi_pad_o(mosi),.miso_pad_i(miso) );

   // /////////////////////////////////////////////////////////////////////////
   // I2C -- Slave #3
   i2c_master_top #(.ARST_LVL(1)) 
     i2c (.wb_clk_i(wb_clk),.wb_rst_i(wb_rst),.arst_i(1'b0), 
	  .wb_adr_i(s3_adr[4:2]),.wb_dat_i(s3_dat_o[7:0]),.wb_dat_o(s3_dat_i[7:0]),
	  .wb_we_i(s3_we),.wb_stb_i(s3_stb),.wb_cyc_i(s3_cyc),
	  .wb_ack_o(s3_ack),.wb_inta_o(i2c_int),
	  .scl_pad_i(scl_pad_i),.scl_pad_o(scl_pad_o),.scl_padoen_o(scl_pad_oen_o),
	  .sda_pad_i(sda_pad_i),.sda_pad_o(sda_pad_o),.sda_padoen_o(sda_pad_oen_o) );

   assign 	 s3_dat_i[31:8] = 24'd0;
   
   // /////////////////////////////////////////////////////////////////////////
   // GPIOs -- Slave #4
   nsgpio nsgpio(.clk_i(wb_clk),.rst_i(wb_rst),
		 .cyc_i(s4_cyc),.stb_i(s4_stb),.adr_i(s4_adr[3:0]),.we_i(s4_we),
		 .dat_i(s4_dat_o),.dat_o(s4_dat_i),.ack_o(s4_ack),
		 .atr(atr_lines),.debug_0(debug_gpio_0),.debug_1(debug_gpio_1),
		 .gpio( {io_tx,io_rx} ) );

   // /////////////////////////////////////////////////////////////////////////
   // Buffer Pool Status -- Slave #5   
   
   reg [31:0] 	 cycle_count;
   always @(posedge wb_clk)
     if(wb_rst)
       cycle_count <= 0;
     else
       cycle_count <= cycle_count + 1;

   //compatibility number -> increment when the fpga has been sufficiently altered
   localparam compat_num = 32'd2;

   wb_readback_mux buff_pool_status
     (.wb_clk_i(wb_clk), .wb_rst_i(wb_rst), .wb_stb_i(s5_stb),
      .wb_adr_i(s5_adr), .wb_dat_o(s5_dat_i), .wb_ack_o(s5_ack),
      
      .word00(status_b0),.word01(status_b1),.word02(status_b2),.word03(status_b3),
      .word04(status_b4),.word05(status_b5),.word06(status_b6),.word07(status_b7),
      .word08(status),.word09({sim_mode,27'b0,clock_divider[3:0]}),.word10(vita_time[63:32]),
      .word11(vita_time[31:0]),.word12(compat_num),.word13(irq),.word14(status_enc),.word15(cycle_count)
      );

   // /////////////////////////////////////////////////////////////////////////
   // Ethernet MAC  Slave #6

   wire [18:0] 	 rx_f19_data, tx_f19_data;
   wire 	 rx_f19_src_rdy, rx_f19_dst_rdy, rx_f36_src_rdy, rx_f36_dst_rdy;
   
   simple_gemac_wrapper19 #(.RXFIFOSIZE(11), .TXFIFOSIZE(6)) simple_gemac_wrapper19
     (.clk125(clk_to_mac),  .reset(wb_rst),
      .GMII_GTX_CLK(GMII_GTX_CLK), .GMII_TX_EN(GMII_TX_EN),  
      .GMII_TX_ER(GMII_TX_ER), .GMII_TXD(GMII_TXD),
      .GMII_RX_CLK(GMII_RX_CLK), .GMII_RX_DV(GMII_RX_DV),  
      .GMII_RX_ER(GMII_RX_ER), .GMII_RXD(GMII_RXD),
      .sys_clk(dsp_clk),
      .rx_f19_data(rx_f19_data), .rx_f19_src_rdy(rx_f19_src_rdy), .rx_f19_dst_rdy(rx_f19_dst_rdy),
      .tx_f19_data(tx_f19_data), .tx_f19_src_rdy(tx_f19_src_rdy), .tx_f19_dst_rdy(tx_f19_dst_rdy),
      .wb_clk(wb_clk), .wb_rst(wb_rst), .wb_stb(s6_stb), .wb_cyc(s6_cyc), .wb_ack(s6_ack),
      .wb_we(s6_we), .wb_adr(s6_adr), .wb_dat_i(s6_dat_o), .wb_dat_o(s6_dat_i),
      .mdio(MDIO), .mdc(MDC),
      .debug(debug_mac));

   wire [35:0] 	 udp_tx_data, udp_rx_data;
   wire 	 udp_tx_src_rdy, udp_tx_dst_rdy, udp_rx_src_rdy, udp_rx_dst_rdy;
   
   udp_wrapper #(.BASE(SR_UDP_SM)) udp_wrapper
     (.clk(dsp_clk), .reset(dsp_rst), .clear(0),
      .set_stb(set_stb_dsp), .set_addr(set_addr_dsp), .set_data(set_data_dsp),
      .rx_f19_data(rx_f19_data), .rx_f19_src_rdy_i(rx_f19_src_rdy), .rx_f19_dst_rdy_o(rx_f19_dst_rdy),
      .tx_f19_data(tx_f19_data), .tx_f19_src_rdy_o(tx_f19_src_rdy), .tx_f19_dst_rdy_i(tx_f19_dst_rdy),
      .rx_f36_data(udp_rx_data), .rx_f36_src_rdy_o(udp_rx_src_rdy), .rx_f36_dst_rdy_i(udp_rx_dst_rdy),
      .tx_f36_data(udp_tx_data), .tx_f36_src_rdy_i(udp_tx_src_rdy), .tx_f36_dst_rdy_o(udp_tx_dst_rdy),
      .debug(debug_udp) );

   wire [35:0] 	 tx_err_data, udp1_tx_data;
   wire 	 tx_err_src_rdy, tx_err_dst_rdy, udp1_tx_src_rdy, udp1_tx_dst_rdy;
   
   fifo_cascade #(.WIDTH(36), .SIZE(ETH_TX_FIFOSIZE)) tx_eth_fifo
     (.clk(dsp_clk), .reset(dsp_rst), .clear(0),
      .datain({rd2_flags,rd2_dat}), .src_rdy_i(rd2_ready_o), .dst_rdy_o(rd2_ready_i),
      .dataout(udp1_tx_data), .src_rdy_o(udp1_tx_src_rdy), .dst_rdy_i(udp1_tx_dst_rdy));

   fifo36_mux #(.prio(0)) mux_err_stream
     (.clk(dsp_clk), .reset(dsp_reset), .clear(0),
      .data0_i(udp1_tx_data), .src0_rdy_i(udp1_tx_src_rdy), .dst0_rdy_o(udp1_tx_dst_rdy),
      .data1_i(tx_err_data), .src1_rdy_i(tx_err_src_rdy), .dst1_rdy_o(tx_err_dst_rdy),
      .data_o(udp_tx_data), .src_rdy_o(udp_tx_src_rdy), .dst_rdy_i(udp_tx_dst_rdy));
   
   fifo_cascade #(.WIDTH(36), .SIZE(ETH_RX_FIFOSIZE)) rx_eth_fifo
     (.clk(dsp_clk), .reset(dsp_rst), .clear(0),
      .datain(udp_rx_data), .src_rdy_i(udp_rx_src_rdy), .dst_rdy_o(udp_rx_dst_rdy),
      .dataout({wr2_flags,wr2_dat}), .src_rdy_o(wr2_ready_i), .dst_rdy_i(wr2_ready_o));
   
   // /////////////////////////////////////////////////////////////////////////
   // Settings Bus -- Slave #7
   settings_bus settings_bus
     (.wb_clk(wb_clk),.wb_rst(wb_rst),.wb_adr_i(s7_adr),.wb_dat_i(s7_dat_o),
      .wb_stb_i(s7_stb),.wb_we_i(s7_we),.wb_ack_o(s7_ack),
      .strobe(set_stb),.addr(set_addr),.data(set_data));
   
   assign 	 s7_dat_i = 32'd0;

   settings_bus_crossclock settings_bus_crossclock
     (.clk_i(wb_clk), .rst_i(wb_rst), .set_stb_i(set_stb), .set_addr_i(set_addr), .set_data_i(set_data),
      .clk_o(dsp_clk), .rst_o(dsp_rst), .set_stb_o(set_stb_dsp), .set_addr_o(set_addr_dsp), .set_data_o(set_data_dsp));
   
   // Output control lines
   wire [7:0] 	 clock_outs, serdes_outs, adc_outs;
   assign 	 {clock_ready, clk_en[1:0], clk_sel[1:0]} = clock_outs[4:0];
   assign 	 {ser_enable, ser_prbsen, ser_loopen, ser_rx_en} = serdes_outs[3:0];
   assign 	 {adc_oe_a, adc_on_a, adc_oe_b, adc_on_b } = adc_outs[3:0];

   wire 	 phy_reset;
   assign 	 PHY_RESETn = ~phy_reset;
   
   setting_reg #(.my_addr(0),.width(8)) sr_clk (.clk(wb_clk),.rst(wb_rst),.strobe(s7_ack),.addr(set_addr),
				      .in(set_data),.out(clock_outs),.changed());
   setting_reg #(.my_addr(1),.width(8)) sr_ser (.clk(wb_clk),.rst(wb_rst),.strobe(set_stb),.addr(set_addr),
				      .in(set_data),.out(serdes_outs),.changed());
   setting_reg #(.my_addr(2),.width(8)) sr_adc (.clk(wb_clk),.rst(wb_rst),.strobe(set_stb),.addr(set_addr),
				      .in(set_data),.out(adc_outs),.changed());
   setting_reg #(.my_addr(4),.width(1)) sr_phy (.clk(wb_clk),.rst(wb_rst),.strobe(set_stb),.addr(set_addr),
				      .in(set_data),.out(phy_reset),.changed());

   // /////////////////////////////////////////////////////////////////////////
   //  LEDS
   //    register 8 determines whether leds are controlled by SW or not
   //    1 = controlled by HW, 0 = by SW
   //    In Rev3 there are only 6 leds, and the highest one is on the ETH connector
   
   wire [7:0] 	 led_src, led_sw;
   wire [7:0] 	 led_hw = {run_tx, run_rx, clk_status, serdes_link_up, 1'b0};
   
   setting_reg #(.my_addr(3),.width(8)) sr_led (.clk(wb_clk),.rst(wb_rst),.strobe(set_stb),.addr(set_addr),
				      .in(set_data),.out(led_sw),.changed());

   setting_reg #(.my_addr(8),.width(8), .at_reset(8'b0001_1110)) 
   sr_led_src (.clk(wb_clk),.rst(wb_rst), .strobe(set_stb),.addr(set_addr), .in(set_data),.out(led_src),.changed());

   assign 	 leds = (led_src & led_hw) | (~led_src & led_sw);
   
   // /////////////////////////////////////////////////////////////////////////
   // Interrupt Controller, Slave #8

   assign irq= {{8'b0},
		{uart_tx_int[3:0], uart_rx_int[3:0]},
		{2'b0, button, periodic_int, clk_status, serdes_link_up, 2'b00},
		{pps_int,overrun,underrun,PHY_INTn,i2c_int,spi_int,onetime_int,buffer_int}};
   
   pic pic(.clk_i(wb_clk),.rst_i(wb_rst),.cyc_i(s8_cyc),.stb_i(s8_stb),.adr_i(s8_adr[4:2]),
	   .we_i(s8_we),.dat_i(s8_dat_o),.dat_o(s8_dat_i),.ack_o(s8_ack),.int_o(proc_int),
	   .irq(irq) );
 	 
   // /////////////////////////////////////////////////////////////////////////
   // Master Timer, Slave #9

   // No longer used, replaced with simple_timer below
   assign s9_ack = 0;
   
   // /////////////////////////////////////////////////////////////////////////
   //  Simple Timer interrupts
   
   simple_timer #(.BASE(SR_SIMTIMER)) simple_timer
     (.clk(wb_clk), .reset(wb_rst),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .onetime_int(onetime_int), .periodic_int(periodic_int));
   
   // /////////////////////////////////////////////////////////////////////////
   // UART, Slave #10

   quad_uart #(.TXDEPTH(3),.RXDEPTH(3)) uart  // depth of 3 is 128 entries
     (.clk_i(wb_clk),.rst_i(wb_rst),
      .we_i(sa_we),.stb_i(sa_stb),.cyc_i(sa_cyc),.ack_o(sa_ack),
      .adr_i(sa_adr[6:2]),.dat_i(sa_dat_o),.dat_o(sa_dat_i),
      .rx_int_o(uart_rx_int),.tx_int_o(uart_tx_int),
      .tx_o(uart_tx_o),.rx_i(uart_rx_i),.baud_o(uart_baud_o));
   
   // /////////////////////////////////////////////////////////////////////////
   // ATR Controller, Slave #11

   reg 		 run_rx_d1;
   always @(posedge dsp_clk)
     run_rx_d1 <= run_rx;
   
   atr_controller atr_controller
     (.clk_i(wb_clk),.rst_i(wb_rst),
      .adr_i(sb_adr[5:0]),.sel_i(sb_sel),.dat_i(sb_dat_o),.dat_o(sb_dat_i),
      .we_i(sb_we),.stb_i(sb_stb),.cyc_i(sb_cyc),.ack_o(sb_ack),
      .run_rx(run_rx_d1),.run_tx(run_tx),.ctrl_lines(atr_lines) );
   
   // //////////////////////////////////////////////////////////////////////////
   // Time Sync, Slave #12 

   // No longer used, see time_64bit.  Still need to handle mimo time, though
   assign sc_ack = 0;
   
   // /////////////////////////////////////////////////////////////////////////
   // ICAP for reprogramming the FPGA, Slave #13 (D)

   s3a_icap_wb s3a_icap_wb
     (.clk(wb_clk), .reset(wb_rst), .cyc_i(sd_cyc), .stb_i(sd_stb), 
      .we_i(sd_we), .ack_o(sd_ack), .dat_i(sd_dat_o), .dat_o(sd_dat_i));
   
   // /////////////////////////////////////////////////////////////////////////
   // SPI for Flash -- Slave #14 (E)
   spi_top flash_spi
     (.wb_clk_i(wb_clk),.wb_rst_i(wb_rst),.wb_adr_i(se_adr[4:0]),.wb_dat_i(se_dat_o),
      .wb_dat_o(se_dat_i),.wb_sel_i(se_sel),.wb_we_i(se_we),.wb_stb_i(se_stb),
      .wb_cyc_i(se_cyc),.wb_ack_o(se_ack),.wb_err_o(se_err),.wb_int_o(spiflash_int),
      .ss_pad_o(spiflash_cs),
      .sclk_pad_o(spiflash_clk),.mosi_pad_o(spiflash_mosi),.miso_pad_i(spiflash_miso) );

   // /////////////////////////////////////////////////////////////////////////
   // DSP RX
   wire [31:0] 	 sample_rx, sample_tx;
   wire 	 strobe_rx, strobe_tx;
   wire 	 rx_dst_rdy, rx_src_rdy, rx1_dst_rdy, rx1_src_rdy;
   wire [99:0] 	 rx_data;
   wire [35:0] 	 rx1_data;
   
   dsp_core_rx #(.BASE(SR_RX_DSP)) dsp_core_rx
     (.clk(dsp_clk),.rst(dsp_rst),
      .set_stb(set_stb_dsp),.set_addr(set_addr_dsp),.set_data(set_data_dsp),
      .adc_a(adc_a),.adc_ovf_a(adc_ovf_a),.adc_b(adc_b),.adc_ovf_b(adc_ovf_b),
      .sample(sample_rx), .run(run_rx_d1), .strobe(strobe_rx),
      .debug(debug_rx_dsp) );

   wire [31:0] 	 vrc_debug;
   
   vita_rx_control #(.BASE(SR_RX_CTRL), .WIDTH(32)) vita_rx_control
     (.clk(dsp_clk), .reset(dsp_rst), .clear(0),
      .set_stb(set_stb_dsp),.set_addr(set_addr_dsp),.set_data(set_data_dsp),
      .vita_time(vita_time), .overrun(overrun),
      .sample(sample_rx), .run(run_rx), .strobe(strobe_rx),
      .sample_fifo_o(rx_data), .sample_fifo_dst_rdy_i(rx_dst_rdy), .sample_fifo_src_rdy_o(rx_src_rdy),
      .debug_rx(vrc_debug));

   wire [3:0] 	 vita_state;
   
   vita_rx_framer #(.BASE(SR_RX_CTRL), .MAXCHAN(1)) vita_rx_framer
     (.clk(dsp_clk), .reset(dsp_rst), .clear(0),
      .set_stb(set_stb_dsp),.set_addr(set_addr_dsp),.set_data(set_data_dsp),
      .sample_fifo_i(rx_data), .sample_fifo_dst_rdy_o(rx_dst_rdy), .sample_fifo_src_rdy_i(rx_src_rdy),
      .data_o(rx1_data), .dst_rdy_i(rx1_dst_rdy), .src_rdy_o(rx1_src_rdy),
      .fifo_occupied(), .fifo_full(), .fifo_empty(),
      .debug_rx(vita_state) );

   fifo_cascade #(.WIDTH(36), .SIZE(DSP_RX_FIFOSIZE)) rx_fifo_cascade
     (.clk(dsp_clk), .reset(dsp_rst), .clear(0),
      .datain(rx1_data), .src_rdy_i(rx1_src_rdy), .dst_rdy_o(rx1_dst_rdy),
      .dataout({wr1_flags,wr1_dat}), .src_rdy_o(wr1_ready_i), .dst_rdy_i(wr1_ready_o));

   // ///////////////////////////////////////////////////////////////////////////////////
   // DSP TX

   wire [35:0] 	 tx_data;
   wire 	 tx_src_rdy, tx_dst_rdy;
   wire [31:0] 	 debug_vt;
   
   fifo_cascade #(.WIDTH(36), .SIZE(DSP_TX_FIFOSIZE)) tx_fifo_cascade
     (.clk(dsp_clk), .reset(dsp_rst), .clear(0),
      .datain({rd1_flags,rd1_dat}), .src_rdy_i(rd1_ready_o), .dst_rdy_o(rd1_ready_i),
      .dataout(tx_data), .src_rdy_o(tx_src_rdy), .dst_rdy_i(tx_dst_rdy) );

   vita_tx_chain #(.BASE_CTRL(SR_TX_CTRL), .BASE_DSP(SR_TX_DSP), 
		   .REPORT_ERROR(1), .PROT_ENG_FLAGS(1)) 
   vita_tx_chain
     (.clk(dsp_clk), .reset(dsp_rst),
      .set_stb(set_stb_dsp),.set_addr(set_addr_dsp),.set_data(set_data_dsp),
      .vita_time(vita_time),
      .tx_data_i(tx_data), .tx_src_rdy_i(tx_src_rdy), .tx_dst_rdy_o(tx_dst_rdy),
      .err_data_o(tx_err_data), .err_src_rdy_o(tx_err_src_rdy), .err_dst_rdy_i(tx_err_dst_rdy),
      .dac_a(dac_a),.dac_b(dac_b),
      .underrun(underrun), .run(run_tx),
      .debug(debug_vt));
   
   assign dsp_rst = wb_rst;

   // ///////////////////////////////////////////////////////////////////////////////////
   // SERDES

   serdes #(.TXFIFOSIZE(SERDES_TX_FIFOSIZE),.RXFIFOSIZE(SERDES_RX_FIFOSIZE)) serdes
     (.clk(dsp_clk),.rst(dsp_rst),
      .ser_tx_clk(ser_tx_clk),.ser_t(ser_t),.ser_tklsb(ser_tklsb),.ser_tkmsb(ser_tkmsb),
      .rd_dat_i(rd0_dat),.rd_flags_i(rd0_flags),.rd_ready_o(rd0_ready_i),.rd_ready_i(rd0_ready_o),
      .ser_rx_clk(ser_rx_clk),.ser_r(ser_r),.ser_rklsb(ser_rklsb),.ser_rkmsb(ser_rkmsb),
      .wr_dat_o(wr0_dat),.wr_flags_o(wr0_flags),.wr_ready_o(wr0_ready_i),.wr_ready_i(wr0_ready_o),
      .tx_occupied(ser_tx_occ),.tx_full(ser_tx_full),.tx_empty(ser_tx_empty),
      .rx_occupied(ser_rx_occ),.rx_full(ser_rx_full),.rx_empty(ser_rx_empty),
      .serdes_link_up(serdes_link_up),.debug0(debug_serdes0), .debug1(debug_serdes1) );

   // /////////////////////////////////////////////////////////////////////////
   // VITA Timing

   time_64bit #(.TICKS_PER_SEC(32'd100000000),.BASE(SR_TIME64)) time_64bit
     (.clk(dsp_clk), .rst(dsp_rst), .set_stb(set_stb_dsp), .set_addr(set_addr_dsp), .set_data(set_data_dsp),
      .pps(pps_in), .vita_time(vita_time), .pps_int(pps_int));
   
   // /////////////////////////////////////////////////////////////////////////////////////////
   // Debug Pins
  
   assign debug_clk = {dsp_clk, wb_clk};
//   assign debug = debug_vt;
   assign debug = {wb_clk, wb_rst, sd_cyc, sd_stb, sd_we, sd_ack, sd_dat_o[7:0], sd_dat_i[7:0], 10'd0};
   
   assign debug_gpio_0 = 32'd0;
   assign debug_gpio_1 = 32'd0;
   
endmodule // u2_core
