// Self-checking bench for glyph_clock: compares against a plain calendar model.
`default_nettype none
`timescale 1ns / 1ps
module tb_clock;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0, frame_tick = 0, qtick = 0, fast_tick = 0;
  reg btn_hour = 0, btn_min = 0, btn_mon = 0, btn_day = 0, clr_time = 0, clr_date = 0;
  wire [3:0] h12, m5, mon;
  wire [2:0] m1, d5, d1;
  wire pm, sec0;
  glyph_clock #(.QTICKS_PER_SEC(17'd3)) dut (.*);

  integer checks = 0, failures = 0;
  // Model: hour 0..23, minute, day 1.., month 1..12, second.
  integer mh = 0, mm = 0, md = 1, mo = 1, ms = 0;
  function integer mlen(input integer m);
    mlen = (m == 2) ? 28 : (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31;
  endfunction

  task check(input [255:0] what);
    begin
      checks = checks + 1;
      if (h12 !== (mh % 12) || pm !== (mh >= 12) || (m5 * 5 + m1) !== mm || m1 > 4 ||
          (d5 * 5 + d1) !== md || d1 > 4 || mon !== (mo % 12) || sec0 !== ms[0]) begin
        failures = failures + 1;
        if (failures < 10)
          $display("FAIL %0s: got %0d%s:%0d day %0d mon %0d, want %0d:%0d day %0d mon %0d", what,
                   h12, pm ? "p" : "a", m5 * 5 + m1, d5 * 5 + d1, mon, mh, mm, md, mo);
      end
    end
  endtask

  task model_day;
    begin
      if (md >= mlen(mo)) begin md = 1; mo = (mo == 12) ? 1 : mo + 1; end
      else md = md + 1;
    end
  endtask
  task model_hour(input integer carry);
    begin
      if (mh == 23) begin mh = 0; if (carry) model_day; end else mh = mh + 1;
    end
  endtask
  task model_min(input integer carry);
    begin
      if (mm == 59) begin mm = 0; if (carry) model_hour(1); end else mm = mm + 1;
    end
  endtask

  // One frame: optional second tick beforehand, then frame_tick with inputs.
  task frame(input integer second, input integer fastm, input [3:0] b);
    begin
      if (second) begin
        repeat (3) begin @(negedge clk) qtick = 1; @(negedge clk) qtick = 0; end
      end
      @(negedge clk);
      frame_tick = 1; fast_tick = fastm;
      {btn_day, btn_mon, btn_min, btn_hour} = b;
      @(negedge clk);
      frame_tick = 0; fast_tick = 0;
      {btn_day, btn_mon, btn_min, btn_hour} = 4'd0;
      // model
      if (b[1]) ms = 0;
      else if (second) begin
        if (ms == 59) begin ms = 0; if (!fastm) model_min(1); end else ms = ms + 1;
      end
      if (b[1]) model_min(0);
      else if (fastm) model_min(!b[0]);
      if (b[0]) model_hour(0);
      if (md > mlen(mo)) md = mlen(mo);
      else if (b[3]) begin if (md >= mlen(mo)) md = 1; else md = md + 1; end
      if (b[2]) mo = (mo == 12) ? 1 : mo + 1;
    end
  endtask

  // A frame with a clear (and whatever else): the clear wins.
  task clear(input integer t, input integer d, input integer second, input integer fastm, input [3:0] b);
    begin
      if (second) begin
        repeat (3) begin @(negedge clk) qtick = 1; @(negedge clk) qtick = 0; end
      end
      @(negedge clk);
      frame_tick = 1; fast_tick = fastm; clr_time = t; clr_date = d;
      {btn_day, btn_mon, btn_min, btn_hour} = b;
      @(negedge clk);
      frame_tick = 0; fast_tick = 0; clr_time = 0; clr_date = 0;
      {btn_day, btn_mon, btn_min, btn_hour} = 4'd0;
      if (!t && fastm) model_min(1);
      if (t) begin mh = 0; mm = 0; ms = 0; end
      if (d) begin md = 1; mo = 1; end
    end
  endtask

  integer i;
  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    check("reset");
    // Real seconds for a little over two hours.
    for (i = 0; i < 2 * 3600 + 100; i = i + 1) begin frame(1, 0, 4'd0); check("seconds"); end
    // Frames without a second do nothing.
    for (i = 0; i < 20; i = i + 1) begin frame(0, 0, 4'd0); check("idle"); end
    // Fast minutes through a whole year and a bit: every month end, the year end.
    for (i = 0; i < 400 * 1440; i = i + 1) begin frame(0, 1, 4'd0); check("fast"); end
    // Buttons: each field wraps on its own without carrying.
    for (i = 0; i < 130; i = i + 1) begin frame(0, 0, 4'b0010); check("min+"); end
    for (i = 0; i < 50; i = i + 1) begin frame(0, 0, 4'b0001); check("hour+"); end
    for (i = 0; i < 70; i = i + 1) begin frame(0, 0, 4'b1000); check("day+"); end
    // Go to the 31st of a 31 day month, then step months: the day clamps.
    while (mlen(mo) != 31) begin frame(0, 0, 4'b0100); check("mon+"); end
    while (md != 31) begin frame(0, 0, 4'b1000); check("day+ to 31"); end
    for (i = 0; i < 30; i = i + 1) begin
      frame(0, 0, 4'b0100); check("mon+ from 31");
      frame(0, 0, 4'd0); check("clamp");
      while (md != mlen(mo)) begin frame(0, 0, 4'b1000); check("day+ to end"); end
    end
    // Minute button zeroes the seconds.
    frame(1, 0, 4'd0); check("sec");
    frame(0, 0, 4'b0010); check("min+ zero sec");
    // Clears: each leaves the other half alone, and wins over a tick, a
    // fast minute and the buttons of its own half.
    for (i = 0; i < 700; i = i + 1) begin frame(0, 1, 4'd0); check("fast"); end
    for (i = 0; i < 40; i = i + 1) begin frame(0, 0, 4'b1100); check("date+"); end
    clear(1, 0, 0, 0, 4'd0); check("clr time");
    for (i = 0; i < 59; i = i + 1) begin frame(1, 0, 4'd0); check("sec after clr"); end
    frame(1, 0, 4'd0); check("first minute after clr");
    clear(0, 1, 0, 0, 4'd0); check("clr date");
    for (i = 0; i < 1500; i = i + 1) begin frame(0, 1, 4'd0); check("fast"); end
    for (i = 0; i < 59; i = i + 1) begin frame(1, 0, 4'd0); check("sec"); end
    clear(1, 0, 1, 1, 4'b0011); check("clr time over tick, fast, buttons");
    clear(0, 1, 0, 0, 4'b1100); check("clr date over buttons");
    for (i = 0; i < 1439; i = i + 1) begin frame(0, 1, 4'd0); check("fast"); end
    clear(0, 1, 0, 1, 4'd0); check("clr date over midnight");
    clear(1, 1, 0, 0, 4'd0); check("clr both");
    for (i = 0; i < 60; i = i + 1) begin frame(1, 0, 4'd0); check("sec after clr"); end
    $display("%0d checks, %0d failures", checks, failures);
    $finish;
  end
endmodule
