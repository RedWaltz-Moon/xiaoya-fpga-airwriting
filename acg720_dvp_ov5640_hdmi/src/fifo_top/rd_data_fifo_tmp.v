//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW5AT-LV138PG484AC1/I0
//Device: GW5AT-138
//Device Version: C
//Created Time: Thu Sep 10 19:00:09 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	rd_data_fifo your_instance_name(
		.Data(Data), //input [127:0] Data
		.Reset(Reset), //input Reset
		.WrClk(WrClk), //input WrClk
		.RdClk(RdClk), //input RdClk
		.WrEn(WrEn), //input WrEn
		.RdEn(RdEn), //input RdEn
		.Wnum(Wnum), //output [8:0] Wnum
		.Rnum(Rnum), //output [11:0] Rnum
		.Q(Q), //output [15:0] Q
		.Empty(Empty), //output Empty
		.Full(Full) //output Full
	);

//--------Copy end-------------------
