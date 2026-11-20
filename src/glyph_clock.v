/*
 * Copyright (c) 2026 Ken Pettit
 * SPDX-License-Identifier: Apache-2.0
 *
 * glyph_clock: time of day and calendar, stored the way the face shows it.
 *
 *   hours   h12 0..11 (0 is twelve) and pm
 *   minutes m5 0..11 (five minute steps) and m1 0..4
 *   month   mon 0..11 as a ring position: January 1 ... November 11, December 0
 *   day     d5 0..6 and d1 0..4, day = 5*d5 + d1 (1..31)
 *
 * Everything advances on frame_tick.  Seconds come from a prescaler counting
 * qtick, which arrives four times per scan line (125875 per second with a
 * 25.175 MHz pixel clock).  A set button advances its own field only: it does
 * not carry into the next one.  February always has 28 days.  clr_time and
 * clr_date put the time (seconds included) or the date back to the reset
 * value, 12:00:00 AM and 1 January, and win over everything else.
 */

`default_nettype none

module glyph_clock #(
    parameter [16:0] QTICKS_PER_SEC = 17'd125875
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_tick,
    input  wire       qtick,
    input  wire       fast_tick,   // with frame_tick: advance one minute (demo mode)
    input  wire       btn_hour,    // with frame_tick: advance the field by one
    input  wire       btn_min,
    input  wire       btn_mon,
    input  wire       btn_day,
    input  wire       clr_time,    // with frame_tick: back to 12:00:00 AM
    input  wire       clr_date,    // with frame_tick: back to 1 January
    output reg  [3:0] h12,
    output reg        pm,
    output reg  [3:0] m5,
    output reg  [2:0] m1,
    output reg  [3:0] mon,
    output reg  [2:0] d5,
    output reg  [2:0] d1,
    output wire       sec0
);

  reg [16:0] pre;
  reg        sec_pend;
  reg [ 5:0] sec;

  assign sec0 = sec[0];

  wire pre_wrap = (pre == QTICKS_PER_SEC - 17'd1);

  always @(posedge clk) begin
    if (!rst_n) begin
      pre <= 17'd0;
      sec_pend <= 1'b0;
    end else if (frame_tick && clr_time) begin
      pre <= 17'd0;
      sec_pend <= 1'b0;
    end else begin
      if (qtick) pre <= pre_wrap ? 17'd0 : pre + 17'd1;
      if (qtick && pre_wrap) sec_pend <= 1'b1;
      else if (frame_tick) sec_pend <= 1'b0;
    end
  end

  // Last day of the month.
  reg [5:0] last;
  always @(*) begin
    case (mon)
      4'd2: last = {3'd5, 3'd3};                      // 28
      4'd4, 4'd6, 4'd9, 4'd11: last = {3'd6, 3'd0};   // 30
      default: last = {3'd6, 3'd1};                   // 31
    endcase
  end

  wire sec_wrap = (sec == 6'd59);
  wire m1_wrap = (m1 == 3'd4);
  wire m5_wrap = (m5 == 4'd11);
  wire h_wrap = (h12 == 4'd11);
  wire day_last = ({d5, d1} == last);
  wire day_over = ({d5, d1} > last);

  wire nat_min = ((sec_pend && sec_wrap) || fast_tick) && !clr_time;
  wire nat_hour = nat_min && !btn_min && m1_wrap && m5_wrap;
  wire nat_day = nat_hour && !btn_hour && h_wrap && pm;
  wire nat_mon = nat_day && !btn_day && day_last;

  always @(posedge clk) begin
    if (!rst_n) begin
      sec <= 6'd0;
      m1  <= 3'd0;
      m5  <= 4'd0;
      h12 <= 4'd0;
      pm  <= 1'b0;
      d1  <= 3'd1;
      d5  <= 3'd0;
      mon <= 4'd1;
    end else if (frame_tick) begin
      if (btn_min) sec <= 6'd0;
      else if (sec_pend) sec <= sec_wrap ? 6'd0 : sec + 6'd1;

      if (nat_min || btn_min) begin
        m1 <= m1_wrap ? 3'd0 : m1 + 3'd1;
        if (m1_wrap) m5 <= m5_wrap ? 4'd0 : m5 + 4'd1;
      end

      if (nat_hour || btn_hour) begin
        h12 <= h_wrap ? 4'd0 : h12 + 4'd1;
        if (h_wrap) pm <= ~pm;
      end

      if (day_over) begin
        // The month changed under a day it does not have.
        {d5, d1} <= last;
      end else if (nat_day || btn_day) begin
        if (day_last) begin
          d5 <= 3'd0;
          d1 <= 3'd1;
        end else if (d1 == 3'd4) begin
          d5 <= d5 + 3'd1;
          d1 <= 3'd0;
        end else begin
          d1 <= d1 + 3'd1;
        end
      end

      if (nat_mon || btn_mon) mon <= (mon == 4'd11) ? 4'd0 : mon + 4'd1;

      if (clr_time) begin
        sec <= 6'd0;
        m1  <= 3'd0;
        m5  <= 4'd0;
        h12 <= 4'd0;
        pm  <= 1'b0;
      end
      if (clr_date) begin
        d1  <= 3'd1;
        d5  <= 3'd0;
        mon <= 4'd1;
      end
    end
  end

endmodule
