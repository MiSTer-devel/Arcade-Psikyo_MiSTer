`timescale 1ns/1ps
// TL-fade probe for rtl/sound/opl4/. One channel plays a DC wave (every
// sample byte 0x40) so the output level IS the channel gain, then the total
// level register is written with LD=0 and the interpolated level is logged
// every 25 samples. ymfm_pcm.cpp:293-300 is the reference: the level moves
// toward the target at +19/1024 per sample (quieter) and -38/1024 (louder),
// so 0 -> 0x40 takes about 3450 samples and 0x7F -> 0 about 3420.
//
// The same sequence drives srg320's YMF278B.sv in the PsikyoSH2 core, so
// the two logs can be compared line for line.
module tb_opl4_fade;

	logic clk = 0;
	always #5 clk = ~clk;
	localparam int SAMPLE = 1948;   // clk_sys cycles per 44.1 kHz sample
	logic reset;

	logic        cs, rd, wr;
	logic [2:0]  addr;
	logic [7:0]  din;
	logic [7:0]  dout;
	logic        irq_n;
	logic        mem_rd_req, mem_rd_valid;
	logic [21:0] mem_rd_addr;
	logic [7:0]  mem_rd_data;
	logic signed [15:0] snd_l, snd_r;
	logic        dbg_fm_wr, dbg_fm_keyon, dbg_pcm_keyon;

	opl4 dut (.*);

	// ---- wave ROM: header as tb_opl4.sv, DC sample data ----
	function automatic [7:0] rom_byte(input [21:0] a);
		case (a)
			22'd0:  rom_byte = 8'h00;   // fmt=0, base[21:16]=0
			22'd1:  rom_byte = 8'h10;   // base[15:8]
			22'd2:  rom_byte = 8'h00;   // base[7:0]
			22'd3:  rom_byte = 8'h00;   // loop hi
			22'd4:  rom_byte = 8'h10;   // loop lo
			22'd5:  rom_byte = 8'hFF;   // -end hi   (-0x20 = 0xFFE0)
			22'd6:  rom_byte = 8'hE0;   // -end lo
			22'd7:  rom_byte = 8'h00;   // LFO/VIB
			22'd8:  rom_byte = 8'hF0;   // AR=15 DR=0
			22'd9:  rom_byte = 8'h00;   // SL=0 SR=0
			22'd10: rom_byte = 8'hFF;   // RC=15 RR=15
			22'd11: rom_byte = 8'h00;   // AM
			default: rom_byte = (a >= 22'h001000 && a < 22'h001100) ? 8'h40 : 8'h00;
		endcase
	endfunction

	logic [21:0] pend_addr;
	logic [2:0]  pend_cnt;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			pend_cnt     <= 3'd0;
			mem_rd_valid <= 1'b0;
			mem_rd_data  <= 8'd0;
		end else begin
			mem_rd_valid <= 1'b0;
			if (mem_rd_req) begin
				pend_addr <= mem_rd_addr;
				pend_cnt  <= 3'd5;
			end else if (pend_cnt != 0) begin
				pend_cnt <= pend_cnt - 3'd1;
				if (pend_cnt == 3'd1) begin
					mem_rd_data  <= rom_byte(pend_addr);
					mem_rd_valid <= 1'b1;
				end
			end
		end
	end

	// ---- bus helpers, as tb_opl4.sv ----
	task automatic bwrite(input [2:0] a, input [7:0] d);
		@(posedge clk);
		addr = a; din = d; cs = 1; wr = 1;
		repeat (6) @(posedge clk);
		wr = 0; cs = 0;
		repeat (6) @(posedge clk);
	endtask
	task automatic fm_wr(input [8:0] a, input [7:0] d);
		if (a[8]) bwrite(3'd2, a[7:0]); else bwrite(3'd0, a[7:0]);
		bwrite(a[8] ? 3'd3 : 3'd1, d);
	endtask
	task automatic pcm_wr(input [7:0] a, input [7:0] d);
		bwrite(3'd4, a);
		bwrite(3'd5, d);
	endtask

	int sample_idx = 0;
	task automatic wait_samples(input int n);
		repeat (n * SAMPLE) @(posedge clk);
		sample_idx += n;
	endtask

	int fd;
	int errors = 0;
	// Log every 25 samples and check the level only ever moves toward the
	// target: dir = -1 for a fade down, +1 for a fade up. settle_lo/hi bound
	// the sample at which the level must have stopped moving, from the
	// reference's 19 and 38 per-sample rates; 0 means "need not settle".
	task automatic log_run(input string tag, input int n, input int dir,
	                       input int settle_lo, input int settle_hi);
		int prev, start, settled;
		prev = snd_l; start = sample_idx; settled = -1;
		for (int i = 0; i < n; i += 25) begin
			wait_samples(25);
			$fdisplay(fd, "%s %0d %0d", tag, sample_idx, snd_l);
			if ((dir < 0 && snd_l > prev) || (dir > 0 && snd_l < prev)) begin
				errors++;
				$display("FAIL %s: level moved away from target at sample %0d (%0d -> %0d)",
				         tag, sample_idx, prev, snd_l);
			end
			if (settled < 0 && snd_l == prev && i > 0) settled = sample_idx - start;
			else if (snd_l != prev) settled = -1;
			prev = snd_l;
		end
		if (settle_hi != 0) begin
			if (settled < settle_lo || settled > settle_hi) begin
				errors++;
				$display("FAIL %s: settled after %0d samples, expected %0d..%0d",
				         tag, settled, settle_lo, settle_hi);
			end
		end
	endtask

	initial begin
		fd = $fopen("ours_fade.log", "w");
		reset = 1; cs = 0; rd = 0; wr = 0; addr = 0; din = 0;
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (10) @(posedge clk);

		fm_wr(9'h105, 8'h03);            // NEW + NEW2

		pcm_wr(8'h68, 8'h00);            // key off, no damp, pan 0
		pcm_wr(8'h20, 8'h00);            // fnum lo, wave bit 8 = 0
		pcm_wr(8'h38, 8'h00);            // oct 0, fnum hi 0
		pcm_wr(8'h08, 8'h00);            // wave 0 -> header load
		wait_samples(24);

		pcm_wr(8'h50, 8'h01);            // TL=0, level direct
		pcm_wr(8'h68, 8'h80);            // key on
		log_run("keyon", 200, 0, 0, 0);

		// 0 -> 0x40 at 19/1024 per sample: 64*1024/19 = 3449 samples
		pcm_wr(8'h50, 8'h80);            // TL=0x40, LD=0: fade down
		log_run("to40", 4000, -1, 3300, 3700);

		// 0x40 -> 0x7F at 19/1024 per sample: 63*1024/19 = 3395 samples. It
		// must settle before the next phase, or that phase's ramp starts short.
		pcm_wr(8'h50, 8'hFE);            // TL=0x7F, LD=0: fade to silence
		log_run("to7f", 3800, -1, 3300, 3700);

		// 0x7F -> 0 at 38/1024 per sample: 127*1024/38 = 3422 samples. The
		// last step lands 12/1024 short of the target, which is where the
		// unsigned (cur - 38) underflow used to wrap to near-max attenuation.
		pcm_wr(8'h50, 8'h00);            // TL=0, LD=0: fade back up
		log_run("to00", 4000, +1, 3300, 3700);

		$fclose(fd);
		if (errors == 0) $display("PASS: TL interpolation monotonic, settle times as reference");
		else $display("%0d CHECK(S) FAILED", errors);
		$finish;
	end

	initial begin
		#400_000_000;
		$display("FAIL: watchdog timeout");
		$finish;
	end
endmodule
