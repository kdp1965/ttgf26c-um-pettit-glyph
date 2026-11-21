/*
 * Copyright (c) 2026 Ken Pettit
 * SPDX-License-Identifier: Apache-2.0
 *
 * Glyph: a VGA clock with the hexagonal "Glyph" watch face
 * (640x480 at 60 Hz, 25.175 MHz clock, Tiny VGA PMOD on uo_out).
 *
 * Set the time:
 *    - Set ui[2] = 0, ui[4] = 0
 *      - ui[0] increments / adds hours
 *      - ui[1] increments / adds minutes
 * Set the date:
 *    - Set ui[4] = 1, ui[2] = 0
 *      - ui[0] increments / adds months
 *      - ui[1] increments / adds days
 * Set the color
 *    - Set ui[2] = 1, ui[4] = 0
 *      - ui[0] cycles the face color
 * Read the clock back (to check what was set)
 *    - uio[6:4] selects, uio[3:0] is the value:
 *      0 hour (0..11, 0 is twelve)   1 PM (0 or 1)
 *      2 minutes / 5 (0..11)         3 minutes mod 5 (0..4)
 *      4 month (1..11, 0 is December) 5 day / 5 (0..6)
 *      6 day mod 5 (0..4)            7 seconds / 5 (0..11)
 * Show numeric time (or date, with ui[4] = 1)
 *    - Set ui[2] = 1
 *      - ui[1] turns the digits on and off (off after reset)
 */

`default_nettype none

module tt_um_pettit_glyph (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // ------------------------------------------------------------- VGA timing

  reg [9:0] hpos;
  reg [9:0] vpos;
  wire h_end = (hpos == 10'd799);
  wire v_end = (vpos == 10'd524);

  always @(posedge clk) begin
    if (!rst_n) begin
      hpos <= 10'd0;
      vpos <= 10'd0;
    end else begin
      hpos <= h_end ? 10'd0 : hpos + 10'd1;
      if (h_end) vpos <= v_end ? 10'd0 : vpos + 10'd1;
    end
  end

  wire active = (hpos < 10'd640) && (vpos < 10'd480);
  wire hsync_n = !((hpos >= 10'd656) && (hpos < 10'd752));
  wire vsync_n = !((vpos >= 10'd490) && (vpos < 10'd492));

  // State changes once per frame, on the first clock of vertical blanking.
  wire frame_tick = (hpos == 10'd0) && (vpos == 10'd480);
  // Four times per line (hpos 0, 256, 512, 768): the seconds time base.
  wire qtick = (hpos[7:0] == 8'd0);

  // ------------------------------------------------------------------ inputs

  // Sampled once per frame, which also debounces the buttons.
  reg [7:0] ui_s;
  reg [2:0] colour;
  reg       digits;
  reg [1:0] btn_prev;
  reg       view_prev;
  reg [4:0] hold;
  reg [1:0] fcnt;
  reg [5:0] reveal;

  wire [1:0] btn = ui_s[1:0];
  wire       set_colour = ui_s[2];
  wire       grid_on = ui_s[3];
  wire       view_date = ui_s[4];
  wire [1:0] mode = ui_s[6:5];
  wire       fast = ui_s[7];

  // A held button repeats: after half a second, then 7.5 times a second.
  wire       rep = (hold == 5'd31);
  // Both buttons together are not two presses: they put the time (or, in the
  // date view, the date) back to its reset value, so a host can set any time
  // by clearing and then counting presses.
  wire       both = (btn == 2'b11);
  wire [1:0] press = (btn & (~btn_prev | {2{rep}})) & {2{!both}};

  // The two buttons set what is on screen: hours and minutes in the time
  // view, month and day in the date view.  With set_color high the first
  // one steps the LED color and the second turns the digits on and off.
  wire       btn_a = press[0] && !set_colour;
  wire       btn_b = press[1] && !set_colour;

  wire       reveal_done = (reveal[5:3] == 3'd5);

  always @(posedge clk) begin
    if (!rst_n) begin
      ui_s <= 8'd0;
      colour <= 3'd0;
      digits <= 1'b0;
      btn_prev <= 2'd0;
      view_prev <= 1'b0;
      hold <= 5'd0;
      fcnt <= 2'd0;
      reveal <= 6'd0;
    end else if (frame_tick) begin
      ui_s <= ui_in;
      if (press[0] && set_colour) colour <= colour + 3'd1;
      if (press[1] && set_colour) digits <= ~digits;
      btn_prev <= btn;
      view_prev <= view_date;
      hold <= (btn == 2'd0 || both) ? 5'd0 : rep ? 5'd24 : hold + 5'd1;
      fcnt <= fcnt + 2'd1;
      // Draw the face on, one segment every other frame, after reset and
      // whenever the view changes.
      if (view_prev != view_date) reveal <= 6'd0;
      else if (!reveal_done && fcnt[0])
        reveal <= (reveal[2:0] == 3'd5) ? {reveal[5:3] + 3'd1, 3'd0} : reveal + 6'd1;
    end
  end

  // ------------------------------------------------------------------- clock

  wire [3:0] h12;
  wire       pm;
  wire [3:0] m5;
  wire [2:0] m1;
  wire [3:0] mon;
  wire [2:0] d5;
  wire [2:0] d1;
  wire       sec0;
  wire [3:0] s5;

  glyph_clock clock (
      .clk       (clk),
      .rst_n     (rst_n),
      .frame_tick(frame_tick),
      .qtick     (qtick),
      .fast_tick (fast && (fcnt == 2'd3)),
      .btn_hour  (btn_a && !view_date),
      .btn_min   (btn_b && !view_date),
      .btn_mon   (btn_a && view_date),
      .btn_day   (btn_b && view_date),
      .clr_time  (both && !view_date),
      .clr_date  (both && view_date),
      .h12       (h12),
      .pm        (pm),
      .m5        (m5),
      .m1        (m1),
      .mon       (mon),
      .d5        (d5),
      .d1        (d1),
      .s5        (s5),
      .sec0      (sec0)
  );

  // -------------------------------------------------------------------- face

  wire [1:0] r;
  wire [1:0] g;
  wire [1:0] b;

  glyph_face face (
      .clk    (clk),
      .rst_n  (rst_n),
      .hpos   (hpos),
      .vpos   (vpos),
      .active (active),
      .pos_o  (view_date ? mon : h12),
      .pos_i  (view_date ? {1'b0, d5} : m5),
      .singles(view_date ? d1 : m1),
      .mode   (mode),
      .reveal (reveal),
      .web_on (grid_on),
      .colour (colour),
      .top_on (pm),
      .bot_on (sec0),
      .secs5  (s5),
      .txt_on (digits),
      .txt_date(view_date),
      .r      (r),
      .g      (g),
      .b      (b)
  );

  // The face takes two clocks for a pixel, so the syncs take two registers.
  reg [1:0] hsync_d;
  reg [1:0] vsync_d;
  always @(posedge clk) begin
    hsync_d <= {hsync_d[0], hsync_n};
    vsync_d <= {vsync_d[0], vsync_n};
  end
  wire hsync_q = hsync_d[1];
  wire vsync_q = vsync_d[1];

  // Tiny VGA PMOD.
  assign uo_out  = {hsync_q, b[0], g[0], r[0], vsync_q, b[1], g[1], r[1]};
  // Readback for a host that is setting the clock: uio[6:4] selects one of
  // the stored numbers, which comes out on uio[3:0].  minute = 5 m5 + m1,
  // day = 5 d5 + d1.
  reg [2:0] rd_sel;
  always @(posedge clk) rd_sel <= uio_in[6:4];

  reg [3:0] rd;
  always @(*) begin
    case (rd_sel)
      3'd0: rd = h12;
      3'd1: rd = {3'd0, pm};
      3'd2: rd = m5;
      3'd3: rd = {1'b0, m1};
      3'd4: rd = mon;
      3'd5: rd = {1'b0, d5};
      3'd6: rd = {1'b0, d1};
      default: rd = s5;
    endcase
  end

  assign uio_out = {4'd0, rd};
  assign uio_oe  = 8'h0F;

  wire _unused = &{ena, uio_in[7], uio_in[3:0], 1'b0};

endmodule
