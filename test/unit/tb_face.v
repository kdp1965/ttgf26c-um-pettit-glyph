// Renders frames of glyph_face to PPM (P3) files, one per +case.
`default_nettype none
`timescale 1ns / 1ps
module tb_face;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg [9:0] hpos = 0, vpos = 0;
  reg [3:0] pos_o, pos_i;
  reg [2:0] singles, colour;
  reg [1:0] mode;
  reg [5:0] reveal;
  reg top_on, bot_on;
  reg web_on = 1;
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
    reveal = 6'h3f; top_on = 0; bot_on = 1; colour = 0;
    // 1:20 hard / medium / easy (the article's comparison)
    pos_o = 1; pos_i = 4; singles = 0;
    mode = 0; frame("out/h_0120.ppm");
    mode = 1; frame("out/m_0120.ppm");
    mode = 2; frame("out/e_0120.ppm");
    // 3:19 hard, red
    colour = 1; mode = 0; pos_o = 3; pos_i = 3; singles = 4; frame("out/h_0319.ppm");
    // 12:00 hard, green
    colour = 2; pos_o = 0; pos_i = 0; singles = 0; top_on = 1; frame("out/h_1200.ppm");
    // 10:44 easy, magenta
    colour = 4; mode = 2; pos_o = 10; pos_i = 8; singles = 4; frame("out/e_1044.ppm");
    // 6:21 medium, amber
    colour = 6; mode = 1; pos_o = 6; pos_i = 4; singles = 1; frame("out/m_0621.ppm");
    // 11:11 easy white, half drawn
    colour = 7; mode = 2; pos_o = 11; pos_i = 2; singles = 1; reveal = {3'd1, 3'd3}; frame("out/e_1111_rev.ppm");
    // More reference screenshots.
    reveal = 6'h3f; bot_on = 0;
    // 8:54 PM medium, blue
    colour = 3; mode = 1; pos_o = 8; pos_i = 10; singles = 4; top_on = 1; frame("out/m_0854pm.ppm");
    // 2:32 PM easy, yellow
    colour = 5; mode = 2; pos_o = 2; pos_i = 6; singles = 2; top_on = 1; frame("out/e_0232pm.ppm");
    // 7:05 AM easy, cyan
    colour = 0; mode = 2; pos_o = 7; pos_i = 1; singles = 0; top_on = 0; frame("out/e_0705.ppm");
    // 11:11 AM hard, green
    colour = 2; mode = 0; pos_o = 11; pos_i = 2; singles = 1; frame("out/h_1111.ppm");
    // Date view, 23 July, medium, white: month 7, day 20 + 3
    colour = 7; mode = 1; pos_o = 7; pos_i = 4; singles = 3; frame("out/m_date_0723.ppm");
    // The same with the unlit grid off.
    web_on = 0; frame("out/m_date_0723_nogrid.ppm");
    $finish;
  end
endmodule
