`timescale 1ns /1ps
`include "interfaces.vh"

`define ADDR_MATCH( in, val) ( {in[6:2],2'b00} == val )
`define ADDR_MATCH_MASK( in, val, mask ) ( ({in[6:2],2'b00} & mask) == (val & mask))

// this is a WISHBONE wrapper for the biquads
// to allow the control interface to be in a different
// domain.
// we have 16 of these guys so we peel off lots of the
// space and just make this 7 bits.
// 7 bits (5 real bits) gives us 32 registers
module biquad8_wrapper #(parameter NBITS=16, // input number of bits
			 parameter NFRAC=2,  // input number of fractional bits
			 parameter NSAMP=8,  // number of samples
			 parameter OUTBITS=16, // output scaling
			 parameter OUTFRAC=2,
			 parameter WBCLKTYPE = "NONE",
			 parameter CLKTYPE = "NONE")
   (    
    // wishbone side
    input		       wb_clk_i,
    input		       wb_rst_i,
			       `TARGET_NAMED_PORTS_WB_IF( wb_ , 7, 32),
    
    // data side
    input		       clk_i,
    // leave this here to allow for updating everyone at the same time
    input		       global_update_i,
    input [NBITS*NSAMP-1:0]    dat_i,
    output [OUTBITS*NSAMP-1:0] dat_o,
    output [47:0] probe,
    output [47:0] probe2,
    output [OUTBITS*NSAMP-1:0] probe3,
    output [47:0] probe4
    );     
   
   // ok so 00 = update
   //       04 = fir
   //       08 = iir
   //       0C = reserved
   //       10 = F chain
   //       14 = G chain
   //       18 = F cross-link
   //       1C = G cross-link   
      
   reg			       pending = 0;
   reg			       pending_rereg = 0;

   (* CUSTOM_CC_SRC = WBCLKTYPE *)
   reg [17:0]		       coeff_hold = {18{1'b0}};
   (* CUSTOM_CC_SRC = WBCLKTYPE *)
   reg			       coeff_fir_wr_hold = 0;
   (* CUSTOM_CC_SRC = WBCLKTYPE *)
   reg                 coeff_polefir_wr_hold = 0;
   (* CUSTOM_CC_SRC = WBCLKTYPE *)
   reg		       coeff_iir_wr_hold = 0;

   (* CUSTOM_CC_DST = CLKTYPE *)
   reg			       coeff_fir_wr = 0;   
   (* CUSTOM_CC_DST = CLKTYPE *)
   reg                 coeff_polefir_wr = 0;  
   (* CUSTOM_CC_DST = CLKTYPE *)
   reg		       coeff_iir_wr = 0;   
   (* CUSTOM_CC_SRC = WBCLKTYPE *)
   reg [1:0]           coeff_polefir_addr = {2{1'b0}};
   

   
   wire			       wr_wbclk = pending && !pending_rereg;   
   wire			       wr_clk;
   flag_sync u_wrsync(.in_clkA(wr_wbclk),.out_clkB(wr_clk),.clkA(wb_clk_i),.clkB(clk_i));
   
   reg			       ack_clk = 0;
   wire			       ack_wbclk;
   flag_sync u_acksync(.in_clkA(ack_clk),.out_clkB(ack_wbclk),.clkA(clk_i),.clkB(wb_clk_i));
      
   reg			       update_wbclk = 0;   
   wire			       update_clk;   
   flag_sync u_updatesync(.in_clkA(update_wbclk),.out_clkB(update_clk),.clkA(wb_clk_i),.clkB(clk_i));
   reg			       update = 0;

   reg			       read_ack = 0;
   
   
   always @(posedge wb_clk_i) begin
      read_ack = (wb_cyc_i && wb_stb_i && !wb_we_i);
      
      if (ack_wbclk || wb_rst_i)
	pending <= 0;
      else if (wb_cyc_i && wb_stb_i && wb_we_i)
	pending <= 1;

      pending_rereg <= pending;      

      update_wbclk <= global_update_i || (pending && !pending_rereg && `ADDR_MATCH(wb_adr_i, 7'h00) && wb_sel_i[0] && wb_dat_i[0]);
            
      if (wb_cyc_i && wb_stb_i && wb_we_i) begin
          // just always capture it
          coeff_hold <= wb_dat_i[17:0];
          if (`ADDR_MATCH(wb_adr_i, 7'h04)) begin
               coeff_fir_wr_hold <= 1;
          end else begin
               coeff_fir_wr_hold <= 0;
          end
	  if (`ADDR_MATCH(wb_adr_i, 7'h08)) begin
	       coeff_iir_wr_hold <= 1;
	  end else begin
	       coeff_iir_wr_hold <= 0;
	  end
	     
          // just check if adr_i[6:4] == 1
          if (`ADDR_MATCH_MASK(wb_adr_i, 7'h10, 7'h70 )) begin
               coeff_polefir_wr_hold <= 1;
               coeff_polefir_addr <= wb_adr_i[3:2];
          end else begin
               coeff_polefir_wr_hold <= 0;
          end
      end	 
   end

   always @(posedge clk_i) begin
      ack_clk <= wr_clk;
      update <= update_clk;
      coeff_fir_wr <= wr_clk && coeff_fir_wr_hold;      
      coeff_polefir_wr <= wr_clk && coeff_polefir_wr_hold;
      coeff_iir_wr <= wr_clk && coeff_iir_wr_hold;
   end   
   
   assign wb_ack_o = ((ack_wbclk && pending) || read_ack) && wb_cyc_i;
   assign wb_err_o = 1'b0;
   assign wb_rty_o = 1'b0;
   // whatever, there's no readback
   assign wb_dat_o = {32{1'b0}};
   
   wire [OUTBITS*NSAMP-1:0] zero_fir_out;
   
   // THIS SHOULD GO AFTER IIR, ACCORDING TO SIM
   biquad8_single_zero_fir #(.NBITS(NBITS),.NFRAC(NFRAC),
			     .NSAMP(NSAMP),.OUTBITS(OUTBITS),
			     .OUTFRAC(OUTFRAC),
			     .CLKTYPE(CLKTYPE))
       u_fir(.clk(clk_i),
         .dat_i(dat_i),
         .coeff_dat_i(coeff_hold),
         .coeff_wr_i(coeff_fir_wr),
         .coeff_update_i(update),
         .dat_o(zero_fir_out));

    wire [47:0] y0_fir_out;
    wire [47:0] y1_fir_out;

    assign probe2 = y1_fir_out;
    assign probe3 = zero_fir_out;

    wire [47:0]	y0_out;
    wire [47:0]	y1_out;
   
   
    // the address bits here 
   biquad8_pole_fir #(.NBITS(12),
                      .NFRAC(0),
                      .CLKTYPE(CLKTYPE))
        u_pole_fir(.clk(clk_i),
                   .dat_i(zero_fir_out),
                   .coeff_dat_i(coeff_hold),
                   .coeff_wr_i(coeff_polefir_wr),
                   .coeff_update_i(update),
                   .coeff_adr_i(coeff_polefir_addr),
                   .y0_out(y0_fir_out),
                   .y1_out(y1_fir_out));                                       

    biquad8_pole_iir #(.NBITS(48),
		       .NFRAC(27),
		       .CLKTYPE(CLKTYPE))
        u_pole_iir(.clk(clk_i),
		   .coeff_dat_i(coeff_hold),
		   .coeff_wr_i(coeff_iir_wr),
		   .coeff_update_i(update),
		   .y0_fir_in(y0_fir_out),
		   .y1_fir_in(y1_fir_out),
		   .y0_out(y0_out),
		   .y1_out(y1_out),
             .probe0(probe),
             .probe1(probe4));		       
   
    // out outputs are Q21.27
    assign dat_o[ 0 +: OUTBITS] = y0_out[27 +: OUTBITS];
    assign dat_o[ OUTBITS +: OUTBITS] = y1_out[27 +: OUTBITS];
    assign dat_o[ 2*OUTBITS +: ((NSAMP-2)*OUTBITS)] = {(NSAMP-2)*OUTBITS{1'b0}};
   
endmodule

`undef ADDR_MATCH
`undef ADDR_MATCH_MASK
