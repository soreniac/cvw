///////////////////////////////////////////
// fdivsqrtpreproc.sv
//
// Written: David_Harris@hmc.edu, me@KatherineParry.com, cturek@hmc.edu
// Modified:13 January 2022
//
// Purpose: Combined Divide and Square Root Floating Point and Integer Unit
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// MIT LICENSE
// Permission is hereby granted, free of charge, to any person obtaining a copy of this 
// software and associated documentation files (the "Software"), to deal in the Software 
// without restriction, including without limitation the rights to use, copy, modify, merge, 
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons 
// to whom the Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or 
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR 
//   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
//   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE 
//   OR OTHER DEALINGS IN THE SOFTWARE.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"

module fdivsqrtpreproc (
  input  logic clk,
  input  logic IFDivStartE, 
  input  logic [`NF:0] Xm, Ym,
  input  logic [`NE-1:0] Xe, Ye,
  input  logic [`FMTBITS-1:0] Fmt,
  input  logic Sqrt,
  input  logic XZero,
  input  logic [`XLEN-1:0] ForwardedSrcAE, ForwardedSrcBE, // *** these are the src outputs before the mux choosing between them and PCE to put in srcA/B
	input  logic [2:0] 	Funct3E, Funct3M,
	input  logic MDUE, W64E,
  output logic [`DIVBLEN:0] n, m,
  output logic OTFCSwap, ALTBM, BZero, As,
  output logic [`NE+1:0] QeM,
  output logic [`DIVb+3:0] X,
  output logic [`DIVb-1:0] DPreproc
);

  logic  [`DIVb-1:0] XPreproc;
  logic  [`DIVb:0] SqrtX;
  logic  [`DIVb+3:0] DivX;
  logic  [`NE+1:0] QeE;
  // Intdiv signals
  logic  [`DIVb-1:0] IFNormLenX, IFNormLenD;
  logic  [`XLEN-1:0] PosA, PosB;
  logic  Bs, CalcOTFCSwap, ALTBE;
  logic  [`XLEN-1:0] A64, B64;
  logic  [`DIVBLEN:0] Calcn, Calcm;
  logic  [`DIVBLEN:0] ZeroDiff, IntBits, RightShiftX;
  logic  [`DIVBLEN:0] pPlusr, pPrCeil, p, ell;
  logic  [`LOGRK-1:0] pPrTrunc;
  logic  [`DIVb+3:0] PreShiftX;

  // ***can probably merge X LZC with conversion
  // cout the number of leading zeros

  assign As = ForwardedSrcAE[`XLEN-1] & ~Funct3E[0];
  assign Bs = ForwardedSrcBE[`XLEN-1] & ~Funct3E[0];
  assign A64 = W64E ? {{(`XLEN-32){As}}, ForwardedSrcAE[31:0]} : ForwardedSrcAE;
  assign B64 = W64E ? {{(`XLEN-32){Bs}}, ForwardedSrcBE[31:0]} : ForwardedSrcBE;

  assign CalcOTFCSwap = (As ^ Bs) & MDUE;
  
  assign PosA = As ? -A64 : A64;
  assign PosB = Bs ? -B64 : B64;
  assign BZero = |ForwardedSrcBE;

  assign IFNormLenX = MDUE ? {PosA, {(`DIVb-`XLEN){1'b0}}} : {Xm, {(`DIVb-`NF-1){1'b0}}};
  assign IFNormLenD = MDUE ? {PosB, {(`DIVb-`XLEN){1'b0}}} : {Ym, {(`DIVb-`NF-1){1'b0}}};
  lzc #(`DIVb) lzcX (IFNormLenX, ell);
  lzc #(`DIVb) lzcY (IFNormLenD, Calcm);

  assign XPreproc = IFNormLenX << (ell + {{`DIVBLEN{1'b0}}, ~MDUE}); // had issue with (`DIVBLEN+1)'(~MDUE) so using this instead
  assign DPreproc = IFNormLenD << (Calcm + {{`DIVBLEN{1'b0}}, ~MDUE});

  assign ZeroDiff = Calcm - ell;
  assign ALTBE = ZeroDiff[`DIVBLEN]; // A less than B
  assign p = ALTBE ? '0 : ZeroDiff;

  assign pPlusr = (`DIVBLEN)'(`LOGR) + p;
  assign pPrTrunc = pPlusr[`LOGRK-1:0];
  assign pPrCeil = (pPlusr >> `LOGRK) + {{`DIVBLEN{1'b0}}, |(pPrTrunc)};
  assign Calcn = (pPrCeil << `LOGK) - 1;
  assign IntBits = (`DIVBLEN)'(`RK) + p;
  assign RightShiftX = (`DIVBLEN)'(`RK) - {{(`DIVBLEN-`RK){1'b0}}, IntBits[`RK-1:0]};

  assign SqrtX = (Xe[0]^ell[0]) ? {1'b0, ~XZero, XPreproc[`DIVb-1:1]} : {~XZero, XPreproc}; // Bottom bit of XPreproc is always zero because DIVb is larger than XLEN and NF
  assign DivX = {3'b000, ~XZero, XPreproc};

  // *** explain why X is shifted between radices (initial assignment of WS=RX)
  if (`RADIX == 2)  assign PreShiftX = Sqrt ? {3'b111, SqrtX} : DivX;
  else              assign PreShiftX = Sqrt ? {2'b11, SqrtX, 1'b0} : DivX;
  assign X = MDUE ? DivX >> RightShiftX : PreShiftX;

  //           radix 2     radix 4
  // 1 copies  DIVLEN+2    DIVLEN+2/2
  // 2 copies  DIVLEN+2/2  DIVLEN+2/2*2
  // 4 copies  DIVLEN+2/4  DIVLEN+2/2*4
  // 8 copies  DIVLEN+2/8  DIVLEN+2/2*8

  // DIVRESLEN = DIVLEN or DIVLEN+2
  // r = 1 or 2
  // DIVRESLEN/(r*`DIVCOPIES)

  flopen #(`NE+2)    expreg(clk, IFDivStartE, QeE, QeM);
  flopen #(1)       swapreg(clk, IFDivStartE, CalcOTFCSwap, OTFCSwap);
  flopen #(1)       altbreg(clk, IFDivStartE, ALTBE, ALTBM);
  flopen #(`DIVBLEN+1) nreg(clk, IFDivStartE, Calcn, n);
  flopen #(`DIVBLEN+1) mreg(clk, IFDivStartE, Calcm, m);
  expcalc expcalc(.Fmt, .Xe, .Ye, .Sqrt, .XZero, .ell, .m(Calcm), .Qe(QeE));

endmodule

module expcalc(
  input  logic [`FMTBITS-1:0] Fmt,
  input  logic [`NE-1:0] Xe, Ye,
  input  logic Sqrt,
  input  logic XZero, 
  input  logic [`DIVBLEN:0] ell, m,
  output logic [`NE+1:0] Qe
  );
  logic [`NE-2:0] Bias;
  logic [`NE+1:0] SXExp;
  logic [`NE+1:0] SExp;
  logic [`NE+1:0] DExp;
  
  if (`FPSIZES == 1) begin
      assign Bias = (`NE-1)'(`BIAS); 

  end else if (`FPSIZES == 2) begin
      assign Bias = Fmt ? (`NE-1)'(`BIAS) : (`NE-1)'(`BIAS1); 

  end else if (`FPSIZES == 3) begin
      always_comb
          case (Fmt)
              `FMT: Bias  =  (`NE-1)'(`BIAS);
              `FMT1: Bias = (`NE-1)'(`BIAS1);
              `FMT2: Bias = (`NE-1)'(`BIAS2);
              default: Bias = 'x;
          endcase

  end else if (`FPSIZES == 4) begin        
    always_comb
        case (Fmt)
            2'h3: Bias =  (`NE-1)'(`Q_BIAS);
            2'h1: Bias =  (`NE-1)'(`D_BIAS);
            2'h0: Bias =  (`NE-1)'(`S_BIAS);
            2'h2: Bias =  (`NE-1)'(`H_BIAS);
        endcase
  end
  assign SXExp = {2'b0, Xe} - {{(`NE+1-`DIVBLEN){1'b0}}, ell} - (`NE+2)'(`BIAS);
  assign SExp  = {SXExp[`NE+1], SXExp[`NE+1:1]} + {2'b0, Bias};
  // correct exponent for denormalized input's normalization shifts
  assign DExp  = ({2'b0, Xe} - {{(`NE+1-`DIVBLEN){1'b0}}, ell} - {2'b0, Ye} + {{(`NE+1-`DIVBLEN){1'b0}}, m} + {3'b0, Bias}) & {`NE+2{~XZero}};
  
  assign Qe = Sqrt ? SExp : DExp;
endmodule