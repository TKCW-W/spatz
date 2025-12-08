module spatz_stream
  import spatz_pkg::*;
  #(
    parameter int unsigned NrReadPorts  = 5,
    parameter int unsigned NrWritePorts = 3
  ) (
    input  logic                         clk_i,
    input  logic                         rst_ni,

    input  vrf_addr_t [1:0]              waddr_i,
    input  vrf_data_t [1:0]              wdata_i,
    output logic      [1:0]              wvalid_o,

    input  vrf_addr_t [2:0]              raddr_i,
    output vrf_data_t [2:0]              rdata_o,
    output logic      [2:0]              rvalid_o,

    input  logic      [NrWritePorts-1:0] vlefw_write_i, 
    input  logic      [NrReadPorts-1:0]  vlefw_read_i 
  );

// Include FF
`include "common_cells/registers.svh"

    //Signals//
    //Idx 0 for VLSU0, Idx 1 for VLSU1
    vrf_data_t [1:0]  buffer_data_q;
    vrf_addr_t [1:0]  buffer_addr_q;
    logic      [1:0]  buffer_valid_q;//High when buffer holds data, low if buffer empty

    logic      [1:0]  vfu_buffer;//High when data streamed to vfu from buffer
    logic      [1:0]  vfu_fallthrough;//High when data streamed to vfu from vlsu directly
    logic      [1:0]  buffer_drain;//Drain valid data from buffer
    logic      [1:0]  buffer_fill;//Fill valid data to buffer

    //Idx 0 for VFU_VS2_RD, Idx1 for VFU_VS1_RD, Idx2 for VFU_VD_RD. registered for sync purpose
    vrf_data_t [2:0]  staged_rdata_d, staged_rdata_q;
    logic      [2:0]  staged_rvalid_d, staged_rvalid_q;

    logic      vlsu0_delivered, vlsu1_delivered, both_ready;

    //Hardwrite sync mode. Sync for fdotp, faxpy. No sync for gemv
    logic      stream_sync;
    assign     stream_sync = 1'b0;


    // Stream Buffers Update
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            buffer_valid_q <= '0;
            buffer_data_q  <= '{default: '0};
            buffer_addr_q <= '{default: '0};
        end else begin
            //VLSU0 bufffer
            if (buffer_fill[0]) begin
                buffer_data_q[0]  <= wdata_i[0];
                buffer_addr_q[0]  <= waddr_i[0];
                buffer_valid_q[0] <= 1'b1;
            end else if (buffer_drain[0]) begin
                buffer_valid_q[0] <= 1'b0;
            end

            //VLSU1 buffer
            if (buffer_fill[1]) begin
                buffer_data_q[1]  <= wdata_i[1];
                buffer_addr_q[1]  <= waddr_i[1];
                buffer_valid_q[1] <= 1'b1;
            end else if (buffer_drain[1]) begin
                buffer_valid_q[1] <= 1'b0;
            end           
        end
    end

    //Staged registers update
    `FF(staged_rdata_q, staged_rdata_d, '0)
    `FF(staged_rvalid_q, staged_rvalid_d, '0)

    //Stream Logic
    always_comb begin
        rdata_o         = '0;
        rvalid_o        = '0;
        wvalid_o        = '0;

        vfu_buffer      = '0;
        vfu_fallthrough = '0;
        buffer_drain    = '0;
        buffer_fill     = '0;

        vlsu0_delivered = '0;
        vlsu1_delivered = '0;
        both_ready      = '0;

        staged_rdata_d  = staged_rdata_q;
        staged_rvalid_d = staged_rvalid_q;


        //VFU is enabled for stream reading
        //Stream from buffer if not empty, otherwise from VLSU with matched address
        if (|vlefw_read_i) begin
            
            //VLSU0 buffer
            if (buffer_valid_q[0]) begin //VLSU0 buffer has valid data
                for (int port = 0; port < 3; port++) begin
                    if (vlefw_read_i[port] && (raddr_i[port] == buffer_addr_q[0])) begin
                        staged_rdata_d[port]  = buffer_data_q[0];
                        staged_rvalid_d[port] = 1'b1;
                        vfu_buffer[0]       = 1'b1;
                        buffer_drain[0]     = 1'b1; //VLSU0 buffer data streamed to VFU_VS2_RD

                        if (vlefw_write_i[VLSU0_VD_WD]) begin
                            buffer_fill[0]  = 1'b1; //Fill the buffer if VLSU0 has new valid data
                        end
                    end
                end
            end else begin // VLSU0 buffer empty, try to stream from VLSU0 directly if addr matched 
                if (vlefw_write_i[VLSU0_VD_WD]) begin // Fall through only when VLSU0 has data to provide
                    for (int i = 0; i < 3; i++) begin
                        if (vlefw_read_i[i] && (raddr_i[i] == waddr_i[0])) begin
                           staged_rdata_d[i]    = wdata_i[0];
                           staged_rvalid_d[i]   = 1'b1;
                           vfu_fallthrough[0] = 1'b1; 
                        end
                    end

                    if (!vfu_fallthrough[0]) begin
                        buffer_fill[0] = 1'b1;
                    end
                end
            end

            //VLSU1 buffer
            if (buffer_valid_q[1]) begin //VLSU1 buffer has valid data
                for (int port = 0; port < 3; port++) begin
                    if (vlefw_read_i[port] && (raddr_i[port] == buffer_addr_q[1])) begin
                        staged_rdata_d[port]  = buffer_data_q[1];
                        staged_rvalid_d[port] = 1'b1;
                        vfu_buffer[1]       = 1'b1;
                        buffer_drain[1]     = 1'b1; //VLSU0 buffer data streamed to VFU_VS2_RD

                        if (vlefw_write_i[VLSU1_VD_WD]) begin
                            buffer_fill[1]  = 1'b1; //Fill the buffer if VLSU0 has new valid data
                        end
                    end
                end
            end else begin // VLSU0 buffer empty, try to stream from VLSU0 directly if addr matched 
                if (vlefw_write_i[VLSU1_VD_WD]) begin // Fall through only when VLSU0 has data to provide
                    for (int i = 0; i < 3; i++) begin
                        if (vlefw_read_i[i] && (raddr_i[i] == waddr_i[1])) begin
                           staged_rdata_d[i]    = wdata_i[1];
                           staged_rvalid_d[i]   = 1'b1;
                           vfu_fallthrough[1] = 1'b1; 
                        end
                    end

                    if (!vfu_fallthrough[1]) begin
                        buffer_fill[1] = 1'b1;
                    end
                end
            end

            // Synchronization and commit
            vlsu0_delivered = vfu_buffer[0] | vfu_fallthrough[0] | staged_rvalid_q[0];
            vlsu1_delivered = vfu_buffer[1] | vfu_fallthrough[1] | staged_rvalid_q[1];
            both_ready      = (staged_rvalid_d[0] && staged_rvalid_d[1]) || (staged_rvalid_d[0] && staged_rvalid_d[2]) || (staged_rvalid_d[1] && staged_rvalid_d[2]); //vlsu0_delivered & vlsu1_delivered;//?use staged_rvalid_d since includes updates already?

            if (stream_sync) begin //No sync for gemv because each vlsu tracks different instructions due to loop unrolling
                if (both_ready) begin
                    if (staged_rvalid_d[0]) begin //?If both ready, must have valid data
                        rdata_o[0]  = staged_rdata_d[0];
                        rvalid_o[0] = 1'b1;
                    end

                    if (staged_rvalid_d[1]) begin
                        rdata_o[1]  = staged_rdata_d[1];
                        rvalid_o[1] = 1'b1;
                    end

                    if (staged_rvalid_d[2]) begin
                        rdata_o[2]  = staged_rdata_d[2];
                        rvalid_o[2] = 1'b1;
                    end

                    //clear the staged registers
                    staged_rvalid_d = '0;
                end
            end else begin
                if (vlsu0_delivered | vlsu1_delivered) begin
                    if (staged_rvalid_d[0]) begin 
                        rdata_o[0]  = staged_rdata_d[0];
                        rvalid_o[0] = 1'b1;
                        staged_rvalid_d[0] = 1'b0;
                    end

                    if (staged_rvalid_d[1]) begin
                        rdata_o[1]  = staged_rdata_d[1];
                        rvalid_o[1] = 1'b1;
                        staged_rvalid_d[1] = 1'b0;
                    end

                    if (staged_rvalid_d[2]) begin
                        rdata_o[2]  = staged_rdata_d[2];
                        rvalid_o[2] = 1'b1;
                        staged_rvalid_d[2] = 1'b0;
                    end
                end
            end

            if (vfu_fallthrough[0] || buffer_fill[0]) wvalid_o[0] = 1'b1; 
            if (vfu_fallthrough[1] || buffer_fill[1]) wvalid_o[1] = 1'b1;             

        end

        // VLSUs enabled for streaming write, data pushed to buffer only if valid write data and buffer empty and data not fall through to vfu
        if (vlefw_write_i[VLSU0_VD_WD] && !buffer_valid_q[0] && !vfu_fallthrough[0]) begin
            buffer_fill[0] = 1'b1;
            wvalid_o[0]    = 1'b1;
        end
            
        if (vlefw_write_i[VLSU1_VD_WD] && !buffer_valid_q[1] && !vfu_fallthrough[1]) begin
            buffer_fill[1] = 1'b1;
            wvalid_o[1]    = 1'b1;
        end
    end



endmodule : spatz_stream