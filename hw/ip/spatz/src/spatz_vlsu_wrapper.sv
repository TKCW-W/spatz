// The VLSU Wrapper unit is the higher level containing the shared operation queue, address generation(address offset calculation) 
// and memory/commit counters(for synchronisation of memory responses and VRF requests) with two lightweight VLSU core focusing 
// purely on data movement, each has its own memory and VRF ports and ROB per port. It would be utilised for two unit/strided 
// vle operation having same vl, vsew, and stride value, which prepare the data for the chained e.g. vmul after them. 

//Current Stage: We move only the operation queue to the wrapper level, duplicate everything else.

module spatz_vlsu_wrapper
  import spatz_pkg::*;
  import rvv_pkg::*;
  import cf_math_pkg::idx_width; #(
    parameter int unsigned   NrMemPorts         = 1,//now is 8 form spatz from spatz_cc
    parameter int unsigned   NrOutstandingLoads = 8,
    // Memory request
    parameter  type          spatz_mem_req_t    = logic,
    parameter  type          spatz_mem_rsp_t    = logic,
    // Dependant parameters. DO NOT CHANGE!
    localparam int  unsigned IdWidth            = idx_width(NrOutstandingLoads)
  ) (
    input  logic                            clk_i,
    input  logic                            rst_ni,
    // Spatz request
    input  spatz_req_t                      spatz_req_i,
    input  logic                            spatz_req_valid_i,
    output logic                            spatz_req_ready_o,
    // VLSU response to controller
    output logic           [1:0]            vlsu_rsp_valid_o,//Bit 0 for VLSU0, Bit 1 for VLSU1
    output vlsu_rsp_t      [1:0]            vlsu_rsp_o,
    // Interface with the VRF
    output vrf_addr_t      [1:0]                 vrf_waddr_o,
    output vrf_data_t      [1:0]                 vrf_wdata_o,
    output logic           [1:0]                 vrf_we_o,
    output vrf_be_t        [1:0]                 vrf_wbe_o,
    input  logic           [1:0]                 vrf_wvalid_i,
    output spatz_id_t      [5:0]                 vrf_id_o, //?
    output vrf_addr_t      [3:0]                 vrf_raddr_o,
    output logic           [3:0]                 vrf_re_o,
    input  vrf_data_t      [3:0]                 vrf_rdata_i,
    input  logic           [3:0]                 vrf_rvalid_i,
    // Memory Request
    output spatz_mem_req_t [NrMemPorts-1:0] spatz_mem_req_o,
    output logic           [NrMemPorts-1:0] spatz_mem_req_valid_o,
    input  logic           [NrMemPorts-1:0] spatz_mem_req_ready_i,
    //  Memory Response
    input  spatz_mem_rsp_t [NrMemPorts-1:0] spatz_mem_rsp_i,
    input  logic           [NrMemPorts-1:0] spatz_mem_rsp_valid_i,
    // Memory Finished
    output logic           [1:0]                 spatz_mem_finished_o,
    output logic           [1:0]                 spatz_mem_str_finished_o,

    output logic [4:0]      vlsu0_vd_o
  );

// Include FF
`include "common_cells/registers.svh"


// Convert the vl to number of bytes for all element widths

spatz_req_t spatz_req_d;

always_comb begin: proc_spatz_req
    spatz_req_d = spatz_req_i;

unique case (spatz_req_i.vtype.vsew)
    EW_8: begin
        spatz_req_d.vl     = spatz_req_i.vl;
        spatz_req_d.vstart = spatz_req_i.vstart;
    end
    EW_16: begin
        spatz_req_d.vl     = spatz_req_i.vl << 1;
        spatz_req_d.vstart = spatz_req_i.vstart << 1;
    end
    EW_32: begin
        spatz_req_d.vl     = spatz_req_i.vl << 2;
        spatz_req_d.vstart = spatz_req_i.vstart << 2;
    end
    default: begin
        spatz_req_d.vl     = spatz_req_i.vl << MAXEW;
        spatz_req_d.vstart = spatz_req_i.vstart << MAXEW;
    end
endcase
end: proc_spatz_req

//ToDo: Check whether indexed memory access, strided memory access (with different strided value than previous)
//Operation queue only chain second vle only if unit stride, strided with same stride value.

///////////////////////
//  Operation queue  //
///////////////////////

//ToDo: OQ chain second vle only if same vl, vsew, unit stride or strided but with same stride value. Check this in OQ
logic queue_ready;
spatz_req_t mem_spatz_req;
logic       mem_spatz_req_valid;
logic [1:0] mem_spatz_req_ready;//Bit 0 for VLSU0, Bit 1 for VLSU1, asserted if corresponding VLSU_Core finishes all memory requests. NOT USED

logic       [1:0] core_busy_q, core_busy_d;
spatz_req_t [1:0] core_req_q, core_req_d;

//VLSUCore1 Extra delay for the sake of bank conflicts
spatz_req_t core1_req_qq, core1_req_qqq;
logic       core1_busy_qq, core1_busy_qqq;

spill_register #(
    .T(spatz_req_t)
) i_operation_queue (
    .clk_i  (clk_i                                          ),
    .rst_ni (rst_ni                                         ),
    .data_i (spatz_req_d                                    ),
    .valid_i(spatz_req_valid_i && spatz_req_i.ex_unit == LSU),
    .ready_o(spatz_req_ready_o                              ),//ready to accept new inst from controller
    .data_o (mem_spatz_req                                  ),
    .valid_o(mem_spatz_req_valid                            ),//has data for output
    .ready_i((mem_spatz_req_ready[0]||mem_spatz_req_ready[1])||(core_busy_d[0] == 1 && core_busy_d[1] == 0))//queue_ready                          ) //downstream ready to handle new instruction, OUTPUT from vlsu_core
);

//ToDO: Save the memory access type in the corresponding VLSU Core?


always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        core_busy_q <= 2'b00;
        core_req_q <= '{default: '0};
        core1_busy_qq <= 1'b0;
        core1_req_qq <= '{default: '0};
        core1_busy_qq <= 1'b0;
        core1_req_qq <= '{default: '0};       
    end else begin
        core_busy_q <= core_busy_d;
        core_req_q <= core_req_d;

        //Core1 Extra delay
        core1_req_qq <= core_req_q[1];
        core1_busy_qq <= core_busy_q[1];
        core1_req_qqq <= core1_req_qq;
        core1_busy_qqq <= core1_busy_qq;
    end
end

always_comb begin
    core_busy_d = core_busy_q;
    core_req_d = core_req_q;

    if (mem_spatz_req_ready[0]) begin//spatz_mem_finished_o[0]) begin
        core_busy_d[0] = 1'b0;
    end 

    if (mem_spatz_req_ready[1]) begin//spatz_mem_finished_o[1]) begin
        core_busy_d[1] = 1'b0;
    end

    if (mem_spatz_req_valid) begin
        if (!core_busy_q[0]) begin
            core_req_d[0] = mem_spatz_req;
            core_busy_d[0] = 1'b1;
        end else if (!core_busy_q[1]) begin
            core_req_d[1] = mem_spatz_req;
            core_busy_d[1] = 1'b1;
        end
    end
end

assign queue_ready = mem_spatz_req_valid && (!core_busy_q[0]||!core_busy_q[1]);


//Distribute Memory ports
localparam int unsigned NrCoreMemPorts = NrMemPorts / 2;

assign vlsu0_vd_o = core_req_q[0].vd;


//VLSU Core
spatz_vlsu_core #(
    .NrMemPorts          (NrCoreMemPorts),
    .spatz_mem_req_t     (spatz_mem_req_t),
    .spatz_mem_rsp_t     (spatz_mem_rsp_t)
)i_spatz_vlsu_core0(
    .clk_i                     (clk_i),
    .rst_ni                    (rst_ni),
    //Request
    .spatz_req_i               (core_req_q[0]),
    .spatz_req_valid_i         (core_busy_q[0]),//core_req_valid[0]),
    .spatz_req_ready_o         (mem_spatz_req_ready[0]),
    //Response via to Controller
    .vlsu_rsp_valid_o          (vlsu_rsp_valid_o[0]),//indicates instruction finished 
    .vlsu_rsp_o                (vlsu_rsp_o[0]),//goes to controller, used in sb?, holds finished instruction id for whole execution
    // VRF
    .vrf_waddr_o               (vrf_waddr_o[0]                                   ),
    .vrf_wdata_o               (vrf_wdata_o[0]                                   ),
    .vrf_we_o                  (vrf_we_o[0]                                      ),
    .vrf_wbe_o                 (vrf_wbe_o[0]                                     ),
    .vrf_wvalid_i              (vrf_wvalid_i[0]                                  ),
    .vrf_raddr_o               (vrf_raddr_o[1:0]                                 ),
    .vrf_re_o                  (vrf_re_o[1:0]                                    ),
    .vrf_rdata_i               (vrf_rdata_i[1:0]                                 ),
    .vrf_rvalid_i              (vrf_rvalid_i[1:0]                                ),
    .vrf_id_o                  (vrf_id_o[2:0]                                    ),
    // Interface Memory
    .spatz_mem_req_o           (spatz_mem_req_o[NrCoreMemPorts-1:0]              ),
    .spatz_mem_req_valid_o     (spatz_mem_req_valid_o[NrCoreMemPorts-1:0]        ),
    .spatz_mem_req_ready_i     (spatz_mem_req_ready_i[NrCoreMemPorts-1:0]        ),
    .spatz_mem_rsp_i           (spatz_mem_rsp_i[NrCoreMemPorts-1:0]              ),
    .spatz_mem_rsp_valid_i     (spatz_mem_rsp_valid_i[NrCoreMemPorts-1:0]        ),
    .spatz_mem_finished_o      (spatz_mem_finished_o[0]                          ),//goes to FPU sequencer
    .spatz_mem_str_finished_o  (spatz_mem_str_finished_o[0]                      )
);



spatz_vlsu_core #(
    .NrMemPorts         (NrCoreMemPorts),
    .spatz_mem_req_t    (spatz_mem_req_t),
    .spatz_mem_rsp_t    (spatz_mem_rsp_t)
)i_spatz_vlsu_core1(
    .clk_i                     (clk_i),
    .rst_ni                    (rst_ni),
    //Request
    .spatz_req_i               (core_req_q[1]),//core_req_q[1]),core1_req_qqq
    .spatz_req_valid_i         (core_busy_q[1]),//core_busy_q[1]),//core_req_valid[1]),
    .spatz_req_ready_o         (mem_spatz_req_ready[1]),
    //Response via to Controller
    .vlsu_rsp_valid_o          (vlsu_rsp_valid_o[1]),//indicates instruction finished 
    .vlsu_rsp_o                (vlsu_rsp_o[1]),//goes to controller, used in sb?, holds finished instruction id for whole execution
    // VRF
    .vrf_waddr_o               (vrf_waddr_o[1]                                 ),
    .vrf_wdata_o               (vrf_wdata_o[1]                                 ),
    .vrf_we_o                  (vrf_we_o[1]                                      ),
    .vrf_wbe_o                 (vrf_wbe_o[1]                                   ),
    .vrf_wvalid_i              (vrf_wvalid_i[1]                                ),
    .vrf_raddr_o               (vrf_raddr_o[3:2]                     ),
    .vrf_re_o                  (vrf_re_o[3:2]                          ),
    .vrf_rdata_i               (vrf_rdata_i[3:2]                     ),
    .vrf_rvalid_i              (vrf_rvalid_i[3:2]                    ),
    .vrf_id_o                  (vrf_id_o[5:3] ),
    // Interface Memory
    .spatz_mem_req_o           (spatz_mem_req_o[NrMemPorts-1:NrCoreMemPorts]                            ),
    .spatz_mem_req_valid_o     (spatz_mem_req_valid_o[NrMemPorts-1:NrCoreMemPorts]                       ),
    .spatz_mem_req_ready_i     (spatz_mem_req_ready_i[NrMemPorts-1:NrCoreMemPorts]                        ),
    .spatz_mem_rsp_i           (spatz_mem_rsp_i[NrMemPorts-1:NrCoreMemPorts]                              ),
    .spatz_mem_rsp_valid_i     (spatz_mem_rsp_valid_i[NrMemPorts-1:NrCoreMemPorts]                        ),
    .spatz_mem_finished_o      (spatz_mem_finished_o[1]                              ),//goes to FPU sequencer
    .spatz_mem_str_finished_o  (spatz_mem_str_finished_o[1]                          )
);





endmodule: spatz_vlsu_wrapper