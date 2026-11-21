// Renders frames of glyph_face to PPM (P3) files, one per +case.
`default_nettype none
`timescale 1ns / 1ps
module tb_face;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg [9:0] hpos = 0, vpos = 0;
  reg [3:0] pos_o, pos_i;
  reg [2:0] singles, color;
  reg [1:0] mode;
  reg [5:0] reveal;
  reg top_on, bot_on;
  reg web_on = 1;
  reg [3:0] secs5 = 0;
  reg txt_on = 0, txt_date = 0;
  wire [1:0] r, g, b;
  wire active = (hpos < 640) && (vpos < 480);
  glyph_face dut (.*);

  always @(posedge clk) begin
    if (!rst_n) begin hpos <= 0; vpos <= 0; end
    else begin
      hpos <= (hpos == 799) ? 0 : hpos + 1;
      if (hpos == 799) vpos <= (vpos == 524) ? 0 : vpos + 1;
    end
  end

  integer f;
  reg [1023:0] name;
  // The face takes two clocks for a pixel.
  reg was_active, act1;
  always @(posedge clk) begin act1 <= active && rst_n; was_active <= act1; end

  task frame(input [1023:0] fn);
    begin
      rst_n = 0; repeat (4) @(posedge clk); #1 rst_n = 1;
      f = $fopen(fn, "w");
      $fwrite(f, "P3 640 480 3\n");
      while (!(vpos == 481)) begin
        @(posedge clk); #1;
        if (was_active) $fwrite(f, "%0d %0d %0d\n", r, g, b);
      end
      $fclose(f);
    end
  endtask

  integer i;
  initial begin
    reveal = 6'h3f; top_on = 0; bot_on = 1; color = 0;
    // 1:20 hard / medium / easy (the article's comparison)
    pos_o = 1; pos_i = 4; singles = 0;
    mode = 0; secs5 = 3; frame("out/h_0120.ppm");
    mode = 1; frame("out/m_0120.ppm");
    mode = 2; frame("out/e_0120.ppm");
    // 3:19 hard, red
    secs5 = 7; color = 1; mode = 0; pos_o = 3; pos_i = 3; singles = 4; frame("out/h_0319.ppm");
    // 12:00 hard, green
    secs5 = 0; color = 2; pos_o = 0; pos_i = 0; singles = 0; top_on = 1; frame("out/h_1200.ppm");
    // 10:44 easy, magenta
    secs5 = 11; color = 4; mode = 2; pos_o = 10; pos_i = 8; singles = 4; frame("out/e_1044.ppm");
    // 6:21 medium, amber
    secs5 = 5; color = 6; mode = 1; pos_o = 6; pos_i = 4; singles = 1; frame("out/m_0621.ppm");
    // 11:11 easy white, half drawn
    color = 7; mode = 2; pos_o = 11; pos_i = 2; singles = 1; reveal = {3'd1, 3'd3}; frame("out/e_1111_rev.ppm");
    // More reference screenshots.
    reveal = 6'h3f; bot_on = 0;
    // 8:54 PM medium, blue
    secs5 = 9; color = 3; mode = 1; pos_o = 8; pos_i = 10; singles = 4; top_on = 1; frame("out/m_0854pm.ppm");
    // 2:32 PM easy, cyan
    secs5 = 2; color = 5; mode = 2; pos_o = 2; pos_i = 6; singles = 2; top_on = 1; frame("out/e_0232pm.ppm");
    // 7:05 AM easy, yellow
    secs5 = 6; color = 0; mode = 2; pos_o = 7; pos_i = 1; singles = 0; top_on = 0; frame("out/e_0705.ppm");
    // 11:11 AM hard, green
    secs5 = 1; color = 2; mode = 0; pos_o = 11; pos_i = 2; singles = 1; frame("out/h_1111.ppm");
    // Date view, 23 July, medium, white: month 7, day 20 + 3
    secs5 = 4; color = 7; mode = 1; pos_o = 7; pos_i = 4; singles = 3; frame("out/m_date_0723.ppm");
    // The same with the unlit grid off.
    web_on = 0; frame("out/m_date_0723_nogrid.ppm");
    // Easy with the time in digits: 10:44, 7:05, 12:38, 9:26.
    web_on = 1; txt_on = 1; mode = 3;
    color = 4; secs5 = 11; pos_o = 10; pos_i = 8; singles = 4; frame("out/d_1044.ppm");
    color = 0; secs5 = 6; pos_o = 7; pos_i = 1; singles = 0; frame("out/d_0705.ppm");
    color = 5; secs5 = 2; pos_o = 0; pos_i = 7; singles = 3; frame("out/d_1238.ppm");
    color = 7; secs5 = 9; pos_o = 9; pos_i = 5; singles = 1; frame("out/d_0926.ppm");
    // Dates in digits: 7/23, 12/31, 2/05.
    txt_date = 1;
    color = 2; secs5 = 4; pos_o = 7; pos_i = 4; singles = 3; frame("out/d_date_0723.ppm");
    color = 6; secs5 = 8; pos_o = 0; pos_i = 6; singles = 1; frame("out/d_date_1231.ppm");
    color = 1; secs5 = 0; pos_o = 2; pos_i = 1; singles = 0; frame("out/d_date_0205.ppm");
    $finish;
  end
endmodule
