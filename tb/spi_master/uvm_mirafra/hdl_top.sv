`ifndef HDL_TOP_INCLUDED_
`define HDL_TOP_INCLUDED_

//--------------------------------------------------------------------------------------------
// Module      : HDL Top
// Description : It has apb_master_agent_bfm and spi_slave agent bfm.
//
// GARUDA copy of Mirafra's src/dv/hdl_top/hdl_top.sv (mbits-mirafra,
// pulpino__spi_master__ip_verification, MIT licence). Only the DUT instance is
// changed; clock, reset, interfaces, BFMs and the FIFO assertion bind are theirs.
//--------------------------------------------------------------------------------------------
module hdl_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  //import apb_global_pkg::*;
  //-------------------------------------------------------
  // Clock Reset Initialization
  //-------------------------------------------------------
  //bit clk;
  //bit rst;

  //-------------------------------------------------------
  // Display statement for hdl_top
  //-------------------------------------------------------
  initial begin
    `uvm_info("UVM_INFO","hdl_top",UVM_LOW);
  end

  //Variable : pclk
  //Declaration of system clock
  bit pclk;

  //Variable : preset_n
  //Declaration of system reset
  bit preset_n;

  bit [1:0]spi_mode;
  bit csn1;
  bit csn2;
  bit csn3;
  bit [1:0]events;

  //-------------------------------------------------------
  //Generation of system clock at frequency rate of 20ns
  //-------------------------------------------------------
  initial begin
    pclk = 1'b0;
    forever #10 pclk =!pclk;
  end

  //-------------------------------------------------------
  //Generation of system preset_n
  //system reset can be asserted asynchronously
  //system reset de-assertion is synchronous.
  //-------------------------------------------------------
  initial begin
    preset_n = 1'b1;
    
    #15 preset_n = 1'b0;

    repeat(1) begin
      @(posedge pclk);
    end
    preset_n = 1'b1;
  end

  //-------------------------------------------------------
  // apb Interface Instantiation
  //-------------------------------------------------------
  apb_if apb_intf(pclk,preset_n);

  //-------------------------------------------------------
  // apb Master BFM Agent Instantiation
  //-------------------------------------------------------
  apb_master_agent_bfm apb_master_agent_bfm_h(apb_intf); 

  //-------------------------------------------------------
  // spi Interface Instantiation
  //-------------------------------------------------------
  spi_if spi_intf(pclk,preset_n);

  //-------------------------------------------------------
  // apb Master BFM Agent Instantiation
  //-------------------------------------------------------
  // GARUDA: the DUT is the SPI master AS INTEGRATED - garuda_spim_top, i.e. the
  // PULP apb_spi_master behind GARUDA's APB shim, with the pins the chip has.
  // Mirafra's own top instantiates the bare apb_spi_master and takes MISO on
  // lane 0 (their copy of spi_master_rx.sv was changed to sample sdi0). The
  // upstream IP that GARUDA vendors samples lane 1 in standard mode, and the
  // wrapper puts the board's MISO there - so the SPI VIP's miso0 goes to the
  // wrapper's one MISO pin, exactly as a device on the board would see it.
  wire irq, dma_req, cs_imu_n;

  garuda_spim_top DUT
  (
       .pclk_i(apb_intf.pclk),
       .preset_n_i(apb_intf.preset_n),
       .psel_i(apb_intf.pselx[0]),
       .penable_i(apb_intf.penable),
       .pwrite_i(apb_intf.pwrite),
       .paddr_i(apb_intf.paddr[11:0]),
       .pwdata_i(apb_intf.pwdata),
       .prdata_o(apb_intf.prdata),
       .pready_o(apb_intf.pready),
       .pslverr_o(apb_intf.pslverr),

       .irq_o(irq),
       .dma_req_o(dma_req),
       .dma_ack_i(1'b0),

       .spim_sclk_o(spi_intf.sclk),
       .spim_mosi_o(spi_intf.mosi0),
       .spim_miso_i(spi_intf.miso0),
       .spim_cs_flash_n_o(spi_intf.cs),
       .spim_cs_imu_n_o(cs_imu_n)
  );

  bind spi_master_fifo fifo_assertions MAS_FIFO_ASSERT ( .clk_i(clk_i        ),
                                                        .rst_ni(rst_ni      ),
                                                        .clr_i(clr_i        ),
                                                        .elements_o(elements_o ),
                                                        .ready_i(ready_i),
                                                        .valid_i(valid_i),
                                                        .valid_o(valid_o)
                                                      );

  //-------------------------------------------------------
  // spi slave agent bfm Instantiation
  //-------------------------------------------------------
  spi_slave_agent_bfm spi_agent_bfm_h(spi_intf);

endmodule : hdl_top

`endif
