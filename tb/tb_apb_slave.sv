// Self-checking testbench for apb_slave.
// Acts as the APB master and compares every response with a simple model of
// the register file. Run with WAIT_STATES = 0, 1, 3 (see Makefile).

`timescale 1ns/1ps

module tb_apb_slave;

  parameter int WAIT_STATES = 0;
  localparam int ADDR_W = 8;
  localparam int DATA_W = 32;

  localparam logic [ADDR_W-1:0] A_CTRL    = 'h00;
  localparam logic [ADDR_W-1:0] A_STATUS  = 'h04;
  localparam logic [ADDR_W-1:0] A_DATA    = 'h08;
  localparam logic [ADDR_W-1:0] A_SCRATCH = 'h0C;

  logic              pclk = 1'b0;
  logic              presetn;
  logic              psel;
  logic              penable;
  logic              pwrite;
  logic [ADDR_W-1:0] paddr;
  logic [DATA_W-1:0] pwdata;
  logic [DATA_W-1:0] prdata;
  logic              pready;
  logic              pslverr;

  always #5 pclk = ~pclk;   // 100 MHz

  apb_slave #(
    .ADDR_W     (ADDR_W),
    .DATA_W     (DATA_W),
    .WAIT_STATES(WAIT_STATES)
  ) dut (.*);

  int errors = 0;
  int checks = 0;

  task automatic check_eq(input logic [31:0] got, input logic [31:0] exp, input string msg);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[FAIL] t=%0t  %s : got 0x%08h, expected 0x%08h", $time, msg, got, exp);
    end
  endtask

  task automatic fail(input string msg);
    errors++;
    $display("[FAIL] t=%0t  %s", $time, msg);
  endtask

  // Reference model
  logic [31:0] m_ctrl, m_data, m_scratch;
  logic [7:0]  exp_wr, exp_rd;

  task automatic model_reset();
    m_ctrl = 0; m_data = 0; m_scratch = 0; exp_wr = 0; exp_rd = 0;
  endtask

  function automatic logic addr_ok(input logic [ADDR_W-1:0] a);
    return (a == A_CTRL) || (a == A_STATUS) || (a == A_DATA) || (a == A_SCRATCH);
  endfunction

  function automatic logic [31:0] model_read(input logic [ADDR_W-1:0] a);
    case (a)
      A_CTRL:    return m_ctrl;
      A_STATUS:  return {16'h0000, exp_rd, exp_wr};
      A_DATA:    return m_data;
      A_SCRATCH: return m_scratch;
      default:   return 32'h0;
    endcase
  endfunction

  // One APB transfer. Inputs are driven 1 ns after a clock edge and sampled
  // on the edge, so there are no races with the DUT.
  task automatic apb_xfer(input  logic              write,
                          input  logic [ADDR_W-1:0] addr,
                          input  logic [DATA_W-1:0] wdata,
                          output logic [DATA_W-1:0] rdata,
                          output logic              err,
                          output int                access_cycles);
    begin
      // SETUP
      @(posedge pclk); #1;
      psel = 1'b1; penable = 1'b0; pwrite = write; paddr = addr; pwdata = wdata;

      // ACCESS, wait for PREADY
      @(posedge pclk); #1;
      penable = 1'b1;
      access_cycles = 0;
      do begin
        @(posedge pclk);
        access_cycles++;
      end while (!pready);
      rdata = prdata;
      err   = pslverr;

      #1;
      psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
    end
  endtask

  task automatic do_write(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] data);
    logic [DATA_W-1:0] rd;
    logic err;
    int   cyc;
    logic exp_err;
    begin
      exp_err = !addr_ok(addr) || (addr == A_STATUS);
      apb_xfer(1'b1, addr, data, rd, err, cyc);
      check_eq({31'b0, err}, {31'b0, exp_err}, $sformatf("PSLVERR on write 0x%02h", addr));
      check_eq(cyc, WAIT_STATES + 1, $sformatf("ACCESS cycles on write 0x%02h", addr));
      if (!exp_err) begin
        case (addr)
          A_CTRL:    m_ctrl    = data;
          A_DATA:    m_data    = data;
          A_SCRATCH: m_scratch = data;
          default: ;
        endcase
        exp_wr++;
      end
    end
  endtask

  task automatic do_read(input logic [ADDR_W-1:0] addr, output logic [DATA_W-1:0] value);
    logic err;
    int   cyc;
    logic exp_err;
    logic [31:0] expected;
    begin
      exp_err  = !addr_ok(addr);
      expected = model_read(addr);   // STATUS shows counts from before this read
      apb_xfer(1'b0, addr, 32'h0, value, err, cyc);
      check_eq({31'b0, err}, {31'b0, exp_err}, $sformatf("PSLVERR on read 0x%02h", addr));
      check_eq(value, expected, $sformatf("PRDATA on read 0x%02h", addr));
      check_eq(cyc, WAIT_STATES + 1, $sformatf("ACCESS cycles on read 0x%02h", addr));
      if (!exp_err) exp_rd++;
    end
  endtask

  task automatic apply_reset();
    begin
      #1 presetn = 1'b0;
      repeat (3) @(posedge pclk);
      #1 presetn = 1'b1;
      model_reset();
    end
  endtask

  // Protocol monitor
  always @(posedge pclk) begin
    if (presetn === 1'b1) begin
      if (penable && !psel)
        fail("PROTOCOL: PENABLE high without PSEL");
      if (pready && !(psel && penable))
        fail("PROTOCOL: PREADY high outside ACCESS phase");
      if (pslverr && !(psel && penable && pready))
        fail("PROTOCOL: PSLVERR high outside the last ACCESS cycle");

      // A write must only update registers when ACCESS completes
      if (psel && pwrite) begin
        if (dut.ctrl_reg    !== m_ctrl)    fail("PROTOCOL: CTRL changed before end of ACCESS");
        if (dut.data_reg    !== m_data)    fail("PROTOCOL: DATA changed before end of ACCESS");
        if (dut.scratch_reg !== m_scratch) fail("PROTOCOL: SCRATCH changed before end of ACCESS");
      end
    end
  end

  // Mix of the four valid registers and several bad addresses
  function automatic logic [ADDR_W-1:0] pick_addr(input int sel);
    case (sel)
      0: return A_CTRL;
      1: return A_STATUS;
      2: return A_DATA;
      3: return A_SCRATCH;
      4: return 8'h10;   // past the map
      5: return 8'h03;   // misaligned
      6: return 8'h7C;
      default: return 8'hFC;
    endcase
  endfunction

  logic [DATA_W-1:0] v;
  int i;

  initial begin
    $dumpfile("apb_slave.vcd");
    $dumpvars(0, tb_apb_slave);

    psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
    presetn = 1'b0;
    model_reset();
    repeat (3) @(posedge pclk);
    #1 presetn = 1'b1;

    $display("==== APB slave testbench (WAIT_STATES = %0d) ====", WAIT_STATES);

    $display("[TEST 1] Registers are 0 after reset");
    do_read(A_CTRL, v);
    do_read(A_DATA, v);
    do_read(A_SCRATCH, v);
    do_read(A_STATUS, v);

    $display("[TEST 2] Write / readback of CTRL, DATA, SCRATCH");
    do_write(A_CTRL,    32'h0000_0001);
    do_write(A_DATA,    32'hDEAD_BEEF);
    do_write(A_SCRATCH, 32'hA5A5_5A5A);
    do_read(A_CTRL, v);
    do_read(A_DATA, v);
    do_read(A_SCRATCH, v);

    $display("[TEST 3] Writing one register does not disturb the others");
    do_write(A_DATA, 32'h1234_5678);
    do_read(A_CTRL, v);
    do_read(A_SCRATCH, v);
    do_read(A_DATA, v);

    $display("[TEST 4] STATUS counters");
    do_read(A_STATUS, v);
    $display("         STATUS = 0x%08h (rd_count=%0d, wr_count=%0d)", v, v[15:8], v[7:0]);

    $display("[TEST 5] PSLVERR: write to STATUS, unmapped and misaligned addresses");
    do_write(A_STATUS, 32'hFFFF_FFFF);
    do_write(8'h10,    32'h1111_1111);
    do_write(8'h03,    32'h2222_2222);
    do_read (8'h10, v);
    do_read (8'hFC, v);
    do_read (A_STATUS, v);               // errors must not change the counters

    $display("[TEST 6] Data patterns");
    do_write(A_SCRATCH, 32'hFFFF_FFFF); do_read(A_SCRATCH, v);
    do_write(A_SCRATCH, 32'h0000_0000); do_read(A_SCRATCH, v);
    do_write(A_SCRATCH, 32'hAAAA_AAAA); do_read(A_SCRATCH, v);
    do_write(A_SCRATCH, 32'h5555_5555); do_read(A_SCRATCH, v);

    $display("[TEST 7] Reset clears registers and counters");
    apply_reset();
    do_read(A_CTRL, v);
    do_read(A_DATA, v);
    do_read(A_SCRATCH, v);
    do_read(A_STATUS, v);

    $display("[TEST 8] 300 random transfers");
    for (i = 0; i < 300; i++) begin
      logic [ADDR_W-1:0] a;
      a = pick_addr($urandom_range(0, 7));
      if ($urandom_range(0, 1)) do_write(a, $urandom);
      else                      do_read(a, v);
    end

    $display("[TEST 9] Final readback");
    do_read(A_CTRL, v);
    do_read(A_DATA, v);
    do_read(A_SCRATCH, v);
    do_read(A_STATUS, v);

    repeat (5) @(posedge pclk);

    $display("--------------------------------------------------");
    $display("Checks run : %0d", checks);
    $display("Failures   : %0d", errors);
    if (errors == 0) $display("RESULT: *** ALL TESTS PASSED ***");
    else             $display("RESULT: *** TESTS FAILED ***");
    $display("--------------------------------------------------");
    $finish;
  end

  // Stop a hung simulation
  initial begin
    #5_000_000;
    $display("[FAIL] Watchdog timeout");
    $finish;
  end

endmodule