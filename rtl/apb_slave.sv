// APB3 slave with a small register file.
//
// Registers (word aligned):
//   0x00 CTRL     RW
//   0x04 STATUS   RO   [7:0] completed writes, [15:8] completed reads
//   0x08 DATA     RW
//   0x0C SCRATCH  RW
//
// PSLVERR is raised in the last ACCESS cycle for an unmapped/misaligned
// address or a write to STATUS. Those writes are ignored and reads return 0.
// WAIT_STATES extra ACCESS cycles are added by holding PREADY low.

`timescale 1ns/1ps

module apb_slave #(
  parameter int ADDR_W      = 8,
  parameter int DATA_W      = 32,   // >= 16, STATUS packs two 8-bit counters
  parameter int WAIT_STATES = 0
) (
  input  logic              pclk,
  input  logic              presetn,   // active-low, asynchronous
  input  logic              psel,
  input  logic              penable,
  input  logic              pwrite,
  input  logic [ADDR_W-1:0] paddr,
  input  logic [DATA_W-1:0] pwdata,
  output logic [DATA_W-1:0] prdata,
  output logic              pready,
  output logic              pslverr
);

  localparam logic [ADDR_W-1:0] ADDR_CTRL    = 'h00;
  localparam logic [ADDR_W-1:0] ADDR_STATUS  = 'h04;
  localparam logic [ADDR_W-1:0] ADDR_DATA    = 'h08;
  localparam logic [ADDR_W-1:0] ADDR_SCRATCH = 'h0C;

  // Transfer phase from PSEL/PENABLE:
  //   SETUP  = PSEL & ~PENABLE (one cycle)
  //   ACCESS = PSEL &  PENABLE (ends when PREADY is high)
  typedef enum logic [1:0] {PH_IDLE = 2'd0, PH_SETUP = 2'd1, PH_ACCESS = 2'd2} phase_t;
  phase_t phase;

  always_comb begin
    if (psel && penable) phase = PH_ACCESS;
    else if (psel)       phase = PH_SETUP;
    else                 phase = PH_IDLE;
  end

  logic access;
  assign access = (phase == PH_ACCESS);

  logic [DATA_W-1:0] ctrl_reg;
  logic [DATA_W-1:0] data_reg;
  logic [DATA_W-1:0] scratch_reg;
  logic [7:0]        wr_count;
  logic [7:0]        rd_count;
  logic [DATA_W-1:0] status_val;

  assign status_val = {{(DATA_W-16){1'b0}}, rd_count, wr_count};

  // Address decode
  logic [DATA_W-1:0] rdata_mux;
  logic              addr_valid;
  logic              is_ro;

  always_comb begin
    addr_valid = 1'b1;
    is_ro      = 1'b0;
    rdata_mux  = '0;
    case (paddr)
      ADDR_CTRL:    rdata_mux = ctrl_reg;
      ADDR_STATUS:  begin rdata_mux = status_val; is_ro = 1'b1; end
      ADDR_DATA:    rdata_mux = data_reg;
      ADDR_SCRATCH: rdata_mux = scratch_reg;
      default:      addr_valid = 1'b0;
    endcase
  end

  // PREADY goes high after WAIT_STATES cycles in ACCESS
  logic [7:0] wait_cnt;

  assign pready = access && (wait_cnt == WAIT_STATES[7:0]);

  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn)                    wait_cnt <= 8'd0;
    else if (access && !pready)      wait_cnt <= wait_cnt + 8'd1;
    else                             wait_cnt <= 8'd0;
  end

  // A transfer completes when PSEL, PENABLE and PREADY are all high
  logic wr_ok, rd_ok, xfer_err;

  assign wr_ok    = access && pready &&  pwrite && addr_valid && !is_ro;
  assign rd_ok    = access && pready && !pwrite && addr_valid;
  assign xfer_err = !addr_valid || (pwrite && is_ro);

  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      ctrl_reg    <= '0;
      data_reg    <= '0;
      scratch_reg <= '0;
      wr_count    <= 8'd0;
      rd_count    <= 8'd0;
    end else begin
      if (wr_ok) begin
        wr_count <= wr_count + 8'd1;
        case (paddr)
          ADDR_CTRL:    ctrl_reg    <= pwdata;
          ADDR_DATA:    data_reg    <= pwdata;
          ADDR_SCRATCH: scratch_reg <= pwdata;
          default: ;
        endcase
      end
      if (rd_ok) rd_count <= rd_count + 8'd1;
    end
  end

  assign prdata  = (access && !pwrite && addr_valid) ? rdata_mux : '0;
  assign pslverr = access && pready && xfer_err;

endmodule