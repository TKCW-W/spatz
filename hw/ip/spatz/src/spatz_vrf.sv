// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Matheus Cavalcante, ETH Zurich
//
// The register file stores all vectors, organized into banks.

module spatz_vrf
  import spatz_pkg::*;
  #(
    parameter int unsigned NrReadPorts  = 5,
    parameter int unsigned NrWritePorts = 3,
    parameter int unsigned FpuBufDepth  = 4
  ) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         testmode_i,
    // Write ports
    input  vrf_addr_t [NrWritePorts-1:0] waddr_i,
    input  vrf_data_t [NrWritePorts-1:0] wdata_i,
    input  logic      [NrWritePorts-1:0] we_i,
    input  vrf_be_t   [NrWritePorts-1:0] wbe_i,
    output logic      [NrWritePorts-1:0] wvalid_o,
`ifdef BUF_FPU
    // Signal to track if  result can be buffered or not
    input  logic      [$clog2(FpuBufDepth)-1:0] fpu_buf_usage_i,
`endif
    // Read ports
    input  vrf_addr_t [NrReadPorts-1:0]  raddr_i,
    input  logic      [NrReadPorts-1:0]  re_i,
    output vrf_data_t [NrReadPorts-1:0]  rdata_o,
    output logic      [NrReadPorts-1:0]  rvalid_o,
    // Streaming
    input  logic                         vlefw_en_i, //QW
    input  logic      [NrWritePorts-1:0] vlefw_write_i, //(yx) 
    input  logic      [NrReadPorts-1:0]  vlefw_read_i //(yx)
  );

`include "common_cells/registers.svh"

  ////////////////
  // Parameters //
  ////////////////

  localparam int unsigned NrReadPortsPerBank = 3;

  //////////////
  // Typedefs //
  //////////////

  typedef logic [$bits(vrf_addr_t)-$clog2(NrVRFBanks)-1:0] vregfile_addr_t;

  function automatic logic [$clog2(NrWordsPerBank)-1:0] f_vreg(vrf_addr_t addr);
    f_vreg = addr[$clog2(NrVRFWords)-1:$clog2(NrVRFBanks)];
  endfunction: f_vreg

  function automatic logic [$clog2(NrVRFBanks)-1:0] f_bank(vrf_addr_t addr);
    // Is this vreg divisible by eight?
    automatic logic [1:0] vreg8 = addr[$clog2(8*NrWordsPerVector) +: 2];

    // Barber's pole. Advance the starting bank of each vector by one every eight vector registers.
    f_bank = addr[$clog2(NrVRFBanks)-1:0] + vreg8;
  endfunction: f_bank

 
  /////////////
  // Signals //
  /////////////

  // Write signals
  vregfile_addr_t [NrVRFBanks-1:0] waddr;
  vrf_data_t      [NrVRFBanks-1:0] wdata;
  logic           [NrVRFBanks-1:0] we;
  vrf_be_t        [NrVRFBanks-1:0] wbe;

  // Signals to handle conflicts between VFU and VLSU interfaces
  logic           [NrVRFBanks-1:0] w_vlsu_vfu_conflict;
  logic           [NrVRFBanks-1:0] w_vfu;

  // Read signals
  vregfile_addr_t [NrVRFBanks-1:0][NrReadPortsPerBank-1:0] raddr;
  vrf_data_t      [NrVRFBanks-1:0][NrReadPortsPerBank-1:0] rdata;


  ////////////////////
  // Stream Signals //
  ////////////////////
  vrf_addr_t [1:0] stream_waddr;
  vrf_data_t [1:0] stream_wdata;
  logic      [1:0] stream_wvalid;
  vrf_addr_t [1:0] stream_raddr;
  vrf_data_t [1:0] stream_rdata;
  logic      [1:0] stream_rvalid;

  always_comb begin
    if (vlefw_en_i) begin
      stream_waddr[0] = waddr_i[VLSU0_VD_WD];
      stream_waddr[1] = waddr_i[VLSU1_VD_WD];
      stream_wdata[0] = wdata_i[VLSU0_VD_WD];
      stream_wdata[1] = wdata_i[VLSU1_VD_WD];
      
      stream_raddr[0] = raddr_i[VFU_VS2_RD];
      stream_raddr[1] = raddr_i[VFU_VS1_RD];
    end else begin
      stream_waddr = '{default: '0};
      stream_wdata = '{default: '0};
      stream_raddr = '{default: '0};
    end 
  end

  ////////////////////////////////
  // Streaming VLSU data to VFU //
  ////////////////////////////////
  spatz_stream # ( 
    .NrWritePorts(NrWritePorts),
    .NrReadPorts(NrReadPorts)
  )i_spatz_stream(
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),

    .waddr_i  (stream_waddr),
    .wdata_i  (stream_wdata),
    .wvalid_o (stream_wvalid),

    .raddr_i  (stream_raddr),
    .rdata_o  (stream_rdata),
    .rvalid_o (stream_rvalid),
    
    .vlefw_write_i (vlefw_write_i),
    .vlefw_read_i  (vlefw_read_i)
  );


  ///////////////////
  // Write Mapping //
  ///////////////////

  logic [NrVRFBanks-1:0][NrWritePorts-1:0] write_request;

  // Original

  always_comb begin: gen_write_request
    for (int bank = 0; bank < NrVRFBanks; bank++) begin
       for (int port = 0; port < NrWritePorts; port++) begin
          write_request[bank][port] = we_i[port] && f_bank(waddr_i[port]) == bank;
          if ((port == VLSU0_VD_WD || port == VLSU1_VD_WD) && vlefw_en_i) begin
            write_request[bank][port] = 1'b0;
          end
       end
    end
  end: gen_write_request

  always_comb begin : proc_write
    waddr    = '0;
    wdata    = '0;
    we       = '0;
    wbe      = '0;
    wvalid_o = '0;

    // QW: Handle streaming VLSU wvalid FIRST (before bank loop)
    if (vlefw_en_i) begin
      wvalid_o[VLSU0_VD_WD] = stream_wvalid[0];
      wvalid_o[VLSU1_VD_WD] = stream_wvalid[1];
    end


    // For each bank, we have a priority based access scheme. First priority always has the VFU,
    // second priority has the LSU, and third priority has the slide unit.
    for (int unsigned bank = 0; bank < NrVRFBanks; bank++) begin
    
    // QW: VRF Merge from Pulp Spatz Main commit 
    // The commit handles VFU conflict with one signal VLSU
    // Now we ignore the bank conflict between two VLSUs (VLSU0 still prioritised) but take the second VLSU into account as well. 
`ifdef BUF_FPU
      automatic logic write_request_vlsu = write_request[bank][VLSU0_VD_WD] || write_request[bank][VLSU1_VD_WD]; 
      w_vlsu_vfu_conflict[bank] = write_request_vlsu & write_request[bank][VFU_VD_WD];
      // Prioritize VFU when VFU buffer usage is high
      // Otherwise VLSU gets the priority
      w_vfu[bank] = w_vlsu_vfu_conflict[bank] && (fpu_buf_usage_i >= (FpuBufDepth-2));
`else
      // If no buffering is done, prioritize VFU always
      w_vfu[bank] = 1'b1;
`endif
      if (~w_vfu[bank]) begin
        // Prioritize VLSU interfaces
        if (write_request[bank][VLSU0_VD_WD]) begin
          waddr[bank]          = f_vreg(waddr_i[VLSU0_VD_WD]);
          wdata[bank]          = wdata_i[VLSU0_VD_WD];
          we[bank]             = 1'b1;
          wbe[bank]            = wbe_i[VLSU0_VD_WD];
          if (!vlefw_en_i) begin
            wvalid_o[VLSU0_VD_WD] = 1'b1;
          end
        end else if (write_request[bank][VLSU1_VD_WD]) begin
          waddr[bank]          = f_vreg(waddr_i[VLSU1_VD_WD]);
          wdata[bank]          = wdata_i[VLSU1_VD_WD];
          we[bank]             = 1'b1;
          wbe[bank]            = wbe_i[VLSU1_VD_WD];
          if (!vlefw_en_i) begin
            wvalid_o[VLSU1_VD_WD] = 1'b1;
          end
        end else if (write_request[bank][VFU_VD_WD]) begin
          waddr[bank]         = f_vreg(waddr_i[VFU_VD_WD]);
          wdata[bank]         = wdata_i[VFU_VD_WD];
          we[bank]            = 1'b1;
          wbe[bank]           = wbe_i[VFU_VD_WD];
          wvalid_o[VFU_VD_WD] = 1'b1;
        end else if (write_request[bank][VSLDU_VD_WD]) begin
          waddr[bank]           = f_vreg(waddr_i[VSLDU_VD_WD]);
          wdata[bank]           = wdata_i[VSLDU_VD_WD];
          we[bank]              = 1'b1;
          wbe[bank]             = wbe_i[VSLDU_VD_WD];
          wvalid_o[VSLDU_VD_WD] = 1'b1;
        end
      end else begin
        //QW
        // Bank write port 0 - Priority: vd (0) -> lsu (round-robin) <-> sld (round-robin)
        if (write_request[bank][VFU_VD_WD]) begin
          waddr[bank]         = f_vreg(waddr_i[VFU_VD_WD]);
          wdata[bank]         = wdata_i[VFU_VD_WD];
          we[bank]            = 1'b1;
          wbe[bank]           = wbe_i[VFU_VD_WD];
          wvalid_o[VFU_VD_WD] = 1'b1;
        end else if (write_request[bank][VLSU0_VD_WD]) begin
          waddr[bank]           = f_vreg(waddr_i[VLSU0_VD_WD]);
          wdata[bank]           = wdata_i[VLSU0_VD_WD];
          we[bank]              = 1'b1; 
          wbe[bank]             = wbe_i[VLSU0_VD_WD];
          if (!vlefw_en_i) begin
            wvalid_o[VLSU0_VD_WD] = 1'b1;
          end
        end else if (write_request[bank][VLSU1_VD_WD]) begin
          waddr[bank]           = f_vreg(waddr_i[VLSU1_VD_WD]);
          wdata[bank]           = wdata_i[VLSU1_VD_WD];
          we[bank]              = 1'b1; // No write enable to VRF if forward is enabled (yx)
          wbe[bank]             = wbe_i[VLSU1_VD_WD];
          if (!vlefw_en_i) begin
            wvalid_o[VLSU1_VD_WD] = 1'b1;
          end
        end else if (write_request[bank][VSLDU_VD_WD]) begin
          waddr[bank]           = f_vreg(waddr_i[VSLDU_VD_WD]);
          wdata[bank]           = wdata_i[VSLDU_VD_WD];
          we[bank]              = 1'b1;
          wbe[bank]             = wbe_i[VSLDU_VD_WD];
          wvalid_o[VSLDU_VD_WD] = 1'b1;
        end
      end
    end
  end

  //////////////////
  // Read Mapping //
  //////////////////

  logic [NrVRFBanks-1:0][NrReadPorts-1:0] read_request;
  always_comb begin: gen_read_request
    for (int bank = 0; bank < NrVRFBanks; bank++) begin
      for (int port = 0; port < NrReadPorts; port++) begin
        read_request[bank][port] = re_i[port] && f_bank(raddr_i[port]) == bank;
        if ((port == VFU_VS2_RD || port == VFU_VS1_RD) && vlefw_en_i) begin
          read_request[bank][port] = 1'b0;
        end
      end
    end
  end: gen_read_request

  always_comb begin : proc_read
    raddr    = '0;
    rvalid_o = '0;
    rdata_o  = 'x;

    if (vlefw_en_i) begin
      rdata_o[VFU_VS2_RD]  = stream_rdata[0];
      rvalid_o[VFU_VS2_RD] = stream_rvalid[0];
      rdata_o[VFU_VS1_RD]  = stream_rdata[1];
      rvalid_o[VFU_VS1_RD] = stream_rvalid[1];
    end

    // For each port or each bank we have a priority based access scheme.
    // Port zero can only be accessed by the VFU (vs2). Port one can be accessed by
    // the VFU (vs1) and then by the slide unit. Port two can be accessed first by the
    // VFU (vd), then by the LSU.
    for (int unsigned bank = 0; bank < NrVRFBanks; bank++) begin
      // Bank read port 0 - Priority: VFU (2) -> VLSU
      if (read_request[bank][VFU_VS2_RD]) begin
      // Confirm read from which VLSU

        raddr[bank][0]       = f_vreg(raddr_i[VFU_VS2_RD]);
        if (!vlefw_en_i) begin
          rdata_o[VFU_VS2_RD]  = rdata[bank][0]; 
          rvalid_o[VFU_VS2_RD] = 1'b1;          
        end
 
      end else if (read_request[bank][VLSU0_VS2_RD]) begin
        raddr[bank][0]        = f_vreg(raddr_i[VLSU0_VS2_RD]);
        rdata_o[VLSU0_VS2_RD]  = rdata[bank][0];
        rvalid_o[VLSU0_VS2_RD] = 1'b1;
      end else if (read_request[bank][VLSU1_VS2_RD]) begin
        raddr[bank][0]        = f_vreg(raddr_i[VLSU1_VS2_RD]);
        rdata_o[VLSU1_VS2_RD]  = rdata[bank][0];
        rvalid_o[VLSU1_VS2_RD] = 1'b1;
      end 

      // Bank read port 1 - Priority: VFU (1) -> VSLDU
      if (read_request[bank][VFU_VS1_RD]) begin
        raddr[bank][1]       = f_vreg(raddr_i[VFU_VS1_RD]);
        if (!vlefw_en_i) begin
          rdata_o[VFU_VS1_RD]  = rdata[bank][1]; 
          rvalid_o[VFU_VS1_RD] = 1'b1;          
        end          

      end else if (read_request[bank][VSLDU_VS2_RD]) begin
        raddr[bank][1]         = f_vreg(raddr_i[VSLDU_VS2_RD]);
        rdata_o[VSLDU_VS2_RD]  = rdata[bank][1];
        rvalid_o[VSLDU_VS2_RD] = 1'b1;
      end

      // Bank read port 2 - Priority: VFU (D) -> VLSU
      if (read_request[bank][VFU_VD_RD]) begin
          raddr[bank][2]       = f_vreg(raddr_i[VFU_VD_RD]);
          rdata_o[VFU_VD_RD]  = rdata[bank][2]; 
          rvalid_o[VFU_VD_RD] = 1'b1;       
      end else if (read_request[bank][VLSU0_VD_RD]) begin
        raddr[bank][2]       = f_vreg(raddr_i[VLSU0_VD_RD]);
        rdata_o[VLSU0_VD_RD]  = rdata[bank][2];
        rvalid_o[VLSU0_VD_RD] = 1'b1;
      end else if (read_request[bank][VLSU1_VD_RD]) begin
        raddr[bank][2]       = f_vreg(raddr_i[VLSU1_VD_RD]);
        rdata_o[VLSU1_VD_RD]  = rdata[bank][2];
        rvalid_o[VLSU1_VD_RD] = 1'b1;
      end
    end
  end

  ////////////////
  // VREG Banks //
  ////////////////

  for (genvar bank = 0; bank < NrVRFBanks; bank++) begin : gen_reg_banks
    for (genvar cut = 0; cut < N_FU; cut++) begin: gen_vrf_slice
      elen_t [NrReadPortsPerBank-1:0] rdata_int;

      for (genvar port = 0; port < NrReadPortsPerBank; port++) begin: gen_rdata_assignment
        assign rdata[bank][port][ELEN*cut +: ELEN] = rdata_int[port];
      end

      vregfile #(
        .NrReadPorts(NrReadPortsPerBank),
        .NrWords    (NrWordsPerBank    ),
        .WordWidth  (ELEN              )
      ) i_vregfile (
        .clk_i     (clk_i                        ),
        .rst_ni    (rst_ni                       ),
        .testmode_i(testmode_i                   ),
        .waddr_i   (waddr[bank]                  ),
        .wdata_i   (wdata[bank][ELEN*cut +: ELEN]),
        .we_i      (we[bank]                     ),
        .wbe_i     (wbe[bank][ELENB*cut +: ELENB]),
        .raddr_i   (raddr[bank]                  ),
        .rdata_o   (rdata_int                    )
      );
    end
  end

  ////////////////
  // Assertions //
  ////////////////

  if (NrReadPorts < 1)
    $error("[spatz_vrf] The number of read ports has to be greater than zero.");

  if (NrWritePorts < 1)
    $error("[spatz_vrf] The number of write ports has to be greater than zero.");

  if (NrReadPorts / NrReadPortsPerBank > NrVRFBanks)
    $error("[spatz_vrf] The number of vregfile banks needs to be increased to handle the number of read ports.");

endmodule : spatz_vrf