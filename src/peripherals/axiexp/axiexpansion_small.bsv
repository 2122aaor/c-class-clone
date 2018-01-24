package axiexpansion_small;
	/*=== Package imports === */
	import FIFO::*;
	import FIFOF::*;
	import SpecialFIFOs::*;
	import BUtils::*;
	import Connectable::*;
	import GetPut::*;
	/*==== Project imports === */
	import defined_types::*;
	`include "defined_parameters.bsv"
	import Semi_FIFOF        :: *;
	import AXI4_Types   :: *;
	import AXI4_Fabric  :: *;
	/*======================== */

	/*=== Type of info to be capture by slave=== */
	typedef struct{
		Bit#(`Reg_width) data;
		Bit#(`PADDR) address;
		Bit#(2) burstmode; // 52:53
		Bit#(3) size;		// 49:51
		Bit#(8) burstlen; // 41:48
		Bit#(8) wrstrb; //33:40
		Bit#(1) wlast; //32
	} SlaveReq deriving (Bits,Eq,FShow);
	/*=============================================== */
	typedef enum {SendReadAddress1, SendReadAddress2, SendWriteAddress2, SendWriteAddress1, SendWriteData1, SendWriteData2, SendWriteResponse,ReceiveReadData1, ReceiveReadData2, Idle} State deriving (Bits,Eq,FShow);

	interface Ifc_AxiExpansion;
		interface AXI4_Slave_IFC#(`PADDR,`Reg_width,`USERSPACE) axi_slave;
		// 1-bit indicating slave response or master request , 2 bits for slverror, 64-info signals, 
	//	method ActionValue#(Bit#(67)) slave_out;
		interface Get#(Bit#(35)) slave_out;
		// 1-bit indicating slave response or master request , 2 bits for slverror, 64-info signals, 
		interface Put#(Bit#(35)) slave_in;
		//method ActionValue slave_in(Bit#(67) datain);
	endinterface

	(*synthesize*)
	(*preempts="receive_from_AXIWrite_request,receive_from_AXIRead_request"*)
	module mkAxiExpansion(Ifc_AxiExpansion);
		AXI4_Slave_Xactor_IFC #(`PADDR, `Reg_width, `USERSPACE)  slave_xactor <- mkAXI4_Slave_Xactor;
		FIFO#(SlaveReq) capture_slave_req <-mkLFIFO();
		FIFO#(Bit#(35)) send_slave_req <-mkLFIFO();
		Wire#(Maybe#(Bit#(35))) wr_receive_slavedata<-mkDWire(tagged Invalid);
		FIFO#(Bit#(35)) ff_receive_slavedata<-mkLFIFO;

		Reg#(Bit#(8)) rg_readburst_counter<-mkReg(0);
		Reg#(Bit#(8)) rg_writeburst_counter<-mkReg(0);
		Reg#(Bit#(8)) rg_readburst_value<-mkReg(0);
		Reg#(Bit#(4)) rg_id<-mkReg(0);
		Reg#(Bit#(32)) received_read_data<-mkReg(0);

		Reg#(Bit#(32)) rg_prescale <-mkReg(0);
		Reg#(Bit#(32)) rg_count <-mkReg(0);

		Reg#(State) rg_state<-mkReg(Idle);

		rule counter;
			$display($time,"\tAXIEXP: State: ",fshow(rg_state));
			if(rg_count==rg_prescale)
				rg_count<=0;
			else
				rg_count<=rg_count+1;
		endrule
		/*============================= Write channel logic =========== */	
		rule receive_from_AXIWrite_request(rg_state==Idle);
			let aw <- pop_o (slave_xactor.o_wr_addr);
			let w  <- pop_o (slave_xactor.o_wr_data);
			let b = AXI4_Wr_Resp {bresp: AXI4_OKAY, buser:?, bid:aw.awid};
			if(aw.awaddr=='hFFFFFFFF)begin
				rg_prescale<=truncate(w.wdata);
				slave_xactor.i_wr_resp.enq (b);
				rg_state<=Idle;
			end
			else begin
				capture_slave_req.enq(SlaveReq{
					data:w.wdata,
					address:aw.awaddr,
					burstmode:aw.awburst,
					size:aw.awsize,
					burstlen:aw.awlen,
					wrstrb:w.wstrb,
					wlast:pack(w.wlast)});	
				rg_writeburst_counter<=aw.awlen;
				rg_state<=SendWriteAddress1;
				rg_id<=aw.awid;
			end
		endrule
		rule send_slave_writerequest1(rg_state==SendWriteAddress1);
			let x=capture_slave_req.first;
			send_slave_req.enq({1'b1,2'd0,x.address[31:0]});
			//send_slave_req.enq({1'b1,2'd0,10'd0,x.burstmode,x.size,x.burstlen,x.wrstrb,x.wlast,x.address[31:0]});
			rg_state<=SendWriteAddress2;
		endrule
		rule send_slave_writerequest2(rg_state==SendWriteAddress2);
			let x=capture_slave_req.first;
			send_slave_req.enq({1'b1,2'd0,10'd0,x.burstmode,x.size,x.burstlen,x.wrstrb,x.wlast});
			rg_state<=SendWriteData1;
		endrule
		rule pop_burst_write_request_from_AXI(rg_state==SendWriteData2);
			let aw <- pop_o (slave_xactor.o_wr_addr);
			let w  <- pop_o (slave_xactor.o_wr_data);
			capture_slave_req.enq(SlaveReq{
				data:w.wdata,
				address:aw.awaddr,
				burstmode:aw.awburst,
				size:aw.awsize,
				burstlen:aw.awlen,
				wrstrb:w.wstrb,
				wlast:pack(w.wlast)});	
		endrule
		rule send_slave_writedata1(rg_state==SendWriteData1);
			let x=capture_slave_req.first;
			send_slave_req.enq({1'b1,2'd1,x.data[31:0]});
			rg_state<=SendWriteData2;
		endrule
		rule send_slave_writedata2(rg_state==SendWriteData2);
			let x=capture_slave_req.first;
			send_slave_req.enq({1'b1,2'd1,x.data[63:32]});
			if(x.wlast==1)begin
				rg_state<=SendWriteResponse;
			end
			capture_slave_req.deq;
		endrule
		rule send_slave_writeresponse(rg_state==SendWriteResponse && ff_receive_slavedata.first[34]==0);
			let b = AXI4_Wr_Resp {bresp: unpack(ff_receive_slavedata.first[33:32]), buser:?, bid:rg_id};
			ff_receive_slavedata.deq;
			slave_xactor.i_wr_resp.enq (b);
			rg_state<=Idle;
		endrule
		/*============================================================ */

		/*============================= Read channel logic =========== */	
		rule receive_from_AXIRead_request(rg_state==Idle);
			let ar<- pop_o(slave_xactor.o_rd_addr);
			AXI4_Rd_Data#(`Reg_width,`USERSPACE) r = AXI4_Rd_Data {rresp: AXI4_OKAY, rdata: duplicate(rg_prescale) ,rlast:True, ruser: 0, rid:ar.arid};
			$display($time,"\tAXIEXP: Recieved Read reques from AXI for address: %h",ar.araddr);
			if(ar.araddr=='hFFFFFFFF)begin
				slave_xactor.i_rd_data.enq(r);
				rg_state<=Idle;
			end
			else begin
				capture_slave_req.enq(SlaveReq{
					data:0,
					address:ar.araddr,
					burstmode:ar.arburst,
					size:ar.arsize,
					burstlen:ar.arlen,
					wrstrb:0,
					wlast:0});	
				rg_readburst_value<=ar.arlen;
				rg_state<=SendReadAddress1;
				rg_id<=ar.arid;
			end
		endrule
		rule send_slave_readrequest1(rg_state==SendReadAddress1);
			let x=capture_slave_req.first;
			send_slave_req.enq({1'b1,2'd2,x.address[31:0]});
			$display($time,"\tAXIEXP: READ: Sending Address: %h",x.address[31:0]);
			//send_slave_req.enq({1'b1,2'd2,10'd0,x.burstmode,x.size,x.burstlen,x.wrstrb,x.wlast,x.address[31:0]});
			rg_state<=SendReadAddress2;
		endrule
		rule send_slave_readrequest2(rg_state==SendReadAddress2);
			let x=capture_slave_req.first;
			send_slave_req.enq({1'b1,2'd2,10'd0,x.burstmode,x.size,x.burstlen,x.wrstrb,x.wlast});
			$display($time,"\tAXIEXP: READ: Sending Metadata: ",fshow(x));
			capture_slave_req.deq;
			rg_state<=ReceiveReadData1;
		endrule
		rule send_axiread_slave_response1(rg_state==ReceiveReadData1 && ff_receive_slavedata.first[34]==0);
			ff_receive_slavedata.deq;
			received_read_data[31:0]<=ff_receive_slavedata.first[31:0];
			rg_state<=ReceiveReadData2;
		endrule
		rule send_axiread_slave_response2(rg_state==ReceiveReadData2 && ff_receive_slavedata.first[34]==0);
			AXI4_Rd_Data#(`Reg_width,`USERSPACE) r = AXI4_Rd_Data {rresp: AXI4_OKAY, rdata: {ff_receive_slavedata.first[31:0],received_read_data} ,rlast:rg_readburst_counter==rg_readburst_value, ruser: 0, rid:rg_id};
			ff_receive_slavedata.deq;
			if(ff_receive_slavedata.first[33:32]!=0)
				r.rresp=unpack(ff_receive_slavedata.first[33:32]);
			slave_xactor.i_rd_data.enq(r);
			if(rg_readburst_counter==rg_readburst_value)begin
				rg_readburst_counter<=0;
			end
			else begin
				rg_readburst_counter<=rg_readburst_counter+1;
			end
			rg_state<=Idle;
		endrule
		/*============================================================ */

		interface axi_slave= slave_xactor.axi_side;
		interface slave_out= interface Get
			method ActionValue#(Bit#(35)) get;
				send_slave_req.deq;
				return send_slave_req.first;
			endmethod
		endinterface;
		interface slave_in=interface Put
			method Action put (Bit#(35) datain); 
				ff_receive_slavedata.enq(datain);
			endmethod
		endinterface;
	endmodule
endpackage