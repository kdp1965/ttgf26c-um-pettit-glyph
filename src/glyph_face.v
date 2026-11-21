/*
 * Copyright (c) 2026 Ken Pettit
 * SPDX-License-Identifier: Apache-2.0
 *
 * glyph_face: pixel renderer for the "Glyph" hexagonal watch face.
 *
 * The face is drawn from three signed distances, all in quarter pixels,
 * measured from the screen center (320, 240):
 *
 *   a0 = y                      top / bottom edges,   3 and 9 o'clock spokes
 *   a1 = (sqrt3/2) x + y/2      4 / 10 o'clock edges, 1 and 7 o'clock spokes
 *   a2 = (sqrt3/2) x - y/2      2 / 8 o'clock edges,  5 and 11 o'clock spokes
 *
 * Each one is both the distance to a pair of hexagon edges and the
 * perpendicular distance to a pair of spokes.  a0 - a1 + a2 = 0, so the one
 * whose sign differs from the other two has the largest magnitude: that
 * magnitude is the "hexagonal radius" d, and its sign names the 60 degree
 * sector.  Rings are bands in d, spokes are bands around a_i = 0, and the
 * fractional distance to a band edge gives four levels of anti-aliasing.
 *
 * A pixel takes two clocks: r, g, b are for the hpos, vpos of two clocks ago.
 *
 * Segment numbering: edge j (0..5) faces hour 2j (12, 2, 4, 6, 8, 10);
 * spoke k (0..5) points at hour 2k+1 (1, 3, 5, 7, 9, 11).
 */

`default_nettype none

module glyph_face (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [9:0] hpos,
    input  wire [9:0] vpos,
    input  wire       active,
    input  wire [3:0] pos_o,     // outer ring (hours / month): position 0..11
    input  wire [3:0] pos_i,     // inner ring (5 minutes / 5 days): position 0..11
    input  wire [2:0] singles,   // center stripes lit, 0..4
    input  wire [1:0] mode,      // 0 hard, 1 medium, 2 or 3 easy
    input  wire [5:0] reveal,    // {group, index}: segments below this are shown
    input  wire       web_on,    // draw the unlit segments
    input  wire [2:0] colour,
    input  wire       top_on,    // top strap bar lit
    input  wire       bot_on,    // bottom strap bar lit
    input  wire [3:0] secs5,     // seconds / 5, 0..11: that many ticks lit
    input  wire       txt_on,    // also write pos_o, pos_i and singles in digits, lower right
    input  wire       txt_date,  // as a date, "7/23", not a time, "7:23"
    output reg  [1:0] r,
    output reg  [1:0] g,
    output reg  [1:0] b
);

  // Geometry, in quarter pixels.
  localparam [11:0] RING_A = 12'd512;   // large hexagon apothem: 128 px
  localparam [11:0] RING_B = 12'd256;   // small hexagon apothem:  64 px
  localparam [11:0] SPOKE_END = 12'd768;  // outer spoke tip:     192 px
  localparam [11:0] BODY_IN = 12'd792;  // watch body inner edge: 198 px
  localparam [11:0] BODY_OUT = 12'd872; // watch body outer edge: 218 px
  localparam [11:0] LOGO = 12'd120;     // center logo clip:       30 px
  localparam [12:0] SEG_GAP = 13'd6;    // inner spoke tip to hexagon: 1.5 px

  // (sqrt3/2) x as an accumulator with 8 fraction bits: 222/256 = 0.8672.
  // -320 * 222 = -71040 at the left edge.
  reg signed [17:0] c;
  always @(posedge clk) begin
    if (!rst_n || hpos >= 10'd640) c <= -18'sd71040;
    else c <= c + 18'sd222;
  end

  wire signed [12:0] cq = {c[17], c[17:6]};
  wire signed [10:0] y = $signed({1'b0, vpos}) - 11'sd240;
  wire signed [12:0] a0 = {y, 2'b00};
  wire signed [12:0] a1 = cq + $signed({y[10], y, 1'b0});
  wire signed [12:0] a2 = cq - $signed({y[10], y, 1'b0});

  // ---------------------------------------------------------------- helpers

  // Coverage of a band of half width 4 px around x = 0 (x in quarter px).
  function [1:0] bandcov(input [12:0] x);
    reg [5:0] ax;
    begin
      ax = x[5] ? (~x[5:0] + 6'd1) : x[5:0];
      if (x[12:5] != 8'h00 && x[12:5] != 8'hFF) bandcov = 2'd0;
      else if (ax[5] || ax >= 6'd18) bandcov = 2'd0;
      else if (ax == 6'd17) bandcov = 2'd1;
      else if (ax == 6'd16) bandcov = 2'd2;
      else bandcov = 2'd3;
    end
  endfunction

  // Coverage of a half plane: 0 for t <= 0, full for t >= 3.
  function [1:0] rampcov(input [12:0] t);
    begin
      if (t[12]) rampcov = 2'd0;
      else if (t[11:2] != 10'd0) rampcov = 2'd3;
      else rampcov = t[1:0];
    end
  endfunction

  function [1:0] min2(input [1:0] p, input [1:0] q);
    min2 = (p < q) ? p : q;
  endfunction

  function [1:0] max2(input [1:0] p, input [1:0] q);
    max2 = (p > q) ? p : q;
  endfunction

  // Rotate a 6 bit pattern left by n (0..5), modulo 6.
  function [5:0] rot6(input [5:0] x, input [2:0] n);
    begin
      rot6 = (x << n) | (x >> (3'd6 - n));
    end
  endfunction

  // Lit segments {spokes, edges} of one ring for a clock position.
  //   even position (flat side j):  spokes j-2, j+1 and edges j-1, j, j+1
  //   odd position (corner k), hard: spokes k-2, k+2
  //                          medium: + edges k-1, k, k+1, k+2
  //                            easy: + spoke k
  function [11:0] segments(input [3:0] p, input [1:0] m);
    reg [5:0] sp;
    reg [5:0] ed;
    begin
      if (p[0]) begin
        sp = {1'b0, 1'b1, 1'b0, 1'b1, 1'b0, m[1]};
        ed = (m != 2'd0) ? 6'b100111 : 6'b000000;
      end else begin
        sp = 6'b010010;
        ed = 6'b100011;
      end
      segments = {rot6(sp, p[3:1]), rot6(ed, p[3:1])};
    end
  endfunction

  // Color scaled by coverage: round(max * cov / 3).
  function [1:0] scale(input [1:0] m, input [1:0] cv);
    begin
      case (m)
        2'd3: scale = cv;
        2'd2: scale = (cv == 2'd3) ? 2'd2 : {1'b0, |cv};
        2'd1: scale = {1'b0, cv[1]};
        default: scale = 2'd0;
      endcase
    end
  endfunction

  // ------------------------------------------------- hexagonal radius, sector

  wire s0 = a0[12];
  wire s1 = a1[12];
  wire s2 = a2[12];
  wire sel0 = (s0 == s1) && (s0 != s2);   // a0 has the unique sign of {a0, -a1, a2}
  wire sel1 = (s0 == s1) && (s0 == s2);   // -a1 has it
  wire signed [12:0] amax = sel0 ? a0 : sel1 ? a1 : a2;
  wire [11:0] d_1 = amax[12] ? (~amax[11:0] + 12'd1) : amax[11:0];

  // Edge sector: which flat side this pixel faces.
  wire [2:0] edge_j_1 = sel0 ? (s0 ? 3'd0 : 3'd3) : sel1 ? (s1 ? 3'd5 : 3'd2) : (s2 ? 3'd4 : 3'd1);

  // ----------------------------------------------------------------- spokes

  wire near0 = (a0[12:5] == 8'h00) || (a0[12:5] == 8'hFF);
  wire near1 = (a1[12:5] == 8'h00) || (a1[12:5] == 8'hFF);
  wire near2 = (a2[12:5] == 8'h00) || (a2[12:5] == 8'hFF);
  wire [12:0] anear = near0 ? a0 : near1 ? a1 : a2;
  // Distance from the spoke's center line, 0..31 quarter pixels (31: not near).
  wire [5:0] pfull = anear[5] ? (~anear[5:0] + 6'd1) : anear[5:0];
  wire [4:0] pabs_1 = ((near0 || near1 || near2) && !pfull[5]) ? pfull[4:0] : 5'd31;
  wire [2:0] spoke_k_1 = near0 ? (s1 ? 3'd4 : 3'd1) : near1 ? (s2 ? 3'd3 : 3'd0) : (s1 ? 3'd5 : 3'd2);

  // |a2| near the center, for the stripes.
  wire [7:0] e2_1 = a2[12] ? (~a2[7:0] + 8'd1) : a2[7:0];

  // ------------------------------------------------------- pipeline register

  // Everything above is the first clock of a pixel (distances, radius,
  // sector); everything below is the second (bands, segments, color).
  reg [11:0] d;
  reg [ 2:0] edge_j;
  reg [ 4:0] pabs;
  reg [ 2:0] spoke_k;
  reg [ 7:0] e2_q;
  reg        a2_neg;
  reg        active_q;
  reg        dither;
  reg        strap_x;
  reg        strap_top;
  reg        strap_bot;

  wire       bar_x = (hpos[9:3] == 7'd43);   // x = 344..351

  // The seconds: eleven ticks, 8 px wide every 16 px, in the bottom of the
  // face between the 5 and 7 o'clock spokes.  Tick n (1..11) is centered on
  // x = 320 + 16 (n - 6), and is lit from second 5 n.
  wire [9:0] tick_u = hpos - 10'd220;
  wire       tick_1 = (tick_u[9:8] == 2'd0) && !tick_u[3] && (tick_u[7:4] != 4'd0) &&
                      (tick_u[7:4] < 4'd12) && (vpos[9:4] == 6'd26) && (vpos[3:2] != 2'd3);
  reg        tick;
  reg  [3:0] tick_n;

  // What the face shows, in digits, for whoever cannot read it yet: "12:34"
  // or "12/31".  The digits come from the same three numbers as the lines:
  // pos_o (0 is twelve), then 5 pos_i + singles.  A 3x5 font on 8 px cells,
  // five characters 4 cells apart, in the lower right corner
  // (x = 480..631, y = 424..463).
  function [14:0] font(input [3:0] ch);   // rows top to bottom, 3 bits each
    begin
      case (ch)
        4'd0: font = 15'b111_101_101_101_111;
        4'd1: font = 15'b010_110_010_010_111;
        4'd2: font = 15'b111_001_111_100_111;
        4'd3: font = 15'b111_001_111_001_111;
        4'd4: font = 15'b101_101_111_001_001;
        4'd5: font = 15'b111_100_111_001_111;
        4'd6: font = 15'b111_100_111_101_111;
        4'd7: font = 15'b111_001_001_001_001;
        4'd8: font = 15'b111_101_111_101_111;
        4'd9: font = 15'b111_101_111_001_111;
        4'd10: font = 15'b000_010_000_010_000;   // colon
        4'd11: font = 15'b001_001_010_100_100;   // slash
        default: font = 15'd0;                   // blank
      endcase
    end
  endfunction

  wire [6:0] txt_cx = hpos[9:3] - 7'd60;   // cell column 0..18
  wire [6:0] txt_cy = vpos[9:3] - 7'd53;   // cell row 0..4
  wire       txt_in = (txt_cx < 7'd19) && (txt_cy < 7'd5) && (txt_cx[1:0] != 2'd3);
  wire       h_two = (pos_o == 4'd0) || (pos_o >= 4'd10);   // 10, 11, 12
  reg  [3:0] txt_ch;
  always @(*) begin
    case (txt_cx[4:2])
      3'd0: txt_ch = h_two ? 4'd1 : 4'd15;
      3'd1: txt_ch = (pos_o == 4'd0) ? 4'd2 : (pos_o >= 4'd10) ? pos_o - 4'd10 : pos_o;
      3'd2: txt_ch = txt_date ? 4'd11 : 4'd10;
      3'd3: txt_ch = {1'b0, pos_i[3:1]};
      default: txt_ch = pos_i[0] ? {1'b0, singles} + 4'd5 : {1'b0, singles};
    endcase
  end
  wire [14:0] txt_rows = font(txt_ch);
  wire [ 2:0] txt_row = (txt_cy[2:0] == 3'd0) ? txt_rows[14:12] : (txt_cy[2:0] == 3'd1) ? txt_rows[11:9] :
                        (txt_cy[2:0] == 3'd2) ? txt_rows[8:6] : (txt_cy[2:0] == 3'd3) ? txt_rows[5:3] : txt_rows[2:0];
  wire       txt_1 = txt_on && txt_in && txt_row[2'd2 - txt_cx[1:0]];
  reg        txt;

  always @(posedge clk) begin
    d <= d_1;
    edge_j <= edge_j_1;
    pabs <= pabs_1;
    spoke_k <= spoke_k_1;
    e2_q <= e2_1;
    a2_neg <= a2[12];
    active_q <= active;
    dither <= hpos[0] ^ vpos[0];
    strap_x <= (hpos >= 10'd224) && (hpos < 10'd416);
    strap_top <= bar_x && (vpos < 10'd24);
    strap_bot <= bar_x && (vpos >= 10'd456);
    tick <= tick_1;
    txt <= txt_1;
    tick_n <= tick_u[7:4];
  end

  // ------------------------------------------------------------ radial bands

  wire [1:0] cov_a = bandcov({1'b0, d} - {1'b0, RING_A});
  wire [1:0] cov_b = bandcov({1'b0, d} - {1'b0, RING_B});
  wire [1:0] cov_tip = rampcov({1'b0, SPOKE_END} + 13'd2 - {1'b0, d});
  wire inside_a = (d <= RING_A);
  wire inside_b = (d <= RING_B);

  // Across a spoke: half width 4 px, as bandcov.
  wire [1:0] cov_perp = (pabs >= 5'd18) ? 2'd0 : (pabs == 5'd17) ? 2'd1 : (pabs == 5'd16) ? 2'd2 : 2'd3;

  // An outer spoke runs from the middle of the large hexagon's line, so it
  // joins it, and ends in a point at SPOKE_END.
  wire [1:0] cov_so = min2(cov_perp, inside_a ? cov_a : cov_tip);

  // An inner spoke is a separate segment, like one on an LCD: it stops
  // SEG_GAP short of the hexagon's line at each end and is beveled to a
  // point there.  d - pabs/2 is the distance along the spoke (d alone bends
  // round the corner), and the half width allowed at each end is the
  // distance from that end, which makes the point a little under 90 degrees.
  wire [12:0] along = {1'b0, d} - {10'd0, pabs[4:1]};
  wire [12:0] seg_lo = {1'b0, RING_B} + 13'd16 + SEG_GAP;
  wire [12:0] seg_hi = {1'b0, RING_A} - 13'd16 - SEG_GAP;
  wire [1:0] cov_lo = rampcov(along - seg_lo - {8'd0, pabs} + 13'd2);
  wire [1:0] cov_hi = rampcov(seg_hi - along - {8'd0, pabs} + 13'd2);
  wire [1:0] cov_si = min2(cov_perp, min2(cov_lo, cov_hi));

  // The watch body: a hexagonal case around the face, and a strap running
  // off the top and bottom of the screen.
  wire body = (d >= BODY_IN) && ((d < BODY_OUT) || strap_x);

  // ----------------------------------------------------------- center stripes

  // Four diagonal bars: bands in a2 centered on +-7 and +-21 px, clipped to a
  // small hexagon.  Stripe 1 is the rightmost.
  wire [7:0] e2 = e2_q;
  wire [1:0] cov_logo = rampcov({1'b0, LOGO} + 13'd2 - {1'b0, d});
  wire [1:0] cov_bar = max2(bandcov({5'd0, e2} - 13'd28), bandcov({5'd0, e2} - 13'd84));
  wire [1:0] cov_t = min2(cov_bar, cov_logo);
  wire bar_outer = (e2 >= 8'd56);
  wire [2:0] bar_n = a2_neg ? (bar_outer ? 3'd4 : 3'd3) : (bar_outer ? 3'd1 : 3'd2);
  wire [2:0] bar_idx = bar_n - 3'd1;

  // ------------------------------------------------------ which segments lit

  wire [11:0] seg_o = segments(pos_o, mode);
  wire [11:0] seg_i = segments(pos_i, mode);

  // Draw-on order: outer spokes, large hexagon, inner spokes, small hexagon,
  // stripes; clockwise from the top within each group.
  wire lit_so = seg_o[4'd6+{1'b0, spoke_k}] && ({3'd0, spoke_k} < reveal);
  wire lit_a = seg_o[{1'b0, edge_j}] && ({3'd1, edge_j} < reveal);
  wire lit_si = seg_i[4'd6+{1'b0, spoke_k}] && ({3'd2, spoke_k} < reveal);
  wire lit_b = seg_i[{1'b0, edge_j}] && ({3'd3, edge_j} < reveal);
  wire lit_t = (singles >= bar_n) && ({3'd4, bar_idx} < reveal);

  wire lit_tick = tick && (tick_n <= secs5);

  wire [1:0] cov_lit = max2(max2(lit_so ? cov_so : 2'd0, lit_a ? cov_a : 2'd0), max2(
      max2(lit_si ? cov_si : 2'd0, lit_b ? cov_b : 2'd0), (lit_t ? cov_t : 2'd0) | {2{lit_tick || txt}}));

  // The unlit web: every segment, at half the body's gray (a checkerboard).
  wire web = (cov_a[1] || cov_b[1] || cov_so[1] || cov_si[1] || cov_t[1] || tick) && dither && web_on;

  // ------------------------------------------------------------- strap bars

  wire bar = strap_top || strap_bot;
  wire bar_on = (strap_top && top_on) || (strap_bot && bot_on);

  // ------------------------------------------------------------------ color

  reg [5:0] cmax;
  always @(*) begin
    case (colour)
      3'd0: cmax = {2'd3, 2'd3, 2'd0};   // yellow
      3'd1: cmax = {2'd3, 2'd0, 2'd0};   // red
      3'd2: cmax = {2'd0, 2'd3, 2'd0};   // green
      3'd3: cmax = {2'd1, 2'd1, 2'd3};   // blue
      3'd4: cmax = {2'd3, 2'd0, 2'd3};   // magenta
      3'd5: cmax = {2'd0, 2'd3, 2'd3};   // cyan
      3'd6: cmax = {2'd3, 2'd2, 2'd0};   // amber
      default: cmax = {2'd3, 2'd3, 2'd3};  // white
    endcase
  end

  // An unlit strap bar is a black slot in the strap.
  wire [1:0] cov = bar ? (bar_on ? 2'd3 : 2'd0) : cov_lit;
  wire dim = (body && !bar) || web;

  always @(posedge clk) begin
    if (!active_q) begin
      r <= 2'd0;
      g <= 2'd0;
      b <= 2'd0;
    end else if (cov != 2'd0) begin
      r <= scale(cmax[5:4], cov);
      g <= scale(cmax[3:2], cov);
      b <= scale(cmax[1:0], cov);
    end else begin
      r <= {1'b0, dim};
      g <= {1'b0, dim};
      b <= {1'b0, dim};
    end
  end

endmodule
