/*
Copyright (c) 2013, IIT Madras
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

*  Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
*  Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
*  Neither the name of IIT Madras  nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
*/
package muldiv;
	/*====== Package import ==== */
	import FIFOF::*;
	import SpecialFIFOs::*;
	import UniqueWrappers::*;
	/*==== Project Import=== */
	import defined_types::*;
	`include "defined_parameters.bsv"
	/*====================== */

	`define UnrollMul 8 // this means the number of bits being analysed simultaneously
	`define UnrollDiv 1

	interface Ifc_muldiv;
		method Action input_operands(Bit#(`Reg_width) in1, Bit#(`Reg_width) in2, Bit#(2) funct3, Bit#(1) word_flag, Bit#(1) is_mul);
		method ActionValue#(Bit#(`Reg_width)) muldiv_result;
		method Action flush;
	endinterface

	function Bit#(73) func_mult(Bit#(9) op1, Bit#(65) op2);
		Bit#(73) lv_result=  signExtend(op1)*signExtend(op2);
		return lv_result;
	endfunction

	function Bool is_op_zero(Bit#(56) op, Bit#(4) count);
		Bool acc_7to0_is_zero  = op[7:0]==0;
		Bool acc_15to8_is_zero = op[15:8]==0;
		Bool acc_23to16_is_zero= op[23:16]==0;
		Bool acc_31to24_is_zero= op[31:24]==0;
		Bool acc_39to32_is_zero= op[39:32]==0;
		Bool acc_47to40_is_zero= op[47:40]==0;
		Bool acc_55to48_is_zero= op[55:48]==0;

		Bool acc_47to32_is_zero= acc_47to40_is_zero && acc_39to32_is_zero;
		Bool acc_31to16_is_zero= acc_31to24_is_zero && acc_23to16_is_zero;
		Bool acc_15to0_is_zero = acc_15to8_is_zero  && acc_7to0_is_zero;
		Bool acc_31to0_is_zero = acc_31to16_is_zero && acc_15to0_is_zero;

		Bool earlyout= False;
		if(count[2:1]=='b11)	//==6 or ==7
			if(acc_55to48_is_zero && acc_47to32_is_zero && acc_31to0_is_zero)
				earlyout= True;
		else if(count==5)
			if(acc_47to32_is_zero && acc_31to0_is_zero)
				earlyout= True;
		else if(count==4)
			if(acc_39to32_is_zero && acc_31to0_is_zero)
				earlyout= True;
		else if(count==3)
			if(acc_31to0_is_zero)
				earlyout= True;
		else if(count==2)
			if(acc_23to16_is_zero && acc_15to0_is_zero)
				earlyout= True;
		else begin 
			if(acc_15to0_is_zero)
				earlyout= True;
		end
		return earlyout;
	endfunction

	(*synthesize*)
	(*descending_urgency = "input_operands, perform_n_restoring_steps"*)
	module mkmuldiv(Ifc_muldiv);

		Wrapper2#(Bit#(73), Bit#(73), Bit#(73))   wrapper_add_1     <- mkUniqueWrapper2( \+ );
		Wrapper2#(Bit#(9), Bit#(65), Bit#(73))   wrapper_mul_1      <- mkUniqueWrapper2( func_mult );
		Wrapper2#(Bit#(56), Bit#(4), Bool)   wrapper_is_op_zero <- mkUniqueWrapper2( is_op_zero );
	
		Reg#(Bit#(65)) multiplicand_divisor <-mkReg(0);				// operand2
		Reg#(Bit#(137)) accumulator <-mkReg(0);  // holds the accumulated results over the iterations
		FIFOF#(Bit#(64)) ff_muldiv_result <-mkBypassFIFOF();					// to hold the final result
		FIFOF#(Tuple5#(Bit#(`Reg_width), Bit#(`Reg_width),Bit#(2), Bit#(1), Bit#(1))) ff_input <-mkLFIFOF();					// to hold the final result
		Reg#(Bit#(4)) rg_count[2]<-mkCReg(2,8);
		Reg#(Bool) rg_signed<-mkReg(False);
		Reg#(Bool) upper_bits<-mkReg(False);
		Reg#(Bit#(1)) temp_multiplier_sign<-mkReg(0);
		Reg#(Bit#(1)) rg_word_flag<-mkReg(0);
		Reg#(Bit#(1)) rg_result_sign<-mkReg(0);
		Reg#(Bool) rg_is_mul <-mkReg(False);

		//Only DIV
		Reg#(Bit#(7)) rg_state_counter[2]<-mkCReg(2,0);										// to count the number of iterations
		Reg#(Bit#(2)) rg_funct3 <-mkReg(0);

		rule unroll_multiplication(rg_is_mul && rg_count[1]!=8);

			//Bit#(137) x=partial_prod_generator(multiplier_sign,multiplicand,accumulator[1]);
			Bit#(73) product<- wrapper_mul_1.func({temp_multiplier_sign,accumulator[7:0]}, multiplicand_divisor);
			Bit#(73) new_accum<- wrapper_add_1.func(accumulator[136:64],product);
			Bit#(137) x = {new_accum,accumulator[63:0]};
			Int#(137) y = unpack(x);
			y=y>>8;
			x=pack(y);
			Bool earlyout=False;
			if(rg_count[1]==7)
				earlyout<- wrapper_is_op_zero.func(accumulator[63:8],rg_count[1]);
			else
				earlyout<- wrapper_is_op_zero.func(accumulator[55:0],rg_count[1]);
			`ifdef verbose $display($time,"\tAccumulator: %h Multiplicand: %h count: %d isHi: %b word: %b compl: %b sign: %b",x,multiplicand_divisor,rg_count[1],upper_bits, rg_word_flag, rg_signed,temp_multiplier_sign); `endif
			`ifdef verbose $display($time,"\tx: %h y: %h",x,y); `endif
			if(rg_count[1]==0 || earlyout)begin
				`ifdef verbose $display($time,"\tMUL/DIV: Ending Mul/Div operation"); `endif
				y = unpack(x);
				x=pack(y>>({2'b0,rg_count[1]}*8));
				`ifdef verbose $display($time,"\tx: %h y: %h",x,y); `endif
				if(rg_word_flag==1)
					x=signExtend(x[31:0]);
				if(upper_bits)
					ff_muldiv_result.enq(x[2*`Reg_width-1:`Reg_width]);
				else
					ff_muldiv_result.enq(x[`Reg_width-1:0]);
				rg_count[1]<=8;
			end
			else begin
				rg_count[1]<=rg_count[1]-1;
				accumulator<=x;
			end
			if(rg_count[1]==1 && rg_signed)
				temp_multiplier_sign<=rg_result_sign;
		endrule

		rule perform_n_restoring_steps(!rg_is_mul && rg_count[1]!='d8);
			Bit#(`Reg_width) divisor= multiplicand_divisor[`Reg_width-1:0];
			Bit#(TAdd#(1,TMul#(2,`Reg_width))) remainder= truncate(accumulator);
			Bit#(TAdd#(1,`Reg_width)) sub;
			for (Integer i=0;i<`UnrollDiv;i=i+1)begin
				remainder=remainder<<1;
				Bit#(73) lv_add_op1= {8'd0,remainder[2*`Reg_width:`Reg_width]};
				Bit#(73) lv_add_op2= signExtend(~divisor+1); 
				let lv_added_inter_res <- wrapper_add_1.func(lv_add_op1, lv_add_op2);
				sub= truncate(lv_added_inter_res);
				if(remainder[2*`Reg_width-1:`Reg_width]>=divisor)begin	// if subtraction is positive
					remainder[0]=1;
					remainder[2*`Reg_width:`Reg_width]=sub;					// restore 
				end
			end
			//Bit#(TAdd#(1,`Reg_width)) lv_to_add= signExtend(~multiplicand_divisor[63:0]+1);
			sub=accumulator[128:64]+signExtend(~multiplicand_divisor[63:0]+1);
			if((rg_state_counter[1]==(64/`UnrollDiv)))begin // end of computation;
				rg_state_counter[1]<=0;
				rg_count[1]<='d8;
				if(rg_funct3[1]==1) // REM/REMU
					if(rg_word_flag==1)
						remainder=signExtend(remainder[95:64]);
					else
						remainder=signExtend(remainder[127:64]);
				else // DIV/DIVU
					if(rg_word_flag==1)
						remainder=signExtend(remainder[31:0]);
					else
						remainder=signExtend(remainder[63:0]);

				if(rg_funct3[1]==0 && rg_signed) begin// DIVU
					remainder=~remainder+1;
				end
				else if(rg_funct3[1:0]=='b10 && remainder[`Reg_width-1]!=rg_result_sign) begin  // REMU/REM
					remainder=~remainder+1;
				end
				if(rg_word_flag==1)
					ff_muldiv_result.enq(signExtend(remainder[31:0]));	    
				else
					ff_muldiv_result.enq(remainder[`Reg_width-1:0]);	    
			end
			else begin
				accumulator[128:0]<=remainder;
				rg_state_counter[1]<=rg_state_counter[1]+1;
			end
		endrule

		rule first_stage(rg_count[1]==8);
			ff_input.deq;
			let {in1,in2,funct3,word_flag,is_mul}=ff_input.first;
			`ifdef verbose $display($time,"\tMUL/DIV: in1: %h in2: %h funct3: %h word_flag: %h is_mul: %b",in1,in2,funct3,word_flag, is_mul); `endif
			Bit#(1) in2_sign=funct3[1:0]==1?word_flag==1?in2[31]:in2[63]:0;
			Bit#(1) in1_sign=(funct3[1]^funct3[0]) & ((word_flag==1)?in1[31]:in1[63]);

			Bit#(TAdd#(`Reg_width,1)) op1;
			Bit#(TAdd#(`Reg_width,1)) op2;
			if(is_mul==1) begin
				op1= word_flag==1? zeroExtend(in1[31:0]):{1'b0,in1};
				op2= word_flag==1? zeroExtend(in2[31:0]):{1'b0,in2};
			end
			else begin
				op1= word_flag==1? (funct3[0]==0?signExtend(in1[31:0]):zeroExtend(in1[31:0])): ({in1[63],in1[63:0]});
                op2= word_flag==1?(funct3[0]==0?signExtend(in2[31:0]):zeroExtend(in2[31:0])):({in2[63],in2[63:0]});

				op1=(funct3[0]==0 && op1[`Reg_width]==1)?~op1[`Reg_width-1:0]+1:op1[`Reg_width-1:0];
				op2=(funct3[0]==0 && op2[`Reg_width]==1)?~op2[`Reg_width-1:0]+1:op2[`Reg_width-1:0];
			end

			rg_word_flag<=word_flag;
			rg_is_mul<= unpack(is_mul);
			Bool op1_31_to_0_is_zero= (op1[31:0]==0);
			Bool op2_31_to_0_is_zero= (op2[31:0]==0);
			Bool op1_is_zero= word_flag==1? op1_31_to_0_is_zero:(op1[63:0]==0 && op1_31_to_0_is_zero);
			Bool op2_is_zero= word_flag==1? op2_31_to_0_is_zero:(op2[63:0]==0 && op2_31_to_0_is_zero);

			if(is_mul==0 && op2_is_zero) begin
				if(funct3[1]==1) begin	//REM/REMU operation
					if(word_flag==1)
						ff_muldiv_result.enq(signExtend(in1[31:0]));
					else
						ff_muldiv_result.enq(in1);
				end
				else begin				//DIV/DIVU operation
					ff_muldiv_result.enq('1);
				end
			end
			else if(op1_is_zero) begin
				ff_muldiv_result.enq(0);
				rg_signed<=False;
			end
			else begin 
				if(funct3==0) begin
					upper_bits<=False;		//used only for MUL
					if(is_mul==1)
						rg_signed<=op1[`Reg_width-1]!=op2[`Reg_width-1];
					else
						rg_signed<=op1[`Reg_width]!=op2[`Reg_width];
				end
				else begin
					upper_bits<=True;		//used only for MUL
					if(is_mul==1)
						rg_signed<=unpack(in1_sign);
					else
						rg_signed<= False;
				end

				if(is_mul==1) begin
					//Bit#(73) product<- wrapper_mul_1.func({1'b0,op1[7:0]}, {in2_sign,op2[`Reg_width-1:0]});
					////Bit#(73) new_accum<- wrapper_add_1.func(accumulator[1][136:64],product);
					//Bit#(137) x = {product,op1[`Reg_width-1:0]};
					//Int#(137) y = unpack(x);
					//y=y>>8;
					//x=pack(y);
					//`ifdef verbose $display("--- in1: %h in2: %h out: %h", {in2_sign,op2[7:0]}, op1, x); `endif
					//Bool earlyout<- wrapper_is_op_zero.func(op1[63:8],rg_count[1]);
					//if(earlyout) begin
					//	y=unpack(x);
					//	x=pack(y>>7*8);
					//	if(word_flag==1)
					//		x=signExtend(x[31:0]);
					//	if(funct3!=0)	//Upper bits
					//		ff_muldiv_result.enq(x[2*`Reg_width-1:`Reg_width]);
					//	else
					//		ff_muldiv_result.enq(x[`Reg_width-1:0]);
					//end
					//else begin
						rg_result_sign<=op1[`Reg_width-1];
						temp_multiplier_sign<=0;
						multiplicand_divisor<={in2_sign,op2[63:0]};
						accumulator<=zeroExtend(op1[63:0]);
						rg_count[1]<=7;
					//end
					//`ifdef verbose $display($time,"\tAccumulator: %h Multiplicand: %h rg_count: %d",x,{in2_sign,op2[63:0]},rg_count[1]); `endif
				end
				else begin
					accumulator<= zeroExtend(op1[63:0]);
					rg_state_counter[1]<=1;
					rg_count[1]<= 4;
					multiplicand_divisor<= op2;
					rg_result_sign<= op1[`Reg_width];
					rg_funct3<= funct3;
				end
			end
		endrule

		method Action input_operands(Bit#(`Reg_width) in1, Bit#(`Reg_width) in2, Bit#(2) funct3, Bit#(1) word_flag, Bit#(1) is_mul) if(rg_count[1]==8);
			ff_input.enq(tuple5(in1,in2,funct3,word_flag,is_mul));
		endmethod
		method ActionValue#(Bit#(`Reg_width)) muldiv_result;
			ff_muldiv_result.deq;
			return ff_muldiv_result.first();
		endmethod
		method Action flush;
			rg_count[0]<=8;
			rg_state_counter[0]<= 0;
		endmethod
	endmodule

	module mkTb(Empty);
		Ifc_muldiv muldiv <-mkmuldiv();
		UInt#(128) op1 = 'hfffffffffffffadb;//'h868c3b620d9a5d2c;//fffffffffffffbde;//'h8000000000000000; //'hfffffffffffffaef;//'h0000000000040000;//000000000fffff8a;//01d9a0aea837b4df;
		UInt#(128) op2 = 'h000000000000004e;//'h868c3b620d9a5d2c;//fffffffffffffbde;//'h8000000000000000; //'hfffffffffffffaef;//'h000000003b48acdb;//fffffffffffff8d5;//04b8d2eb05855afa;
		Bit#(2) funct=0;
		UInt#(128) y = op1*op2;
		Reg#(Bit#(32)) rg_clk <- mkReg(0);
		rule give_ip;
			`ifdef verbose $display($time," Giving Inputs : Op1: %d Op2: %d",op1,op2); `endif
			muldiv.input_operands(pack(truncate(op1)),pack(truncate(op2)),funct,1,0);
		endrule

		rule get_out;
			let x <-muldiv.muldiv_result;
			`ifdef verbose $display($time," Output: %h Expected: %h Match: %b",x,y,(zeroExtend(x)==pack(y))); `endif
			$finish(0);
		endrule

		rule rl_clk;
			rg_clk<= rg_clk+1;
			if(rg_clk=='d100)
				$finish(0);
		endrule
	endmodule
endpackage
